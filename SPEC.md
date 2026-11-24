# vela — spec v1

Ultra-fast, ultra-light media player for macOS. Install with `brew install vela`, run with `vela movie.mkv`.

## Goals
- Starts in under 100 ms and opens a file instantly.
- Plays 20–30 GB Blu-ray remuxes (80–120 Mbps, TrueHD/DTS-HD audio) with no stutter.
- Small: app under 25 MB, idle RAM under 80 MB.
- Chromeless, keyboard-first UI.

## Non-goals (v1)
Library and playlists, streaming URLs, filters, skins, Windows and Linux, our own decoders.

## Stack
| Layer | Choice |
|---|---|
| Language / UI | Swift 6, AppKit (no SwiftUI in the hot path) |
| Playback engine | libmpv (FFmpeg underneath) |
| Video decode | VideoToolbox hardware decode (`hwdec=videotoolbox`) |
| Rendering | libmpv render API, then a Metal/OpenGL layer (Phase 2) |
| Build | Swift Package Manager (works without full Xcode) |
| Targets | macOS 13+, arm64 + x86_64 |

## Formats
- **Containers:** mkv, mp4, m4v, mov, avi, webm, ts, m2ts, mts, flv, wmv, mpg, mpeg, vob, 3gp, ogv
- **Video:** H.264, HEVC (10-bit, HDR10, HLG, DV profile 5/8), AV1, VP9, VP8, MPEG-2/4, VC-1, ProRes
- **Audio files:** mp3, flac, wav, aac, m4a, alac, ogg, opus, wma, aiff, ape, dsf, dff, wv
- **Movie audio:** TrueHD (+Atmos bed), DTS-HD MA / DTS:X core, E-AC3, AC3, LPCM 7.1
- **Subtitles:** srt, ass/ssa, PGS, VobSub, WebVTT, embedded

## Large files and high-bitrate audio
- Demuxer cache of 128 MB forward and 32 MB back, never the whole file (measured: 485 MB to 340 MB footprint vs 256/64).
- Audio is the master clock (`video-sync=audio`); video frames drop or repeat, audio never glitches.
- Audio is decoded in a float pipeline to multichannel output; macOS downmixes. No passthrough in v1 (no AV receiver). Spatial audio for the Atmos bed is a later option.
- Hardware decode is on by default, with software fallback.

## UI (v1)
- Video fills the window. The overlay appears on mouse move and fades out after 2 s.
- Overlay: seek bar with hover time, play/pause, volume, elapsed/remaining time, title.
- Track picker: audio (e.g. "TrueHD Atmos 7.1"), subtitles, load external .srt.
- Open via drag and drop, CLI argument, file associations, or resume from the last position.
- Fullscreen, Picture-in-Picture, always-on-top.
- Audio-only mode: compact window with artwork.
- Stats overlay (`I`): codec, bitrate, hwdec status, dropped frames, cache fill.
- Config: `~/.config/vela/config` (key=value, passed through to mpv).

### Keys
| Key | Action |
|---|---|
| Space | Play/pause |
| ← / → | Seek −5 / +5 s (Shift: 60 s) |
| ↑ / ↓ | Volume |
| F | Fullscreen |
| M | Mute |
| A / S | Cycle audio / subtitle track |
| [ / ] | Speed −/+ |
| I | Stats |
| Q | Quit (saves position) |

## License
GPL-3.0-or-later (compatible with libmpv GPLv2+ and FFmpeg GPL builds). Every source file carries an SPDX header.

## Distribution (no-blocker rollout)
1. **Public GitHub repo** plus a **Homebrew tap** (`brew install <user>/tap/vela`). The formula builds from source and depends on `mpv`, so Gatekeeper never prompts. Free.
2. **homebrew-core** (`brew install vela`) once the project meets Homebrew's notability bar.
3. **Cask / .app download** only after Apple notarization (Developer account, $99/year). Unsigned .app downloads aren't offered because macOS blocks them.
4. Later: a trimmed static FFmpeg/libmpv build to drop the brew dependency and support older macOS.

## Phases
1. Spec, SwiftPM scaffold, libmpv linked, headless playback smoke test
2. Window, rendering, open file/CLI
3. UI overlay and keys
4. Tracks, audio, buffering tuning
5. Resume, PiP, stats, audio-only mode, config
6. Packaging and Homebrew
