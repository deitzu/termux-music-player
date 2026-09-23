# termux-music-player

A small Bash music player for Termux with synchronized lyrics from LRCLIB.

The project is intentionally simple:

- Local music files are played by mpv.
- Track metadata and duration are read with ffprobe.
- Synchronized lyrics are fetched from LRCLIB when they are not cached.
- Lyrics are cached locally as normal .lrc files.
- Subtitle timing follows mpv's actual playback position through its JSON IPC socket.
- Subtitles are printed with echo.
- A configurable subtitle offset is available in milliseconds.

## Requirements

This project currently targets Termux.

Dependencies:

- bash
- mpv
- ffmpeg (for ffprobe)
- curl
- jq
- socat
- coreutils

## Install

Clone the repository and run:

~~~bash
bash setup.sh
~~~

The setup script installs the dependencies, copies the player into Termux's $PREFIX/bin, and creates the default config file.

## Usage

Play a local music file:

~~~bash
termux-music-player ~/Music/song.mp3
~~~

Set a subtitle offset for one run:

~~~bash
termux-music-player ~/Music/song.mp3 --offset 350
~~~

A positive offset delays subtitles. A negative offset makes them appear earlier.

The default configuration is:

~~~text
~/.config/termux-music-player/config
~~~

Example:

~~~ini
SUBTITLE_OFFSET_MS=0
POLL_INTERVAL=0.10
LRCLIB_TIMEOUT=15
~~~

## How it works

~~~text
local music
    |
    v
  ffprobe
    |
    +--> title / artist / album / duration
    |
    v
 lyric cache --------------------+
    |                             |
    | miss                        | hit
    v                             |
  LRCLIB -------------------------+
    |
    v
  cached .lrc
    |
    v
   mpv
    |
    v
  JSON IPC -> time-pos
    |
    v
 subtitle timestamp + offset
    |
    v
   echo
~~~

Lyrics are prepared before playback starts, so the network request does not introduce subtitle startup drift.

If no cached or remotely available synchronized lyrics are found, the music still plays normally without subtitles.

## Cache

Lyrics are stored under:

~~~text
~/.cache/termux-music-player/lyrics/
~~~

Each cache file is keyed from the track metadata and duration.

The cached file contains the synchronized LRC data returned by LRCLIB. Instrumental tracks or tracks without synchronized lyrics are cached as a marker so the player does not repeatedly fetch the same missing result.

## Notes

This is an experimental MVP. It intentionally does not include playlists, a TUI, streaming, music downloading, or a full music library database.

mpv is controlled through its Unix-domain JSON IPC interface rather than by parsing mpv's terminal output. This keeps subtitle timing tied to the actual playback position.

LRCLIB requests identify this project with a User-Agent as required by the LRCLIB API documentation.
