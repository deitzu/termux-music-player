#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

VERSION="0.1.0"
APP_NAME="termux-music-player"
CONFIG_DIR="$HOME/.config/$APP_NAME"
CACHE_DIR="$HOME/.cache/$APP_NAME/lyrics"
CONFIG_FILE="$CONFIG_DIR/config"
LRCLIB_API="https://lrclib.net/api/get"
USER_AGENT="$APP_NAME/$VERSION (https://github.com/deitzu/termux-music-player)"

SUBTITLE_OFFSET_MS=0
POLL_INTERVAL=0.10
LRCLIB_TIMEOUT=15

MUSIC_FILE=""
TITLE=""
ARTIST=""
ALBUM=""
DURATION_RAW=""
DURATION_LOOKUP=0
DURATION_DISPLAY="--:--"
CACHE_FILE=""
LYRICS_FILE=""
PARSED_LYRICS_FILE=""
MPV_SOCKET=""
RUNTIME_DIR=""
MPV_PID=""
LYRIC_PID=""

usage() {
    cat <<'EOF'
Usage:
  termux-music-player <music-file> [--offset <milliseconds>]
  termux-music-player <music-file> [--offset=<milliseconds>]

Options:
  --offset MS    Subtitle offset. Positive delays subtitles, negative advances them.
  -h, --help     Show this help.

Examples:
  termux-music-player ~/Music/song.mp3
  termux-music-player ~/Music/song.flac --offset 350
  termux-music-player ~/Music/song.m4a --offset=-250

Config:
  ~/.config/termux-music-player/config

Lyrics cache:
  ~/.cache/termux-music-player/lyrics/
EOF
}

