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
    private let statsPanel = StatsPanel()
    /// AISubtitleController on macOS 26+ (stored untyped so older macOS can load this class).
    private var ai: AnyObject?
    private var statsTimer: Timer?
    private var state = PlaybackState()
    private var sizedForCurrentFile = false
    private var overlayVisible = true
    private var hideTimer: Timer?
    private var debugTimer: Timer?
    private var fileLoaded = false

    /// Audio files get a compact window. `.art` shows the cover; `.compact` is just the controls.
    private enum AudioLayout { case none, art, compact }
    private var audioLayout = AudioLayout.none

    private(set) var floatsOnTop = false
    private var miniPlayerFrame: NSRect?  // window frame to restore when leaving the mini player
    var isMiniPlayer: Bool { miniPlayerFrame != nil }
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
        statsPanel.translatesAutoresizingMaskIntoConstraints = false
        statsPanel.isHidden = true
        container.addSubview(statsPanel)
        NSLayoutConstraint.activate([
            statsPanel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            statsPanel.topAnchor.constraint(equalTo: container.topAnchor, constant: 36),
            statsPanel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -76),
        ])
        window.contentView = container

        videoView.onOpen = { [weak self] url in
            if subtitleExtensions.contains(url.pathExtension.lowercased()) { self?.addSubtitle(url) } else { self?.open(url) }
        }
        overlay.onAudioMenu = { [weak self] view in self?.popUp(self?.audioMenu, from: view) }
        overlay.onSubtitleMenu = { [weak self] view in self?.popUp(self?.subtitleMenu, from: view) }
        overlay.onClearVoice = { [weak self] in self?.toggleClearVoice() }
        videoView.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        videoView.onMouseMove = { [weak self] in self?.poke() }
        overlay.onTogglePause = { [weak self] in self?.player.run("cycle", "pause") }
        overlay.onToggleMute = { [weak self] in self?.player.run("cycle", "mute") }
        overlay.onVolume = { [weak self] v in self?.player.setProperty("volume", String(format: "%.0f", v)) }
        overlay.seekBar.onSeek = { [weak self] t, done in self?.requestSeek(t, final: done) }

        for (name, format) in [("time-pos", MPV_FORMAT_DOUBLE), ("duration", MPV_FORMAT_DOUBLE),
                               ("demuxer-cache-time", MPV_FORMAT_DOUBLE), ("pause", MPV_FORMAT_FLAG),
                               ("volume", MPV_FORMAT_DOUBLE), ("mute", MPV_FORMAT_FLAG),
                               ("track-list", MPV_FORMAT_NONE), ("audio-params/channels", MPV_FORMAT_NONE),
                               ("audio-out-params/channel-count", MPV_FORMAT_NONE)] {
            player.observe(name, format)
        }
        player.onEvent = { [weak self] ev in self?.handle(ev) }
        player.startEventPump()
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            ai = MainActor.assumeIsolated {
                let c = AISubtitleController(player: player, window: window)
                c.onChange = { [weak self] in self?.rebuildTrackMenus() }
                return c
            }
        }
        #endif
        rebuildTrackMenus()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
        poke()
    }

    func open(_ url: URL) {
        stopAI()
        saveResumePosition()
        fileLoaded = false
        audioLayout = .none
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
            if !sizedForCurrentFile, !isMiniPlayer { fitWindowToVideo() }
        case MPV_EVENT_FILE_LOADED:
            fileLoaded = true
            fileDidLoad()
            if ProcessInfo.processInfo.environment["VELA_DEBUG"] != nil, debugTimer == nil { startDebugStats() }
        case MPV_EVENT_PLAYBACK_RESTART:
            seekLanded()
        case MPV_EVENT_SHUTDOWN:
            NSApp.terminate(nil)
        default:
            break
        }
    }

    private func propertyChanged(_ p: mpv_event_property) {
        let name = String(cString: p.name)
        if name == "track-list" { rebuildTrackMenus(); return }
        if name == "audio-params/channels" { applyClearVoice(); return }
        if name == "audio-out-params/channel-count" {
            // Remember what the device takes, but not while our own downmix is shaping the output.
            if !clearVoiceActive, let n = player.int(name), n > 0 { deviceChannels = Int(n) }
            return
        }
        let double = p.format == MPV_FORMAT_DOUBLE ? p.data.load(as: Double.self) : 0
        let flag = p.format == MPV_FORMAT_FLAG ? p.data.load(as: Int32.self) != 0 : false
        switch name {
        case "time-pos":
            // While scrubbing, the controls follow the pointer, not the decoder.
            if scrubTarget != nil { return }
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

    // MARK: - Scrubbing

    // Dragging the seek bar produces 60-120 positions a second. Sending each as a seek makes
    // mpv flush and restart decoding constantly, which stutters. Instead: one seek in flight,
    // and when it lands we jump straight to the latest pointer position (older ones are skipped).
    private var seekInFlight = false
    private var pendingSeek: (time: Double, final: Bool)?
    private var scrubbing = false
    private var scrubTarget: Double?   // shown instead of time-pos until the last seek lands
    private var seekWatchdog: Timer?

    private func requestSeek(_ t: Double, final: Bool) {
        scrubbing = !final
        scrubTarget = t
        state.position = t
        overlay.update(state)
        poke()
        if seekInFlight { pendingSeek = (t, final) } else { sendSeek(t, final: final) }
    }

    private func sendSeek(_ t: Double, final: Bool) {
        seekInFlight = true
        // Keyframe seeks are instant while dragging; the release lands on the exact frame.
        if (try? player.command(["seek", String(t), final ? "absolute+exact" : "absolute+keyframes"])) == nil {
            seekLanded()
            return
        }
        // If mpv never reports the seek finished (e.g. end of file), don't stay stuck.
        seekWatchdog?.invalidate()
        seekWatchdog = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in self?.seekLanded() }
    }

    private func seekLanded() {
        seekWatchdog?.invalidate()
        seekInFlight = false
        if let next = pendingSeek {
            pendingSeek = nil
            sendSeek(next.time, final: next.final)
        } else if !scrubbing {
            scrubTarget = nil  // hand the controls back to the real playback position
        }
    }

    func stopAI() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let c = ai as? AISubtitleController { MainActor.assumeIsolated { c.stop() } }
        #endif
    }

    // MARK: - Clear Voice

    private var clearVoiceOn = UserDefaults.standard.bool(forKey: "clearVoice")
    private var clearVoiceActive = false   // filter currently in mpv's chain
    private var clearVoiceLayout = ""      // the layout it was built for
    private var deviceChannels = 2

    @objc func toggleClearVoice() {
        clearVoiceOn.toggle()
        UserDefaults.standard.set(clearVoiceOn, forKey: "clearVoice")
        applyClearVoice(force: true)
        player.run("show-text", clearVoiceOn ? "Clear Voice on  ·  louder dialogue, tamer explosions" : "Clear Voice off", "2000")
        rebuildTrackMenus()
    }

    /// (Re)build the filter for the current track's channel layout. Called on toggle and whenever
    /// the audio format changes (new file, other audio track).
    private func applyClearVoice(force: Bool = false) {
        let layout = player.string("audio-params/channels") ?? ""
        overlay.setClearVoice(on: clearVoiceOn, available: !layout.isEmpty)
        let wanted = clearVoiceOn && !layout.isEmpty
        if !force, wanted == clearVoiceActive, layout == clearVoiceLayout { return }
        if clearVoiceActive { player.run("af", "remove", ClearVoice.label) }
        clearVoiceActive = false
        guard wanted else { return }
        player.run("af", "add", ClearVoice.filter(layout: layout, deviceChannels: deviceChannels))
        clearVoiceActive = true
        clearVoiceLayout = layout
    }

    // MARK: - Tracks

    /// Rebuild the Audio and Subtitles menus (menu bar and overlay buttons share them).
    private func rebuildTrackMenus() {
        let tracks = Track.list(from: player.node("track-list"))
        fill(audioMenu, with: tracks.filter { $0.kind == .audio }, property: "aid")
        audioMenu.addItem(.separator())
        let cv = audioMenu.addItem(withTitle: "Clear Voice", action: #selector(toggleClearVoice), keyEquivalent: "")
        cv.target = self
        cv.state = clearVoiceOn ? .on : .off
        cv.toolTip = "Louder dialogue, tamer explosions (V)"
        fill(subtitleMenu, with: tracks.filter { $0.kind == .sub }, property: "sid")
        subtitleMenu.addItem(.separator())
        let add = subtitleMenu.addItem(withTitle: "Add Subtitle File…", action: #selector(chooseSubtitle), keyEquivalent: "")
        add.target = self
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), fileLoaded, let c = ai as? AISubtitleController {
            let menu = subtitleMenu
            MainActor.assumeIsolated { c.addMenuItems(to: menu) }
        }
        #endif
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

    // MARK: - Resume, audio layout

    private func fileDidLoad() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let c = ai as? AISubtitleController, let url = window.representedURL {
            MainActor.assumeIsolated { c.fileOpened(url) }
        }
        #endif
        rebuildTrackMenus()
        let tracks = Track.list(from: player.node("track-list"))
        if !tracks.contains(where: { $0.kind == .video && !$0.albumArt }) {
            audioLayout = tracks.contains { $0.kind == .video } ? .art : .compact
            let title = player.string("media-title") ?? window.title
            let artist = player.string("metadata/by-key/Artist")
            overlay.titleLabel.stringValue = [artist, title].compactMap { $0 }.joined(separator: " — ")
            layOutForAudio()
        } else {
            window.minSize = NSSize(width: 480, height: 270)
        }
        if let pos = player.double("time-pos"), pos > 30 {
            let hours = (player.double("duration") ?? 0) >= 3600
            player.run("show-text", "Resumed at \(formatTime(pos, showHours: hours))   ·   Home to start over", "3000")
        }
    }

    /// Remember the position unless the file is basically unwatched or finished.
    func saveResumePosition() {
        guard fileLoaded, state.duration > 0 else { return }
        if state.position > 30 && state.position < state.duration - 60 {
            player.run("write-watch-later-config")
        } else {
            player.run("delete-watch-later-config")
        }
    }

    private func layOutForAudio() {
        guard !window.styleMask.contains(.fullScreen), !isMiniPlayer else { return }
        let size = audioLayout == .art ? NSSize(width: 420, height: 420) : NSSize(width: 520, height: 132)
        window.contentResizeIncrements = NSSize(width: 1, height: 1)  // drop the video aspect lock
        if audioLayout == .art { window.contentAspectRatio = NSSize(width: 1, height: 1) }
        window.minSize = audioLayout == .art ? NSSize(width: 300, height: 300) : NSSize(width: 420, height: 132)
        sizedForCurrentFile = true
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2)
        window.setFrame(frame, display: true, animate: true)
        poke()
    }

    // MARK: - Float on top, mini player

    @objc func toggleFloatOnTop() {
        floatsOnTop.toggle()
        applyWindowLevel()
        player.run("show-text", floatsOnTop ? "Float on top: on" : "Float on top: off")
    }

    private func applyWindowLevel() {
        window.level = floatsOnTop || isMiniPlayer ? .floating : .normal
    }

    /// A small always-on-top window in the screen corner that follows you across Spaces.
    @objc func toggleMiniPlayer() {
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); return }
        guard let screen = window.screen ?? NSScreen.main else { return }
        if let restore = miniPlayerFrame {
            miniPlayerFrame = nil
            window.collectionBehavior = [.fullScreenPrimary]
            applyWindowLevel()
            window.setFrame(restore, display: true, animate: true)
            return
        }
        miniPlayerFrame = window.frame
        let content = window.contentRect(forFrameRect: window.frame).size
        let width: CGFloat = audioLayout == .compact ? 420 : 400
        let size = NSSize(width: width, height: audioLayout == .compact ? 132 : width * content.height / content.width)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let area = screen.visibleFrame
        frame.origin = NSPoint(x: area.maxX - frame.width - 20, y: area.minY + 20)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        applyWindowLevel()
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Overlay auto-hide

    /// Show the controls and restart the 2-second hide timer.
    private func poke() {
        setOverlay(visible: true)
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Compact audio windows have nothing behind the controls, so they stay.
            if self.overlay.pointerInsideControls || self.audioLayout == .compact { self.poke() }
            else { self.setOverlay(visible: false) }
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
            else if isMiniPlayer { toggleMiniPlayer() }
        case 51: player.run("osd-msg", "set", "speed", "1")                      // backspace
        case 115: player.run("seek", "0", "absolute"); poke()                    // home: start over
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "f": window.toggleFullScreen(nil)
            case "m": player.run("osd-msg", "cycle", "mute")
            case "a": player.run("osd-msg", "cycle", "audio")
            case "s": player.run("osd-msg", "cycle", "sub")
            case "[": player.run("osd-msg", "multiply", "speed", "1/1.1")
            case "]": player.run("osd-msg", "multiply", "speed", "1.1")
            case "i": toggleStats()
            case ".": player.run("frame-step")
            case ",": player.run("frame-back-step")
            case "t": toggleFloatOnTop()
            case "v": toggleClearVoice()
            case "p": toggleMiniPlayer()
            case "q": NSApp.terminate(nil)
            default: return false
            }
        }
        return true
    }

    // MARK: - Stats panel

    @objc func toggleStats() {
        if statsPanel.isHidden {
            refreshStats()
            statsPanel.isHidden = false
            statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStats() }
        } else {
            statsPanel.isHidden = true
            statsTimer?.invalidate()
            statsTimer = nil
        }
    }

    private func refreshStats() {
        statsPanel.show(player.statsSections(window: window))
    }

    // MARK: - Window sizing

    /// Size the window to the video's display size, capped at 85% of the screen, aspect locked.
    private func fitWindowToVideo() {
        if audioLayout != .none { layOutForAudio(); return }
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
                        "audio-params/channel-count", "volume", "mute", "current-tracks/audio/lang", "af"]
            fputs(keys.map { "\($0)=\(p.string($0) ?? "-")" }.joined(separator: " ") + "\n", stderr)
            if ProcessInfo.processInfo.environment["VELA_DEBUG"] == "stats" {
                for (title, rows) in p.statsSections(window: self.window) {
                    fputs("  \(title.uppercased())\n", stderr)
                    for (l, v) in rows { if let v, !v.isEmpty { fputs("    \(l.padding(toLength: 12, withPad: " ", startingAt: 0)) \(v)\n", stderr) } }
                }
            }
        }
    }

    /// Tick marks for the View menu toggles.
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleFloatOnTop) { item.state = floatsOnTop ? .on : .off }
        if item.action == #selector(toggleMiniPlayer) { item.state = isMiniPlayer ? .on : .off }
        if item.action == #selector(toggleClearVoice) { item.state = clearVoiceOn ? .on : .off }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
