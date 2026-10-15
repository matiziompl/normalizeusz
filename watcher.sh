#!/usr/bin/env bash
# watcher.sh - Music library loudness normalization sidecar watcher (rsgain / normalizeusz)
set -uo pipefail

MUSIC_DIR="${MUSIC_DIR:-/music}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"
INITIAL_SCAN="${INITIAL_SCAN:-true}"
MAX_THREADS="${MAX_THREADS:-MAX}"
QUEUE_DIR="${QUEUE_DIR:-/tmp/normalizeusz/queue}"
SCANNED_DIR="${SCANNED_DIR:-/tmp/normalizeusz/scanned}"
ECHO_COOLDOWN_SECONDS="${ECHO_COOLDOWN_SECONDS:-15}"
TEST_MODE="${TEST_MODE:-false}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
ERROR_LOG_FILE="${ERROR_LOG_FILE:-${MUSIC_DIR%/}/.normalizeusz_errors.log}"

mkdir -p "${QUEUE_DIR}" "${SCANNED_DIR}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [normalizeusz] $*"
}

# Determine if a file is a temporary or hidden file
is_temp_file() {
  local filename
  filename="$(basename "$1")"
  # Hidden dot-files (e.g. .syncthing*, .DS_Store)
  if [[ "${filename}" =~ ^\. ]]; then
    return 0
  fi
  # Temporary extensions
  if [[ "${filename}" =~ \.(part|tmp|crdownload)$ ]]; then
    return 0
  fi
  return 1
}

# Determine if a file is a supported audio file
is_audio_file() {
  local filepath="$1"
  if is_temp_file "${filepath}"; then
    return 1
  fi

  # Check supported extensions case-insensitively
  local ext="${filepath##*.}"
  case "${ext,,}" in
    mp3|flac|opus|ogg|m4a)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Determine the normalization target:
# - Root file: FILE:<path> (track gain only via rsgain custom)
# - Subdirectory: DIR:<directory> (album gain & track gain via rsgain easy)
get_target() {
  local filepath="$1"
  local parent_dir
  parent_dir="$(dirname "${filepath}")"

  # Normalize paths by removing trailing slash
  local norm_music_dir="${MUSIC_DIR%/}"
  local norm_parent_dir="${parent_dir%/}"

  if [[ "${norm_parent_dir}" == "${norm_music_dir}" ]]; then
    echo "FILE:${filepath}"
  else
    echo "DIR:${parent_dir}"
  fi
}

# Enqueue an event for a target with debounce timestamp
queue_event() {
  local target="$1"
  # Compute safe filename hash for the target path
  local hash
  hash="$(printf "%s" "${target}" | md5sum | awk '{print $1}')"
  local queue_file="${QUEUE_DIR}/${hash}"
  local tmp_file="${QUEUE_DIR}/.${hash}.tmp"

  # Write timestamp (line 1) and target string (lines 2+) atomically
  printf "%s\n%s\n" "$(date +%s)" "${target}" > "${tmp_file}"
  mv "${tmp_file}" "${queue_file}"
}

# Handle an inotify filesystem event
handle_event() {
  local event_path="$1"
  local target=""

  if [[ -d "${event_path}" ]]; then
    # Directory moved_to event (e.g. atomic move of an album directory)
    local norm_music_dir="${MUSIC_DIR%/}"
    local norm_event_dir="${event_path%/}"
    if [[ "${norm_event_dir}" != "${norm_music_dir}" ]]; then
      target="DIR:${event_path}"
    fi
  elif is_audio_file "${event_path}"; then
    target="$(get_target "${event_path}")"
  fi

  [[ -n "${target}" ]] || return 0

  # Echo suppression check:
  # If this target was scanned recently by normalizeusz itself, ignore the inotify echo
  local hash
  hash="$(printf "%s" "${target}" | md5sum | awk '{print $1}')"
  local scanned_file="${SCANNED_DIR}/${hash}"
  if [[ -f "${scanned_file}" ]]; then
    local last_scan
    last_scan="$(head -n 1 "${scanned_file}" 2>/dev/null || true)"
    if [[ -n "${last_scan}" && "${last_scan}" =~ ^[0-9]+$ ]]; then
      local now
      now="$(date +%s)"
      local diff=$(( now - last_scan ))
      if (( diff < ECHO_COOLDOWN_SECONDS )); then
        # Echo event from rsgain write - ignore
        return 0
      fi
    fi
  fi

  queue_event "${target}"
}

# Mark a target as recently scanned to prevent self-trigger inotify feedback
mark_scanned() {
  local target="$1"
  local hash
  hash="$(printf "%s" "${target}" | md5sum | awk '{print $1}')"
  date +%s > "${SCANNED_DIR}/${hash}"
}

