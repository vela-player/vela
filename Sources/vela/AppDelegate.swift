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

    func applicationDidFinishLaunching(_ note: Notification) {
        do {
            let c = PlayerWindowController(player: try Player(options: mpvOptions))
            controller = c
            NSApp.mainMenu = makeMenu()
            c.show()
            NSApp.activate(ignoringOtherApps: true)
            if let file = initialFile { c.open(file) } else { openDocument(nil) }
        } catch {
            fputs("vela: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    /// Finder "Open With" / dock drops (once vela ships as a .app bundle).
    func application(_ app: NSApplication, open urls: [URL]) {
        if let url = urls.first { controller?.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) {
        controller?.videoView.videoLayer.shutdown()  // render context before the mpv core
        controller = nil
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio, .audiovisualContent]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url { controller?.open(url) }
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
