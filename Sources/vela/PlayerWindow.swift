// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CMpv
import UniformTypeIdentifiers

/// The view that hosts the video layer, takes keys and accepts dropped files.
final class VideoView: NSView {
    let videoLayer: VideoLayer
    var onOpen: ((URL) -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onMouseMove: (() -> Void)?

    init(player: Player) {
        videoLayer = VideoLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer { videoLayer }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        videoLayer.contentsScale = window?.backingScaleFactor ?? 2  // render at native Retina pixels
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onMouseMove?() }
    override func mouseEntered(with event: NSEvent) { onMouseMove?() }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { window?.toggleFullScreen(nil) }
    }

    // MARK: drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(from: sender) else { return false }
        onOpen?(url)
        return true
    }

    private func fileURL(from info: NSDraggingInfo) -> URL? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true])?.first as? URL
    }
}

/// One chromeless window playing one file at a time.
final class PlayerWindowController: NSObject, NSWindowDelegate {
    let player: Player
    let window: NSWindow
    let videoView: VideoView
    private let overlay = OverlayView()
    private var state = PlaybackState()
    private var sizedForCurrentFile = false
    private var overlayVisible = true
    private var hideTimer: Timer?
    private var debugTimer: Timer?
    let audioMenu = NSMenu(title: "Audio")
    let subtitleMenu = NSMenu(title: "Subtitles")

    init(player: Player) {
        self.player = player
        videoView = VideoView(player: player)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.delegate = self
        window.title = "vela"
        window.minSize = NSSize(width: 480, height: 270)
        window.center()

        let container = NSView()
        for v in [videoView, overlay] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        window.contentView = container

        videoView.onOpen = { [weak self] url in
            if subtitleExtensions.contains(url.pathExtension.lowercased()) { self?.addSubtitle(url) } else { self?.open(url) }
        }
        overlay.onAudioMenu = { [weak self] view in self?.popUp(self?.audioMenu, from: view) }
        overlay.onSubtitleMenu = { [weak self] view in self?.popUp(self?.subtitleMenu, from: view) }
        videoView.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        videoView.onMouseMove = { [weak self] in self?.poke() }
        overlay.onTogglePause = { [weak self] in self?.player.run("cycle", "pause") }
        overlay.onToggleMute = { [weak self] in self?.player.run("cycle", "mute") }
        overlay.onVolume = { [weak self] v in self?.player.setProperty("volume", String(format: "%.0f", v)) }
        overlay.seekBar.onSeek = { [weak self] t, done in
            self?.player.run("seek", String(t), done ? "absolute+exact" : "absolute+keyframes")
            self?.poke()
        }

        for (name, format) in [("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
                               ("demuxer-cache-time", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
                               ("volume", MPV_FORMAT_DOUBLE), ("mute", MPV_FORMAT_FLAG),
                               ("track-list", MPV_FORMAT_NONE)] {
            player.observe(name, format)
        }
        player.onEvent = { [weak self] ev in self?.handle(ev) }
        player.startEventPump()
        rebuildTrackMenus()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        poke()
    }

    func open(_ url: URL) {
        sizedForCurrentFile = false
        window.title = url.lastPathComponent
        overlay.titleLabel.stringValue = url.deletingPathExtension().lastPathComponent
        window.representedURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        player.run("loadfile", url.path)
        poke()
    }

    // MARK: - mpv events

    private func handle(_ ev: UnsafePointer<mpv_event>) {
        switch ev.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            propertyChanged(ev.pointee.data.assumingMemoryBound(to: mpv_event_property.self).pointee)
        case MPV_EVENT_VIDEO_RECONFIG:
            if !sizedForCurrentFile { fitWindowToVideo() }
        case MPV_EVENT_FILE_LOADED:
            if ProcessInfo.processInfo.environment["VELA_DEBUG"] != nil, debugTimer == nil { startDebugStats() }
        case MPV_EVENT_SHUTDOWN:
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func propertyChanged(_ p: mpv_event_property) {
        let name = String(cString: p.name)
        if name == "track-list" { rebuildTrackMenus(); return }
        let double = p.format == MPV_FORMAT_DOUBLE ? p.data.load(as: Double.self) : 0
        let flag = p.format == MPV_FORMAT_FLAG ? p.data.load(as: Int32.self) != 0 : false
        switch name {
        case "time-pos":
            // time-pos fires every frame; the controls only change once per second.
            let secondChanged = Int(double) != Int(state.position)
            state.position = double
            if !secondChanged { return }
        case "duration": state.duration = double
        case "demuxer-cache-time": state.cachedUntil = double
        case "pause": state.paused = flag; poke()
        case "volume": state.volume = double
        case "mute": state.muted = flag
        default: return
        }
        if overlayVisible { overlay.update(state) }  // no UI work while hidden
    }

    // MARK: - Tracks

    /// Rebuild the Audio and Subtitles menus (menu bar and overlay buttons share them).
    private func rebuildTrackMenus() {
        let tracks = Track.list(from: player.node("track-list"))
        fill(audioMenu, with: tracks.filter { $0.kind == .audio }, property: "aid")
        fill(subtitleMenu, with: tracks.filter { $0.kind == .sub }, property: "sid")
        subtitleMenu.addItem(.separator())
        let add = subtitleMenu.addItem(withTitle: "Add Subtitle File…", action: #selector(chooseSubtitle), keyEquivalent: "")
        add.target = self
        overlay.setTrackButtons(audio: tracks.contains { $0.kind == .audio } ? tracks.filter { $0.kind == .audio }.count : 0,
                                subtitles: tracks.filter { $0.kind == .sub }.count)
    }

    private func fill(_ menu: NSMenu, with tracks: [Track], property: String) {
        menu.removeAllItems()
        let off = menu.addItem(withTitle: tracks.isEmpty ? "No Tracks" : "Off", action: #selector(selectTrack(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = [property, "no"]
        off.state = tracks.contains { $0.selected } ? .off : .on
        if tracks.isEmpty { off.isEnabled = false; off.action = nil; off.state = .off }
        if !tracks.isEmpty { menu.addItem(.separator()) }
        for t in tracks {
            let item = menu.addItem(withTitle: t.label, action: #selector(selectTrack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [property, String(t.id)]
            item.state = t.selected ? .on : .off
        }
    }

    @objc private func selectTrack(_ item: NSMenuItem) {
        guard let pv = item.representedObject as? [String] else { return }
        player.run("osd-msg", "set", pv[0], pv[1])
    }

    @objc func chooseSubtitle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = subtitleExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.directoryURL = window.representedURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] r in
            if r == .OK, let url = panel.url { self?.addSubtitle(url) }
        }
    }

    func addSubtitle(_ url: URL) {
        player.run("osd-msg", "sub-add", url.path, "select")
    }

    private func popUp(_ menu: NSMenu?, from view: NSView) {
        guard let menu else { return }
        hideTimer?.invalidate()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 6), in: view)
        poke()
    }

    // MARK: - Overlay auto-hide

    /// Show the controls and restart the 2-second hide timer.
    private func poke() {
        setOverlay(visible: true)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.overlay.pointerInsideControls { self.poke() } else { self.setOverlay(visible: false) }
        }
    }

