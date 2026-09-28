# Specyfikacja Projektowa: Bezinwazyjna Normalizacja Głośności (rsgain / normalizeusz)

- **Data:** 2026-09-28
- **Projekt:** `normalizeusz` (`music-gain`)
- **Środowisko docelowe:** Serweusz (Debian GNU/Linux 6.x, Lenovo ThinkCentre E73, i5-4590S, 8GB RAM, SSD 250GB, UID: 1000 / GID: 1000)
- **Katalog na hoście:** `/home/mateusz/docker/music-gain/`
- **Ścieżka do biblioteki:** `/home/mateusz/media/music` montowana jako `/music:rw`

---

## 1. Cel i Wymagania Biznesowe

Wdrożenie ultralekkiego, bezobsługowego kontenera Docker (sidecar), działającego w tle serwera domowego. Kontener w sposób ciągły monitoruje bibliotekę muzyczną i automatycznie oblicza oraz zapisuje metadane ReplayGain 2.0 / EBU R128 bez transkodowania audio.

### Kluczowe reguły:
1. **Zero transkodowania:** Brak ponownej kompresji; zapisywane są wyłącznie tagi głośności.
2. **Obsługiwane formaty:** `.mp3` (ID3v2), `.flac` (Vorbis Comments), `.opus` (Opus R128), `.ogg`, `.m4a`.
3. **Wydajność i unikanie duplikacji:** Użycie `rsgain` z flagą `-S` (`--skip-existing`). Pliki już otagowane są natychmiast pomijane.
4. **Rozróżnienie struktury katalogów:**
   - **Albumy w podkatalogach (`/music/<Artysta>/<Album>/*`):** Uruchomienie `rsgain easy -S -m MAX <katalog_albumu>` w celu wyznaczenia spójnego Album Gain oraz Track Gain.
   - **Pojedyncze pliki w katalogu głównym (`/music/*`):** Uruchomienie `rsgain custom -s i -S <plik>` w celu wyliczenia wyłącznie Track Gain bez sztucznego scalania luźnych utworów w jeden album.
5. **Uprawnienia i bezpieczeństwo:** Kontener uruchamia się z uprawnieniami roota wyłącznie w celu dynamicznej konfiguracji użytkownika o zadanym `PUID`/`PGID` (domyślnie 1000:1000 `mateusz`), po czym poprzez `su-exec` zrzuca uprawnienia do użytkownika nieuprzywilejowanego. Pliki muzyczne nigdy nie stają się własnością roota.
6. **Odporność na proces pobierania (slskd / Downloadeusz):**
   - Ignorowanie plików tymczasowych (`*.part`, `*.tmp`, `*.crdownload`, `.syncthing*`, pliki ukryte).
   - Mechanizm debounce (domyślnie 5 sekund): buforowanie zdarzeń per katalog albumu lub per luźny plik. Przetwarzanie następuje dopiero po ustaniu zapisów.
7. **Skan początkowy:** Przy starcie kontener weryfikuje i uzupełnia brakujące tagi w całej bibliotece.

---

## 2. Architektura Komponentów

```
+---------------------------------------------------------------------------------+
|                                 Host (Serweusz)                                 |
|                                                                                 |
|   /home/mateusz/media/music <-----+ (pliki audio z slskd / Downloadeusz)        |
+-----------------------------------|---------------------------------------------+
                                    | wolumen: /music (rw)
+-----------------------------------|---------------------------------------------+
| Kontener: music-gain (Alpine)     v                                             |
|                                                                                 |
|  [entrypoint.sh] (root)                                                         |
|         |                                                                       |
|         +---> Konfiguracja UID:GID (1000:1000)                                  |
|         +---> su-exec mateusz watcher.sh                                        |
|                     |                                                           |
|                     v                                                           |
|        +-------------------------------------------------------+                |
|        | [watcher.sh]                                          |                |
|        |                                                       |                |
|        |  1. Initial Scan:                                     |                |
|        |     - podkatalogi -> rsgain easy -S -m MAX            |                |
|        |     - luźne pliki -> rsgain custom -s i -S            |                |
|        |                                                       |                |
|        |  2. inotifywait loop (close_write, moved_to)          |                |
|        |     - filtruj rozszerzenia & ignoruj tmp              |                |
|        |     - wyznacz cel: DIR (album) lub FILE (roocik)      |                |
|        |                                                       |                |
|        |  3. Debounce Worker:                                  |                |
|        |     - bufor 5s braku aktywności w celu                |                |
|        |     - wywołanie rsgain dla ustabilizowanego celu      |                |
|        +-------------------------------------------------------+                |
+---------------------------------------------------------------------------------+
```