# Escape strings safely for JSON payloads
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf "%s" "${s}"
}

# Resolve Discord webhook URL from environment or fallback files
get_discord_webhook_url() {
  if [[ -n "${DISCORD_WEBHOOK_URL}" ]]; then
    printf "%s" "${DISCORD_WEBHOOK_URL}"
    return 0
  fi
  if [[ -f "${MUSIC_DIR%/}/.discord_webhook" ]]; then
    head -n 1 "${MUSIC_DIR%/}/.discord_webhook" 2>/dev/null | tr -d '\r\n'
    return 0
  fi
  if [[ -f "/etc/normalizeusz/discord_webhook" ]]; then
    head -n 1 "/etc/normalizeusz/discord_webhook" 2>/dev/null | tr -d '\r\n'
    return 0
  fi
  printf ""
}

# Append failure details to dead-letter error log file
log_error_ledger() {
  local target_path="$1"
  local reason="$2"
  local raw_error="$3"

  local log_dir
  log_dir="$(dirname "${ERROR_LOG_FILE}")"
  if [[ -w "${log_dir}" || -w "${ERROR_LOG_FILE}" || ! -e "${ERROR_LOG_FILE}" ]]; then
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local clean_error
    clean_error="$(printf "%s" "${raw_error}" | tr '\r\n' ' ')"
    printf "[%s] FAILED: %s | Reason: %s | Error: %s\n" "${ts}" "${target_path}" "${reason}" "${clean_error}" >> "${ERROR_LOG_FILE}" 2>/dev/null || true
  fi
}

