# termux-music-player

A lightweight Bash music player for Termux with synchronized LRCLIB lyrics and an optional terminal karaoke display. Music files stay local; the project does not download audio.

## Features

- Plays local music files with either termux-media-player or the optional mpg123 backend.
- Automatically selects mpg123 for MP3 files when installed; other formats use termux-media-player.
- Reads title, artist, and album from ID3v2/ID3v1, FLAC/Vorbis comments, Ogg/Opus comments, MP4/M4A atoms, and WAV RIFF INFO tags, with filename fallback.
- Fetches timestamped lyrics from LRCLIB and caches them as LRC files for offline reuse.
- Looks up lyrics using track metadata first. The fuzzy-search fallback only accepts a result when both normalized title and artist match.
- Supports an optional manual LRCLIB result picker to correct a missing or incorrect match.
- Shows track information with terminal colors and can animate lyric highlighting in place.
- Supports character-, word-, or syllable-based highlighting and karaoke or spotlight styles.
- Allows global and per-track subtitle offsets.
- Fetches lyrics for a whole music directory without starting playback.
- Includes music-clone for copying supported music files from Android Downloads into ~/Music.

## Requirements

The player is intended for Bash in Termux. Its lightweight runtime tools include curl, jq, sha256sum, awk, sed, dd, od, cut, head, wc, mktemp, grep, find, tr, and readlink. Run the setup script to check these dependencies.

Playback backends:

- termux-media-player is required for non-MP3 playback and when PLAYER=termux. On recent Google Play Termux builds it may be built in; other builds may need the Termux:API integration.
- mpg123 is optional and supports MP3 only. Install it with pkg install mpg123. The package and its dependencies use additional storage, so it is not installed by the project setup script.

The player does not require mpv, ffprobe, ffmpeg, or socat.

## Install

Clone or download this repository, enter its directory, then check the environment:

~~~bash
bash setup.sh
~~~

To install the lightweight command-line dependencies:

~~~bash
bash setup.sh --install-deps
~~~

To enable the optional MP3 backend:

~~~bash
pkg install mpg123
~~~

Setup installs the player scripts and adds aliases to ~/.bashrc:

~~~bash
alias music='termux-music-player'
alias mclone='music-clone'
alias mwatch='music-clone --watch'
alias mlyrics='termux-music-player --fetch-all'
~~~

Reload Bash to load the aliases:

~~~bash
source ~/.bashrc
~~~

## Usage

Play a local track:

~~~bash
music ~/Music/song.mp3
~~~

Use the full command name instead of the alias:

~~~bash
termux-music-player ~/Music/song.mp3
~~~

### Playback options

~~~bash
music ~/Music/song.mp3 --offset -300
music ~/Music/song.mp3 --player mpg123
music ~/Music/song.mp3 --color never
music ~/Music/song.mp3 --color always
music ~/Music/song.mp3 --lyric-unit syllable --lyric-style spotlight
~~~

Available options:

| Option | Purpose |
|---|---|
| --offset MS | Shift lyrics by a number of milliseconds. Positive values delay lyrics; negative values advance them. An explicitly supplied offset is saved for that track. |
| --player auto | Use mpg123 for MP3 when installed; otherwise use termux-media-player. |
| --player termux | Force termux-media-player. |
| --player mpg123 | Force mpg123; the input must be an MP3 file and mpg123 must be installed. |
| --color auto | Use colors when stdout is a terminal and NO_COLOR is unset. |
| --color always | Keep color codes in output even when it is redirected. In-place karaoke animation still requires a terminal. |
| --color never or --no-color | Disable colors and the in-place sweep. |
| --lyric-unit char | Highlight one character at a time (default). |
| --lyric-unit word | Highlight one word at a time. |
| --lyric-unit syllable | Use a heuristic syllable split. |
| --lyric-style karaoke | Highlight the sung portion and dim the upcoming portion (default). |
| --lyric-style spotlight | Show the whole sentence normally and highlight only the currently active unit. |
| --fetch-all DIR | Fetch and cache lyrics for all supported music files in DIR without playing them. Defaults to ~/Music. |
| --force | With --fetch-all, fetch again even if the lyric cache exists. |
| --select-lyrics | Let the user choose a synced LRCLIB result manually and replace this track's cache. |

### Select a lyric manually

If the automatic match is missing or wrong, use:

~~~bash
music ~/Music/song.mp3 --select-lyrics
~~~

The picker lists LRCLIB results that contain synced lyrics and displays their
title, artist, album, and duration. Choose a number to save that result in the
local cache; enter 0 to cancel. This option bypasses the existing cache, so a
wrong cached result can be replaced. The picker is interactive and cannot be
combined with --fetch-all.

### Fetch lyrics in bulk

Fetch lyrics for the default ~/Music folder without playback:

~~~bash
mlyrics
~~~

Use another directory:

~~~bash
music --fetch-all ~/Music
~~~

Force a new fetch even when cache entries already exist:

~~~bash
music --fetch-all ~/Music --force
~~~

## Colors and karaoke lyrics

When output goes to a terminal, track information is colored by default. Karaoke mode redraws the active lyric sentence in place, highlighting the portion estimated to be sung while dimming the remaining text. Finished sentences remain above in a quieter color.

LRCLIB timestamps are usually sentence-level, not word-level. The sweep inside a sentence is therefore estimated over the interval until the next lyric timestamp, up to LYRIC_SWEEP_MAX_MS; it is not true word-timed karaoke.

