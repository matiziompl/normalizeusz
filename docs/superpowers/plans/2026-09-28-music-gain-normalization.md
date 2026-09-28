# Music-Gain Normalization Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a lightweight, non-invasive Docker sidecar service (`music-gain`) that automatically monitors `/home/mateusz/media/music` and calculates ReplayGain 2.0 / EBU R128 loudness metadata tags without re-encoding audio.

**Architecture:** An Alpine Linux-based container running an `entrypoint.sh` wrapper that configures host UID/GID (1000:1000 `mateusz`) and drops privileges via `su-exec` to `watcher.sh`. `watcher.sh` runs an initial scan, an inotifywait event listener, and a debounced queue worker (5s window) to run `rsgain easy -S -m MAX` for album directories and `rsgain custom -s i -S` for single tracks in the music root directory.

**Tech Stack:** Docker, Alpine Linux 3.21, Bash 5+, `rsgain`, `inotify-tools`, `su-exec`, `coreutils`.

**Spec:** [docs/superpowers/specs/2026-09-28-music-gain-normalization-design.md](file:///c:/Antigravity%20Projects/normalizeusz/docs/superpowers/specs/2026-09-28-music-gain-normalization-design.md)

## Global Constraints

- Zero transcoding: Audio streams must never be re-encoded; only ReplayGain 2.0 / EBU R128 metadata tags are written.
- Permissions: Container must drop root privileges and execute tasks as `PUID:PGID` (default 1000:1000). Music library files must never be owned by root.
- Supported audio formats: `.mp3`, `.flac`, `.opus`, `.ogg`, `.m4a` (case-insensitive).
- Skip existing: All scans must use `-S` / `--skip-existing` to avoid redundant CPU work.
- Temporary file exclusion: Files ending in `.part`, `.tmp`, `.crdownload`, or beginning with `.` must be ignored.
- Minimal footprint: Pure Bash debounce logic without heavy runtimes (no Python/Node.js); base image Alpine 3.21.

## Review Focus

1. Filenames containing spaces, brackets, single/double quotes, and unicode characters (`01 - L'Amour [2024] (feat. Artist).flac`) — Queue IDs and arguments must be safely escaped or hashed so Bash does not split tokens.
2. Torrent / download client temporary files (`track.flac.part`, `download.tmp`, `.syncthing...`) — Must be filtered out before queuing.
3. Rapid burst of multiple tracks during an album download — All tracks in the same directory must update the same queue item, firing a single `rsgain easy` scan 5 seconds after the final track completes.
4. Loose files directly in `/music` vs album subdirectories — Files in `/music/*` must trigger `rsgain custom -s i -S`, never treating `/music` as an album folder.
5. Signal handling (`SIGTERM` / `SIGINT`) — Container stop must gracefully kill the debounce worker and inotifywait child processes without hanging.

---

### Task 1: Test Suite Harness & Fixtures

**Files:**
- Create: `tests/test_watcher.sh`
- Create: `tests/fixtures/dummy.mp3`

**Interfaces:**
- Produces: `run_all_tests()` returning exit code 0 on success, non-zero on failure.
- Consumes: Mock commands (`rsgain`, `inotifywait`) for isolated unit testing of Bash functions.

- [ ] **Step 1: Write the failing test for watcher functions**

```bash
# tests/test_watcher.sh
# Tests:
# - is_audio_file returns 0 for valid extensions, 1 for invalid
# - is_temp_file returns 0 for .part, .tmp, .crdownload, hidden files
# - get_target returns FILE:<path> for root files and DIR:<dir> for subfolder files
# - queue_event creates/updates queue marker with timestamp
# - process_queue triggers correct rsgain command when elapsed >= DEBOUNCE_SECONDS
```

- [ ] **Step 2: Run test to verify it fails**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_watcher.sh`
Expected: FAIL with "watcher.sh: No such file or directory" or "is_audio_file: command not found"

- [ ] **Step 3: Create test scaffolding and mock utilities in `tests/test_watcher.sh`**

Implement mock `rsgain` logging invocations to a trace log file so assertions can verify exact arguments.

- [ ] **Step 4: Verify test runner executes and fails predictably**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_watcher.sh`
Expected: FAIL (red phase)

- [ ] **Step 5: Commit**

```bash
git add tests/
git commit -m "test: add test suite harness and test cases for music-gain watcher"
```

---

### Task 2: Core Watcher Script Implementation (`watcher.sh`)

**Files:**
- Create: `watcher.sh`
- Test: `tests/test_watcher.sh`

**Interfaces:**
- Produces:
  - `is_audio_file "$filename"` -> 0 or 1
  - `is_temp_file "$filename"` -> 0 or 1
  - `get_target "$filepath"` -> outputs `FILE:<filepath>` or `DIR:<dirpath>`
  - `queue_event "$target"` -> updates `/tmp/music-gain/queue/<hash>`
  - `process_queue` -> checks items, calls `rsgain`, deletes expired queue items
  - `initial_scan` -> scans existing library
  - `main` / runtime loop
- Consumes: Environment variables `MUSIC_DIR`, `DEBOUNCE_SECONDS`, `INITIAL_SCAN`, `MAX_THREADS`, `QUEUE_DIR`.

- [ ] **Step 1: Implement filtering & target classification functions**

Implement `is_audio_file`, `is_temp_file`, and `get_target` with support for spaces and special characters.

- [ ] **Step 2: Run tests to verify filtering and target tests pass**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_watcher.sh`
Expected: Unit tests for filter and target pass; queue and scan tests fail.

- [ ] **Step 3: Implement debounce queue management and scanner execution**

Implement `queue_event`, `process_queue`, and `run_scan_target`:
- For `DIR`: `rsgain easy -S -m "$MAX_THREADS" "$target_path"`
- For `FILE`: `rsgain custom -s i -S "$target_path"`
- Queue worker loop with 1s sleep.

- [ ] **Step 4: Implement initial scan and inotifywait event listener with traps**

Implement `initial_scan` scanning subdirectories and root files. Add trap on `SIGTERM`, `SIGINT`, `EXIT` to clean up child PIDs (`inotifywait` and worker background loop).

- [ ] **Step 5: Run complete unit test suite**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_watcher.sh`
Expected: All tests PASS (exit code 0).

- [ ] **Step 6: Commit**

```bash
git add watcher.sh tests/test_watcher.sh
git commit -m "feat: implement watcher.sh with debounce queue and rsgain orchestration"
```

---

### Task 3: Entrypoint Script & UID/GID Privilege Dropping (`entrypoint.sh`)

**Files:**
- Create: `entrypoint.sh`
- Test: `tests/test_entrypoint.sh`

**Interfaces:**
- Produces: `entrypoint.sh` managing user creation and running `exec su-exec "$PUID:$PGID" /usr/local/bin/watcher.sh "$@"`
- Consumes: `PUID` (default 1000), `PGID` (default 1000).

- [ ] **Step 1: Write the failing test for entrypoint script**

Create `tests/test_entrypoint.sh` verifying that:
- Default `PUID`/`PGID` are set to 1000 if unset.
- User and group `appuser`/`appgroup` creation logic is syntactically valid.
- Target queue directory `/tmp/music-gain` is created with ownership `$PUID:$PGID`.
- `exec su-exec` is invoked with correct target binary and parameters.

- [ ] **Step 2: Run test to verify it fails**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_entrypoint.sh`
Expected: FAIL with "entrypoint.sh: No such file or directory"

- [ ] **Step 3: Implement `entrypoint.sh`**

Write `entrypoint.sh` with robust group/user checking, folder creation, and `su-exec` execution.

- [ ] **Step 4: Run test to verify it passes**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_entrypoint.sh`
Expected: PASS (exit code 0)

- [ ] **Step 5: Commit**

```bash
git add entrypoint.sh tests/test_entrypoint.sh
git commit -m "feat: implement entrypoint.sh with dynamic PUID/PGID and su-exec privilege dropping"
```

---

### Task 4: Dockerfile & Container Image Configuration

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`

**Interfaces:**
- Produces: Production-ready Docker build specification based on `alpine:3.21` with `rsgain` installed.

- [ ] **Step 1: Create `.dockerignore`**

Exclude `.git`, `tests/`, docs, and local files from container build context.

- [ ] **Step 2: Create `Dockerfile`**

- Base image: `alpine:3.21`
- Install packages: `apk add --no-cache rsgain inotify-tools bash su-exec coreutils tzdata`
- Copy `entrypoint.sh` and `watcher.sh` to `/usr/local/bin/` with `chmod +x`
- Set `VOLUME ["/music"]`
- Set `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`

- [ ] **Step 3: Validate Dockerfile syntax and script executable flags**

Verify linting, syntax, and permission flags.

- [ ] **Step 4: Commit**

```bash
git add Dockerfile .dockerignore
git commit -m "feat: add optimized Alpine 3.21 Dockerfile for music-gain"
```

---

### Task 5: Docker Compose Configuration & Deployment Guide

**Files:**
- Create: `docker-compose.yml`
- Create: `README.md`

**Interfaces:**
- Produces:
  - Ready-to-deploy `docker-compose.yml` for `/home/mateusz/docker/music-gain/`
  - Step-by-step instructions for copying files via `scp` to `mateusz@192.168.1.102` and starting the service via `ssh`.

- [ ] **Step 1: Create `docker-compose.yml`**

Configure service with:
- `container_name: music-gain`
- `restart: unless-stopped`
- Environment variables: `PUID=1000`, `PGID=1000`, `TZ=Europe/Warsaw`, `DEBOUNCE_SECONDS=5`, `INITIAL_SCAN=true`, `MAX_THREADS=MAX`
- Volumes: `/home/mateusz/media/music:/music:rw`

- [ ] **Step 2: Create comprehensive `README.md`**

Document:
- System overview & architecture.
- Deployment commands (`scp`, `ssh`, `docker compose up -d`).
- Log inspection (`docker compose logs -f music-gain`).
- How to test on Serweusz with sample tracks.

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml README.md
git commit -m "docs: add docker-compose configuration and deployment instructions"
```

---

### Task 6: Full Verification & Sanity Check

**Files:**
- Verify: All files in repository
- Run: Complete automated test suite

- [ ] **Step 1: Run the full test suite**

Run: `& "C:\Program Files\Git\bin\bash.exe" tests/test_watcher.sh && & "C:\Program Files\Git\bin\bash.exe" tests/test_entrypoint.sh`
Expected: All tests pass with exit code 0.

- [ ] **Step 2: Verify git status and file tree**

Run: `git status`
Expected: Working tree clean, all files staged/committed.
