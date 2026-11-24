# vela

Ultra-fast, ultra-light media player for macOS. Plays everything FFmpeg plays (MKV, MP4, MOV, AVI, WebM, TS, FLAC, MP3, ALAC, DSD, …) with hardware decoding, and handles 20–30 GB Blu-ray remuxes with TrueHD / DTS-HD audio smoothly.

> **Status:** early development (Phase 3 of 6). Native window, hardware decoding, auto-hiding controls and the full keymap. Track menus land in Phase 4. See [SPEC.md](SPEC.md).

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
vela --probe movie.mkv              # print codec, resolution, audio info
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
| `F`, double-click | Fullscreen (`Esc` leaves) |
| `I` | Stats overlay |
| `Q` | Quit |

Controls appear when you move the mouse and fade out after 2 s.

```bash
VELA_DEBUG=1 vela movie.mkv         # print hwdec / dropped frames / cache every 5 s
```

## Why it's fast

- Hardware video decode through Apple VideoToolbox
- Audio is the master clock, so high-bitrate audio never glitches
- Large read-ahead cache (256 MB) so huge files on slow drives don't stutter
- Native Swift/AppKit, no Electron, a small binary

## License

vela is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0 or later**. See [LICENSE](LICENSE).

vela uses [libmpv](https://mpv.io) (GPLv2+) and [FFmpeg](https://ffmpeg.org) (LGPL/GPL), and their licenses apply to them.
