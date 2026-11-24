// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CMpv

/// The view that hosts the video layer, takes keys and accepts dropped files.
final class VideoView: NSView {
    let player: Player
    let videoLayer: VideoLayer
    var onOpen: ((URL) -> Void)?

    init(player: Player) {
        self.player = player
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

    // Minimal keys for Phase 2; the full keymap lands in Phase 3.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: player.run("cycle", "pause")                       // space
        case 123: player.run("seek", "-5")                         // ←
        case 124: player.run("seek", "5")                          // →
        case 53: if window?.styleMask.contains(.fullScreen) == true { window?.toggleFullScreen(nil) } // esc
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": window?.toggleFullScreen(nil)
            case "q": NSApp.terminate(nil)
            default: super.keyDown(with: event)
            }
        }
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
    private var sizedForCurrentFile = false

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
        window.contentView = videoView
        window.delegate = self
        window.title = "vela"
        window.center()

        videoView.onOpen = { [weak self] url in self?.open(url) }
        player.onEvent = { [weak self] ev in self?.handle(ev) }
        player.startEventPump()
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(videoView)
    }

    func open(_ url: URL) {
        sizedForCurrentFile = false
        window.title = url.lastPathComponent
        window.representedURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        player.run("loadfile", url.path)
    }

    private func handle(_ ev: UnsafePointer<mpv_event>) {
        switch ev.pointee.event_id {
        case MPV_EVENT_VIDEO_RECONFIG:
            if !sizedForCurrentFile { fitWindowToVideo() }
        case MPV_EVENT_FILE_LOADED:
            if ProcessInfo.processInfo.environment["VELA_DEBUG"] != nil { startDebugStats() }
        case MPV_EVENT_SHUTDOWN:
            NSApp.terminate(nil)
        default:
            break
        }
    }

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
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let p = self?.player else { return }
            let keys = ["time-pos", "hwdec-current", "video-params/pixelformat", "estimated-vf-fps",
                        "frame-drop-count", "decoder-frame-drop-count", "mistimed-frame-count",
                        "cache-buffering-state", "demuxer-cache-duration", "audio-params/channel-count"]
            fputs(keys.map { "\($0)=\(p.string($0) ?? "-")" }.joined(separator: " ") + "\n", stderr)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }
}
