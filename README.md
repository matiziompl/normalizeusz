# 🎵 normalizeusz

> **Automated, non-destructive loudness normalization (ReplayGain 2.0 / EBU R128) Docker sidecar for your music library.**

`normalizeusz` is an ultra-lightweight (~4 MB RAM), zero-maintenance background daemon designed to work alongside self-hosted music servers like **Navidrome**, **slskd**, and download utilities (e.g. Downloadeusz). It uses Linux `inotify` kernel events and `rsgain` to automatically scan and write ReplayGain 2.0 metadata tags whenever new music is added to your library.

---

## ✨ Features

- **Zero Transcoding / 100% Lossless:** Audio streams are never re-encoded or compressed. Normalization is achieved strictly through standardized ReplayGain 2.0 / EBU R128 metadata tags.
- **Broad Format Support:** `.mp3` (ID3v2.3/ID3v2.4), `.flac` (Vorbis Comments), `.opus` (Opus R128), `.ogg`, and `.m4a` (MP4 tags).
- **Intelligent Library Structure Handling:**
  - **Albums in subdirectories (`/music/<Artist>/<Album>/*`):** Processed with `rsgain easy -S -m MAX` to calculate both cohesive **Album Gain** (preserving the artist's intentional track-to-track volume dynamics) and **Track Gain**.
  - **Loose tracks in root (`/music/*`):** Processed with `rsgain custom -s i -S` to calculate individual **Track Gain** without synthesizing a fake album.
- **Smart Debouncing & Download Safety:** Automatically ignores download in-progress files (`*.part`, `*.tmp`, `*.crdownload`, hidden `.*` files) and applies a configurable stabilization window (default: 5 seconds) so tags are written only after downloads complete.
- **Echo Suppression:** Prevents self-triggering inotify loops when `rsgain` updates file tags.
- **Fast Startup & Skip Existing (`-S`):** Existing tagged files are skipped in milliseconds during container startup without wasting CPU cycles.
- **Unprivileged Host User Security:** Container drops root privileges via `su-exec` to match your host user's UID:GID (e.g., `1000:1000`). Files are never modified or owned by `root`.

---

## 📁 Repository Structure

```text
.
├── Dockerfile           # Minimal Alpine 3.21 image with rsgain and inotify-tools
├── docker-compose.yml   # Ready-to-use Docker Compose configuration
├── entrypoint.sh        # Privilege setup (PUID/PGID) and su-exec privilege drop
├── watcher.sh           # Inotify listener, debounce queue worker, and rsgain orchestration
└── tests/               # Automated unit and integration test suite
    ├── test_watcher.sh
    └── test_entrypoint.sh
```

---

## 🚀 Quick Start & Deployment

### 1. `docker-compose.yml`

```yaml
services:
  normalizeusz:
    container_name: normalizeusz
    build: .
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Warsaw
      - MUSIC_DIR=/music
      - DEBOUNCE_SECONDS=5
      - INITIAL_SCAN=true
      - MAX_THREADS=MAX
    volumes:
      - /home/user/media/music:/music:rw
```

### 2. Environment Variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `PUID` | `1000` | Host User ID for file ownership and permissions |
| `PGID` | `1000` | Host Group ID for file ownership and permissions |
| `TZ` | `Europe/Warsaw` | Container timezone |
| `MUSIC_DIR` | `/music` | Path to the music library inside the container |
| `DEBOUNCE_SECONDS`| `5` | Inactivity window before processing queued files |
| `INITIAL_SCAN` | `true` | Run a library scan on startup (skips already tagged files) |
| `MAX_THREADS` | `MAX` | Parallel threads for `rsgain` calculation (`MAX` uses all CPU cores) |

### 3. Deploying to Server

From your local machine:

```bash
# 1. Create remote directory
ssh user@server "mkdir -p /home/user/docker/normalizeusz"

# 2. Transfer files
scp Dockerfile docker-compose.yml entrypoint.sh watcher.sh user@server:/home/user/docker/normalizeusz/

# 3. Build and start
ssh user@server
cd /home/user/docker/normalizeusz
docker compose up -d --build
```

---

## 🎧 Audio Player & Client Compatibility

ReplayGain is a **two-step standard**:
1. **Tagging (handled by `normalizeusz`):** Calculations determine the loudness offset and write tags (`REPLAYGAIN_TRACK_GAIN`, `REPLAYGAIN_ALBUM_GAIN`) into the audio files.
2. **Playback (handled by your audio player):** The player reads the tag and adjusts the output volume accordingly.

### Navidrome
- **Web Player:** The built-in Navidrome web UI in browsers uses native HTML5 audio and **does not** apply ReplayGain volume adjustments. It will play tracks at their raw recorded volume.
- **Subsonic API:** Navidrome reads ReplayGain tags during its library scan and exposes them over the Subsonic API to external client apps.

### Supported Clients:
- **Feishin (Desktop):** Ensure ReplayGain is enabled in **Settings → Audio / Playback → ReplayGain** (set to *Track* or *Album*).
- **Symfonium (Android):** Full native ReplayGain 2.0 support with customizable pre-amp and peak clipping prevention.
- **DSub / Ultrasonic / Audinaut:** Support ReplayGain over Subsonic API.
- **foobar2000 / MPV / VLC:** Full native ReplayGain support.

> [!TIP]
> If a newly tagged song does not apply ReplayGain in your client, trigger a **Quick Scan** in Navidrome (`Activity -> Scan`) so Navidrome refreshes its database cache with the new tags.

---

## 🧪 Testing

The repository includes a comprehensive test suite covering file filtering, path extraction, debouncing, queue resilience, and echo suppression:

```bash
bash tests/test_watcher.sh
bash tests/test_entrypoint.sh
```

---

## 📄 License

MIT
