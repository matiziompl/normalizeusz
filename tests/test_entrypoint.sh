#!/usr/bin/env bash
# tests/test_entrypoint.sh - Unit test suite for entrypoint.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENTRYPOINT_SCRIPT="${REPO_DIR}/entrypoint.sh"

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

echo "=== Running entrypoint.sh test suite ==="

if [[ ! -f "${ENTRYPOINT_SCRIPT}" ]]; then
  echo "FATAL: ${ENTRYPOINT_SCRIPT} not found!"
  exit 1
fi

MOCK_DIR="$(mktemp -d /tmp/music_gain_entrypoint_mock.XXXXXX)"
MOCK_LOG="${MOCK_DIR}/calls.log"

cleanup_test() {
  rm -rf "${MOCK_DIR}"
}
trap cleanup_test EXIT

# Create mocks for Alpine system commands
cat << 'EOF' > "${MOCK_DIR}/addgroup"
#!/usr/bin/env bash
echo "addgroup: $*" >> "${MOCK_LOG_FILE}"
EOF

cat << 'EOF' > "${MOCK_DIR}/adduser"
#!/usr/bin/env bash
echo "adduser: $*" >> "${MOCK_LOG_FILE}"
EOF

cat << 'EOF' > "${MOCK_DIR}/chown"
#!/usr/bin/env bash
echo "chown: $*" >> "${MOCK_LOG_FILE}"
EOF

cat << 'EOF' > "${MOCK_DIR}/su-exec"
#!/usr/bin/env bash
echo "su-exec: $*" >> "${MOCK_LOG_FILE}"
EOF

cat << 'EOF' > "${MOCK_DIR}/getent"
#!/usr/bin/env bash
# Simulate empty lookup to trigger user/group creation
exit 1
EOF

chmod +x "${MOCK_DIR}"/*
export MOCK_LOG_FILE="${MOCK_LOG}"
export PATH="${MOCK_DIR}:${PATH}"

echo
echo "--- Testing: Default PUID and PGID (1000:1000) ---"
rm -f "${MOCK_LOG}"
unset PUID PGID || true
(
  export TEST_MODE=true
  # shellcheck source=/dev/null
  source "${ENTRYPOINT_SCRIPT}"
)

assert_eq "addgroup called for default PGID 1000" "1" "$(grep -c "addgroup: -g 1000" "${MOCK_LOG}" || true)"
assert_eq "adduser called for default PUID 1000" "1" "$(grep -c "adduser: -u 1000" "${MOCK_LOG}" || true)"
assert_eq "chown called with 1000:1000" "1" "$(grep -c "chown: -R 1000:1000" "${MOCK_LOG}" || true)"
assert_eq "su-exec called with 1000:1000 /usr/local/bin/watcher.sh" "1" "$(grep -c "su-exec: 1000:1000 /usr/local/bin/watcher.sh" "${MOCK_LOG}" || true)"

echo
echo "--- Testing: Custom PUID and PGID (1002:1002) ---"
rm -f "${MOCK_LOG}"
(
  export TEST_MODE=true
  export PUID=1002
  export PGID=1002
  # shellcheck source=/dev/null
  source "${ENTRYPOINT_SCRIPT}"
)

assert_eq "addgroup called for custom PGID 1002" "1" "$(grep -c "addgroup: -g 1002" "${MOCK_LOG}" || true)"
assert_eq "adduser called for custom PUID 1002" "1" "$(grep -c "adduser: -u 1002" "${MOCK_LOG}" || true)"
assert_eq "chown called with 1002:1002" "1" "$(grep -c "chown: -R 1002:1002" "${MOCK_LOG}" || true)"
assert_eq "su-exec called with 1002:1002 /usr/local/bin/watcher.sh" "1" "$(grep -c "su-exec: 1002:1002 /usr/local/bin/watcher.sh" "${MOCK_LOG}" || true)"

echo
echo "=== Test Summary: Passed: ${PASSED}, Failed: ${FAILED} ==="
if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi
exit 0
