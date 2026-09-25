#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

VERSION="0.6.0"
APP_NAME="termux-music-player"
CONFIG_DIR="$HOME/.config/$APP_NAME"
CACHE_DIR="$HOME/.cache/$APP_NAME/lyrics"
OFFSET_CACHE_DIR="$HOME/.cache/$APP_NAME/offsets"
CONFIG_FILE="$CONFIG_DIR/config"
LRCLIB_API="https://lrclib.net/api/get"
LRCLIB_SEARCH="https://lrclib.net/api/search"
USER_AGENT="$APP_NAME/$VERSION (https://github.com/deitzu/termux-music-player)"

SUBTITLE_OFFSET_MS=0
OFFSET_EXPLICIT=0
OFFSET_SOURCE="config"
POLL_INTERVAL=0.20
LRCLIB_TIMEOUT=15

MUSIC_FILE=""
FETCH_ALL=0
FETCH_ROOT=""
FORCE_FETCH=0
TITLE=""
ARTIST=""
ALBUM=""
DURATION_DISPLAY="--:--"
PLAYER_STATUS=""
PLAYER_POSITION_MS=0
PLAYER_DURATION_MS=0
LYRICS_FILE=""
CACHE_FILE=""
LYRIC_COUNT=0
CURRENT_INDEX=-1
LAST_POSITION_MS=-1

declare -a LYRIC_TIMES=()
declare -a LYRIC_TEXTS=()

usage() {
    cat <<'EOF'
Usage:
  termux-music-player <music-file> [--offset <milliseconds>]
  termux-music-player <music-file> [--offset=<milliseconds>]
  termux-music-player --fetch-all [directory] [--force]

Options:
  --offset MS      Subtitle offset. Positive delays subtitles, negative advances them.
                   Explicit values are remembered for this track.
  --fetch-all DIR  Fetch and cache synced lyrics for all music files under DIR.
                   Defaults to ~/Music and does not play anything.
  --force          Re-fetch lyrics even when a cache entry already exists.
  -h, --help       Show this help.

Examples:
  termux-music-player ~/Music/song.mp3
  termux-music-player ~/Music/song.flac --offset 350
  termux-music-player ~/Music/song.mp3
  termux-music-player --fetch-all
  termux-music-player --fetch-all ~/Music --force

Config:
  ~/.config/termux-music-player/config

Lyrics cache:
  ~/.cache/termux-music-player/lyrics/

Per-track offset cache:
  ~/.cache/termux-music-player/offsets/
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
                OFFSET_EXPLICIT=1
                shift 2
                ;;
            --offset=*)
                SUBTITLE_OFFSET_MS="$(printf '%s\n' "$1" | sed 's/^--offset=//')"
                OFFSET_EXPLICIT=1
                shift
                ;;
            --fetch-all)
                FETCH_ALL=1
                shift
                ;;
            --force)
                FORCE_FETCH=1
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
                if ((FETCH_ALL)); then
                    [[ -z "$FETCH_ROOT" ]] ||
                        die "Only one fetch-all directory can be provided."
                    FETCH_ROOT="$1"
                    shift
                else
                    [[ -z "$MUSIC_FILE" ]] ||
                        die "Only one music file can be played at a time."
                    MUSIC_FILE="$1"
                    shift
                fi
                ;;
        esac
    done

    if ((FETCH_ALL)); then
        ((OFFSET_EXPLICIT == 0)) ||
            die "--offset cannot be used with --fetch-all."
        FETCH_ROOT="${FETCH_ROOT:-$HOME/Music}"
        [[ -d "$FETCH_ROOT" ]] ||
            die "Fetch directory does not exist: $FETCH_ROOT"
        return
    fi

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
    for command in curl jq sha256sum awk sed dd od cut head wc mktemp grep find tr readlink; do
        command -v "$command" >/dev/null 2>&1 || die "Missing dependency: $command"
    done
}

check_playback_dependency() {
    command -v termux-media-player >/dev/null 2>&1 ||
        die "Missing dependency: termux-media-player"
}

trim_text() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

