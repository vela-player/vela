// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Snapshot of what the controls show. Filled from mpv property changes.
struct PlaybackState {
    var position: Double = 0
    var duration: Double = 0
    var cachedUntil: Double = 0
    var paused = false
    var volume: Double = 100
    var muted = false
}

func formatTime(_ t: Double, showHours: Bool) -> String {
    let s = max(0, Int(t.rounded(.down)))
    let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60)
    return showHours ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

// MARK: - Seek bar

/// Thin timeline: buffered range, played range, a knob and a hover time.
final class SeekBar: NSView {
    var duration: Double = 0 { didSet { needsDisplay = true } }
    var position: Double = 0 { didSet { if !dragging { needsDisplay = true } } }
    var cachedUntil: Double = 0 { didSet { needsDisplay = true } }

    /// (seconds, done) — done is false while dragging (fast keyframe seek), true on release.
    var onSeek: ((Double, Bool) -> Void)?
    /// x in this view's coordinates and the time under it, or nil when the pointer leaves.
    var onHover: ((CGFloat, Double)?) -> Void = { _ in }

    private var dragging = false
    private var dragPosition: Double = 0
    private var hovering = false

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 20) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func time(at x: CGFloat) -> Double {
        guard bounds.width > 0 else { return 0 }
        return Double(min(max(x / bounds.width, 0), 1)) * duration
    }

    override func draw(_ dirty: NSRect) {
        let h: CGFloat = hovering || dragging ? 6 : 4
        let track = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        func bar(_ fraction: Double, _ color: NSColor) {
            var r = track
            r.size.width = track.width * CGFloat(min(max(fraction, 0), 1))
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        }
        guard duration > 0 else { bar(1, .white.withAlphaComponent(0.2)); return }
        let shown = dragging ? dragPosition : position
        bar(1, .white.withAlphaComponent(0.2))
        bar(cachedUntil / duration, .white.withAlphaComponent(0.35))
        bar(shown / duration, .white)
        if hovering || dragging {
            let x = bounds.width * CGFloat(shown / duration)
            let knob: CGFloat = 12
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - knob / 2, y: (bounds.height - knob) / 2, width: knob, height: knob)).fill()
        }
    }

    override func mouseEntered(with e: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hovering = false; needsDisplay = true; onHover(nil) }
    override func mouseMoved(with e: NSEvent) { reportHover(e) }

    override func mouseDown(with e: NSEvent) {
        dragging = true
        mouseDragged(with: e)
    }

    override func mouseDragged(with e: NSEvent) {
        let x = convert(e.locationInWindow, from: nil).x
        dragPosition = time(at: x)
        needsDisplay = true
        reportHover(e)
        onSeek?(dragPosition, false)
    }

    override func mouseUp(with e: NSEvent) {
        dragging = false
        position = dragPosition
        onSeek?(dragPosition, true)
    }

    private func reportHover(_ e: NSEvent) {
        let x = min(max(convert(e.locationInWindow, from: nil).x, 0), bounds.width)
        duration > 0 ? onHover((x, time(at: x))) : onHover(nil)
    }
}

// MARK: - Control bar

/// HUD panel that never drags the window (so the seek bar and slider work).
private final class Panel: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Everything drawn over the video: bottom control bar and the title.
final class OverlayView: NSView {
    let seekBar = SeekBar()
    private let panel = Panel()
    private let playButton = NSButton()
    private let muteButton = NSButton()
    private let audioButton = NSButton()
    private let subtitleButton = NSButton()
    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let elapsed = OverlayView.label()
    private let remaining = OverlayView.label()
    private let hoverTime = OverlayView.label()
    private let hoverPill = NSVisualEffectView()
    let titleLabel = NSTextField(labelWithString: "")

    var onTogglePause: () -> Void = {}
    var onToggleMute: () -> Void = {}
    var onVolume: (Double) -> Void = { _ in }
    var onAudioMenu: (NSView) -> Void = { _ in }
    var onSubtitleMenu: (NSView) -> Void = { _ in }
    var onClearVoice: () -> Void = {}
    private let voiceButton = NSButton()

    /// True while the pointer is over the control bar; the overlay stays visible then.
    private(set) var pointerInsideControls = false

    private static func label() -> NSTextField {
        let l = NSTextField(labelWithString: "0:00")
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        l.textColor = .white
        return l
    }

    private static func symbolButton(_ b: NSButton, _ name: String) {
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.contentTintColor = .white
        b.image = NSImage(systemSymbolName: name, accessibilityDescription: name)
        b.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)

        panel.material = .hudWindow
        panel.blendingMode = .withinWindow
        panel.state = .active
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 12
        panel.layer?.masksToBounds = true