---

## 3. Szczegóły Implementacyjne

### 3.1. Dockerfile
- **Baza:** `alpine:3.20` lub nowsza.
- **Pakiety:** `apk add --no-cache rsgain inotify-tools bash su-exec coreutils tzdata`.
- **Struktura:**
  - Kopiowanie `entrypoint.sh` do `/usr/local/bin/entrypoint.sh` (`chmod +x`).
  - Kopiowanie `watcher.sh` do `/usr/local/bin/watcher.sh` (`chmod +x`).
  - Domyślny `ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`.

### 3.2. entrypoint.sh
- Odczytuje zmienne środowiskowe:
  - `PUID` (domyślnie `1000`)
  - `PGID` (domyślnie `1000`)
- Sprawdza, czy istnieje grupa o `PGID`, jeśli nie – tworzy `appgroup`.
- Sprawdza, czy istnieje użytkownik o `PUID`, jeśli nie – tworzy `appuser`.
- Zapewnia uprawnienia do katalogu roboczego kolejki `/tmp/music-gain`.
- Uruchamia: `exec su-exec "$PUID:$PGID" /usr/local/bin/watcher.sh "$@"`.

### 3.3. watcher.sh
- **Konfiguracja środowiska:**
  - `MUSIC_DIR` (domyślnie `/music`)
  - `DEBOUNCE_SECONDS` (domyślnie `5`)
  - `INITIAL_SCAN` (domyślnie `true`)
  - `MAX_THREADS` (domyślnie `MAX`)
- **Obsługa sygnałów:**
  - `trap cleanup SIGTERM SIGINT SIGQUIT EXIT` – ubija proces `inotifywait` oraz pętlę debounce worker.
- **Funkcja Initial Scan (`initial_scan`):**
  - Dla każdego podkatalogu w `$MUSIC_DIR/*`: jeśli jest katalogiem, wywołuje:
    `rsgain easy -S -m "$MAX_THREADS" "$dir"`
  - Dla każdego pliku bezpośrednio w `$MUSIC_DIR/*`: jeśli pasuje do rozszerzeń audio, wywołuje:
    `rsgain custom -s i -S "$file"`
- **Funkcja Debounce i Kolejkowania:**
  - Katalog stanu kolejki: `/tmp/music-gain/queue/`.
  - Po odebraniu zdarzenia:
    - Sprawdzenie rozszerzenia: ignorowanie `*.part`, `*.tmp`, `*.crdownload`, plików z kropką na początku (`.*`).
    - Sprawdzenie formatu audio: `.(mp3|flac|opus|ogg|m4a)$` (case-insensitive).
    - Rozpoznanie typu celu:
      - Jeśli ścieżka pliku znajduje się w `$MUSIC_DIR/` bez dalszych podkatalogów -> cel to `FILE:<ścieżka_pliku>`.
      - Jeśli ścieżka znajduje się w podkatalogu -> cel to `DIR:<katalog_zawierający_plik>`.
    - Zapis/aktualizacja pliku znacznika w `/tmp/music-gain/queue/` z aktualnym czasem Unix (`date +%s`).
  - **Worker pętli debounce:**
    - Co 1 sekundę sprawdza pliki w kolejce.
    - Dla każdego zadania: `elapsed = now - last_event_time`.
    - Jeśli `elapsed >= DEBOUNCE_SECONDS`:
      - Wykonuje operację `rsgain` (dla `DIR`: `rsgain easy -S -m "$MAX_THREADS" "$path"`, dla `FILE`: `rsgain custom -s i -S "$path"`).
      - Usuwa plik zadania z kolejki.

### 3.4. docker-compose.yml
```yaml
services:
  music-gain:
    build: .
    container_name: music-gain
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Warsaw
      - DEBOUNCE_SECONDS=5
      - INITIAL_SCAN=true
      - MAX_THREADS=MAX
    volumes:
      - /home/mateusz/media/music:/music:rw
```

---

## 4. Testy i Weryfikacja (TDD)

Przed zakończeniem prac przygotowany zostanie zestaw testów weryfikujących:
1. Prawidłowość filtrowania plików audio vs ignorowania plików tymczasowych (`.part`, `.tmp`).
2. Poprawne wyznaczanie typu celu (`DIR` vs `FILE`).
3. Działanie logiki debounce (seria zdarzeń w oknie czasowym wywołuje rsgain dokładnie raz).
4. Poprawność uprawnień (brak działania procesu roboczego jako root).
5. Poprawność składni Dockerfile i skryptów bashowych (`shellcheck` / walidacja składniowa basha).
