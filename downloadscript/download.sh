
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

# Existing exported variables take priority over .env.
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
  --redownload             Redownload even if previously completed
  --spotify                Search Spotify after successful downloads
  --help, -h               Show this help

Examples:
  ./download.sh
  ./download.sh --mp4
  ./download.sh --mp3 --spotify
  ./download.sh --audio --spotify --range 1:10
  ./download.sh --mp3 --spotify -o "$HOME/Music"
  ./download.sh --mp4 -o .
  ./download.sh --redownload --range 1:5

Input:
  urls.txt beside this script, one URL per line.
  Blank lines and lines starting with # are ignored.

Spotify:
  Reads SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET from exported
  environment variables first, then from .env beside this script.
  Prompts for missing credentials when running interactively.
  .example.env is a template and is not loaded automatically.
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
if (( SPOTIFY == 1 )); then
    echo "Spotify lookup:   enabled"
else
    echo "Spotify lookup:   disabled"
fi

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
else
    if ask_install "FFmpeg"; then
        install_ffmpeg && FFMPEG_AVAILABLE=1
    fi
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
# Spotify credentials: exported environment first, then .env
# ============================================================

load_spotify_env() {
    local line key value

    [[ -f "$ENV_FILE" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        # Ignore blank lines and comments.
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Support KEY=value and export KEY=value.
        line="${line#export }"

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"

            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"

            # Remove surrounding matching quotes.
            if [[ "$value" == \"*\" && "$value" == *\" ]]; then
                value="${value:1:${#value}-2}"
            elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
                value="${value:1:${#value}-2}"
            fi

            case "$key" in
                SPOTIFY_CLIENT_ID)
                    if [[ -z "$SPOTIFY_CLIENT_ID" ]]; then
                        SPOTIFY_CLIENT_ID="$value"
                    fi
                    ;;
                SPOTIFY_CLIENT_SECRET)
                    if [[ -z "$SPOTIFY_CLIENT_SECRET" ]]; then
                        SPOTIFY_CLIENT_SECRET="$value"
                    fi
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
    else
        if ask_install "Python 3"; then
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
    fi

    if [[ -z "$PYTHON" ]]; then
        echo "Error: Spotify lookup requires Python 3."
        exit 1
    fi

    # Only fill missing values from .env; exported values win.
    load_spotify_env

    # Prompt for any credentials still missing.
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
# Validate input and prepare output directory
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

if (( SPOTIFY == 1 )); then
    SPOTIFY_LINKS_FILE="$DOWNLOAD_DIR/spotify-links.tsv"
fi

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
# Spotify lookup helper
# ============================================================

spotify_lookup() {
    local url="$1"

    "$PYTHON" - "$YTDLP" "$url" "$SPOTIFY_LINKS_FILE" <<'PYTHON_SCRIPT'
import base64
import csv
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
import urllib.error

ytdlp, source_url, output_file = sys.argv[1:4]
client_id = os.environ.get("SPOTIFY_CLIENT_ID", "")
client_secret = os.environ.get("SPOTIFY_CLIENT_SECRET", "")

def fail(message):
    print("Spotify lookup warning:", message, file=sys.stderr)
    sys.exit(1)

if not client_id or not client_secret:
    fail("Spotify credentials are missing.")

# Read metadata without downloading the source a second time.
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

title = (metadata.get("track") or metadata.get("title") or "").strip()
artist = (
    metadata.get("artist")
    or metadata.get("creator")
    or metadata.get("uploader")
    or ""
).strip()

if not title:
    fail("No title could be extracted from the source.")

print("Spotify search:", title, "-", artist or "artist unknown")

# Spotify Client Credentials flow.
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
    fail("Spotify authentication failed; check credentials and API eligibility: " + str(exc))

query = f'track:{title} artist:{artist}' if artist else title
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
    fail(f"Spotify search returned HTTP {exc.code}: {detail[:300]}")
except Exception as exc:
    fail("Spotify search failed: " + str(exc))

tracks = search_data.get("tracks", {}).get("items", [])
if not tracks:
    fail("No matching Spotify track found.")

# First result is a candidate, not a guaranteed exact recording.
match = tracks[0]
matched_title = match.get("name", "")
matched_artists = ", ".join(
    a.get("name", "") for a in match.get("artists", [])
)
spotify_url = match.get("external_urls", {}).get("spotify", "")

if not spotify_url and match.get("id"):
    spotify_url = "https://open.spotify.com/track/" + match["id"]

if not spotify_url:
    fail("The top result did not include a shareable Spotify URL.")

exists = os.path.exists(output_file) and os.path.getsize(output_file) > 0

try:
    with open(output_file, "a", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, delimiter="\t", lineterminator="\n")
        if not exists:
            writer.writerow([
                "Source title",
                "Source artist",
                "Spotify title",
                "Spotify artist",
                "Spotify URL",
            ])
        writer.writerow([
            title,
            artist,
            matched_title,
            matched_artists,
            spotify_url,
        ])
except Exception as exc:
    fail("Could not write Spotify link file: " + str(exc))

print("Spotify candidate:", matched_title, "-", matched_artists)
print("Spotify link:", spotify_url)
print("Saved to:", output_file)
PYTHON_SCRIPT
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
    echo "Spotify matches:  $SPOTIFY_MATCHES"
    echo "Spotify failures: $SPOTIFY_FAILURES"
    echo "Spotify links:    $SPOTIFY_LINKS_FILE"
fi

echo "Output directory: $DOWNLOAD_DIR"
echo "Completion index: $COMPLETED_MODE_FILE"
echo "================================================="

if (( FAILED > 0 )); then
    exit 1
fi

exit 0
