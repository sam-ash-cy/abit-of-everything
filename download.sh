
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

MODE="video"
RANGE=""
REDOWNLOAD=0

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
  --audio                 Extract audio in the best available format
  --mp3                   Extract and convert audio to MP3

Options:
  --output-dir DIR, -o DIR
                          Directory for downloaded files
                          Default: ./downloads beside this script
  --range START:END       Download a range of URLs (1-based)
  --range START:          Download from START to the end
  --range :END            Download from the beginning through END
  --range START-          Download from START to the end
  --redownload             Ignore completion index and redownload
  --help, -h               Show this help

Examples:
  ./download.sh
  ./download.sh --mp4
  ./download.sh --mp3
  ./download.sh --range 1:10
  ./download.sh --mp4 --range 5:20
  ./download.sh --mp3 --redownload
  ./download.sh --output-dir "$HOME/Videos"
  ./download.sh --mp3 -o "$HOME/Music"
  ./download.sh -o .
  ./download.sh -o "My Videos"

Input:
  urls.txt beside this script, one URL per line.
  Blank lines and lines starting with # are ignored.

Dependencies:
  yt-dlp - required for all downloads
  FFmpeg - required for audio extraction and MP3 conversion;
           recommended for merging video and audio streams
EOF
}

# ============================================================
# Parse arguments
# ============================================================

while (($#)); do
    case "$1" in
        --video|video)
            MODE="video"
            ;;
        --mp4|mp4)
            MODE="mp4"
            ;;
        --audio|audio)
            MODE="audio"
            ;;
        --mp3|mp3)
            MODE="mp3"
            ;;
        --range)
            if (($# < 2)); then
                echo "Error: --range requires a value such as 1:10."
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
        --redownload)
            REDOWNLOAD=1
            ;;
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

# Expand ~ when provided as the entire path or at its start.
case "$DOWNLOAD_DIR" in
    "~")
        DOWNLOAD_DIR="$HOME"
        ;;
    "~/"*)
        DOWNLOAD_DIR="$HOME/${DOWNLOAD_DIR#~/}"
        ;;
esac

# Resolve relative paths against the script directory.
# Absolute Unix paths and Windows drive-letter paths are preserved.
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
echo "Download mode:    $MODE"
echo "Output directory: $DOWNLOAD_DIR"

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
        n|N|no|NO|No)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

ensure_sudo() {
    if [[ "$OS" == "macos" || "$OS" == "linux" || "$OS" == "wsl" ]]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "Error: sudo is unavailable. Install the dependency manually."
            return 1
        fi

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
    echo
    echo "Attempting to install yt-dlp..."

    case "$OS" in
        macos)
            if ! command -v brew >/dev/null 2>&1; then
                echo "Homebrew is not installed."
                echo "Install Homebrew from https://brew.sh/"
                return 1
            fi

            brew install yt-dlp || brew upgrade yt-dlp
            ;;

        linux|wsl)
            if command -v apt-get >/dev/null 2>&1; then
                ensure_sudo || return 1
                sudo apt-get update || return 1

                if ! sudo apt-get install -y yt-dlp; then
                    echo "Trying pipx as an alternative..."

                    if ! command -v pipx >/dev/null 2>&1; then
                        sudo apt-get install -y pipx || return 1
                    fi

                    refresh_path
                    pipx install yt-dlp ||
                        pipx upgrade yt-dlp ||
                        return 1
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
                echo "No supported package manager was detected."
                echo "Install yt-dlp manually: https://github.com/yt-dlp/yt-dlp"
                return 1
            fi
            ;;

        gitbash)
            if ! command -v winget >/dev/null 2>&1; then
                echo "winget is unavailable."
                echo "Install yt-dlp manually: https://github.com/yt-dlp/yt-dlp"
                return 1
            fi

            winget install --id yt-dlp.yt-dlp \
                --exact --accept-source-agreements \
                --accept-package-agreements || return 1

            echo "Restart Git Bash if yt-dlp is not found."
            ;;

        *)
            echo "Unsupported operating system."
            echo "Install yt-dlp manually: https://github.com/yt-dlp/yt-dlp"
            return 1
            ;;
    esac

    refresh_path

    if command -v yt-dlp >/dev/null 2>&1; then
        yt-dlp --version
        echo "yt-dlp is ready."
        return 0
    fi

    if command -v yt-dlp.exe >/dev/null 2>&1; then
        echo "yt-dlp.exe is ready."
        return 0
    fi

    echo "yt-dlp installation was attempted but it is still unavailable."
    echo "Restart your terminal if necessary, then rerun this script."
    return 1
}