die() {
    echo "Error: $*" >&2
    exit 1
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    [[ "$SUBTITLE_OFFSET_MS" =~ ^-?[0-9]+$ ]] ||
        die "SUBTITLE_OFFSET_MS must be an integer."

    [[ "$LRCLIB_TIMEOUT" =~ ^[0-9]+$ ]] ||
        die "LRCLIB_TIMEOUT must be an integer."

    [[ "$POLL_INTERVAL" =~ ^[0-9]+([.][0-9]+)?$|^[.][0-9]+$ ]] ||
        die "POLL_INTERVAL must be a positive number."
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --offset)
                (($# >= 2)) || die "--offset requires a value."
                SUBTITLE_OFFSET_MS="$2"
                shift 2
                ;;
            --offset=*)
                SUBTITLE_OFFSET_MS="$(printf '%s\n' "$1" | sed 's/^--offset=//')"
                shift
                ;;
            --)
                shift
                (($# == 1)) || die "Expected exactly one music file."
                MUSIC_FILE="$1"
                shift
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                [[ -z "$MUSIC_FILE" ]] ||
                    die "Only one music file can be played at a time."
                MUSIC_FILE="$1"
                shift
                ;;
        esac
    done

    [[ -n "$MUSIC_FILE" ]] || {
        usage >&2
        exit 2
    }

    [[ "$SUBTITLE_OFFSET_MS" =~ ^-?[0-9]+$ ]] ||
        die "Subtitle offset must be an integer in milliseconds."

    [[ -f "$MUSIC_FILE" ]] ||
        die "Music file does not exist: $MUSIC_FILE"

    [[ -r "$MUSIC_FILE" ]] ||
        die "Music file is not readable: $MUSIC_FILE"

    MUSIC_FILE="$(readlink -f "$MUSIC_FILE")"
}

check_dependencies() {
    local command

    for command in ffprobe curl jq mpv socat sha256sum readlink awk sed cut head basename mktemp; do
        command -v "$command" >/dev/null 2>&1 ||
            die "Missing dependency: $command. Run: bash setup.sh"
    done
}

probe_tag() {
    local tag="$1"

    ffprobe \
        -v error \
        -show_entries "format_tags=$tag:stream_tags=$tag" \
        -of default=noprint_wrappers=1:nokey=1 \
        "$MUSIC_FILE" 2>/dev/null |
        head -n 1
}

read_metadata() {
    TITLE="$(probe_tag title || true)"
    ARTIST="$(probe_tag artist || true)"
    ALBUM="$(probe_tag album || true)"

    [[ -n "$TITLE" ]] || TITLE="$(basename "$MUSIC_FILE")"
    TITLE="$(printf '%s\n' "$TITLE" | sed 's/\.[^.]*$//')"

    [[ -n "$ARTIST" ]] || ARTIST="Unknown Artist"
    [[ -n "$ALBUM" ]] || ALBUM="Unknown Album"

    DURATION_RAW="$(
        ffprobe \
            -v error \
            -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 \
            "$MUSIC_FILE" 2>/dev/null |
            head -n 1
    )" || true

    if [[ "$DURATION_RAW" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        DURATION_LOOKUP="$(awk -v d="$DURATION_RAW" 'BEGIN { printf "%.0f", d }')"
        DURATION_DISPLAY="$(
            awk -v d="$DURATION_RAW" '
                BEGIN {
                    if (d < 0) d = 0
                    h = int(d / 3600)
                    m = int((d - h * 3600) / 60)
                    s = int(d % 60)
                    if (h > 0)
                        printf "%d:%02d:%02d", h, m, s
                    else
                        printf "%02d:%02d", m, s
                }
            '
        )"
    fi
}

make_cache_key() {
    printf '%s\0' "$ARTIST" "$TITLE" "$ALBUM" "$DURATION_LOOKUP" |
        sha256sum |
        cut -d' ' -f1
}

find_cached_lyrics() {
    local key
    key="$(make_cache_key)"
    CACHE_FILE="$CACHE_DIR/$key.lrc"

    [[ -s "$CACHE_FILE" ]] || return 1
    LYRICS_FILE="$CACHE_FILE"
    return 0
}

curl_lrclib() {
    curl \
        --silent \
        --show-error \
        --location \
        --connect-timeout 5 \
        --max-time "$LRCLIB_TIMEOUT" \
        --header "User-Agent: $USER_AGENT" \
        --get \
        --data-urlencode "track_name=$TITLE" \
        --data-urlencode "artist_name=$ARTIST" \
        "$@"
}

fetch_lyrics() {
    local response_file status synced instrumental tmp_cache

    [[ "$ARTIST" != "Unknown Artist" ]] || return 1

    response_file="$(mktemp)"

    if [[ "$ALBUM" != "Unknown Album" &&
          "$DURATION_LOOKUP" -gt 0 &&
          "$DURATION_LOOKUP" -le 3600 ]]; then
        if ! status="$(curl_lrclib \
            --data-urlencode "album_name=$ALBUM" \
            --data-urlencode "duration=$DURATION_LOOKUP" \
            --output "$response_file" \
            --write-out '%{http_code}'
        )"; then
            rm -f "$response_file"
            return 1
        fi
    elif [[ "$ALBUM" != "Unknown Album" ]]; then
        if ! status="$(curl_lrclib \
            --data-urlencode "album_name=$ALBUM" \
            --output "$response_file" \
            --write-out '%{http_code}'
        )"; then
            rm -f "$response_file"
            return 1
        fi
    elif [[ "$DURATION_LOOKUP" -gt 0 && "$DURATION_LOOKUP" -le 3600 ]]; then
        if ! status="$(curl_lrclib \
            --data-urlencode "duration=$DURATION_LOOKUP" \
            --output "$response_file" \
            --write-out '%{http_code}'
        )"; then
            rm -f "$response_file"
            return 1
        fi
    else
        if ! status="$(curl_lrclib \
            --output "$response_file" \
            --write-out '%{http_code}'
        )"; then
            rm -f "$response_file"
            return 1
        fi
    fi

    [[ "$status" == "200" ]] || {
        rm -f "$response_file"
        return 1
    }

    synced="$(jq -r '.syncedLyrics // ""' "$response_file")"
    instrumental="$(jq -r '.instrumental // false' "$response_file")"
    rm -f "$response_file"

    mkdir -p "$CACHE_DIR"
    tmp_cache="$(mktemp "$CACHE_DIR/.tmp.XXXXXX")"

    if [[ "$instrumental" == "true" || -z "$synced" ]]; then
        printf '%s\n' '# termux-music-player: no-synced-lyrics' > "$tmp_cache"
    else
        printf '%s\n' "$synced" > "$tmp_cache"
    fi

    mv -f "$tmp_cache" "$CACHE_FILE"
    LYRICS_FILE="$CACHE_FILE"
}

prepare_lyrics() {
    if find_cached_lyrics; then
        echo "Lyrics: cache"
        return 0
    fi

    echo "Lyrics: fetching from LRCLIB..."
    if fetch_lyrics; then
        echo "Lyrics: cached"
    else
        echo "Lyrics: unavailable"
        LYRICS_FILE=""
    fi
}

parse_lrc() {
    PARSED_LYRICS_FILE="$RUNTIME_DIR/lyrics.tsv"

    [[ -n "$LYRICS_FILE" && -s "$LYRICS_FILE" ]] || return 0

    awk '
        {
            line = $0
            count = 0

            while (match(line, /^\[[0-9][0-9]*:[0-9][0-9](\.[0-9][0-9][0-9]?)?\]/)) {
                tag = substr(line, RSTART, RLENGTH)
                stamp = substr(tag, 2, length(tag) - 2)

                split(stamp, parts, ":")
                minute = parts[1]
                seconds_part = parts[2]

                split(seconds_part, secparts, ".")
                second = secparts[1]
                millis = 0

                if (length(secparts) > 1) {
                    fraction = secparts[2]
                    if (length(fraction) == 1)
                        millis = fraction * 100
                    else if (length(fraction) == 2)
                        millis = fraction * 10
                    else
                        millis = substr(fraction, 1, 3)
                }

                times[++count] = minute * 60000 + second * 1000 + millis
                line = substr(line, RSTART + RLENGTH)
            }

            if (count > 0 && line != "") {
                for (i = 1; i <= count; i++)
                    print times[i] "\t" line
            }
        }
    ' "$LYRICS_FILE" > "$PARSED_LYRICS_FILE"

    [[ -s "$PARSED_LYRICS_FILE" ]] || rm -f "$PARSED_LYRICS_FILE"
}

