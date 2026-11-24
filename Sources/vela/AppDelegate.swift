// vela — ultra-light media player for macOS
// Copyright (C) 2026 vela contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let initialFile: URL?
    private let mpvOptions: [(String, String)]
    private var controller: PlayerWindowController?

    init(file: URL?, mpvOptions: [(String, String)]) {
        initialFile = file
        self.mpvOptions = mpvOptions
    }

    private var openedFile = false

    // The window exists before Finder hands over files (application(_:open:) can arrive first).
    func applicationWillFinishLaunching(_ note: Notification) {
        do {
            controller = PlayerWindowController(player: try Player(options: mpvOptions))
            NSApp.mainMenu = makeMenu()
        } catch {
            fputs("vela: \(error)\n", stderr)
            exit(1)
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let c = controller else { return }
        c.show()
        NSApp.activate(ignoringOtherApps: true)
        if let file = initialFile {
            open(file)
        } else {
            // Give a Finder "open file" a moment to arrive before asking.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.openedFile == false { self?.openDocument(nil) }
            }
        }
    }

    private func open(_ url: URL) {
        openedFile = true
        controller?.open(url)
    }

    /// Finder double-click / "Open With" / drops on the Dock icon (vela.app).
    func application(_ app: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if subtitleExtensions.contains(url.pathExtension.lowercased()) { controller?.addSubtitle(url) } else { open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        controller?.stopAI()
        controller?.saveResumePosition()
        controller?.videoView.videoLayer.shutdown()  // render context before the mpv core
        controller = nil
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .audiovisualContent]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private func makeMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit vela", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(.separator())
        let top = viewMenu.addItem(withTitle: "Float on Top", action: #selector(PlayerWindowController.toggleFloatOnTop), keyEquivalent: "t")
        top.target = controller
        let mini = viewMenu.addItem(withTitle: "Mini Player", action: #selector(PlayerWindowController.toggleMiniPlayer), keyEquivalent: "p")
        mini.keyEquivalentModifierMask = [.command, .shift]
        mini.target = controller
        let stats = viewMenu.addItem(withTitle: "Show Stats", action: #selector(PlayerWindowController.toggleStats), keyEquivalent: "i")
        stats.target = controller
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        // Track menus are owned and kept current by the window controller.
        for menu in [controller?.audioMenu, controller?.subtitleMenu].compactMap({ $0 }) {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }

        return main
    }
}
