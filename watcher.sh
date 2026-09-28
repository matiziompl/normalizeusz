#!/usr/bin/env bash
# watcher.sh - Music library loudness normalization sidecar watcher (rsgain)
set -uo pipefail

MUSIC_DIR="${MUSIC_DIR:-/music}"
DEBOUNCE_SECONDS="${DEBOUNCE_SECONDS:-5}"
INITIAL_SCAN="${INITIAL_SCAN:-true}"
MAX_THREADS="${MAX_THREADS:-MAX}"
QUEUE_DIR="${QUEUE_DIR:-/tmp/music-gain/queue}"
TEST_MODE="${TEST_MODE:-false}"

mkdir -p "${QUEUE_DIR}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [music-gain] $*"
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

  # Write timestamp (line 1) and target string (line 2) atomically
  printf "%s\n%s\n" "$(date +%s)" "${target}" > "${tmp_file}"
  mv "${tmp_file}" "${queue_file}"
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

  if [[ "${type}" == "DIR" ]]; then
    log "Normalizing album directory (rsgain easy): ${target_path}"
    rsgain easy -S -m "${MAX_THREADS}" "${target_path}"
  elif [[ "${type}" == "FILE" ]]; then
    log "Normalizing single track (rsgain custom): ${target_path}"
    rsgain custom -s i -S "${target_path}"
  else
    log "Warning: Unknown target type: ${type}"
  fi
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
    target="$(sed -n '2p' "${queue_file}" 2>/dev/null || true)"

    if [[ -z "${ts}" || -z "${target}" ]]; then
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
  done

  # Scan loose files in root
  find "${MUSIC_DIR}" -mindepth 1 -maxdepth 1 -type f | while IFS= read -r file; do
    if is_audio_file "${file}"; then
      log "Initial scan: loose track '${file}'"
      rsgain custom -s i -S "${file}"
    fi
  done

  log "Initial library scan completed."
}

# Cleanup on exit
RUNNING=true
WORKER_PID=""
INOTIFY_PID=""

cleanup() {
  log "Shutting down music-gain watcher..."
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

  log "music-gain watcher service initialized."
  log "Settings: MUSIC_DIR=${MUSIC_DIR}, DEBOUNCE=${DEBOUNCE_SECONDS}s, THREADS=${MAX_THREADS}"

  initial_scan

  # Start queue worker loop in background
  (
    while [[ "${RUNNING}" == "true" ]]; do
      process_queue
      sleep 1
    done
  ) &
  WORKER_PID=$!

  log "Watching ${MUSIC_DIR} for close_write and moved_to events..."

  # Run inotifywait loop
  inotifywait -m -r -e close_write,moved_to --format '%w%f' "${MUSIC_DIR}" | while IFS= read -r file_path; do
    if is_audio_file "${file_path}"; then
      local target
      target="$(get_target "${file_path}")"
      queue_event "${target}"
    fi
  done
}

# Only run main if executed directly, not sourced during tests
if [[ "${TEST_MODE}" != "true" && "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
