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
TEST_MUSIC_DIR="$(mktemp -d /tmp/music_gain_test_music.XXXXXX)"
export MUSIC_DIR="${TEST_MUSIC_DIR}"
export DEBOUNCE_SECONDS=2
export MAX_THREADS="MAX"
TEST_QUEUE_DIR="$(mktemp -d /tmp/music_gain_test_queue.XXXXXX)"
export QUEUE_DIR="${TEST_QUEUE_DIR}"

mkdir -p "${TEST_MUSIC_DIR}/Pink Floyd/The Wall/CD1"
mkdir -p "${TEST_MUSIC_DIR}/Artist/Album"
mkdir -p "${TEST_MUSIC_DIR}/AC/DC/Back In Black [1980]"
touch "${TEST_MUSIC_DIR}/single_song.mp3"
touch "${TEST_MUSIC_DIR}/01 - Artist - Song.flac"
touch "${TEST_MUSIC_DIR}/Pink Floyd/The Wall/01 - Mother.flac"
touch "${TEST_MUSIC_DIR}/Pink Floyd/The Wall/CD1/01.mp3"
touch "${TEST_MUSIC_DIR}/Artist/Album/track.mp3"
touch "${TEST_MUSIC_DIR}/AC/DC/Back In Black [1980]/01 - Hells Bells.mp3"

cleanup_test() {
  rm -rf "${TEST_QUEUE_DIR}" "${TEST_MUSIC_DIR}"
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
assert_eq "Root file resolves to FILE: target" "FILE:${MUSIC_DIR}/single_song.mp3" "$(get_target "${MUSIC_DIR}/single_song.mp3")"
assert_eq "Root file with spaces resolves to FILE: target" "FILE:${MUSIC_DIR}/01 - Artist - Song.flac" "$(get_target "${MUSIC_DIR}/01 - Artist - Song.flac")"
assert_eq "Subfolder file resolves to DIR: target" "DIR:${MUSIC_DIR}/Pink Floyd/The Wall" "$(get_target "${MUSIC_DIR}/Pink Floyd/The Wall/01 - Mother.flac")"
assert_eq "Nested subfolder resolves to DIR: target" "DIR:${MUSIC_DIR}/Pink Floyd/The Wall/CD1" "$(get_target "${MUSIC_DIR}/Pink Floyd/The Wall/CD1/01.mp3")"
assert_eq "Special characters in path resolved properly" "DIR:${MUSIC_DIR}/AC/DC/Back In Black [1980]" "$(get_target "${MUSIC_DIR}/AC/DC/Back In Black [1980]/01 - Hells Bells.mp3")"

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
run_scan_target "DIR:${MUSIC_DIR}/Artist/Album"
assert_eq "rsgain easy called for DIR target" "easy -S -m MAX ${MUSIC_DIR}/Artist/Album" "$(tail -n 1 "${MOCK_LOG}")"

# Test scan execution for FILE
run_scan_target "FILE:${MUSIC_DIR}/single_song.mp3"
assert_eq "rsgain custom called for FILE target" "custom -s i -S ${MUSIC_DIR}/single_song.mp3" "$(tail -n 1 "${MOCK_LOG}")"

# Test queue enqueuing and debounce timing
rm -f "${MOCK_LOG}"
queue_event "DIR:${MUSIC_DIR}/Artist/Album"
assert_eq "Queue entry created" "1" "$(find "${QUEUE_DIR}" -type f | wc -l | tr -d ' ')"

# Process queue immediately (elapsed < DEBOUNCE_SECONDS) -> should NOT trigger scan
process_queue
assert_eq "Process queue skipped before debounce expires" "0" "$(if [[ -f "${MOCK_LOG}" ]]; then wc -l < "${MOCK_LOG}" | tr -d ' '; else echo "0"; fi)"
assert_eq "Queue entry still present" "1" "$(find "${QUEUE_DIR}" -type f | wc -l | tr -d ' ')"

# Artificially age the queue item (simulate time passing past DEBOUNCE_SECONDS)
QUEUE_FILE="$(find "${QUEUE_DIR}" -type f | head -n 1)"
OLD_TIME=$(( $(date +%s) - DEBOUNCE_SECONDS - 2 ))
TARGET="$(sed -n '2p' "${QUEUE_FILE}")"
printf "%s\n%s\n" "${OLD_TIME}" "${TARGET}" > "${QUEUE_FILE}.ts"
mv "${QUEUE_FILE}.ts" "${QUEUE_FILE}"

# Now process queue -> should trigger scan and remove queue item
process_queue
assert_eq "rsgain easy executed after debounce" "easy -S -m MAX ${MUSIC_DIR}/Artist/Album" "$(tail -n 1 "${MOCK_LOG}")"
assert_eq "Queue entry removed after processing" "0" "$(find "${QUEUE_DIR}" -type f | wc -l | tr -d ' ')"

echo
echo "--- Testing: Initial Library Scan (initial_scan) ---"
rm -f "${MOCK_LOG}"
initial_scan
# Check that rsgain easy was called for subdirectories
assert_exit_code "initial_scan called rsgain easy for album dir" 0 grep -F "easy -S -m MAX ${MUSIC_DIR}/Artist" "${MOCK_LOG}"
# Check that rsgain custom was called for loose root file
assert_exit_code "initial_scan called rsgain custom for loose track" 0 grep -F "custom -s i -S ${MUSIC_DIR}/single_song.mp3" "${MOCK_LOG}"

# Clean mock bin
rm -rf "${MOCK_BIN_DIR}"

echo
echo "=== Test Summary: Passed: ${PASSED}, Failed: ${FAILED} ==="
if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
exit 0