read_u32be_at() {
    local offset="$1" data
    local -a bytes=()
    data="$(dd if="$MUSIC_FILE" bs=1 skip="$offset" count=4 2>/dev/null | od -An -tu1)" || return 1
    read -r -a bytes <<< "$data"
    (( ${#bytes[@]} == 4 )) || return 1
    printf "%d\n" $((bytes[0] * 16777216 + bytes[1] * 65536 + bytes[2] * 256 + bytes[3]))
}

read_u32le_at() {
    local offset="$1" data
    local -a bytes=()
    data="$(dd if="$MUSIC_FILE" bs=1 skip="$offset" count=4 2>/dev/null | od -An -tu1)" || return 1
    read -r -a bytes <<< "$data"
    (( ${#bytes[@]} == 4 )) || return 1
    printf "%d\n" $((bytes[0] + bytes[1] * 256 + bytes[2] * 65536 + bytes[3] * 16777216))
}

read_u32synchsafe_at() {
    local offset="$1" data
    local -a bytes=()
    data="$(dd if="$MUSIC_FILE" bs=1 skip="$offset" count=4 2>/dev/null | od -An -tu1)" || return 1
    read -r -a bytes <<< "$data"
    (( ${#bytes[@]} == 4 )) || return 1
    printf "%d\n" $(((bytes[0] & 127) * 2097152 + (bytes[1] & 127) * 16384 + (bytes[2] & 127) * 128 + (bytes[3] & 127)))
}

read_u24be_at() {
    local offset="$1" data
    local -a bytes=()
    data="$(dd if="$MUSIC_FILE" bs=1 skip="$offset" count=3 2>/dev/null | od -An -tu1)" || return 1
    read -r -a bytes <<< "$data"
    (( ${#bytes[@]} == 3 )) || return 1
    printf "%d\n" $((bytes[0] * 65536 + bytes[1] * 256 + bytes[2]))
}

read_u64be_at() {
    local offset="$1"
    local high low
    high="$(read_u32be_at "$offset")" || return 1
    low="$(read_u32be_at "$((offset + 4))")" || return 1
    printf "%d\n" $((high * 4294967296 + low))
}

read_hex_at() {
    local offset="$1" count="$2"
    dd if="$MUSIC_FILE" bs=1 skip="$offset" count="$count" 2>/dev/null |
        od -An -tx1 |
        tr -d ' \n'
}

read_ascii_at() {
    local offset="$1" count="$2"
    dd if="$MUSIC_FILE" bs=1 skip="$offset" count="$count" 2>/dev/null
}

read_text_at() {
    local offset="$1" count="$2"
    read_ascii_at "$offset" "$count" |
        tr -d '\000'
}

set_metadata_field() {
    local variable="$1" value="$2"
    [[ -n "$value" ]] || return 0
    [[ -n "${!variable}" ]] || printf -v "$variable" "%s" "$value"
}

decode_id3_text() {
    local offset="$1" size="$2" encoding
    ((size > 0)) || return 0

    encoding="$(dd if="$MUSIC_FILE" bs=1 skip="$offset" count=1 2>/dev/null | od -An -tu1 | tr -d '[:space:]')"
    offset=$((offset + 1))
    size=$((size - 1))
    ((size > 0)) || return 0

    case "$encoding" in
        0)
            read_ascii_at "$offset" "$size" | tr -d '\000' | trim_text
            ;;
        1)
            if command -v iconv >/dev/null 2>&1; then
                read_ascii_at "$offset" "$size" | iconv -f UTF-16 -t UTF-8 2>/dev/null | trim_text
            else
                local bom
                bom="$(read_hex_at "$offset" 2)"
                if [[ "$bom" == "fffe" || "$bom" == "feff" ]]; then
                    offset=$((offset + 2))
                    size=$((size - 2))
                fi
                ((size > 0)) || return 0
                read_ascii_at "$offset" "$size" | tr -d '\000' | trim_text
            fi
            ;;
        2)
            if command -v iconv >/dev/null 2>&1; then
                read_ascii_at "$offset" "$size" | iconv -f UTF-16 -t UTF-8 2>/dev/null | trim_text
            else
                local bom
                bom="$(read_hex_at "$offset" 2)"
                if [[ "$bom" == "fffe" || "$bom" == "feff" ]]; then
                    offset=$((offset + 2))
                    size=$((size - 2))
                fi
                ((size > 0)) || return 0
                read_ascii_at "$offset" "$size" | tr -d '\000' | trim_text
            fi
            ;;
        3)
            read_ascii_at "$offset" "$size" | trim_text
            ;;
        *)
            read_ascii_at "$offset" "$size" | tr -d '\000' | trim_text
            ;;
    esac
}

parse_id3v2() {
    local magic version flags tag_size offset end frame_id frame_size
    local ext_size encoding title artist album

    magic="$(read_hex_at 0 3)"
    [[ "$magic" == "494433" ]] || return 0

    version="$(dd if="$MUSIC_FILE" bs=1 skip=3 count=1 2>/dev/null | od -An -tu1)"
    ((version >= 2 && version <= 4)) || return 0
    flags="$(dd if="$MUSIC_FILE" bs=1 skip=5 count=1 2>/dev/null | od -An -tu1)"
    tag_size="$(read_u32synchsafe_at 6)" || return 0
    offset=10
    end=$((10 + tag_size))
    ((end <= MUSIC_SIZE)) || return 0

    if ((flags & 64)); then
        if ((version == 3)); then
            ext_size="$(read_u32be_at "$offset" 2>/dev/null)" || return 0
        else
            ext_size="$(read_u32synchsafe_at "$offset" 2>/dev/null)" || return 0
        fi
        offset=$((offset + ext_size))
    fi

    if ((version == 2)); then
        while ((offset + 6 <= end)); do
            frame_id="$(read_text_at "$offset" 3)"
            [[ -n "$frame_id" && "$frame_id" != $'\000\000\000' ]] || break
            frame_size="$(read_u24be_at "$((offset + 3))")" || break
            ((frame_size > 0 && offset + 6 + frame_size <= end)) || break

            case "$frame_id" in
                TT2) title="$(decode_id3_text "$((offset + 6))" "$frame_size")" ;;
                TP1) artist="$(decode_id3_text "$((offset + 6))" "$frame_size")" ;;
                TAL) album="$(decode_id3_text "$((offset + 6))" "$frame_size")" ;;
            esac

            set_metadata_field TITLE "${title:-}"
            set_metadata_field ARTIST "${artist:-}"
            set_metadata_field ALBUM "${album:-}"
            title=""; artist=""; album=""
            offset=$((offset + 6 + frame_size))
        done
        return 0
    fi

    while ((offset + 10 <= end)); do
        frame_id="$(read_text_at "$offset" 4)"
        [[ -n "$frame_id" && "$frame_id" != $'\000\000\000\000' ]] || break

        if ((version == 3)); then
            frame_size="$(read_u32be_at "$((offset + 4))")" || break
        else
            frame_size="$(read_u32synchsafe_at "$((offset + 4))")" || break
        fi
        ((frame_size > 0 && offset + 10 + frame_size <= end)) || break

        case "$frame_id" in
            TIT2) title="$(decode_id3_text "$((offset + 10))" "$frame_size")" ;;
            TPE1) artist="$(decode_id3_text "$((offset + 10))" "$frame_size")" ;;
            TALB) album="$(decode_id3_text "$((offset + 10))" "$frame_size")" ;;
        esac

        set_metadata_field TITLE "${title:-}"
        set_metadata_field ARTIST "${artist:-}"
        set_metadata_field ALBUM "${album:-}"
        title=""; artist=""; album=""
        offset=$((offset + 10 + frame_size))
    done
}

parse_flac_vorbis_comments() {
    local magic offset header first block_type last block_size
    local vendor_len comment_count comment_len comment key value

    magic="$(read_hex_at 0 4)"
    [[ "$magic" == "664c6143" ]] || return 0

    offset=4
    while ((offset + 4 <= MUSIC_SIZE)); do
        header="$(read_ascii_at "$offset" 4 | od -An -tu1)"
        read -r first b1 b2 b3 <<< "$header"
        (( first >= 0 && first <= 255 )) || return 0
        block_type=$((first & 127))
        last=$((first & 128))
        block_size=$((b1 * 65536 + b2 * 256 + b3))
        ((offset + 4 + block_size <= MUSIC_SIZE)) || return 0

        if ((block_type == 4 && block_size >= 8)); then
            vendor_len="$(read_u32le_at "$((offset + 4))")" || return 0
            comment_count_offset=$((offset + 8 + vendor_len))
            ((comment_count_offset + 4 <= offset + 4 + block_size)) || return 0
            comment_count="$(read_u32le_at "$comment_count_offset")" || return 0
            offset=$((comment_count_offset + 4))

            for ((i=0; i<comment_count; i++)); do
                ((offset + 4 <= MUSIC_SIZE)) || break
                comment_len="$(read_u32le_at "$offset")" || break
                offset=$((offset + 4))
                ((comment_len > 0 && offset + comment_len <= MUSIC_SIZE)) || break
                comment="$(read_ascii_at "$offset" "$comment_len" | trim_text)"
                key="${comment%%=*}"
                value="${comment#*=}"
                key="${key^^}"
                case "$key" in
                    TITLE) set_metadata_field TITLE "$value" ;;
                    ARTIST) set_metadata_field ARTIST "$value" ;;
                    ALBUM) set_metadata_field ALBUM "$value" ;;
                esac
                offset=$((offset + comment_len))
            done
            return 0
        fi

        offset=$((offset + 4 + block_size))
        ((last != 0)) && break
    done
}