mpv_request() {
    local request="$1"

    printf '%s\n' "$request" |
        socat -T 0.5 - "UNIX-CONNECT:$MPV_SOCKET" 2>/dev/null |
        tail -n 1
}

get_time_pos_ms() {
    local response value

    response="$(mpv_request '{"command":["get_property","time-pos"]}' || true)"
    [[ -n "$response" ]] || return 1

    value="$(jq -r '.data // empty' <<<"$response" 2>/dev/null || true)"
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1

    awk -v t="$value" 'BEGIN { printf "%d", t * 1000 }'
}

wait_for_playback_start() {
    local attempt pos

    for ((attempt = 0; attempt < 100; attempt++)); do
        if [[ -S "$MPV_SOCKET" ]]; then
            pos="$(get_time_pos_ms || true)"
            [[ "$pos" =~ ^[0-9]+$ ]] && return 0
        fi

        kill -0 "$MPV_PID" 2>/dev/null || return 1
        sleep 0.1
    done

    return 1
}

print_metadata() {
    echo
    echo "▶ Playing: $TITLE"
    echo "  Artist : $ARTIST"
    echo "  Album  : $ALBUM"
    echo "  Length : $DURATION_DISPLAY"

    if ((SUBTITLE_OFFSET_MS > 0)); then
        echo "  Offset : +$SUBTITLE_OFFSET_MS ms"
    else
        echo "  Offset : $SUBTITLE_OFFSET_MS ms"
    fi
    echo
}

get_current_lyric() {
    local effective_ms="$1"

    [[ -s "$PARSED_LYRICS_FILE" ]] || return 1

    awk -F '\t' -v ms="$effective_ms" '
        $1 <= ms {
            found = $1
            text = $0
        }
        END {
            if (found != "") {
                sub(/^[^\t]*\t/, "", text)
                print found "\t" text
            }
        }
    ' "$PARSED_LYRICS_FILE"
}

subtitle_loop() {
    local current_timestamp=-1
    local last_position_ms=-1
    local position_ms effective_ms candidate candidate_time candidate_text

    [[ -s "$PARSED_LYRICS_FILE" ]] || return 0

    while kill -0 "$MPV_PID" 2>/dev/null; do
        if position_ms="$(get_time_pos_ms)"; then
            effective_ms=$((position_ms - SUBTITLE_OFFSET_MS))

            if ((last_position_ms >= 0 && effective_ms < last_position_ms - 500)); then
                current_timestamp=-1
            fi

            candidate="$(get_current_lyric "$effective_ms" || true)"

            if [[ -n "$candidate" ]]; then
                candidate_time="$(printf '%s\n' "$candidate" | cut -f1)"
                candidate_text="$(printf '%s\n' "$candidate" | cut -f2-)"

                if [[ "$candidate_time" != "$current_timestamp" ]]; then
                    current_timestamp="$candidate_time"
                    echo "$candidate_text"
                fi
            fi

            last_position_ms="$effective_ms"
        fi

        sleep "$POLL_INTERVAL"
    done
}

cleanup() {
    if [[ -n "$LYRIC_PID" ]] && kill -0 "$LYRIC_PID" 2>/dev/null; then
        kill "$LYRIC_PID" 2>/dev/null || true
    fi

    if [[ -n "$MPV_PID" ]] && kill -0 "$MPV_PID" 2>/dev/null; then
        kill "$MPV_PID" 2>/dev/null || true
    fi

    [[ -n "$RUNTIME_DIR" ]] && rm -rf "$RUNTIME_DIR"
}

main() {
    load_config
    parse_args "$@"
    check_dependencies
    read_metadata

    mkdir -p "$HOME/.cache/$APP_NAME"
    RUNTIME_DIR="$(mktemp -d "$HOME/.cache/$APP_NAME/run.XXXXXX")"
    MPV_SOCKET="$RUNTIME_DIR/mpv.sock"

    trap cleanup EXIT INT TERM

    prepare_lyrics
    parse_lrc

    mpv \
        --no-video \
        --force-window=no \
        --input-terminal=no \
        --input-ipc-server="$MPV_SOCKET" \
        --really-quiet \
        -- "$MUSIC_FILE" &
    MPV_PID=$!

    if ! wait_for_playback_start; then
        wait "$MPV_PID" || true
        die "mpv failed to start playback."
    fi

    print_metadata

    if [[ -s "$PARSED_LYRICS_FILE" ]]; then
        subtitle_loop &
        LYRIC_PID=$!
    fi

    wait "$MPV_PID"
}

main "$@"