# Send structured Discord webhook embed
send_discord_alert() {
  local target_path="$1"
  local reason="$2"
  local raw_error="$3"

  local webhook_url
  webhook_url="$(get_discord_webhook_url)"
  [[ -n "${webhook_url}" ]] || return 0

  if (( ${#raw_error} > 950 )); then
    raw_error="${raw_error:0:950}..."
  fi

  local esc_target esc_reason esc_error
  esc_target="$(json_escape "${target_path}")"
  esc_reason="$(json_escape "${reason}")"
  esc_error="$(json_escape "${raw_error}")"
  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")"

  local payload
  payload=$(cat <<EOF
{
  "embeds": [
    {
      "title": "🎵 normalizeusz: Błąd normalizacji głośności",
      "description": "Nie udało się zapisać tagów ReplayGain 2.0 dla elementu.",
      "color": 15158332,
      "fields": [
        {
          "name": "📁 Ścieżka",
          "value": "\`${esc_target}\`",
          "inline": false
        },
        {
          "name": "⚠️ Przyczyna",
          "value": "${esc_reason}",
          "inline": false
        },
        {
          "name": "📝 Szczegóły błędu (rsgain)",
          "value": "\`\`\`\n${esc_error}\n\`\`\`",
          "inline": false
        }
      ],
      "footer": {
        "text": "normalizeusz • Serweusz"
      },
      "timestamp": "${timestamp}"
    }
  ]
}
EOF
)

  curl -s -S -X POST \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${webhook_url}" >/dev/null 2>&1 || log "Warning: Failed to deliver Discord webhook notification."
}

# Handle normalization failure
notify_failure() {
  local target_path="$1"
  local raw_error="$2"

  local reason="Błąd podczas przetwarzania przez rsgain"
  if [[ "${raw_error}" =~ "Couldn't write to" ]] || [[ ! -w "${target_path}" ]]; then
    reason="Brak uprawnień do zapisu pliku (plik należy do innego użytkownika, np. root:root). Rozwiązanie na Serweuszu: sudo chown -R mateusz:mateusz ~/media/music"
  fi

  log "ERROR: Normalization failed for ${target_path}: ${reason}"
  log_error_ledger "${target_path}" "${reason}" "${raw_error}"
  send_discord_alert "${target_path}" "${reason}" "${raw_error}"
}

# Execute rsgain on the target
run_scan_target() {
  local target="$1"
  local type="${target%%:*}"
  local target_path="${target#*:}"

  if [[ ! -e "${target_path}" ]]; then
    log "Notice: Target path no longer exists (removed or moved): ${target_path}"
    return 0
  fi

  # Check write permissions before running rsgain
  if [[ ! -w "${target_path}" ]]; then
    notify_failure "${target_path}" "Path is not writable by current user ($(id -u 2>/dev/null || true):$(id -g 2>/dev/null || true)). File/directory owned by another user or read-only."
    return 1
  fi

  local scan_output=""
  local scan_exit=0

  if [[ "${type}" == "DIR" ]]; then
    log "Normalizing album directory (rsgain easy): ${target_path}"
    scan_output="$(rsgain easy -S -m "${MAX_THREADS}" "${target_path}" 2>&1)" || scan_exit=$?
  elif [[ "${type}" == "FILE" ]]; then
    log "Normalizing single track (rsgain custom): ${target_path}"
    scan_output="$(rsgain custom -s i -S "${target_path}" 2>&1)" || scan_exit=$?
  else
    log "Warning: Unknown target type: ${type}"
    return 0
  fi

  if [[ -n "${scan_output}" ]]; then
    echo "${scan_output}"
  fi

  # Detect rsgain errors or file write failures
  if (( scan_exit != 0 )) || [[ "${scan_output}" =~ "Couldn't write to" ]] || [[ "${scan_output}" =~ "\[ERROR\]" ]]; then
    notify_failure "${target_path}" "${scan_output:-Exit code ${scan_exit}}"
    return 1
  fi

  # Record completion timestamp so self-writes do not re-queue this target
  mark_scanned "${target}"
}

# Process the queue, executing rsgain for items that stabilized past DEBOUNCE_SECONDS
process_queue() {
  local now
  now="$(date +%s)"

  for queue_file in "${QUEUE_DIR}"/*; do
    [[ -f "${queue_file}" ]] || continue

    local ts
    ts="$(head -n 1 "${queue_file}" 2>/dev/null || true)"
    local target
    target="$(tail -n +2 "${queue_file}" 2>/dev/null || true)"

    # Validate that timestamp exists and is numeric, and target is non-empty
    if [[ -z "${ts}" || ! "${ts}" =~ ^[0-9]+$ || -z "${target}" ]]; then
      rm -f "${queue_file}"
      continue
    fi

    local elapsed=$(( now - ts ))
    if (( elapsed >= DEBOUNCE_SECONDS )); then
      # Remove from queue before execution to prevent duplicate triggers
      rm -f "${queue_file}"
      run_scan_target "${target}"
    fi
  done
}

# Full library initial scan
initial_scan() {
  if [[ "${INITIAL_SCAN}" != "true" ]]; then
    log "Initial scan disabled via configuration."
    return 0
  fi

  log "Starting initial library scan in ${MUSIC_DIR}..."

  # Scan subdirectories as albums
  find "${MUSIC_DIR}" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r dir; do
    log "Initial scan: album directory '${dir}'"
    rsgain easy -S -m "${MAX_THREADS}" "${dir}"
    mark_scanned "DIR:${dir}"
  done

  # Scan loose files in root
  find "${MUSIC_DIR}" -mindepth 1 -maxdepth 1 -type f | while IFS= read -r file; do
    if is_audio_file "${file}"; then
      log "Initial scan: loose track '${file}'"
      rsgain custom -s i -S "${file}"
      mark_scanned "FILE:${file}"
    fi
  done

  log "Initial library scan completed."
}

# Cleanup on exit
RUNNING=true
WORKER_PID=""
INOTIFY_PID=""

cleanup() {
  log "Shutting down normalizeusz watcher..."
  RUNNING=false
  if [[ -n "${WORKER_PID}" ]]; then
    kill "${WORKER_PID}" 2>/dev/null || true
  fi
  if [[ -n "${INOTIFY_PID}" ]]; then
    kill "${INOTIFY_PID}" 2>/dev/null || true
  fi
  exit 0
}

# Main execution loop
main() {
  trap cleanup SIGTERM SIGINT SIGQUIT EXIT

  # Clean any stale queue entries on startup to prevent stale restart loops
  rm -rf "${QUEUE_DIR:?}"/* "${SCANNED_DIR:?}"/* 2>/dev/null || true

  log "normalizeusz watcher service initialized."
  log "Settings: MUSIC_DIR=${MUSIC_DIR}, DEBOUNCE=${DEBOUNCE_SECONDS}s, THREADS=${MAX_THREADS}"

  # Start queue worker loop in background
  (
    while [[ "${RUNNING}" == "true" ]]; do
      process_queue
      sleep 1
    done
  ) &
  WORKER_PID=$!

  log "Watching ${MUSIC_DIR} for close_write and moved_to events..."

  # Start inotifywait loop in background
  (
    inotifywait -m -r -e close_write,moved_to --format '%w%f' "${MUSIC_DIR}" | while IFS= read -r file_path; do
      handle_event "${file_path}"
    done
  ) &
  INOTIFY_PID=$!

  # Perform initial scan while watcher is already actively listening
  initial_scan

  # Wait on background processes to allow signals to be handled immediately
  wait -n "${WORKER_PID}" "${INOTIFY_PID}" 2>/dev/null || true
}

# Only run main if executed directly, not sourced during tests
if [[ "${TEST_MODE}" != "true" && "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
