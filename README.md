# termux-music-player

A small Bash music player for Termux with synchronized lyrics from LRCLIB.

## Features

- Plays local music files with mpv.
- Reads title, artist, album, and duration through mpv media properties.
- Fetches synchronized lyrics from LRCLIB when they are not already cached.
- Stores successful lyrics locally as LRC cache files.
- Uses mpv JSON IPC time-pos for subtitle timing.
- Supports a configurable subtitle offset in milliseconds.
- Prints synchronized lyrics with echo.
- Music playback is fully local/offline.
- Cached lyrics can also be used fully offline.

## Requirements

Direct runtime dependencies:

- mpv
- curl
- jq
- socat

The player does not invoke ffprobe or ffmpeg itself anymore.

Important: the current official Termux mpv package declares ffmpeg as a package dependency, along with other media libraries. Therefore installing stock mpv can still pull a large media stack. This comes from Termux's mpv package, not from this script.

## Install

By default, setup only checks dependencies and installs the command:

~~~bash
bash setup.sh
~~~

To let setup install the runtime dependencies:

~~~bash
bash setup.sh --install-deps
~~~

The dependency installation is explicit so the script does not surprise you with a large package transaction on a device with limited storage.

## Usage

Play a local file:

~~~bash
termux-music-player ~/Music/song.mp3
~~~

Override subtitle timing for one run:

~~~bash
termux-music-player ~/Music/song.mp3 --offset -350
~~~

Positive offsets delay subtitles. Negative offsets make them appear earlier.

## How it works

The player starts mpv paused first. This makes mpv the source of truth for media metadata and duration.

~~~text
local music
    |
    v
   mpv (paused)
    |
    +--> metadata + duration
    |
    v
 lyric cache
    |
    +--> hit ---------------------+
    |                             |
    +--> miss -> LRCLIB -> cache -+
                                  |
                                  v
                         unpause mpv
                                  |
                                  v
                         print metadata
                                  |
                                  v
                           mpv JSON IPC
                                  |
                               time-pos
                                  |
                             offset math
                                  |
                                  v
                            LRC pointer
                                  |
                                  v
                                echo
~~~

Lyrics are fetched while mpv is paused, so a network delay does not shift the playback clock.

The LRC file is parsed once at startup and stored in Bash arrays. The subtitle loop advances through those timestamps instead of rescanning the entire LRC file on every poll.

Large backward seeks use a binary search to jump to the lyric active at the new position. Large forward jumps show the lyric active at the new position instead of dumping every skipped line.

## Configuration

Default config:

~~~text
~/.config/termux-music-player/config
~~~

Example:

~~~ini
SUBTITLE_OFFSET_MS=0
POLL_INTERVAL=0.20
LRCLIB_TIMEOUT=15
~~~

## Cache

Lyrics are stored under:

~~~text
~/.cache/termux-music-player/lyrics/
~~~

Cache keys are derived from artist, title, album, and duration.

A successful LRCLIB response without synced lyrics can be cached as a marker. A 404 is not cached because missing lyrics can become available later.

## Offline behavior

Music never needs the network because the player only accepts a local music file.

Cached lyrics also work without network access:

~~~text
cached .lrc
   |
   +--> use immediately
~~~

Without a cached lyric file, the player attempts LRCLIB and then continues playing normally when no synchronized lyric is available.

## Notes

This is an experimental MVP. It intentionally avoids playlists, streaming, music downloading, a full TUI, and a music database.

The project uses mpv's documented Unix-domain JSON IPC interface rather than parsing mpv terminal output.
