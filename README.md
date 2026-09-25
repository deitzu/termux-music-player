# termux-music-player

A small Bash music player for Termux with synchronized lyrics from LRCLIB.

## Features

- Plays a local music file through Termux's media-player API.
- Uses termux-media-player as the playback clock.
- Reads metadata with lightweight format-specific parsers for ID3v2/ID3v1, FLAC/Vorbis comments, Ogg/Opus comments, MP4/M4A atoms, and WAV RIFF INFO tags.
- Fetches synchronized lyrics from LRCLIB and caches them as LRC files.
- Prints lyrics with echo as playback reaches each timestamp.
- Supports a configurable subtitle offset in milliseconds.
- Cached lyrics work offline.
- Music itself is always a local file.

## Requirements

Direct runtime dependencies used by the script:

- termux-media-player
- curl
- jq
- core Termux utilities such as awk, sed, dd and od

The player script does not use mpv, ffprobe, ffmpeg or socat.

On recent Google Play Termux builds, termux-media-player is built in. On other Termux distributions, it is provided through the Termux:API integration.

## Install

Check the environment:

~~~bash
bash setup.sh
~~~

Let setup install the lightweight command-line dependencies:

~~~bash
bash setup.sh --install-deps
~~~

The project intentionally does not install mpv or ffmpeg.

The metadata parser uses only small shell/Unix tools already available in Termux. It does not require ffmpeg, ffprobe, or a large media-metadata library.

Setup also adds a small alias block to `~/.bashrc`:

~~~bash
alias music='termux-music-player'
alias mclone='music-clone'
alias mwatch='music-clone --watch'
alias mlyrics='termux-music-player --fetch-all'
~~~

Reload the shell after installation:

~~~bash
source ~/.bashrc
~~~

## Usage

Play a local file:

~~~bash
music ~/Music/song.mp3
~~~

The full command `termux-music-player` still works.

Fetch and cache synced lyrics for every supported music file under `~/Music` without playing anything:

~~~bash
mlyrics
~~~

Use a different directory:

~~~bash
music --fetch-all ~/Music
~~~

Force a re-fetch even when a lyric cache already exists:

~~~bash
music --fetch-all ~/Music --force
~~~

Override subtitle timing for one run:

~~~bash
music ~/Music/song.mp3 --offset -300
~~~

Positive offsets delay subtitles. Negative offsets make them appear earlier.

When `--offset` is explicitly supplied, that value is saved per track. A later run without `--offset` reuses the saved value for that track; when no saved value exists, the global `SUBTITLE_OFFSET_MS` from the config is used.

Per-track offset cache:

~~~text
~/.cache/termux-music-player/offsets/
~~~

## How it works

The player first reads metadata and prepares lyrics. It then starts the local file through termux-media-player and polls its playback information.

The same lyric-fetching path can be run independently with `--fetch-all`. It scans supported audio files, resolves metadata, and stores synced LRCLIB lyrics in the normal lyric cache without starting playback.

~~~text
local music
    |
    +--> custom MP3 metadata reader
    |       |
    |       +--> ID3v1
    |       +--> filename fallback
    |
    +--> lyric cache
            |
            +--> hit -------------------+
            |                            |
            +--> miss -> LRCLIB -> cache+
                                         |
                                         v
                              termux-media-player
                                         |
                                  Current Position
                                         |
                                  offset adjustment
                                         |
                                         v
                                    LRC lookup
                                         |
                                         v
                                       echo
~~~

termux-media-player info provides playback status and a Current Position value containing the current and total duration. That position is used as the timing source instead of an independent sleep timer.

The metadata reader currently prefers a filename convention such as:

~~~text
Artist - Title.mp3
~~~

It also reads ID3v1 when useful. ID3v1 only has 30-byte title, artist, and album fields, so a full 30-byte value is treated as potentially truncated instead of being displayed as if it were complete.

ID3v2 support is intentionally left for a later parser pass rather than pulling in a large metadata dependency.

## LRCLIB

The lyric lookup uses GET /api/get first with track, artist, and album metadata.

When that does not return synchronized lyrics, it retries without the album and then searches LRCLIB with several artist/title query shapes. The first result containing synced lyrics is used.

Only syncedLyrics is cached because this project is specifically experimenting with timestamped terminal subtitles.

## Cache

Lyrics are stored under:

~~~text
~/.cache/termux-music-player/lyrics/
~~~

The cache key is derived from artist, title, and album.

When a cache entry exists, no network request is needed.

## Subtitle offset

Configuration:

~~~ini
SUBTITLE_OFFSET_MS=0
POLL_INTERVAL=0.20
LRCLIB_TIMEOUT=15
~~~

A positive offset delays the lyric relative to playback. A negative offset advances it.

## Current limitations

This is still an experimental MVP.

- Metadata parsing is intentionally lightweight and uses format-specific parsers with filename fallback. Some uncommon container-specific tags may still require a future parser pass.
- A player seek is handled by jumping the lyric pointer to the timestamp active at the new position.
- Very large forward jumps skip directly to the active lyric instead of printing every skipped line.
- There is no playlist, TUI, music downloader, or music database.

The point is to keep the experiment small enough that the dependency graph does not become larger than the music player itself.

## Music cloner

`music-clone` copies only known music formats from the Android Downloads directory into a normal Termux music directory.

Default source detection checks:

~~~text
/storage/download
~/storage/download
~/storage/downloads
~~~

Default destination:

~~~text
~/Music
~~~

A normal run performs one scan:

~~~bash
mclone
~~~

Watch mode keeps scanning for new or updated music files:

~~~bash
mclone --watch
~~~

Or use the dedicated alias:

~~~bash
mwatch
~~~

Change the watch interval:

~~~bash
mclone --watch --interval 10
~~~

Custom source or destination:

~~~bash
music-clone --source ~/storage/download --dest ~/Music
~~~

Non-music files are ignored. Existing files are left alone unless the source file is newer.

The setup script installs the `music-clone` command and adds the `mclone`, `mwatch`, and `mlyrics` aliases to `~/.bashrc`.

~~~bash
alias mclone='music-clone'
~~~