parse_ogg_comments() {
    local container key match offset comment_len comment field_key field_value

    container="$(read_hex_at 0 4)"
    [[ "$container" == "4f676753" ]] || return 0

    for key in TITLE ARTIST ALBUM; do
        match="$(LC_ALL=C grep -aobm1 -- "$key=" "$MUSIC_FILE" 2>/dev/null | cut -d: -f1 || true)"
        [[ "$match" == *:* ]] || continue
        offset="${match%%:*}"
        [[ "$offset" =~ ^[0-9]+$ && offset -ge 4 ]] || continue
        comment_len="$(read_u32le_at "$((offset - 4))" 2>/dev/null || true)"
        [[ "$comment_len" =~ ^[0-9]+$ ]] || continue
        ((comment_len >= 6 && comment_len <= 1048576)) || continue
        ((offset + comment_len <= MUSIC_SIZE)) || continue
        comment="$(read_ascii_at "$offset" "$comment_len")"
        field_key="${comment%%=*}"
        field_value="${comment#*=}"
        field_key="${field_key^^}"
        case "$field_key" in
            TITLE) set_metadata_field TITLE "$field_value" ;;
            ARTIST) set_metadata_field ARTIST "$field_value" ;;
            ALBUM) set_metadata_field ALBUM "$field_value" ;;
        esac
    done
}