# ============================================================
# Install FFmpeg
# ============================================================

install_ffmpeg() {
    echo
    echo "Attempting to install FFmpeg..."

    case "$OS" in
        macos)
            if ! command -v brew >/dev/null 2>&1; then
                echo "Homebrew is required for automatic FFmpeg installation."
                echo "Install it from https://brew.sh/"
                return 1
            fi

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
                echo "No supported package manager was detected."
                echo "Install FFmpeg manually: https://ffmpeg.org/download.html"
                return 1
            fi
            ;;

        gitbash)
            if ! command -v winget >/dev/null 2>&1; then
                echo "winget is unavailable."
                echo "Install FFmpeg manually: https://ffmpeg.org/download.html"
                return 1
            fi

            winget install --id Gyan.FFmpeg.Shared \
                --exact --accept-source-agreements \
                --accept-package-agreements || return 1

            echo "Restart Git Bash if FFmpeg is not found."
            ;;

        *)
            echo "Unsupported operating system."
            echo "Install FFmpeg manually: https://ffmpeg.org/download.html"
            return 1
            ;;
    esac

    refresh_path

    if command -v ffmpeg >/dev/null 2>&1; then
        ffmpeg -version | head -n 1
        echo "FFmpeg is ready."
        return 0
    fi

    echo "FFmpeg installation was attempted but it is still unavailable."
    echo "Restart your terminal if necessary."
    return 1
}

# ============================================================
# Check dependencies
# ============================================================

if ! command -v yt-dlp >/dev/null 2>&1 &&
   ! command -v yt-dlp.exe >/dev/null 2>&1; then

    echo "yt-dlp was not found."

    if ask_install "yt-dlp"; then
        install_ytdlp || {
            echo "Error: yt-dlp could not be installed."
            exit 1
        }
    else
        echo "yt-dlp is required. Exiting."
        exit 1
    fi
else
    echo "yt-dlp is installed."
fi

if command -v yt-dlp >/dev/null 2>&1; then
    YTDLP="yt-dlp"
else
    YTDLP="yt-dlp.exe"
fi

FFMPEG_AVAILABLE=0

if command -v ffmpeg >/dev/null 2>&1; then
    FFMPEG_AVAILABLE=1
    echo "FFmpeg is installed."
else
    echo "FFmpeg was not found."

    if ask_install "FFmpeg"; then
        if install_ffmpeg; then
            FFMPEG_AVAILABLE=1
        else
            echo "FFmpeg installation failed."
        fi
    else
        echo "FFmpeg installation declined."
    fi
fi

if [[ "$MODE" == "audio" || "$MODE" == "mp3" ]] &&
   (( FFMPEG_AVAILABLE == 0 )); then
    echo
    echo "Error: $MODE mode requires FFmpeg."
    echo "Install FFmpeg and rerun the script."
    exit 1
fi

if [[ "$MODE" == "video" || "$MODE" == "mp4" ]] &&
   (( FFMPEG_AVAILABLE == 0 )); then
    echo
    echo "Warning: FFmpeg is unavailable."
    echo "Video merging may fail or produce lower-quality results."
fi

# ============================================================
# Validate input and create output directory
# ============================================================

if [[ ! -f "$URLS_FILE" ]]; then
    echo "Error: URL list not found: $URLS_FILE"
    echo "Create urls.txt beside this script, with one URL per line."
    exit 1
fi

mkdir -p "$DOWNLOAD_DIR" || {
    echo "Error: could not create output directory: $DOWNLOAD_DIR"
    exit 1
}

DOWNLOAD_DIR="$(cd -- "$DOWNLOAD_DIR" && pwd)" || exit 1

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
    echo "Error: no URLs found in $URLS_FILE"
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
        echo "Use START:END, START:, :END, or START-."
        exit 1
    fi
fi

if (( START < 1 || END < START || START > TOTAL )); then
    echo "Error: range is outside the URL list."
    echo "Valid URL indexes: 1 through $TOTAL"
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
         END { exit !found }' \
        "$COMPLETED_MODE_FILE"
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
# Download loop
# ============================================================

SUCCESS=0
SKIPPED=0
FAILED=0
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
echo "Mode:       $MODE"
echo "Succeeded:  $SUCCESS"
echo "Skipped:    $SKIPPED"
echo "Failed:     $FAILED"
echo "Output:     $DOWNLOAD_DIR"
echo "Index:      $COMPLETED_MODE_FILE"
echo "================================================="

if (( FAILED > 0 )); then
    exit 1
fi

exit 0