        Self.symbolButton(playButton, "pause.fill")
        playButton.target = self
        playButton.action = #selector(playClicked)
        Self.symbolButton(muteButton, "speaker.wave.2.fill")
        muteButton.target = self
        muteButton.action = #selector(muteClicked)

        Self.symbolButton(audioButton, "waveform")
        audioButton.target = self
        audioButton.action = #selector(audioClicked)
        audioButton.toolTip = "Audio track"
        Self.symbolButton(subtitleButton, "captions.bubble.fill")
        subtitleButton.target = self
        subtitleButton.action = #selector(subtitleClicked)
        subtitleButton.toolTip = "Subtitles"
        Self.symbolButton(voiceButton, "person.wave.2")
        voiceButton.target = self
        voiceButton.action = #selector(voiceClicked)
        voiceButton.toolTip = "Clear Voice (V): louder dialogue, tamer explosions"

        volumeSlider.controlSize = .small
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true

        seekBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        seekBar.onHover = { [weak self] h in self?.showHover(h) }
        remaining.alignment = .right

        let row = NSStackView(views: [playButton, elapsed, seekBar, remaining, voiceButton, audioButton, subtitleButton, muteButton, volumeSlider])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 14)
        row.setCustomSpacing(4, after: muteButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(row)
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        hoverPill.material = .hudWindow
        hoverPill.state = .active
        hoverPill.wantsLayer = true
        hoverPill.layer?.cornerRadius = 6
        hoverPill.isHidden = true
        hoverTime.alignment = .center
        hoverTime.frame = NSRect(x: 0, y: 3, width: 64, height: 16)
        hoverPill.frame = NSRect(x: 0, y: 0, width: 64, height: 22)
        hoverPill.addSubview(hoverTime)
        addSubview(hoverPill)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.shadow = { let s = NSShadow(); s.shadowBlurRadius = 4; s.shadowColor = .black; return s }()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            panel.heightAnchor.constraint(equalToConstant: 44),
            row.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            row.topAnchor.constraint(equalTo: panel.topAnchor),
            row.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            elapsed.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
            remaining.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -180),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // Clicks outside the panel fall through to the video (double-click fullscreen, window drag).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === titleLabel ? nil : hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: panel.frame, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with e: NSEvent) { pointerInsideControls = true }
    override func mouseExited(with e: NSEvent) { pointerInsideControls = false }

    func update(_ s: PlaybackState) {
        let hours = s.duration >= 3600
        elapsed.stringValue = formatTime(s.position, showHours: hours)
        remaining.stringValue = "-" + formatTime(max(s.duration - s.position, 0), showHours: hours)
        seekBar.duration = s.duration
        seekBar.position = s.position
        seekBar.cachedUntil = s.cachedUntil
        playButton.image = NSImage(systemSymbolName: s.paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        let speaker = s.muted || s.volume == 0 ? "speaker.slash.fill"
            : s.volume < 34 ? "speaker.wave.1.fill" : s.volume < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        muteButton.image = NSImage(systemSymbolName: speaker, accessibilityDescription: nil)
        if volumeSlider.window?.currentEvent?.type != .leftMouseDragged { volumeSlider.doubleValue = s.volume }
    }

    private func showHover(_ h: (CGFloat, Double)?) {
        guard let (x, t) = h else { hoverPill.isHidden = true; return }
        hoverTime.stringValue = formatTime(t, showHours: seekBar.duration >= 3600)
        let p = seekBar.convert(NSPoint(x: x, y: seekBar.bounds.maxY), to: self)
        hoverPill.setFrameOrigin(NSPoint(x: min(max(p.x - 32, 8), bounds.width - 72), y: panel.frame.maxY + 6))
        hoverPill.isHidden = false
    }

    /// Hide the audio button only when the file has no audio at all.
    func setTrackButtons(audio: Int, subtitles: Int) {
        audioButton.isHidden = audio == 0  // shown even for one track, so it's easy to find
        subtitleButton.isHidden = false  // always offers "Add Subtitle File…"
    }

    @objc private func audioClicked() { onAudioMenu(audioButton) }
    @objc private func subtitleClicked() { onSubtitleMenu(subtitleButton) }
    @objc private func voiceClicked() { onClearVoice() }

    /// Filled, accent-colored icon while Clear Voice is on.
    func setClearVoice(on: Bool, available: Bool) {
        voiceButton.isHidden = !available
        voiceButton.image = NSImage(systemSymbolName: on ? "person.wave.2.fill" : "person.wave.2", accessibilityDescription: "Clear Voice")
        voiceButton.contentTintColor = on ? .controlAccentColor : .white
    }
    @objc private func playClicked() { onTogglePause() }
    @objc private func muteClicked() { onToggleMute() }
    @objc private func volumeChanged() { onVolume(volumeSlider.doubleValue) }
}
