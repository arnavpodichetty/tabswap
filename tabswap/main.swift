// TabSwap — swaps Cmd+Tab <-> Ctrl+Tab (and the Shift variants) for easier browser tab switching.
// Tiny menu bar app: toggle on/off, hide the icon, open at login. That's it.
// The key swapping itself lives in KeySwapper.swift.
import Cocoa
import ApplicationServices

// MARK: - Open at login (and restart after a crash)

/// A per-user LaunchAgent. Unlike a plain login item, launchd also restarts TabSwap
/// if it ever crashes. Choosing "Quit TabSwap" exits cleanly, so it stays quit.
enum LoginAgent {
    static let label = Bundle.main.bundleIdentifier ?? "com.arnavpodicehtty.tabswap"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    private static var plist: [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? ""],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],   // restart after a crash, not after Quit
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
    }

    static func enable() throws {
        try write()
        // Load it now so crash protection works this session too. launchd starts a fresh
        // copy, which takes over from this one (see takeOverFromOtherCopies).
        let domain = "gui/\(getuid())"
        if !launchctl(["bootstrap", domain, plistURL.path]) {
            launchctl(["kickstart", "\(domain)/\(label)"])   // already loaded: just make sure it runs
        }
    }

    /// Removing the file stops it starting at the next login. We don't unload it now,
    /// because that would kill this running copy.
    static func disable() throws {
        try FileManager.default.removeItem(at: plistURL)
    }

    /// If the app was moved, point the agent at its new location.
    static func updatePathIfNeeded() {
        guard isEnabled,
              let saved = NSDictionary(contentsOf: plistURL)?["ProgramArguments"] as? [String],
              saved.first != Bundle.main.executablePath
        else { return }
        try? write()
    }

    private static func write() throws {
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let defaults = UserDefaults.standard
    var swapper: KeySwapper!
    var statusItem: NSStatusItem!
    var hideTimer: Timer?
    var menuOpen = false
    var activity: NSObjectProtocol?

    let enabledItem = NSMenuItem(title: "Swap Cmd+Tab ↔ Ctrl+Tab", action: #selector(toggleEnabled), keyEquivalent: "")
    let permissionItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    let hideItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(toggleHidden), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    var iconHidden: Bool {
        get { defaults.bool(forKey: "iconHidden") }
        set { defaults.set(newValue, forKey: "iconHidden") }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Two copies would each swap the keys and cancel each other out.
        takeOverFromOtherCopies()

        // Keep macOS from napping or auto-quitting a windowless background app.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Swapping Cmd+Tab and Ctrl+Tab")
        ProcessInfo.processInfo.disableAutomaticTermination("Swapping Cmd+Tab and Ctrl+Tab")

        defaults.register(defaults: ["enabled": true, "iconHidden": false])
        LoginAgent.updatePathIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "TabSwap")
            img?.isTemplate = true
            button.image = img
        }

        let menu = NSMenu()
        menu.delegate = self
        let header = NSMenuItem(title: "TabSwap", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(enabledItem)
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(hideItem)
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit TabSwap", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil { item.target = self }
        statusItem.menu = menu

        // Prompt for Accessibility permission if we don't have it. The swapper keeps
        // retrying every second and starts working as soon as it's granted.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        swapper = KeySwapper(enabled: defaults.bool(forKey: "enabled")) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        swapper.start()

        // Re-check after sleep and user switching, when taps and modifier state can go stale.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.swapper.checkNow() }
            }
        }

        statusItem.isVisible = true
        if iconHidden { scheduleHide(after: 5) }
        refresh()
    }

    func applicationWillTerminate(_ note: Notification) {
        swapper?.stop()
    }

    // Opening the app again while it's running shows the hidden icon for a few seconds.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if iconHidden {
            statusItem.isVisible = true
            scheduleHide(after: 5)
        }
        return false
    }

    /// The newest copy wins: ask any other running TabSwap to quit cleanly.
    /// If one refuses, we quit instead, so there's never more than one.
    func takeOverFromOtherCopies() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        if others.contains(where: { !$0.isTerminated }) { exit(0) }
    }

    func refresh() {
        guard let statusItem else { return }
        let active = swapper?.isActive ?? false
        let enabled = swapper?.isEnabled ?? true
        enabledItem.state = enabled ? .on : .off
        enabledItem.isEnabled = active
        permissionItem.isHidden = active
        hideItem.state = iconHidden ? .on : .off
        loginItem.state = LoginAgent.isEnabled ? .on : .off
        statusItem.button?.appearsDisabled = !enabled || !active
    }

    func scheduleHide(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.iconHidden, !self.menuOpen else { return }
                self.statusItem.isVisible = false
            }
        }
    }

    // Don't hide the icon out from under an open menu.
    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        hideTimer?.invalidate()
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        if iconHidden { scheduleHide(after: 3) }
    }

    // MARK: Actions

    @objc func toggleEnabled() {
        let on = !swapper.isEnabled
        defaults.set(on, forKey: "enabled")
        swapper.setEnabled(on)
        refresh()
    }

    @objc func toggleHidden() {
        if iconHidden {
            iconHidden = false
            hideTimer?.invalidate()
            statusItem.isVisible = true
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Hide the TabSwap icon?"
            alert.informativeText = "TabSwap keeps running. To get the icon back, open TabSwap again from Applications — it will appear for a few seconds so you can turn this off."
            alert.addButton(withTitle: "Hide")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            iconHidden = true
            statusItem.isVisible = false
        }
        refresh()
    }

    @objc func toggleLogin() {
        do {
            if LoginAgent.isEnabled { try LoginAgent.disable() } else { try LoginAgent.enable() }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
        refresh()
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)   // applicationWillTerminate releases any held key
    }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon, no app menu
    app.run()
}
