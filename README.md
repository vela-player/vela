# vela

Ultra-fast, ultra-light media player for macOS. Plays everything FFmpeg plays (MKV, MP4, MOV, AVI, WebM, TS, FLAC, MP3, ALAC, DSD, …) with hardware decoding, and handles 20–30 GB Blu-ray remuxes with TrueHD / DTS-HD audio smoothly.

> **Status:** early development (Phase 5 of 6). Feature-complete for v1: playback, controls, tracks, resume, mini player, audio mode and config. Packaging and Homebrew land in Phase 6. See [SPEC.md](SPEC.md).

## Install

### Homebrew (recommended, no Gatekeeper prompts)

```bash
brew install <github-user>/tap/vela
```

This builds vela from source on your Mac, so macOS never blocks it. It is published once the repository goes public.

### From source

Requires macOS 13+, the Xcode Command Line Tools (`xcode-select --install`) and mpv:

```bash
brew install mpv
git clone https://github.com/<github-user>/vela.git
cd vela
swift build -c release
.build/release/vela --version
```

## Usage

```bash
vela movie.mkv                      # play (or drag a file onto the window, or ⌘O)
vela --start=3600 --volume=50 a.mkv  # any --key=value is passed to mpv
vela --probe movie.mkv              # print format and every audio/subtitle track
vela --version
```

### Keys

| Key | Action |
|---|---|
| `Space` | Play / pause |
| `←` `→` | Seek 5 s (`Shift`: 60 s) |
| `↑` `↓` | Volume |
| `M` | Mute |
| `A` / `S` | Next audio / subtitle track |
| `[` `]` / `Backspace` | Slower / faster / normal speed |
| `,` `.` | Frame back / forward |
| `Home` | Start over |
| `F`, double-click | Fullscreen (`Esc` leaves) |
| `T` | Float on top |
| `P` | Mini player (small, corner, all Spaces) |
| `I` | Stats overlay |
| `Q` | Quit |

Controls appear when you move the mouse and fade out after 2 s. Pick audio and subtitle tracks from the menu bar or the buttons in the control bar. Drop an `.srt`/`.ass`/`.vtt` file on the window to add it; subtitles next to the movie (or in a `Subs/` folder) load automatically.

vela remembers where you stopped and resumes there next time (unless you were in the first 30 s or the last minute). Audio files open in a compact window, or a square one when they have cover art.

### Config

Put defaults in `~/.config/vela/config`, one mpv option per line. Command-line options win.

```
# ~/.config/vela/config
volume=70
sub-font-size=40
alang=en,hi
```

```bash
VELA_DEBUG=1 vela movie.mkv         # print hwdec / dropped frames / cache every 5 s
```

## Why it's fast

- Hardware video decode through Apple VideoToolbox
- Audio is the master clock, so high-bitrate audio never glitches
- 128 MB read-ahead cache: about 13 s of headroom even at Blu-ray remux bitrates, without wasting RAM
- Native Swift/AppKit, no Electron, a small binary

## License

vela is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0 or later**. See [LICENSE](LICENSE).

vela uses [libmpv](https://mpv.io) (GPLv2+) and [FFmpeg](https://ffmpeg.org) (LGPL/GPL), and their licenses apply to them.
