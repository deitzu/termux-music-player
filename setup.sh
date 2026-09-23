#!/data/data/com.termux/files/usr/bin/bash
set -e

APP_NAME="termux-music-player"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
CONFIG_DIR="$HOME/.config/$APP_NAME"
CONFIG_FILE="$CONFIG_DIR/config"

usage() {
    cat <<'EOF'
Usage:
  bash setup.sh
  bash setup.sh --install-deps
EOF
}

install_deps=0

while (($# > 0)); do
    case "$1" in
        --install-deps)
            install_deps=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$PREFIX" || "$PREFIX" != /data/data/com.termux/files/usr ]]; then
    echo "Error: this setup script is intended for Termux." >&2
    exit 1
fi

if ((install_deps)); then
    echo "Installing runtime dependencies..."
    echo "Stock Termux mpv currently depends on ffmpeg and a large media stack."
    apt clean || true
    pkg install -y mpv curl jq socat
    apt clean || true
else
    echo "Checking runtime dependencies..."
    missing=""
    for command in mpv curl jq socat; do
        if ! command -v "$command" >/dev/null 2>&1; then
            missing="$missing $command"
        fi
    done

    if [[ -n "$missing" ]]; then
        echo "Missing:$missing"
        echo "Run: bash setup.sh --install-deps"
        echo
        echo "The player script does not call ffprobe or ffmpeg."
        echo "Stock Termux mpv may still install ffmpeg transitively."
        exit 1
    fi
fi

mkdir -p "$CONFIG_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" <<'EOF'
# Subtitle timing adjustment in milliseconds.
# Positive values delay subtitles.
# Negative values make subtitles appear earlier.
SUBTITLE_OFFSET_MS=0

# Poll interval for mpv playback position.
POLL_INTERVAL=0.20

# Maximum seconds for an LRCLIB request.
LRCLIB_TIMEOUT=15
EOF
    echo "Created config: $CONFIG_FILE"
fi

cp "$SCRIPT_DIR/music.sh" "$PREFIX/bin/$APP_NAME"
chmod 755 "$PREFIX/bin/$APP_NAME"

echo
echo "Installed: $PREFIX/bin/$APP_NAME"
echo "Run:"
echo "  $APP_NAME ~/Music/song.mp3"
