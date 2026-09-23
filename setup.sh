#!/data/data/com.termux/files/usr/bin/bash
set -e

APP_NAME="termux-music-player"
CLONER_NAME="music-clone"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
CONFIG_DIR="$HOME/.config/$APP_NAME"
CONFIG_FILE="$CONFIG_DIR/config"
BASHRC="$HOME/.bashrc"

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
    echo "Installing lightweight dependencies..."
    pkg install -y curl jq coreutils
else
    echo "Checking dependencies..."
fi

missing=""
for command in termux-media-player curl jq sha256sum awk sed dd od cut head wc mktemp find tr cp mkdir dirname; do
    if ! command -v "$command" >/dev/null 2>&1; then
        missing="$missing $command"
    fi
done

if [[ -n "$missing" ]]; then
    echo "Missing:$missing"
    echo "Run: bash setup.sh --install-deps"
    exit 1
fi

if ! command -v termux-media-player >/dev/null 2>&1; then
    echo
    echo "termux-media-player is unavailable."
    echo "On non-Play Termux builds, install the Termux:API integration."
    echo "On recent Google Play Termux builds, it should be available in Termux."
    exit 1
fi

mkdir -p "$CONFIG_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" <<'EOF'
# Subtitle timing adjustment in milliseconds.
# Positive values delay subtitles.
# Negative values make subtitles appear earlier.
SUBTITLE_OFFSET_MS=0

# Poll interval for termux-media-player playback position.
POLL_INTERVAL=0.20

# Maximum seconds for an LRCLIB request.
LRCLIB_TIMEOUT=15
EOF
    echo "Created config: $CONFIG_FILE"
fi

cp "$SCRIPT_DIR/music.sh" "$PREFIX/bin/$APP_NAME"
cp "$SCRIPT_DIR/music-clone" "$PREFIX/bin/$CLONER_NAME"
chmod 755 "$PREFIX/bin/$APP_NAME" "$PREFIX/bin/$CLONER_NAME"

touch "$BASHRC"

# Keep one canonical alias block so rerunning setup updates it instead of
# stacking duplicate aliases into .bashrc.
sed -i '/^# termux-music-player aliases$/,/^# end termux-music-player aliases$/d' "$BASHRC"

{
    echo
    echo "# termux-music-player aliases"
    echo "alias music='$APP_NAME'"
    echo "alias mclone='$CLONER_NAME'"
    echo "alias mwatch='$CLONER_NAME --watch'"
    echo "# end termux-music-player aliases"
} >> "$BASHRC"

echo "Updated aliases: music, mclone, mwatch"

echo
echo "Installed:"
echo "  $PREFIX/bin/$APP_NAME"
echo "  $PREFIX/bin/$CLONER_NAME"
echo
echo "Commands:"
echo "  music <file>       Play music with synced lyrics"
echo "  mclone             Clone music from Downloads"
echo "  mclone --watch     Keep cloning new/updated music"
echo
echo "Reload Bash after setup with:"
echo "  source ~/.bashrc"
