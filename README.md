# vela

Ultra-fast, ultra-light media player for macOS. Plays everything FFmpeg plays (MKV, MP4, MOV, AVI, WebM, TS, FLAC, MP3, ALAC, DSD, …) with hardware decoding, and handles 20–30 GB Blu-ray remuxes with TrueHD / DTS-HD audio smoothly.

> **Status:** early development (Phase 1 of 6). Command-line probing and audio playback work; the video window lands in Phase 2. See [SPEC.md](SPEC.md).

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
vela movie.mkv           # play
vela --probe movie.mkv   # print codec, resolution, audio info
vela --version
```

## Why it's fast

- Hardware video decode through Apple VideoToolbox
- Audio is the master clock, so high-bitrate audio never glitches
- Large read-ahead cache (256 MB) so huge files on slow drives don't stutter
- Native Swift/AppKit, no Electron, a small binary

## License

vela is free software: you can redistribute it and/or modify it under the terms of the **GNU General Public License v3.0 or later**. See [LICENSE](LICENSE).

vela uses [libmpv](https://mpv.io) (GPLv2+) and [FFmpeg](https://ffmpeg.org) (LGPL/GPL), and their licenses apply to them.
