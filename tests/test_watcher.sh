#!/usr/bin/env bash
# tests/test_watcher.sh - Unit test suite for music-gain watcher.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WATCHER_SCRIPT="${REPO_DIR}/watcher.sh"

FAILED=0
PASSED=0

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "  [PASS] ${desc}"
    ((PASSED++)) || true
  else
    echo "  [FAIL] ${desc}"
    echo "         Expected: '${expected}'"
    echo "         Actual:   '${actual}'"
    ((FAILED++)) || true
  fi
}

assert_exit_code() {
  local desc="$1"
  local expected_code="$2"
  shift 2
  local actual_code=0
  "$@" >/dev/null 2>&1 || actual_code=$?
  if [[ "${expected_code}" -eq "${actual_code}" ]]; then
    echo "  [PASS] ${desc}"
    ((PASSED++)) || true
  else
    echo "  [FAIL] ${desc} (Expected exit code ${expected_code}, got ${actual_code})"
    ((FAILED++)) || true
  fi
}

echo "=== Running music-gain watcher test suite ==="

# Pre-check: Ensure watcher.sh exists and source it in test mode
if [[ ! -f "${WATCHER_SCRIPT}" ]]; then
  echo "FATAL: ${WATCHER_SCRIPT} not found!"
  exit 1
fi

export TEST_MODE=true
export MUSIC_DIR="/music"
export DEBOUNCE_SECONDS=2
export MAX_THREADS="MAX"
TEST_QUEUE_DIR="$(mktemp -d /tmp/music_gain_test_queue.XXXXXX)"
export QUEUE_DIR="${TEST_QUEUE_DIR}"

cleanup_test() {
  rm -rf "${TEST_QUEUE_DIR}"
}
trap cleanup_test EXIT

# Source the watcher functions
# shellcheck source=/dev/null
source "${WATCHER_SCRIPT}"

echo
echo "--- Testing: File Filtering (is_audio_file & is_temp_file) ---"
assert_exit_code "is_audio_file accepts mp3" 0 is_audio_file "track.mp3"
assert_exit_code "is_audio_file accepts uppercase FLAC" 0 is_audio_file "SONG.FLAC"
assert_exit_code "is_audio_file accepts opus" 0 is_audio_file "track.opus"
assert_exit_code "is_audio_file accepts ogg" 0 is_audio_file "track.ogg"
assert_exit_code "is_audio_file accepts m4a" 0 is_audio_file "track.m4a"
assert_exit_code "is_audio_file accepts spaces & special chars" 0 is_audio_file "01 - L'Amour [2024] (Live).flac"
assert_exit_code "is_audio_file rejects txt" 1 is_audio_file "notes.txt"
assert_exit_code "is_audio_file rejects jpg" 1 is_audio_file "cover.jpg"
assert_exit_code "is_audio_file rejects .part file" 1 is_audio_file "track.mp3.part"
assert_exit_code "is_audio_file rejects .tmp file" 1 is_audio_file "track.flac.tmp"
assert_exit_code "is_audio_file rejects .crdownload file" 1 is_audio_file "track.mp3.crdownload"
assert_exit_code "is_audio_file rejects hidden dot files" 1 is_audio_file ".hidden.mp3"

assert_exit_code "is_temp_file identifies .part" 0 is_temp_file "file.mp3.part"
assert_exit_code "is_temp_file identifies .tmp" 0 is_temp_file "file.tmp"
assert_exit_code "is_temp_file identifies .crdownload" 0 is_temp_file "file.mp3.crdownload"
assert_exit_code "is_temp_file identifies hidden dotfile" 0 is_temp_file ".syncthing.track.flac"
assert_exit_code "is_temp_file rejects regular flac" 1 is_temp_file "track.flac"

echo
echo "--- Testing: Target Extraction (get_target) ---"
assert_eq "Root file resolves to FILE: target" "FILE:/music/single_song.mp3" "$(get_target "/music/single_song.mp3")"
assert_eq "Root file with spaces resolves to FILE: target" "FILE:/music/01 - Artist - Song.flac" "$(get_target "/music/01 - Artist - Song.flac")"
assert_eq "Subfolder file resolves to DIR: target" "DIR:/music/Pink Floyd/The Wall" "$(get_target "/music/Pink Floyd/The Wall/01 - Mother.flac")"
assert_eq "Nested subfolder resolves to DIR: target" "DIR:/music/Pink Floyd/The Wall/CD1" "$(get_target "/music/Pink Floyd/The Wall/CD1/01.mp3")"
assert_eq "Special characters in path resolved properly" "DIR:/music/AC/DC/Back In Black [1980]" "$(get_target "/music/AC/DC/Back In Black [1980]/01 - Hells Bells.mp3")"

echo
echo "--- Testing: Queue Management & Debounce Execution ---"
# Set up a mock rsgain in PATH
MOCK_BIN_DIR="$(mktemp -d /tmp/music_gain_mock_bin.XXXXXX)"
MOCK_LOG="${MOCK_BIN_DIR}/rsgain_mock.log"
cat << 'EOF' > "${MOCK_BIN_DIR}/rsgain"
#!/usr/bin/env bash
echo "$@" >> "${MOCK_LOG_FILE}"
EOF
chmod +x "${MOCK_BIN_DIR}/rsgain"
export MOCK_LOG_FILE="${MOCK_LOG}"
export PATH="${MOCK_BIN_DIR}:${PATH}"

# Test scan execution for DIR
run_scan_target "DIR:/music/Artist/Album"
assert_eq "rsgain easy called for DIR target" "easy -S -m MAX /music/Artist/Album" "$(tail -n 1 "${MOCK_LOG}")"

# Test scan execution for FILE
run_scan_target "FILE:/music/single_song.mp3"
assert_eq "rsgain custom called for FILE target" "custom -s i -S /music/single_song.mp3" "$(tail -n 1 "${MOCK_LOG}")"

# Test queue enqueuing and debounce timing
rm -f "${MOCK_LOG}"
queue_event "DIR:/music/Artist/Album"
assert_eq "Queue entry created" "1" "$(find "${QUEUE_DIR}" -type f | wc -l | tr -d ' ')"

# Process queue immediately (elapsed < DEBOUNCE_SECONDS) -> should NOT trigger scan
process_queue
assert_eq "Process queue skipped before debounce expires" "0" "$(if [[ -f "${MOCK_LOG}" ]]; then wc -l < "${MOCK_LOG}" | tr -d ' '; else echo "0"; fi)"
assert_eq "Queue entry still present" "1" "$(find "${QUEUE_DIR}" -type f | wc -l | tr -d ' ')"

# Artificially age the queue item (simulate time passing past DEBOUNCE_SECONDS)
QUEUE_FILE="$(find "${QUEUE_DIR}" -type f | head -n 1)"
OLD_TIME=$(( $(date +%s) - DEBOUNCE_SECONDS - 2 ))
# Write aged timestamp into queue file
echo "${OLD_TIME}" > "${QUEUE_FILE}.ts"
mv "${QUEUE_FILE}.ts" "${QUEUE_FILE}"

# Now process queue -> should trigger scan and remove queue item
process_queue
assert_eq "rsgain easy executed after debounce" "easy -S -m MAX /music/Artist/Album" "$(tail -n 1 "${MOCK_LOG}")"
assert_eq "Queue entry removed after processing" "0" "$(find "${QUEUE_DIR}" -type f | wc -l | tr -d ' ')"

# Clean mock bin
rm -rf "${MOCK_BIN_DIR}"

echo
echo "=== Test Summary: Passed: ${PASSED}, Failed: ${FAILED} ==="
if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
exit 0
