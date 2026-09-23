# termux-music-player

A small Bash music player for Termux with synchronized lyrics from LRCLIB.

## Features

- Plays a local music file through Termux's media-player API.
- Uses termux-media-player as the playback clock.
- Reads basic MP3 metadata without ffmpeg or ffprobe.
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

## Usage

Play a local file:

~~~bash
termux-music-player ~/Music/song.mp3
~~~

Override subtitle timing for one run:

~~~bash
termux-music-player ~/Music/song.mp3 --offset -300
~~~

Positive offsets delay subtitles. Negative offsets make them appear earlier.

## How it works

The player first reads metadata and prepares lyrics. It then starts the local file through termux-media-player and polls its playback information.

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

The metadata reader currently supports ID3v1 and a filename convention such as:

~~~text
Artist - Title.mp3
~~~

ID3v2 support is intentionally left for a later parser pass rather than pulling in a large metadata dependency.

## LRCLIB

The lyric lookup uses GET /api/get first with track, artist, and album metadata.

When that does not return synchronized lyrics, it retries without the album and then falls back to GET /api/search. The first result containing synced lyrics is used.

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

- Metadata parsing is intentionally small and currently focuses on ID3v1 plus filename fallback.
- A player seek is handled by jumping the lyric pointer to the timestamp active at the new position.
- Very large forward jumps skip directly to the active lyric instead of printing every skipped line.
- There is no playlist, TUI, music downloader, or music database.

The point is to keep the experiment small enough that the dependency graph does not become larger than the music player itself.
