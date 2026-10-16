
#!/usr/bin/env bash

set -uo pipefail

# ============================================================
# Configuration
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

URLS_FILE="$SCRIPT_DIR/urls.txt"
DOWNLOAD_DIR="$SCRIPT_DIR/downloads"
COMPLETED_FILE="$SCRIPT_DIR/completed-index.tsv"
ENV_FILE="$SCRIPT_DIR/.env"

MODE="video"
RANGE=""
REDOWNLOAD=0
SPOTIFY=0

# Exported environment variables take priority over .env.
SPOTIFY_CLIENT_ID="${SPOTIFY_CLIENT_ID:-}"
SPOTIFY_CLIENT_SECRET="${SPOTIFY_CLIENT_SECRET:-}"

# ============================================================
# Help
# ============================================================

usage() {
    cat <<'EOF'
Usage:
  ./download.sh [OPTIONS]

Download modes:
  --video                 Best available video and audio (default)
  --mp4                   Download and merge into MP4
  --audio                 Extract audio
  --mp3                   Extract and convert audio to MP3

Options:
  --output-dir DIR, -o DIR
                          Output directory (default: ./downloads)
  --range START:END       Download URL indexes in this range
  --range START:          Download from START to the end
  --range :END            Download from the beginning through END
  --range START-          Download from START to the end
  --redownload             Retry previously completed items
  --spotify                Try Spotify API, then web-search fallback
  --help, -h               Show this help

Examples:
  ./download.sh
  ./download.sh --mp4
  ./download.sh --mp3 --spotify
  ./download.sh --audio --spotify --range 1:10
  ./download.sh --mp3 --spotify -o "$HOME/Music"
  ./download.sh --redownload --range 1:5

Input:
  urls.txt beside this script, one URL per line.
  Blank lines and lines beginning with # are ignored.

Spotify:
  Uses exported SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET first,
  then reads missing values from .env beside this script.
  If the Spotify API fails, including with HTTP 403, the script
  searches the web for a Spotify track URL.
  If no direct track URL is found, it saves a Spotify search URL.
EOF
}

# ============================================================
# Parse arguments
# ============================================================

while (($#)); do
    case "$1" in
        --video|video) MODE="video" ;;
        --mp4|mp4) MODE="mp4" ;;
        --audio|audio) MODE="audio" ;;
        --mp3|mp3) MODE="mp3" ;;

        --range)
            if (($# < 2)); then
                echo "Error: --range requires a value."
                exit 1
            fi
            RANGE="$2"
            shift
            ;;

        --output-dir|-o)
            if (($# < 2)); then
                echo "Error: $1 requires a directory path."
                exit 1
            fi
            DOWNLOAD_DIR="$2"
            shift
            ;;

        --redownload) REDOWNLOAD=1 ;;
        --spotify) SPOTIFY=1 ;;

        --help|-h)
            usage
            exit 0
            ;;

        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

# ============================================================
# Resolve output directory
# ============================================================

case "$DOWNLOAD_DIR" in
    "~") DOWNLOAD_DIR="$HOME" ;;
    "~/"*) DOWNLOAD_DIR="$HOME/${DOWNLOAD_DIR#~/}" ;;
esac