The LYRIC_UNIT setting controls whether the active portion advances by character, word, or syllable. The syllable splitter is heuristic: Indonesian mode treats ng, ny, sy, kh as combined consonants and ai, au, oi as combined vowels. Set LYRIC_SYLLABLE_LANG=en for the English heuristic, which also accounts for some silent final-e words. Unusual words can still be split incorrectly.

The LYRIC_STYLE setting has two modes:

- karaoke: the sung part remains highlighted and the upcoming part is dim.
- spotlight: the full sentence is shown in the normal color; only the currently active unit is highlighted.

Examples:

~~~bash
music song.mp3 --lyric-unit word
music song.mp3 --lyric-unit syllable --lyric-style spotlight
music song.mp3 --no-color
~~~

The in-place sweep requires a terminal and may be disabled by setting LYRIC_SWEEP=0. Lines wider than the terminal are shown without the sweep. NO_COLOR is respected by default.

## Player backends

### termux-media-player

This backend runs through Termux:API or the built-in command available in some Termux distributions. It can play formats supported by the Android media stack, but reports playback position in whole seconds. The lyric code estimates time between reported positions using the local clock.

### mpg123

The optional mpg123 backend runs inside Termux and reports fractional-second playback position, allowing smoother lyric synchronization. It supports MP3 only. Install it with:

~~~bash
pkg install mpg123
~~~

PLAYER=auto selects mpg123 for MP3 when available; otherwise it uses termux-media-player. The backend can be set globally in the config or per run with --player.

## Configuration

The configuration file is:

~~~text
~/.config/termux-music-player/config
~~~

Setup creates it if it does not exist. The repository includes config.example with comments for every setting. Available settings and defaults:

| Setting | Default | Purpose |
|---|---:|---|
| SUBTITLE_OFFSET_MS | 0 | Global subtitle offset in milliseconds, used when no saved per-track offset exists. |
| POLL_INTERVAL | 0.20 | Polling interval in seconds. Smaller values can improve responsiveness while using more CPU. |
| LRCLIB_TIMEOUT | 15 | Maximum duration of an LRCLIB request in seconds. |
| PLAYER | auto | Playback backend: auto, termux, or mpg123. |
| COLOR | auto | Color behavior: auto, always, or never. |
| LYRIC_SWEEP | 1 | Animate the current line in a terminal; set to 0 to print each line once. |
| LYRIC_SWEEP_MAX_MS | 5000 | Maximum estimated sweep duration for a lyric line. |
| LYRIC_UNIT | char | Highlight granularity: char, word, or syllable. |
| LYRIC_SYLLABLE_LANG | id | Syllable heuristic: id or en. |
| LYRIC_STYLE | karaoke | Highlight style: karaoke or spotlight. |
| LYRIC_HI_COLOR | 87 | 256-color code for the active portion, from 0 to 255. |
| LYRIC_LO_COLOR | 240 | 256-color code for the upcoming portion, from 0 to 255. |
| LYRIC_DONE_COLOR | 250 | 256-color code for completed lines, from 0 to 255. |

CLI flags override the corresponding settings for one run. An explicitly supplied --offset is stored under ~/.cache/termux-music-player/offsets/ and reused for that track on later runs.

## How it works

1. Reads file metadata using format-specific shell parsers and falls back to a filename such as Artist - Title.mp3.
2. Checks the local lyrics cache. If there is no cache entry, it queries LRCLIB.
3. Starts the selected playback backend and polls its playback position.
4. Applies the configured offset and displays the lyric line active at that timestamp.

The bulk fetch command uses the same metadata and LRCLIB lookup path but does not start playback.

## LRCLIB lookup and cache

The player uses LRCLIB's GET /api/get endpoint with track, artist, and album metadata. If that does not return synced lyrics, it retries without the album and then searches with multiple artist/title query shapes. The automatic fuzzy-search fallback only accepts a result with a normalized title and artist matching the local metadata.

Only syncedLyrics is cached because the player displays timestamped terminal subtitles. Cache files are stored under:

~~~text
~/.cache/termux-music-player/lyrics/
~~~

The cache key is derived from artist, title, and album. Existing cache entries can be reused offline. Run --select-lyrics to replace a wrong match manually, or use --force with --fetch-all to fetch again in bulk.

## Music cloner

music-clone copies supported music files from Android Downloads into ~/Music by default. It ignores non-music files and preserves subdirectories. Existing destination files are left unchanged unless the source file is newer.

Aliases:

~~~bash
mclone
mwatch
~~~

Commands:

~~~bash
music-clone --help
mclone
mclone --watch
mclone --watch --interval 10
music-clone --source ~/storage/download --dest ~/Music
~~~

Options include --watch, --interval SEC, --source DIR, and --dest DIR. Run music-clone --help for details.

## Current limitations

- The project is an experimental MVP.
- Metadata parsing is lightweight and not every uncommon metadata/container variant is supported.
- Karaoke timing is estimated from line timestamps, not actual word-level timestamps.
- The syllable splitter is heuristic and can be wrong for unusual words.
- There is no playlist, full-screen TUI, downloader, or music database.
- The player has no built-in audio library view; playback starts from a file path.

The goal is to keep the dependency graph small while gradually improving terminal playback and lyric synchronization.