parse_mp4_atoms() {
    local start="$1" end="$2" parent_type="${3:-}" depth="${4:-0}"
    local size type_hex atom_end child_start payload_size value

    ((depth <= 8)) || return 0

    while ((start + 8 <= end)); do
        size="$(read_u32be_at "$start" 2>/dev/null || true)"
        [[ "$size" =~ ^[0-9]+$ ]] || return 0
        type_hex="$(read_hex_at "$((start + 4))" 4)"

        if ((size == 1)); then
            size="$(read_u64be_at "$((start + 8))" 2>/dev/null || true)"
            [[ "$size" =~ ^[0-9]+$ ]] || return 0
            child_start=$((start + 16))
        else
            child_start=$((start + 8))
        fi

        if ((size == 0)); then
            atom_end="$end"
        else
            atom_end=$((start + size))
        fi
        ((atom_end > start && atom_end <= end)) || return 0

        if [[ "$type_hex" == "64617461" ]]; then
            if ((size >= 16)); then
                payload_size=$((size - 16))
                case "$parent_type" in
                    c2a96e616d) value="$(read_ascii_at "$((start + 16))" "$payload_size" | tr -d '\000' | trim_text)"; set_metadata_field TITLE "$value" ;;
                    c2a9415254) value="$(read_ascii_at "$((start + 16))" "$payload_size" | tr -d '\000' | trim_text)"; set_metadata_field ARTIST "$value" ;;
                    c2a9616c62) value="$(read_ascii_at "$((start + 16))" "$payload_size" | tr -d '\000' | trim_text)"; set_metadata_field ALBUM "$value" ;;
                    61415254) value="$(read_ascii_at "$((start + 16))" "$payload_size" | tr -d '\000' | trim_text)"; set_metadata_field ARTIST "$value" ;;
                esac
            fi
        fi

        case "$type_hex" in
            6d6f6f76|75647461|6d657461|696c7374|7472616b|6d646961|6d696e66|64696e66|7374626c|65647473|c2a96e616d|c2a9415254|c2a9616c62|61415254)
                if [[ "$type_hex" == "6d657461" ]]; then
                    child_start=$((start + 12))
                fi
                parse_mp4_atoms "$child_start" "$atom_end" "$type_hex" "$((depth + 1))"
                ;;
        esac

        start="$atom_end"
    done
}

