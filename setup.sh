#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

APP_NAME="termux-music-player"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PREFIX="$PREFIX"

if [[ -z "$PREFIX" || "$PREFIX" != /data/data/com.termux/files/usr ]]; then
    echo "This setup script is intended for Termux." >&2
    exit 1
fi

echo "Installing dependencies..."
pkg update
pkg install -y bash curl jq mpv ffmpeg socat coreutils

echo "Installing $APP_NAME..."
cp "$SCRIPT_DIR/music.sh" "$PREFIX/bin/$APP_NAME"
chmod 755 "$PREFIX/bin/$APP_NAME"

CONFIG_DIR="$HOME/.config/$APP_NAME"
CONFIG_FILE="$CONFIG_DIR/config"
mkdir -p "$CONFIG_DIR"

if [[ ! -f "$CONFIG_FILE" ]]; then
    cp "$SCRIPT_DIR/config.example" "$CONFIG_FILE"
    echo "Created config: $CONFIG_FILE"
else
    echo "Keeping existing config: $CONFIG_FILE"
fi

echo
echo "Installed: $PREFIX/bin/$APP_NAME"
echo "Run it with:"
echo "  $APP_NAME ~/Music/song.mp3"
