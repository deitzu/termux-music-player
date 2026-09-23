#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

VERSION="0.2.0"
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
    for command in termux-media-player curl jq sha256sum awk sed dd cut head wc mktemp; do
        command -v "$command" >/dev/null 2>&1 || die "Missing dependency: $command"
    done
}

trim_text() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

parse_id3v1() {
    local size start tag
    size="$(wc -c < "$MUSIC_FILE")"
    ((size >= 128)) || return 0
    start=$((size - 128))
    tag="$(dd if="$MUSIC_FILE" bs=1 skip="$start" count=128 2>/dev/null)"
    [[ "$(printf '%s' "$tag" | dd bs=1 count=3 2>/dev/null)" == "TAG" ]] || return 0
    [[ -n "$TITLE" ]] || TITLE="$(printf '%s' "$tag" | dd bs=1 skip=3 count=30 2>/dev/null | tr -d '\000' | trim_text)"
    [[ -n "$ARTIST" ]] || ARTIST="$(printf '%s' "$tag" | dd bs=1 skip=33 count=30 2>/dev/null | tr -d '\000' | trim_text)"
    [[ -n "$ALBUM" ]] || ALBUM="$(printf '%s' "$tag" | dd bs=1 skip=63 count=30 2>/dev/null | tr -d '\000' | trim_text)"
}

read_metadata() {
    local base artist_guess title_guess
    TITLE=""
    ARTIST=""
    ALBUM=""
    parse_id3v1

    base="$(basename "$MUSIC_FILE")"
    base="$(printf '%s\n' "$base" | sed 's/\.[^.]*$//')"

    if [[ "$base" == *" - "* ]]; then
        artist_guess="$(printf '%s\n' "$base" | sed 's/ - .*//')"
        title_guess="$(printf '%s\n' "$base" | sed 's/^[^ -]* - //')"
        [[ -n "$ARTIST" ]] || ARTIST="$artist_guess"
        [[ -n "$TITLE" ]] || TITLE="$title_guess"
    else
        [[ -n "$TITLE" ]] || TITLE="$base"
    fi

    [[ -n "$TITLE" ]] || TITLE="Unknown Title"
    [[ -n "$ARTIST" ]] || ARTIST="Unknown Artist"
    [[ -n "$ALBUM" ]] || ALBUM="Unknown Album"
}

time_to_ms() {
    local value="$1"
    local first second third
    first="$(printf '%s' "$value" | cut -d: -f1)"
    second="$(printf '%s' "$value" | cut -d: -f2)"
    third="$(printf '%s' "$value" | cut -d: -f3)"

    if [[ -n "$third" ]]; then
        printf '%d\n' $((10#$first * 3600000 + 10#$second * 60000 + 10#$third * 1000))
    elif [[ -n "$second" ]]; then
        printf '%d\n' $((10#$first * 60000 + 10#$second * 1000))
    else
        return 1
    fi
}

read_player_info() {
    local info position
    info="$(termux-media-player info 2>/dev/null || true)"
    [[ -n "$info" && "$info" != No\ track* ]] || return 1

    PLAYER_STATUS="$(printf '%s\n' "$info" | sed -n 's/^Status: //p' | head -n1)"
    position="$(printf '%s\n' "$info" | sed -n 's/^Current Position: //p' | head -n1)"
    [[ "$position" == */* ]] || return 1
    position="$(printf '%s' "$position" | tr -d ' ')"

    PLAYER_POSITION_MS="$(time_to_ms "$(printf '%s' "$position" | cut -d/ -f1)")"
    PLAYER_DURATION_MS="$(time_to_ms "$(printf '%s' "$position" | cut -d/ -f2)")"

    DURATION_DISPLAY="$(
        awk -v ms="$PLAYER_DURATION_MS" '
            BEGIN {
                total = int(ms / 1000)
                h = int(total / 3600)
                m = int((total - h * 3600) / 60)
                s = total % 60
                if (h) printf "%d:%02d:%02d", h, m, s
                else printf "%02d:%02d", m, s
            }
        '
    )"
}
make_cache_key() {
    printf '%s\0' "$ARTIST" "$TITLE" "$ALBUM" |
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

wait_for_playback_start() {
    for i in 1 2 3 4 5 6 7 8 9 10; do
        read_player_info && return 0
        sleep 0.10
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
    termux-media-player stop >/dev/null 2>&1 || true
}

main() {
    load_config
    parse_args "$@"
    check_dependencies
    read_metadata
    prepare_lyrics
    parse_lrc

    termux-media-player play "$MUSIC_FILE" >/dev/null 2>&1 ||
        die "termux-media-player could not start playback."

    local metadata_printed=0
    local effective_ms lyric_index delta i

    while :; do
        if ! read_player_info; then
            break
        fi

        if [[ "$PLAYER_STATUS" == "Playing" ]]; then
            if ((metadata_printed == 0)); then
                print_metadata
                metadata_printed=1
            fi

            effective_ms=$((PLAYER_POSITION_MS - SUBTITLE_OFFSET_MS))
            lyric_index="$(find_lyric_index "$effective_ms")"

            if ((LAST_POSITION_MS >= 0 &&
                 PLAYER_POSITION_MS + 500 < LAST_POSITION_MS)); then
                CURRENT_INDEX=$((lyric_index - 1))
            fi

            delta=$((lyric_index - CURRENT_INDEX))

            if ((lyric_index >= 0 && delta > 0)); then
                if ((delta > 5)); then
                    echo "lyrics skipped to index $lyric_index"
                else
                    for ((i=CURRENT_INDEX + 1; i<=lyric_index; i++)); do
                        echo "\${LYRIC_TEXTS[i]}"
                    done
                fi
                CURRENT_INDEX="$lyric_index"
            fi

            LAST_POSITION_MS="$PLAYER_POSITION_MS"
        fi

        sleep "$POLL_INTERVAL"
    done
}

main "$@"
