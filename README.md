# normalizeusz: Automatyczna Normalizacja Głośności Biblioteki Muzycznej (ReplayGain 2.0 / EBU R128)

Ultralekki, bezobsługowy kontener Docker (sidecar), który działa w tle i automatycznie wylicza oraz zapisuje metadane głośności dla plików muzycznych trafiających do katalogu biblioteki (zasilanej m.in. przez slskd, Navidrome i Downloadeusza).

---

## 1. Najważniejsze Cechy i Reguły Biznesowe

- **Zero transkodowania:** Żaden strumień audio nie jest rekompresowany. Normalizacja polega wyłącznie na dodaniu standardowych tagów ReplayGain 2.0 / EBU R128.
- **Obsługiwane formaty:** `.mp3` (ID3v2), `.flac` (Vorbis Comments), `.opus` (Opus R128), `.ogg`, `.m4a`.
- **Wydajność:** Narzędzie `rsgain` uruchamiane z flagą `-S` (`--skip-existing`) – pliki posiadające już poprawne tagi są natychmiast pomijane.
- **Inteligentna struktura biblioteki:**
  - **Albumy w podkatalogach (`/music/<Artysta>/<Album>/*`):** `rsgain easy -S -m MAX <katalog>` wyliczające spójny Album Gain oraz Track Gain.
  - **Pojedyncze pliki w katalogu głównym (`/music/*`):** `rsgain custom -s i -S <plik>` wyliczające wyłącznie Track Gain (bez tworzenia sztucznego albumu).
- **Bezpieczeństwo uprawnień (UID/GID):** Kontener zrzuca uprawnienia roota przez `su-exec` do użytkownika `mateusz` (`PUID: 1000`, `PGID: 1000`). Pliki muzyczne nigdy nie stają się własnością roota.
- **Odporność na proces pobierania:** Ignorowanie plików tymczasowych (`*.part`, `*.tmp`, `*.crdownload`, plików ukrytych `.*`) oraz bufor debounce (domyślnie 5 sekund), aby nie tagować plików w trakcie zapisu.

---

## 2. Struktura Projektu

```text
├── Dockerfile           # Lekki obraz Alpine 3.21 z rsgain i inotify-tools
├── docker-compose.yml   # Definicja usługi normalizeusz pod montowanie wolumenów
├── entrypoint.sh        # Konfiguracja uprawnień PUID/PGID (1000:1000) i su-exec
├── watcher.sh           # Skan początkowy, nasłuch inotifywait oraz kolejka debounce
├── tests/               # Zestaw automatycznych testów jednostkowych
│   ├── test_watcher.sh
│   └── test_entrypoint.sh
└── docs/                # Specyfikacja projektowa i plan implementacji
```

---

## 3. Instrukcja Wdrożenia na Serwerze (Serweusz)

Wszystkie polecenia wykonujesz ze swojego komputera PC.

### Krok 1: Utworzenie katalogu na serwerze i przesłanie plików przez `scp`

```bash
# 1. Połącz się przez SSH lub utwórz katalog docelowy
ssh mateusz@192.168.1.102 "mkdir -p /home/mateusz/docker/normalizeusz"

# 2. Prześlij pliki konfiguracyjne i skrypty na serwer
scp Dockerfile docker-compose.yml entrypoint.sh watcher.sh mateusz@192.168.1.102:/home/mateusz/docker/normalizeusz/
```

### Krok 2: Uruchomienie kontenera przez `ssh`

```bash
ssh mateusz@192.168.1.102
cd /home/mateusz/docker/normalizeusz

# Zbudowanie obrazu i uruchomienie w tle
docker compose up -d --build
```

### Krok 3: Weryfikacja działania i logi

```bash
# Podgląd logów w czasie rzeczywistym
docker compose logs -f normalizeusz
```

Przykładowy poprawny log startowy:
```text
[normalizeusz-entrypoint] Dropping privileges to UID:GID (1000:1000)...
[normalizeusz] normalizeusz watcher service initialized.
[normalizeusz] Settings: MUSIC_DIR=/music, DEBOUNCE=5s, THREADS=MAX
[normalizeusz] Starting initial library scan in /music...
[normalizeusz] Initial library scan completed.
[normalizeusz] Watching /music for close_write and moved_to events...
```

---

## 4. Testy Lokalne (TDD)

Testy można uruchomić lokalnie (np. w Git Bash na Windows lub w dowolnym środowisku bash):

```bash
bash tests/test_watcher.sh
bash tests/test_entrypoint.sh
```
