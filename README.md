# vela

Ultra-fast, ultra-light media player for macOS. Plays everything FFmpeg plays (MKV, MP4, MOV, AVI, WebM, TS, FLAC, MP3, ALAC, DSD, …) with hardware decoding, and handles 20–30 GB Blu-ray remuxes with TrueHD / DTS-HD audio smoothly.

> **Status:** v1.0.0. See [SPEC.md](SPEC.md) for the design. See [SPEC.md](SPEC.md).

## Clear Voice

Quiet dialogue, deafening explosions? Press **`V`** (or the voice button in the control bar).

Film mixes put dialogue in the center channel and effects everywhere else; a normal surround-to-stereo downmix buries the center, which is why laptop speakers and headphones make you ride the volume all film. Clear Voice remixes with the dialogue in front and evens out the jumps:

| Measured on a 5.1 film clip | Standard mix | Clear Voice |
|---|---|---|
| Dialogue vs effects | baseline | **+6.7 dB** louder relative to effects |
| Loudness range (EBU R128) | 13.0 LU | **6.9 LU** (about half the swings) |
| Bass and treble balance | baseline | within about 1 dB, so it stays full, not thin |
| Clipping | — | limited to −1 dBFS |

Works on any track: surround gets a dialogue-first remix, stereo gets a speech-band lift. vela remembers the setting.

## AI subtitles (macOS 26+)

No subtitles for a film, or none in your language? **Subtitles → Generate Subtitles** writes them on your Mac with Apple's on-device speech recognition. Nothing is uploaded.

- Starts where you are watching and fills in progressively (lines appear within seconds), then goes back and does the beginning.
- **Generate Translated Subtitles → Hindi / Spanish / …** translates as it goes. The first time, macOS asks to download that language.
- Done once per film: the result is cached and offered as an "AI · English" track next time.
- Tested on a full 2 h 8 min film: transcribed in **51 seconds** (about 150× real time), matching **90%** of the words in the official subtitles.

From the command line:

```bash
vela --ai-subtitles movie.mkv > movie.srt
vela --ai-subtitles --to=hi movie.mkv > movie.hi.srt
```

## Ask the movie (experimental, command line)

Ask about what you've watched so far, or get a "previously" recap, answered by Apple's on-device model (Apple Intelligence must be on). It only ever sees dialogue up to the time you give, so it can't spoil what comes next.

```bash
vela --ask movie.mkv --at=3480 "why are they called the Thunderbolts?"
vela --recap movie.mkv --at=3600
```

**It's experimental because it isn't reliable yet.** On a full film it answered simple early questions correctly with the supporting line and never spoiled anything, but Apple's safety filter refused some action dialogue, it missed questions the dialogue did answer, and long recaps were vague. It isn't in the player's menus for that reason.

## Install

### Homebrew (recommended, no Gatekeeper prompts)

```bash
brew install vela-player/tap/vela
```

Homebrew builds vela from source on your Mac (about a minute), so macOS never blocks it. Upgrade with `brew upgrade vela`.

### From source

Requires macOS 13+, the Xcode Command Line Tools (`xcode-select --install`) and mpv:

```bash
brew install mpv
git clone https://github.com/vela-player/vela.git
cd vela
make install          # installs to /usr/local/bin (PREFIX=... to change)
make app              # optional: build/vela.app with Finder file associations
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
| `V` | Clear Voice on/off |
| `I` | Stats panel (codec, 10-bit/HDR, audio channels, output device, dropped frames, buffer) |
| `Q` | Quit |

Controls appear when you move the mouse and fade out after 2 s. Switch audio language (English, Chinese, commentary…) with the **waveform button** in the control bar, the **Audio** menu, or `A` to step through tracks; subtitles work the same with the speech-bubble button, **Subtitles** menu or `S`. vela picks audio in your Mac's language automatically (System Settings → Language & Region) and turns on subtitles in your language when the audio isn't; override with `alang=`/`slang=` in the config. Drop an `.srt`/`.ass`/`.vtt` file on the window to add it; subtitles next to the movie (or in a `Subs/` folder) load automatically.

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

## Releasing

1. Bump `version` in `Sources/vela/main.swift`, commit.
2. `git tag v1.2.3 && git push --tags`.
3. The Release workflow creates the GitHub release and updates `vela-player/homebrew-tap` (needs the `TAP_GITHUB_TOKEN` secret).