parse_mp4_metadata() {
    [[ "$(read_hex_at 4 4)" == "66747970" ]] || return 0
    parse_mp4_atoms 0 "$MUSIC_SIZE" "" 0
}

parse_riff_info() {
    local magic form offset chunk_id chunk_size chunk_end list_type sub_offset sub_id sub_size value

    [[ "$(read_hex_at 0 4)" == "52494646" ]] || return 0
    form="$(read_text_at 8 4)"
    [[ "$form" == "WAVE" ]] || return 0

    offset=12
    while ((offset + 8 <= MUSIC_SIZE)); do
        chunk_id="$(read_text_at "$offset" 4)"
        chunk_size="$(read_u32le_at "$((offset + 4))" 2>/dev/null || true)"
        [[ "$chunk_size" =~ ^[0-9]+$ ]] || break
        chunk_end=$((offset + 8 + chunk_size))
        ((chunk_end <= MUSIC_SIZE)) || break

        if [[ "$chunk_id" == "LIST" && chunk_size -ge 4 ]]; then
            list_type="$(read_ascii_at "$((offset + 8))" 4)"
            if [[ "$list_type" == "INFO" ]]; then
                sub_offset=$((offset + 12))
                while ((sub_offset + 8 <= chunk_end)); do
                    sub_id="$(read_text_at "$sub_offset" 4)"
                    sub_size="$(read_u32le_at "$((sub_offset + 4))" 2>/dev/null || true)"
                    [[ "$sub_size" =~ ^[0-9]+$ ]] || break
                    ((sub_offset + 8 + sub_size <= chunk_end)) || break
                    value="$(read_ascii_at "$((sub_offset + 8))" "$sub_size" | tr -d '\000' | trim_text)"
                    case "$sub_id" in
                        INAM) set_metadata_field TITLE "$value" ;;
                        IART) set_metadata_field ARTIST "$value" ;;
                        IPRD) set_metadata_field ALBUM "$value" ;;
                    esac
                    sub_offset=$((sub_offset + 8 + sub_size + (sub_size & 1)))
                done
            fi
        fi

        offset=$((offset + 8 + chunk_size + (chunk_size & 1)))
    done
}

parse_id3v1() {
    local size start tag value bytes

    size="$MUSIC_SIZE"
    ((size >= 128)) || return 0

    start=$((size - 128))

    tag="$(dd if="$MUSIC_FILE" bs=1 skip="$start" count=3 2>/dev/null)"
    [[ "$tag" == "TAG" ]] || return 0

    # ID3v1 fields are exactly 30 bytes. A full 30-byte value may be
    # truncated, so do not present it as complete metadata.
    value="$(
        dd if="$MUSIC_FILE" bs=1 skip=$((start + 3)) count=30 2>/dev/null |
            tr -d '\000' |
            trim_text
    )"
    bytes="$(printf '%s' "$value" | wc -c)"
    if [[ -z "$TITLE" && "$bytes" -lt 30 ]]; then
        TITLE="$value"
    fi

    value="$(
        dd if="$MUSIC_FILE" bs=1 skip=$((start + 33)) count=30 2>/dev/null |
            tr -d '\000' |
            trim_text
    )"
    bytes="$(printf '%s' "$value" | wc -c)"
    if [[ -z "$ARTIST" && "$bytes" -lt 30 ]]; then
        ARTIST="$value"
    fi

    value="$(
        dd if="$MUSIC_FILE" bs=1 skip=$((start + 63)) count=30 2>/dev/null |
            tr -d '\000' |
            trim_text
    )"
    bytes="$(printf '%s' "$value" | wc -c)"
    if [[ -z "$ALBUM" && "$bytes" -lt 30 ]]; then
        ALBUM="$value"
    fi
}