    private func setOverlay(visible: Bool) {
        if visible { overlay.update(state) }
        guard visible != overlayVisible else { return }
        overlayVisible = visible
        let titlebar = window.standardWindowButton(.closeButton)?.superview
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.12 : 0.35
            overlay.animator().alphaValue = visible ? 1 : 0
            titlebar?.animator().alphaValue = visible ? 1 : 0
        }
        if !visible { NSCursor.setHiddenUntilMouseMoves(true) }
    }

    // MARK: - Keys

    /// Returns true when the key was handled. `osd-msg` makes mpv draw feedback on the video.
    private func handleKey(_ e: NSEvent) -> Bool {
        let shift = e.modifierFlags.contains(.shift)
        let step = shift ? "60" : "5"
        switch e.keyCode {
        case 49: player.run("cycle", "pause")                                    // space
        case 123: player.run("seek", "-" + step); poke()                         // ←
        case 124: player.run("seek", step); poke()                               // →
        case 126: player.run("osd-msg-bar", "add", "volume", "5")                // ↑
        case 125: player.run("osd-msg-bar", "add", "volume", "-5")               // ↓
        case 53:                                                                 // esc
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        case 51: player.run("osd-msg", "set", "speed", "1")                      // backspace
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "f": window.toggleFullScreen(nil)
            case "m": player.run("osd-msg", "cycle", "mute")
            case "a": player.run("osd-msg", "cycle", "audio")
            case "s": player.run("osd-msg", "cycle", "sub")
            case "[": player.run("osd-msg", "multiply", "speed", "1/1.1")
            case "]": player.run("osd-msg", "multiply", "speed", "1.1")
            case "i": player.run("script-binding", "stats/display-stats-toggle")
            case ".": player.run("frame-step")
            case ",": player.run("frame-back-step")
            case "q": NSApp.terminate(nil)
            default: return false
            }
        }
        return true
    }

    // MARK: - Window sizing

    /// Size the window to the video's display size, capped at 85% of the screen, aspect locked.
    private func fitWindowToVideo() {
        guard let w = player.int("dwidth"), let h = player.int("dheight"), w > 0, h > 0,
              let screen = window.screen ?? NSScreen.main else { return }
        sizedForCurrentFile = true
        let aspect = CGFloat(w) / CGFloat(h)
        window.contentAspectRatio = NSSize(width: CGFloat(w), height: CGFloat(h))
        guard !window.styleMask.contains(.fullScreen) else { return }

        let limit = screen.visibleFrame.insetBy(dx: screen.visibleFrame.width * 0.075,
                                                dy: screen.visibleFrame.height * 0.075)
        var size = NSSize(width: CGFloat(w), height: CGFloat(h))
        if size.width > limit.width { size = NSSize(width: limit.width, height: limit.width / aspect) }
        if size.height > limit.height { size = NSSize(width: limit.height * aspect, height: limit.height) }
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        window.setFrame(NSRect(x: screen.visibleFrame.midX - frame.width / 2,
                               y: screen.visibleFrame.midY - frame.height / 2,
                               width: frame.width, height: frame.height),
                        display: true, animate: false)
    }

    /// VELA_DEBUG=1: print playback health every 5 s (used for performance testing).
    private func startDebugStats() {
        debugTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let p = self.player
            fputs("visible=\(self.window.occlusionState.contains(.visible)) ", stderr)
            let keys = ["time-pos", "hwdec-current", "estimated-vf-fps", "frame-drop-count",
                        "decoder-frame-drop-count", "cache-buffering-state", "demuxer-cache-duration",
                        "audio-params/channel-count"]
            fputs(keys.map { "\($0)=\(p.string($0) ?? "-")" }.joined(separator: " ") + "\n", stderr)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
