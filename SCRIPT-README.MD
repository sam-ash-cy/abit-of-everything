# Download Script README

A cross-platform Bash script for downloading videos or audio from URLs using `yt-dlp`. Supports batch downloads, URL ranges, completion tracking, custom output directories, and optional Spotify track lookup.

## Contents

- [Features](#features)
- [Requirements](#requirements)
- [Project Structure](#project-structure)
- [Setup](#setup)
- [Spotify Configuration](#spotify-configuration)
- [Usage](#usage)
- [URL List Format](#url-list-format)
- [Download Modes](#download-modes)
- [Output and Tracking](#output-and-tracking)
- [Redownloading Files](#redownloading-files)
- [Troubleshooting](#troubleshooting)
- [Security Notes](#security-notes)

## Features

- Downloads video, MP4, audio, or MP3 using `yt-dlp`.
- Processes multiple URLs from one text file.
- Ignores blank lines and comment lines in the URL list.
- Supports downloading a specific range of URL indexes.
- Tracks completed downloads to avoid repeating work.
- Supports a `--redownload` option to retry completed items.
- Allows a custom output directory.
- Checks for required tools and offers to install missing dependencies on supported systems.
- Optionally searches Spotify after a successful download and records a candidate match.
- Reads Spotify API credentials from environment variables or a local `.env` file.

## Requirements

### Supported environments

The script is designed for Bash environments on:

- macOS
- Linux
- Windows Subsystem for Linux (WSL)
- Windows with Git Bash, subject to the availability of compatible dependencies

### Dependencies

| Dependency | Purpose |
|---|---|
| Bash | Runs the script |
| `yt-dlp` | Downloads supported media |
| FFmpeg | Merges separate video/audio streams and converts audio |
| Python 3 | Required for Spotify lookup |

The script checks for missing dependencies and may offer to install them using a detected package manager. Installation depends on your operating system, permissions, and package availability. Some installations may require administrator privileges or a terminal restart.

You can also install dependencies manually:

- yt-dlp: https://github.com/yt-dlp/yt-dlp
- FFmpeg: https://ffmpeg.org/download.html
- Python: https://www.python.org/downloads/

## Setup

### 1. Put the files together

Save `download.sh`, `urls.txt`, and your environment files in the same directory.

### 2. Create the URL list

Create a file named `urls.txt`. Add one supported media URL per line.

Example:

```text
https://www.youtube.com/watch?v=EXAMPLE01
https://www.youtube.com/watch?v=EXAMPLE02

# This line is a comment and will be ignored.
https://www.youtube.com/watch?v=EXAMPLE03
```

Replace the example URLs with real URLs.

Blank lines and lines beginning with `#` are ignored. URL indexes refer to the cleaned list, not the original line numbers in the file.

### 3. Make the script executable

On macOS, Linux, or WSL, run:

```bash
chmod +x download.sh
```

### 4. Run the script

For the default video download mode:

```bash
./download.sh
```

You can also explicitly select a mode:

```bash
./download.sh --video
```

On Windows, run the script from Git Bash if your installed dependencies are compatible with that environment.

## Spotify Configuration

Spotify lookup is optional. The script can search Spotify after each successful download and save the top candidate match to a TSV file.

### 1. Create Spotify API credentials

Create a Spotify developer application and obtain its Client ID and Client Secret.

Spotify developer documentation:

https://developer.spotify.com/documentation/web-api

API availability and eligibility may depend on Spotify's current developer policies and your application access.

### 2. Configure `.env`

Create a file named `.env` beside `download.sh`:

```dotenv
SPOTIFY_CLIENT_ID=your_actual_client_id
SPOTIFY_CLIENT_SECRET=your_actual_client_secret
```

Replace the placeholders with your actual credentials.

The script reads these two keys from `.env` when Spotify lookup is enabled. Existing non-empty environment variables take priority over values in `.env`.

The `.env` parser supports simple `KEY=value` entries, optional matching single or double quotes, blank lines, comment lines, and an optional `export` prefix. Avoid relying on shell variable expansion, escaped values, or inline comments.

### 3. Keep `.example.env` as a template

Create `.example.env` for sharing the expected configuration without sharing secrets:

```dotenv
SPOTIFY_CLIENT_ID=your_client_id_here
SPOTIFY_CLIENT_SECRET=your_client_secret_here
```

The script does **not** automatically load `.example.env`. Copy it to `.env` and fill in your credentials.

### 4. Alternatively, export credentials

You can set the variables in your shell instead of putting them in `.env`.

```bash
export SPOTIFY_CLIENT_ID="your_actual_client_id"
export SPOTIFY_CLIENT_SECRET="your_actual_client_secret"

./download.sh --mp3 --spotify
```

If a required credential is missing, the script attempts to prompt for it when running interactively.

### 5. Run Spotify lookup

```bash
./download.sh --mp3 --spotify
```

After a successful download, the script reads the source metadata, searches Spotify, and saves the top candidate to:

```text
downloads/spotify-links.tsv
```

If you specify a custom output directory, the TSV file is written there instead.

**Important:** Spotify search results are candidates, not guaranteed exact matches. Review the title and artist in the TSV file before using a link. Spotify lookup can fail independently of the media download.

## Usage

General syntax:

```bash
./download.sh [OPTIONS]
```

### Download modes

Download video with the default settings:

```bash
./download.sh --video
```

Download and merge into MP4:

```bash
./download.sh --mp4
```

Extract audio:

```bash
./download.sh --audio
```

Extract and convert audio to MP3:

```bash
./download.sh --mp3
```

### Use a custom output directory

Specify a destination with `--output-dir` or `-o`:

```bash
./download.sh --mp3 --output-dir "$HOME/Music"
```

Or use the shorter option:

```bash
./download.sh --mp4 -o ./my-videos
```

Relative output paths are resolved relative to the directory containing `download.sh`. The default output directory is `downloads/` beside the script.

### Download a range of URLs

Download URL indexes 1 through 10:

```bash
./download.sh --mp3 --range 1:10
```

Download indexes 5 through 12:

```bash
./download.sh --mp4 --range 5:12
```

Download from index 8 through the end:

```bash
./download.sh --video --range 8:
```

The script also accepts a hyphen form for a range that runs to the end:

```bash
./download.sh --video --range 8-
```

Download from the beginning through index 5:

```bash
./download.sh --audio --range :5
```

Ranges use **1-based indexes** from the cleaned URL list. An index outside the available list, or an invalid range, causes an error.

### Combine options

Options can be combined:

```bash
./download.sh --mp3 --spotify --range 1:10 -o "$HOME/Music"
```

This extracts MP3s for the first ten URLs, searches Spotify after successful downloads, and saves output to your Music directory.

### Show help

```bash
./download.sh --help
```

## URL List Format

The URL list is read from `urls.txt` beside the script.

Example:

```text
# Music
https://example.com/audio-one

# Video
https://www.youtube.com/watch?v=EXAMPLE01

https://www.youtube.com/watch?v=EXAMPLE02
```

Rules:

- One URL per line.
- Empty lines are ignored.
- Lines whose first non-whitespace character is `#` are ignored.
- URL indexes are assigned after blank and comment lines are removed.
- Update