read_metadata() {
    local base artist_guess title_guess

    TITLE=""
    ARTIST=""
    ALBUM=""
    MUSIC_SIZE="$(wc -c < "$MUSIC_FILE")"

    # Prefer modern/container-aware metadata parsers, then use older tags
    # and finally the filename as a fallback.
    parse_id3v2
    parse_flac_vorbis_comments
    parse_ogg_comments
    parse_mp4_metadata
    parse_riff_info
    parse_id3v1

    base="$(basename "$MUSIC_FILE")"
    base="$(printf '%s\n' "$base" | sed 's/\.[^.]*$//')"

    if [[ "$base" == *" - "* ]]; then
        artist_guess="${base%% - *}"
        title_guess="${base#* - }"
        set_metadata_field ARTIST "$artist_guess"
        set_metadata_field TITLE "$title_guess"
    else
        set_metadata_field TITLE "$base"
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
    CACHE_FILE="$CACHE_DIR/$(make_cache_key).lrc"
    [[ -s "$CACHE_FILE" ]] || return 1
    LYRICS_FILE="$CACHE_FILE"
}

resolve_offset() {
    OFFSET_CACHE_FILE="$OFFSET_CACHE_DIR/$(make_cache_key).offset"

    if ((OFFSET_EXPLICIT)); then
        mkdir -p "$OFFSET_CACHE_DIR"
        printf '%s\n' "$SUBTITLE_OFFSET_MS" > "$OFFSET_CACHE_FILE"
        OFFSET_SOURCE="command"
        return
    fi

    if [[ -s "$OFFSET_CACHE_FILE" ]]; then
        local cached_offset
        cached_offset="$(head -n1 "$OFFSET_CACHE_FILE")"
        if [[ "$cached_offset" =~ ^-?[0-9]+$ ]]; then
            SUBTITLE_OFFSET_MS="$cached_offset"
            OFFSET_SOURCE="saved"
        fi
    fi
}

is_music_file() {
    local ext
    ext="$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')"

    case "$ext" in
        mp3|flac|wav|m4a|aac|ogg|oga|opus|wma|alac|aiff|aif|ape)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

fetch_all_lyrics() {
    local total=0 cached=0 fetched=0 missing=0 file

    mkdir -p "$CACHE_DIR"

    echo "Fetching lyrics under: $FETCH_ROOT"
    echo

    while IFS= read -r -d '' file; do
        is_music_file "$file" || continue

        MUSIC_FILE="$file"
        TITLE=""
        ARTIST=""
        ALBUM=""
        LYRICS_FILE=""
        read_metadata
        CACHE_FILE="$CACHE_DIR/$(make_cache_key).lrc"
        total=$((total + 1))

        if ((FORCE_FETCH == 0)) && find_cached_lyrics; then
            cached=$((cached + 1))
            echo "[cached] $ARTIST - $TITLE"
            continue
        fi

        if fetch_lyrics; then
            fetched=$((fetched + 1))
            echo "[fetched] $ARTIST - $TITLE"
        else
            missing=$((missing + 1))
            echo "[missing] $ARTIST - $TITLE"
        fi
    done < <(find "$FETCH_ROOT" -type f -print0)

    echo
    echo "Fetch complete:"
    echo "  Music files : $total"
    echo "  Cached      : $cached"
    echo "  Fetched     : $fetched"
    echo "  Missing     : $missing"
}

curl_json() {
    curl \
        --silent \
        --show-error \
        --location \
        --connect-timeout 5 \
        --max-time "$LRCLIB_TIMEOUT" \
        --header "User-Agent: $USER_AGENT" \
        --get \
        "$@"
}

fetch_lyrics() {
    local json synced query

    json="$(
        curl_json \
            --data-urlencode "track_name=$TITLE" \
            --data-urlencode "artist_name=$ARTIST" \
            --data-urlencode "album_name=$ALBUM" \
            "$LRCLIB_API" 2>/dev/null || true
    )"

    synced="$(printf '%s' "$json" | jq -r '.syncedLyrics // ""' 2>/dev/null || true)"

    if [[ -n "$synced" ]]; then
        mkdir -p "$CACHE_DIR"
        printf '%s\n' "$synced" > "$CACHE_FILE"
        LYRICS_FILE="$CACHE_FILE"
        return 0
    fi

    json="$(
        curl_json \
            --data-urlencode "track_name=$TITLE" \
            --data-urlencode "artist_name=$ARTIST" \
            "$LRCLIB_API" 2>/dev/null || true
    )"

    synced="$(printf '%s' "$json" | jq -r '.syncedLyrics // ""' 2>/dev/null || true)"

    if [[ -n "$synced" ]]; then
        mkdir -p "$CACHE_DIR"
        printf '%s\n' "$synced" > "$CACHE_FILE"
        LYRICS_FILE="$CACHE_FILE"
        return 0
    fi

    # Search with multiple query shapes when direct metadata lookup fails.
    for query in "$TITLE $ARTIST" "$ARTIST $TITLE" "$TITLE"; do
        json="$(
            curl_json \
                --data-urlencode "q=$query" \
                "$LRCLIB_SEARCH" 2>/dev/null || true
        )"

        synced="$(
            printf '%s' "$json" |
                jq -r '[.[] | select(.syncedLyrics != null and .syncedLyrics != "")][0].syncedLyrics // ""' 2>/dev/null || true
        )"

        if [[ -n "$synced" ]]; then
            mkdir -p "$CACHE_DIR"
            printf '%s\n' "$synced" > "$CACHE_FILE"
            LYRICS_FILE="$CACHE_FILE"
            return 0
        fi
    done

    return 1
}