if [[ "$DOWNLOAD_DIR" != /* &&
      ! "$DOWNLOAD_DIR" =~ ^[A-Za-z]:[\\/].* ]]; then
    DOWNLOAD_DIR="$SCRIPT_DIR/$DOWNLOAD_DIR"
fi

# ============================================================
# Detect operating system
# ============================================================

detect_os() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Darwin)
            OS="macos"
            ;;
        Linux*)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                OS="wsl"
            else
                OS="linux"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            OS="gitbash"
            ;;
        *)
            OS="unknown"
            ;;
    esac
}

detect_os

echo "Operating system: $OS"
echo "Mode:             $MODE"
echo "Output directory: $DOWNLOAD_DIR"
echo "Spotify lookup:   $([[ "$SPOTIFY" == 1 ]] && echo enabled || echo disabled)"

# ============================================================
# Installation helpers
# ============================================================

ask_install() {
    local dependency="$1"
    local answer=""

    if [[ ! -t 0 ]]; then
        echo "Cannot prompt to install $dependency in non-interactive mode."
        return 1
    fi

    printf "%s is missing. Try to install it? [Y/n] " "$dependency"
    read -r answer </dev/tty || return 1

    case "$answer" in
        n|N|no|NO|No) return 1 ;;
        *) return 0 ;;
    esac
}

ensure_sudo() {
    if [[ "$OS" == "macos" || "$OS" == "linux" || "$OS" == "wsl" ]]; then
        command -v sudo >/dev/null 2>&1 || {
            echo "Error: sudo is unavailable."
            return 1
        }

        echo "Administrator permission may be required."
        sudo -v || {
            echo "Error: administrator authentication failed."
            return 1
        }
    fi
}

refresh_path() {
    export PATH="$HOME/.local/bin:$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
    hash -r 2>/dev/null || true
}

# ============================================================
# Install yt-dlp
# ============================================================

install_ytdlp() {
    echo "Attempting to install yt-dlp..."

    case "$OS" in
        macos)
            command -v brew >/dev/null 2>&1 || {
                echo "Install Homebrew from https://brew.sh/ first."
                return 1
            }
            brew install yt-dlp || brew upgrade yt-dlp
            ;;

        linux|wsl)
            if command -v apt-get >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo apt-get update || return 1

                if ! sudo apt-get install -y yt-dlp; then
                    echo "Trying pipx..."
                    if ! command -v pipx >/dev/null 2>&1; then
                        sudo apt-get install -y pipx || return 1
                    fi
                    refresh_path
                    pipx install yt-dlp || pipx upgrade yt-dlp || return 1
                fi
            elif command -v pacman >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo pacman -Sy --needed yt-dlp || return 1
            elif command -v dnf >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo dnf install -y yt-dlp || return 1
            elif command -v zypper >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo zypper --non-interactive install yt-dlp || return 1
            else
                echo "Install yt-dlp manually: https://github.com/yt-dlp/yt-dlp"
                return 1
            fi
            ;;

        gitbash)
            command -v winget >/dev/null 2>&1 || return 1
            winget install --id yt-dlp.yt-dlp --exact \
                --accept-source-agreements --accept-package-agreements || return 1
            echo "Restart Git Bash if yt-dlp is not found."
            ;;

        *)
            echo "Install yt-dlp manually: https://github.com/yt-dlp/yt-dlp"
            return 1
            ;;
    esac

    refresh_path
    command -v yt-dlp >/dev/null 2>&1 ||
        command -v yt-dlp.exe >/dev/null 2>&1
}

# ============================================================
# Install FFmpeg
# ============================================================

install_ffmpeg() {
    echo "Attempting to install FFmpeg..."

    case "$OS" in
        macos)
            command -v brew >/dev/null 2>&1 || return 1
            brew install ffmpeg || brew upgrade ffmpeg
            ;;

        linux|wsl)
            if command -v apt-get >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo apt-get update &&
                    sudo apt-get install -y ffmpeg || return 1
            elif command -v pacman >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo pacman -Sy --needed ffmpeg || return 1
            elif command -v dnf >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo dnf install -y ffmpeg || return 1
            elif command -v zypper >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo zypper --non-interactive install ffmpeg || return 1
            else
                echo "Install FFmpeg manually: https://ffmpeg.org/download.html"
                return 1
            fi
            ;;

        gitbash)
            command -v winget >/dev/null 2>&1 || return 1
            winget install --id Gyan.FFmpeg.Shared --exact \
                --accept-source-agreements --accept-package-agreements || return 1
            echo "Restart Git Bash if FFmpeg is not found."
            ;;

        *)
            echo "Install FFmpeg manually: https://ffmpeg.org/download.html"
            return 1
            ;;
    esac

    refresh_path
    command -v ffmpeg >/dev/null 2>&1
}

# ============================================================
# Install Python (needed for Spotify lookup)
# ============================================================

install_python() {
    echo "Attempting to install Python 3..."

    case "$OS" in
        macos)
            command -v brew >/dev/null 2>&1 || return 1
            brew install python
            ;;
        linux|wsl)
            if command -v apt-get >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo apt-get update && sudo apt-get install -y python3
            elif command -v pacman >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo pacman -Sy --needed python
            elif command -v dnf >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo dnf install -y python3
            elif command -v zypper >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo zypper --non-interactive install python3
            else
                return 1
            fi
            ;;
        gitbash)
            command -v winget >/dev/null 2>&1 || return 1
            winget install --id Python.Python.3.12 --exact \
                --accept-source-agreements --accept-package-agreements
            ;;
        *)
            return 1
            ;;
    esac

    refresh_path
    command -v python3 >/dev/null 2>&1 ||
        command -v python >/dev/null 2>&1
}

# ============================================================
# Check yt-dlp
# ============================================================

if ! command -v yt-dlp >/dev/null 2>&1 &&
   ! command -v yt-dlp.exe >/dev/null 2>&1; then
    if ask_install "yt-dlp"; then
        install_ytdlp || {
            echo "Error: yt-dlp could not be installed or found."
            exit 1
        }
    else
        echo "yt-dlp is required. Exiting."
        exit 1
    fi
fi

if command -v yt-dlp >/dev/null 2>&1; then
    YTDLP="yt-dlp"
else
    YTDLP="yt-dlp.exe"
fi

"$YTDLP" --version || {
    echo "Error: yt-dlp is not working."
    exit 1
}

# ============================================================
# Check FFmpeg
# ============================================================

FFMPEG_AVAILABLE=0

if command -v ffmpeg >/dev/null 2>&1; then
    FFMPEG_AVAILABLE=1
elif ask_install "FFmpeg"; then
    install_ffmpeg && FFMPEG_AVAILABLE=1
fi

if [[ "$MODE" == "audio" || "$MODE" == "mp3" ]] &&
   (( FFMPEG_AVAILABLE == 0 )); then
    echo "Error: $MODE mode requires FFmpeg."
    exit 1
fi

if (( FFMPEG_AVAILABLE == 0 )); then
    echo "Warning: FFmpeg is unavailable; some video downloads may not merge."
fi

# ============================================================
# Read .env credentials without overriding exported values
# ============================================================

load_spotify_env() {
    local line key value

    [[ -f "$ENV_FILE" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        line="${line#export }"

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"

            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"

            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value:1:${#value}-2}"
            elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
                value="${value:1:${#value}-2}"
            fi

            case "$key" in
                SPOTIFY_CLIENT_ID)
                    [[ -n "$SPOTIFY_CLIENT_ID" ]] ||
                        SPOTIFY_CLIENT_ID="$value"
                    ;;
                SPOTIFY_CLIENT_SECRET)
                    [[ -n "$SPOTIFY_CLIENT_SECRET" ]] ||
                        SPOTIFY_CLIENT_SECRET="$value"
                    ;;
            esac
        fi
    done < "$ENV_FILE"
}

# ============================================================
# Spotify setup
# ============================================================

PYTHON=""

if (( SPOTIFY == 1 )); then
    if command -v python3 >/dev/null 2>&1; then
        PYTHON="python3"
    elif command -v python >/dev/null 2>&1; then
        PYTHON="python"
    elif ask_install "Python 3"; then
        install_python || {
            echo "Error: Python could not be installed."
            exit 1
        }

        if command -v python3 >/dev/null 2>&1; then
            PYTHON="python3"
        elif command -v python >/dev/null 2>&1; then
            PYTHON="python"
        fi
    fi

    if [[ -z "$PYTHON" ]]; then
        echo "Error: Spotify lookup requires Python 3."
        exit 1
    fi

    load_spotify_env

    if [[ -z "$SPOTIFY_CLIENT_ID" || -z "$SPOTIFY_CLIENT_SECRET" ]]; then
        if [[ ! -t 0 ]]; then
            echo "Error: Spotify credentials are missing."
            echo "Set them in .env or export them in your shell."
            exit 1
        fi

        echo "Spotify credentials not found in environment or .env."

        if [[ -z "$SPOTIFY_CLIENT_ID" ]]; then
            read -r -p "Spotify Client ID: " SPOTIFY_CLIENT_ID </dev/tty
        fi

        if [[ -z "$SPOTIFY_CLIENT_SECRET" ]]; then
            read -r -s -p "Spotify Client Secret: " SPOTIFY_CLIENT_SECRET </dev/tty
            echo
        fi
    fi

    if [[ -z "$SPOTIFY_CLIENT_ID" || -z "$SPOTIFY_CLIENT_SECRET" ]]; then
        echo "Error: Spotify credentials cannot be empty."
        exit 1
    fi

    export SPOTIFY_CLIENT_ID SPOTIFY_CLIENT_SECRET
    echo "Spotify credentials loaded."
fi

# ============================================================
# Validate URL list and prepare output
# ============================================================

if [[ ! -f "$URLS_FILE" ]]; then
    echo "Error: URL list not found: $URLS_FILE"
    echo "Create urls.txt beside this script."
    exit 1
fi

mkdir -p "$DOWNLOAD_DIR" || {
    echo "Error: could not create output directory: $DOWNLOAD_DIR"
    exit 1
}

DOWNLOAD_DIR="$(cd -- "$DOWNLOAD_DIR" && pwd)" || exit 1
SPOTIFY_LINKS_FILE="$DOWNLOAD_DIR/spotify-links.tsv"

CLEAN_FILE="$(mktemp)" || exit 1
SELECTED_FILE="$(mktemp)" || {
    rm -f "$CLEAN_FILE"
    exit 1
}
trap 'rm -f "$CLEAN_FILE" "$SELECTED_FILE"' EXIT

# ============================================================
# Clean URL list
# ============================================================

while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" ]] && continue
    [[ "$line" == \#* ]] && continue

    printf '%s\n' "$line" >> "$CLEAN_FILE"
done < "$URLS_FILE"

TOTAL="$(wc -l < "$CLEAN_FILE" | tr -d '[:space:]')"

if [[ ! "$TOTAL" =~ ^[0-9]+$ ]] || (( TOTAL == 0 )); then
    echo "Error: no URLs found in $URLS_FILE."
    exit 1
fi

# ============================================================
# Apply URL range
# ============================================================

START=1
END="$TOTAL"

if [[ -n "$RANGE" ]]; then
    if [[ "$RANGE" =~ ^([0-9]+):([0-9]*)$ ]]; then
        START="${BASH_REMATCH[1]}"
        END="${BASH_REMATCH[2]:-$TOTAL}"
    elif [[ "$RANGE" =~ ^:([0-9]+)$ ]]; then
        START=1
        END="${BASH_REMATCH[1]}"
    elif [[ "$RANGE" =~ ^([0-9]+)-$ ]]; then
        START="${BASH_REMATCH[1]}"
        END="$TOTAL"
    else
        echo "Error: invalid range '$RANGE'."
        exit 1
    fi
fi

if (( START < 1 || END < START || START > TOTAL )); then
    echo "Error: range is outside the URL list."
    exit 1
fi

(( END > TOTAL )) && END="$TOTAL"

awk -v start="$START" -v end="$END" \
    'NR >= start && NR <= end { print NR "\t" $0 }' \
    "$CLEAN_FILE" > "$SELECTED_FILE"

SELECTED="$(wc -l < "$SELECTED_FILE" | tr -d '[:space:]')"

echo
echo "URLs in list:  $TOTAL"
echo "Selected:      $SELECTED (indexes $START through $END)"
echo "Output folder: $DOWNLOAD_DIR"

# ============================================================
# Completion tracking
# ============================================================

COMPLETED_MODE_FILE="${COMPLETED_FILE%.ts}-$MODE.tsv"
ARCHIVE_FILE="$DOWNLOAD_DIR/archive-$MODE.txt"

touch "$COMPLETED_MODE_FILE" || exit 1

is_completed() {
    local idx="$1"
    local url="$2"

    awk -F '\t' -v i="$idx" -v u="$url" -v m="$MODE" \
        '$1 == i && $2 == u && $3 == m { found=1 }
         END { exit !found }' "$COMPLETED_MODE_FILE"
}

record_completed() {
    local idx="$1"
    local url="$2"
    local tmp

    tmp="$(mktemp)" || return 1

    awk -F '\t' -v i="$idx" -v m="$MODE" \
        '!($1 == i && $3 == m)' \
        "$COMPLETED_MODE_FILE" > "$tmp" || {
            rm -f "$tmp"
            return 1
        }

    printf '%s\t%s\t%s\n' "$idx" "$url" "$MODE" >> "$tmp" || {
        rm -f "$tmp"
        return 1
    }

    mv "$tmp" "$COMPLETED_MODE_FILE"
}

# ============================================================
# Spotify result writer
#
# TSV columns:
# Source title, Source artist, Candidate title, Candidate artist,
# Spotify URL, Lookup method
#
# Existing five-column TSV files are upgraded automatically.
# ============================================================

write_spotify_result() {
    "$PYTHON" - "$SPOTIFY_LINKS_FILE" "$@" <<'PYTHON_WRITER'
import csv
import os
import sys
import tempfile

path, source_title, source_artist, candidate_title, candidate_artist, url, method = sys.argv[1:]

header = [
    "Source title",
    "Source artist",
    "Spotify candidate title",
    "Spotify candidate artist",
    "Spotify URL",
    "Lookup method",
]

rows = []

if os.path.exists(path) and os.path.getsize(path) > 0:
    try:
        with open(path, "r", newline="", encoding="utf-8") as f:
            rows = list(csv.reader(f, delimiter="\t"))
    except Exception:
        rows = []

    if rows:
        old_header = rows[0]
        if old_header != header:
            upgraded = [header]
            for row in rows[1:]:
                row = row[:]
                while len(row) < 6:
                    row.append("")
                if len(row) == 5:
                    row.append("Previous result")
                upgraded.append(row[:6])
            rows = upgraded
else:
    rows = [header]

rows.append([
    source_title,
    source_artist,
    candidate_title,
    candidate_artist,
    url,
    method,
])

directory = os.path.dirname(os.path.abspath(path))
fd, temp_path = tempfile.mkstemp(prefix=".spotify-links-", dir=directory)

try:
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, delimiter="\t", lineterminator="\n")
        writer.writerows(rows)
    os.replace(temp_path, path)
except Exception:
    try:
        os.unlink(temp_path)
    except OSError:
        pass
    raise

print("Saved Spotify result:", url)
PYTHON_WRITER
}

# ============================================================
# Spotify API lookup
#
# Exit 0 if the API returns a candidate and it is saved.
# Exit non-zero on API/auth/search failure, triggering web fallback.
# ============================================================

spotify_api_lookup() {
    local source_url="$1"

    "$PYTHON" - "$YTDLP" "$source_url" "$SPOTIFY_LINKS_FILE" <<'PYTHON_API'
import base64
import csv
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
import urllib.error
import tempfile

ytdlp, source_url, output_file = sys.argv[1:4]
client_id = os.environ.get("SPOTIFY_CLIENT_ID", "")
client_secret = os.environ.get("SPOTIFY_CLIENT_SECRET", "")

def fail(message):
    print("Spotify API warning:", message, file=sys.stderr)
    sys.exit(1)

try:
    result = subprocess.run(
        [ytdlp, "--dump-single-json", "--skip-download", source_url],
        capture_output=True,
        text=True,
        check=True,
        timeout=120,
    )
    metadata = json.loads(result.stdout)
except Exception as exc:
    fail("Could not read source metadata: " + str(exc))

source_title = (metadata.get("track") or metadata.get("title") or "").strip()
source_artist = (
    metadata.get("artist")
    or metadata.get("creator")
    or metadata.get("uploader")
    or ""
).strip()

if not source_title:
    fail("No title could be extracted from the source.")

if not client_id or not client_secret:
    fail("Spotify credentials are missing.")

print("Spotify API search:", source_title, "-", source_artist or "artist unknown")

token_data = urllib.parse.urlencode({
    "grant_type": "client_credentials",
}).encode("utf-8")

basic = base64.b64encode(
    (client_id + ":" + client_secret).encode("utf-8")
).decode("ascii")

token_request = urllib.request.Request(
    "https://accounts.spotify.com/api/token",
    data=token_data,
    headers={
        "Authorization": "Basic " + basic,
        "Content-Type": "application/x-www-form-urlencoded",
    },
    method="POST",
)

try:
    with urllib.request.urlopen(token_request, timeout=30) as response:
        token = json.loads(response.read().decode("utf-8"))["access_token"]
except Exception as exc:
    fail("Spotify authentication failed: " + str(exc))

query = f'track:{source_title} artist:{source_artist}' if source_artist else source_title
params = urllib.parse.urlencode({
    "q": query,
    "type": "track",
    "limit": 5,
})

search_request = urllib.request.Request(
    "https://api.spotify.com/v1/search?" + params,
    headers={"Authorization": "Bearer " + token},
)

try:
    with urllib.request.urlopen(search_request, timeout=30) as response:
        search_data = json.loads(response.read().decode("utf-8"))
except urllib.error.HTTPError as exc:
    detail = exc.read().decode("utf-8", errors="replace")
    fail(f"Spotify search returned HTTP {exc.code}: {detail[:400]}")
except Exception as exc:
    fail("Spotify search failed: " + str(exc))

tracks = search_data.get("tracks", {}).get("items", [])
if not tracks:
    fail("Spotify API returned no track candidates.")

match = tracks[0]
candidate_title = match.get("name", "")
candidate_artist = ", ".join(
    a.get("name", "") for a in match.get("artists", [])
)
spotify_url = match.get("external_urls", {}).get("spotify", "")

if not spotify_url and match.get("id"):
    spotify_url = "https://open.spotify.com/track/" + match["id"]

if not spotify_url:
    fail("The API result did not include a Spotify URL.")

header = [
    "Source title",
    "Source artist",
    "Spotify candidate title",
    "Spotify candidate artist",
    "Spotify URL",
    "Lookup method",
]

rows = []
if os.path.exists(output_file) and os.path.getsize(output_file) > 0:
    try:
        with open(output_file, "r", newline="", encoding="utf-8") as f:
            rows = list(csv.reader(f, delimiter="\t"))
    except Exception:
        rows = []

    if rows and rows[0] != header:
        upgraded = [header]
        for row in rows[1:]:
            row = row[:]
            while len(row) < 6:
                row.append("")
            if len(row) == 5:
                row.append("Previous result")
            upgraded.append(row[:6])
        rows = upgraded
else:
    rows = [header]

rows.append([
    source_title,
    source_artist,
    candidate_title,
    candidate_artist,
    spotify_url,
    "Spotify API",
])

fd, temp_path = tempfile.mkstemp(
    prefix=".spotify-links-",
    dir=os.path.dirname(os.path.abspath(output_file)),
)

try:
    with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
        csv.writer(f, delimiter="\t", lineterminator="\n").writerows(rows)
    os.replace(temp_path, output_file)
except Exception as exc:
    try:
        os.unlink(temp_path)
    except OSError:
        pass
    fail("Could not save the Spotify result: " + str(exc))

print("Spotify API candidate:", candidate_title, "-", candidate_artist)
print("Spotify link:", spotify_url)
PYTHON_API
}

# ============================================================
# Web fallback
#
# Search DuckDuckGo HTML for a direct Spotify track URL.
# If no direct result is available, save a Spotify search URL.
# Uses Python standard library only.
# ============================================================

spotify_web_lookup() {
    local source_url="$1"

    "$PYTHON" - "$YTDLP" "$source_url" "$SPOTIFY_LINKS_FILE" <<'PYTHON_WEB'
import csv
import html
import html.parser
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

ytdlp, source_url, output_file = sys.argv[1:4]

def get_metadata():
    result = subprocess.run(
        [ytdlp, "--dump-single-json", "--skip-download", source_url],
        capture_output=True,
        text=True,
        check=True,
        timeout=120,
    )
    data = json.loads(result.stdout)

    title = (data.get("track") or data.get("title") or "").strip()
    artist = (
        data.get("artist")
        or data.get("creator")
        or data.get("uploader")
        or ""
    ).strip()

    if not title:
        raise ValueError("No title could be extracted from source metadata.")

    return title, artist

class ResultParser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.results = []
        self._anchor = None
        self._parts = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)

        if tag == "a":
            classes = attrs.get("class", "").split()
            if "result__a" in classes and attrs.get("href"):
                self._anchor = attrs["href"]
                self._parts = []

    def handle_data(self, data):
        if self._anchor is not None:
            self._parts.append(data)

    def handle_endtag(self, tag):
        if tag == "a" and self._anchor is not None:
            title = " ".join("".join(self._parts).split())
            self.results.append((title, self._anchor))
            self._anchor = None
            self._parts = []

def unwrap_result_url(href):
    href = html.unescape(href)
    parsed = urllib.parse.urlparse(
        urllib.parse.urljoin("https://duckduckgo.com/", href)
    )
    params = urllib.parse.parse_qs(parsed.query)

    if "uddg" in params and params["uddg"]:
        return params["uddg"][0]

    return urllib.parse.urlunparse(parsed)

def spotify_track_url(url):
    parsed = urllib.parse.urlparse(url)
    host = (parsed.hostname or "").lower()

    if host not in ("open.spotify.com", "www.open.spotify.com"):
        return ""

    match = re.search(
        r"/(?:intl-[^/]+/)?track/([A-Za-z0-9]+)",
        parsed.path,
    )

    if not match:
        return ""

    return "https://open.spotify.com/track/" + match.group(1)

def search_web(title, artist):
    query = f'site:open.spotify.com/track "{title}"'
    if artist:
        query += f' "{artist}"'

    search_url = (
        "https://html.duckduckgo.com/html/?"
        + urllib.parse.urlencode({"q": query})
    )

    request = urllib.request.Request(
        search_url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/131.0 Safari/537.36"
            ),
            "Accept": "text/html,application/xhtml+xml",
        },
    )

    with urllib.request.urlopen(request, timeout=25) as response:
        page = response.read().decode("utf-8", errors="replace")

    parser = ResultParser()
    parser.feed(page)

    for result_title, href in parser.results:
        target = unwrap_result_url(href)
        track_url = spotify_track_url(target)
        if track_url:
            return result_title, track_url

    return "", ""

def save_result(source_title, source_artist, candidate_title,
                candidate_artist, url, method):
    header = [
        "Source title",
        "Source artist",
        "Spotify candidate title",
        "Spotify candidate artist",
        "Spotify URL",
        "Lookup method",
    ]

    rows = []
    if os.path.exists(output_file) and os.path.getsize(output_file) > 0:
        try:
            with open(output_file, "r", newline="", encoding="utf-8") as f:
                rows = list(csv.reader(f, delimiter="\t"))
        except Exception:
            rows = []

        if rows and rows[0] != header:
            upgraded = [header]
            for row in rows[1:]:
                row = row[:]
                while len(row) < 6:
                    row.append("")
                if len(row) == 5:
                    row.append("Previous result")
                upgraded.append(row[:6])
            rows = upgraded
    else:
        rows = [header]

    rows.append([
        source_title,
        source_artist,
        candidate_title,
        candidate_artist,
        url,
        method,
    ])

    fd, temp_path = tempfile.mkstemp(
        prefix=".spotify-links-",
        dir=os.path.dirname(os.path.abspath(output_file)),
    )

    try:
        with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
            csv.writer(f, delimiter="\t", lineterminator="\n").writerows(rows)
        os.replace(temp_path, output_file)
    except Exception:
        try:
            os.unlink(temp_path)
        except OSError:
            pass
        raise

try:
    source_title, source_artist = get_metadata()
except Exception as exc:
    print("Web fallback warning: could not read source metadata:", exc,
          file=sys.stderr)
    sys.exit(1)

print("Web search:", source_title, "-", source_artist or "artist unknown")

try:
    candidate_title, track_url = search_web(source_title, source_artist)

    if track_url:
        # The title is the search engine's result title, not independently
        # verified Spotify metadata.
        save_result(
            source_title,
            source_artist,
            candidate_title,
            "",
            track_url,
            "Web search",
        )
        print("Web candidate:", candidate_title)
        print("Spotify track link:", track_url)
        print("Please verify the candidate before relying on it.")
        sys.exit(0)

    # Search did not expose a direct Spotify track URL. Still provide a
    # useful Spotify search page without falsely claiming an exact match.
    query = " ".join(part for part in (source_title, source_artist) if part)
    search_link = (
        "https://open.spotify.com/search/"
        + urllib.parse.quote(query, safe="")
    )

    save_result(
        source_title,
        source_artist,
        "Spotify search page (no direct track match found)",
        "",
        search_link,
        "Spotify search fallback",
    )

    print("No direct Spotify track URL was found by web search.")
    print("Saved Spotify search page:", search_link)
    sys.exit(0)

except urllib.error.HTTPError as exc:
    print(f"Web search warning: HTTP {exc.code}", file=sys.stderr)
except Exception as exc:
    print("Web search warning:", str(exc), file=sys.stderr)

# The search engine may be unavailable or may block automated requests.
# In that case, save a Spotify search link rather than inventing a match.
try:
    query = " ".join(part for part in (source_title, source_artist) if part)
    search_link = (
        "https://open.spotify.com/search/"
        + urllib.parse.quote(query, safe="")
    )

    save_result(
        source_title,
        source_artist,
        "Spotify search page (web search unavailable)",
        "",
        search_link,
        "Spotify search fallback",
    )

    print("Web search was unavailable.")
    print("Saved Spotify search page instead:", search_link)
    sys.exit(0)

except Exception as exc:
    print("Could not save Spotify search fallback:", exc, file=sys.stderr)
    sys.exit(1)
PYTHON_WEB
}

# ============================================================
# Spotify workflow: API first, web fallback if it fails
# ============================================================

spotify_lookup() {
    local url="$1"

    echo "Trying Spotify API first..."

    if spotify_api_lookup "$url"; then
        echo "Spotify API lookup succeeded."
        return 0
    fi

    echo
    echo "Spotify API failed. Falling back to web search..."
    echo "This can happen if the API returns HTTP 403 or other errors."

    if spotify_web_lookup "$url"; then
        echo "Spotify web fallback completed."
        return 0
    fi

    echo "Warning: both Spotify API and web fallback failed."
    return 1
}

# ============================================================
# Download loop
# ============================================================

SUCCESS=0
SKIPPED=0
FAILED=0
SPOTIFY_MATCHES=0
SPOTIFY_FAILURES=0
CURRENT=0

while IFS=$'\t' read -r INDEX URL; do
    [[ -z "${URL:-}" ]] && continue
    CURRENT=$((CURRENT + 1))

    echo
    echo "============================================================"
    echo "Item $CURRENT of $SELECTED (URL index $INDEX)"
    echo "Mode: $MODE"
    echo "URL:  $URL"
    echo "============================================================"

    if (( REDOWNLOAD == 0 )) && is_completed "$INDEX" "$URL"; then
        echo "Already completed for this mode; skipping."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    ARGS=(
        --continue
        --output "$DOWNLOAD_DIR/%(title)s [%(id)s].%(ext)s"
    )

    if (( REDOWNLOAD == 0 )); then
        ARGS+=(--download-archive "$ARCHIVE_FILE")
        ARGS+=(--no-overwrites)
    else
        ARGS+=(--force-overwrites)
    fi

    case "$MODE" in
        video)
            ARGS+=(-f 'bv*+ba/b')
            ;;
        mp4)
            ARGS+=(-f 'bv*+ba/b' --merge-output-format mp4)
            ;;
        audio)
            ARGS+=(-x)
            ;;
        mp3)
            ARGS+=(-x --audio-format mp3)
            ;;
    esac

    if "$YTDLP" "${ARGS[@]}" "$URL"; then
        if record_completed "$INDEX" "$URL"; then
            echo "Download completed and recorded."
            SUCCESS=$((SUCCESS + 1))

            if (( SPOTIFY == 1 )); then
                echo
                echo "Looking for a Spotify match..."

                if spotify_lookup "$URL"; then
                    SPOTIFY_MATCHES=$((SPOTIFY_MATCHES + 1))
                else
                    echo "Spotify lookup failed; download itself succeeded."
                    SPOTIFY_FAILURES=$((SPOTIFY_FAILURES + 1))
                fi
            fi
        else
            echo "Warning: download succeeded, but completion tracking failed."
            FAILED=$((FAILED + 1))
        fi
    else
        echo "Download failed. It can be retried on the next run."
        FAILED=$((FAILED + 1))
    fi
done < "$SELECTED_FILE"

# ============================================================
# Summary
# ============================================================

echo
echo "==================== SUMMARY ===================="
echo "Mode:             $MODE"
echo "Succeeded:        $SUCCESS"
echo "Skipped:          $SKIPPED"
echo "Failed downloads: $FAILED"

if (( SPOTIFY == 1 )); then
    echo "Spotify results:  $SPOTIFY_MATCHES"
    echo "Lookup failures:  $SPOTIFY_FAILURES"
    echo "Spotify links:    $SPOTIFY_LINKS_FILE"
fi

echo "Output directory: $DOWNLOAD_DIR"
echo "Completion index: $COMPLETED_MODE_FILE"
echo "================================================="

if (( FAILED > 0 )); then
    exit 1
fi

exit 0