prepare_lyrics() {
    mkdir -p "$CACHE_DIR"
    find_cached_lyrics && return 0
    fetch_lyrics || true
}


parse_lrc() {
    local timestamp text

    LYRIC_TIMES=()
    LYRIC_TEXTS=()
    LYRIC_COUNT=0
    CURRENT_INDEX=-1

    [[ -n "$LYRICS_FILE" && -s "$LYRICS_FILE" ]] || return 0

    while IFS=$'\t' read -r timestamp text; do
        LYRIC_TIMES[LYRIC_COUNT]="$timestamp"
        LYRIC_TEXTS[LYRIC_COUNT]="$text"
        LYRIC_COUNT=$((LYRIC_COUNT + 1))
    done < <(
        awk '
            {
                line = $0

                while (match(line, /^\[[0-9][0-9]*:[0-9][0-9](\.[0-9][0-9][0-9]?)?\]/)) {
                    tag = substr(line, RSTART, RLENGTH)
                    rest = substr(line, RSTART + RLENGTH)

                    split(substr(tag, 2, length(tag) - 2), p, ":")
                    split(p[2], s, ".")

                    ms = p[1] * 60000 + s[1] * 1000

                    if (length(s) > 1) {
                        if (length(s[2]) == 1) ms += s[2] * 100
                        else if (length(s[2]) == 2) ms += s[2] * 10
                        else ms += substr(s[2], 1, 3)
                    }

                    print ms "\t" rest
                    line = rest

                    if (line !~ /^\[/)
                        break
                }
            }
        ' "$LYRICS_FILE"
    )
}

find_lyric_index() {
    local target="$1"
    local low=0
    local high=$((LYRIC_COUNT - 1))
    local mid
    local answer=-1

    ((LYRIC_COUNT > 0)) || {
        printf '%d\n' -1
        return
    }

    while ((low <= high)); do
        mid=$(( (low + high) / 2 ))

        if ((LYRIC_TIMES[mid] <= target)); then
            answer="$mid"
            low=$((mid + 1))
        else
            high=$((mid - 1))
        fi
    done

    printf '%d\n' "$answer"
}

print_lyric_index() {
    local index="$1"
    printf '%s\n' "${LYRIC_TEXTS[$index]}"
}
print_metadata() {
    echo
    echo "▶ Playing: $TITLE"
    echo "  Artist : $ARTIST"
    echo "  Album  : $ALBUM"
    echo "  Length : $DURATION_DISPLAY"

    if ((SUBTITLE_OFFSET_MS > 0)); then
        echo "  Offset : +$SUBTITLE_OFFSET_MS ms ($OFFSET_SOURCE)"
    else
        echo "  Offset : $SUBTITLE_OFFSET_MS ms ($OFFSET_SOURCE)"
    fi

    if [[ -n "$LYRICS_FILE" ]]; then
        echo "  Lyrics : synced (LRCLIB)"
    else
        echo "  Lyrics : not found"
    fi
    echo
}

cleanup() {
    termux-media-player stop >/dev/null 2>&1 || true
}

main() {
    trap cleanup EXIT INT TERM

    load_config
    parse_args "$@"
    check_dependencies

    if ((FETCH_ALL)); then
        fetch_all_lyrics
        return 0
    fi

    check_playback_dependency
    read_metadata
    resolve_offset
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
                    print_lyric_index "$lyric_index"
                else
                    for ((i=CURRENT_INDEX + 1; i<=lyric_index; i++)); do
                        print_lyric_index "$i"
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
