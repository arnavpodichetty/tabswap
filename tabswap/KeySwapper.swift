// The keyboard part of TabSwap: swaps Cmd+Tab <-> Ctrl+Tab (and the Shift variants).
//
// Everything here runs on its own high-priority thread, so nothing the menu bar UI does
// (alerts, menus, login-item changes) can ever delay a keystroke or get the tap disabled.
// A once-a-second health check rebuilds the tap if macOS kills it and makes sure we never
// leave a fake Cmd key stuck down.
import Foundation
import CoreGraphics
import ApplicationServices

nonisolated final class KeySwapper: @unchecked Sendable {
    private static let kTab: CGKeyCode = 48
    private static let kLeftCmd: CGKeyCode = 55

    /// Runs on the main thread whenever `isActive` changes.
    private let onStatusChange: @Sendable () -> Void

    // Shared with the main thread, guarded by `lock`.
    private let lock = NSLock()
    private var _enabled: Bool
    private var _active = false

    // Touched only on the tap thread.
    private var runLoop: CFRunLoop!
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// True while Ctrl+Tab has been turned into Cmd+Tab and the app switcher is open.
    /// We hold a synthetic Cmd down until the user lets go of Ctrl.
    private var fakeCmdHeld = false

    init(enabled: Bool, onStatusChange: @escaping @Sendable () -> Void) {
        _enabled = enabled
        self.onStatusChange = onStatusChange
    }

    var isEnabled: Bool { lock.withLock { _enabled } }
    /// True when the tap exists, i.e. we have Accessibility permission and are intercepting keys.
    var isActive: Bool { lock.withLock { _active } }

    // MARK: Called from the main thread

    func start() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.healthCheck() }
            timer.tolerance = 0.2
            RunLoop.current.add(timer, forMode: .common)
            ready.signal()
            healthCheck()
            while true { CFRunLoopRun() }
        }
        thread.name = "TabSwap event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func setEnabled(_ on: Bool) {
        lock.withLock { _enabled = on }
        perform { [self] in
            if !on { releaseFakeCmd() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: on) }
        }
    }

    /// Re-check everything now (after wake from sleep, user switch, etc).
    func checkNow() { perform { [self] in healthCheck() } }

    /// Called on quit: make sure no fake Cmd is left held down.
    func stop() {
        let done = DispatchSemaphore(value: 0)
        perform { [self] in teardown(); done.signal() }
        _ = done.wait(timeout: .now() + 1)
    }

    private func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: Tap thread

    private func healthCheck() {
        // Permission revoked, or macOS invalidated the tap: throw it away and rebuild.
        if let tap, !CFMachPortIsValid(tap) || !AXIsProcessTrusted() { teardown() }
        if tap == nil { createTap() }

        if let tap {
            let want = isEnabled
            if CGEvent.tapIsEnabled(tap: tap) != want { CGEvent.tapEnable(tap: tap, enable: want) }
        }
        releaseFakeCmdIfCtrlIsUp()
        setActive(tap != nil)
    }

    private func createTap() {
        guard AXIsProcessTrusted() else { return }   // the health check retries every second
        let mask = (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue)
        guard let newTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<KeySwapper>.fromOpaque(info).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }   // no Accessibility permission yet; the health check retries

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(runLoop, src, .commonModes)
        tap = newTap
        source = src
        CGEvent.tapEnable(tap: newTap, enable: isEnabled)
    }

    private func teardown() {
        releaseFakeCmd()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        tap = nil
        source = nil
    }

    private func setActive(_ value: Bool) {
        let changed = lock.withLock { () -> Bool in
            defer { _active = value }
            return _active != value
        }
        if changed { DispatchQueue.main.async(execute: onStatusChange) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // macOS disables taps that are slow or interrupted; turn it straight back on.
        // We may have missed Ctrl being released while disabled, so check for that too.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, isEnabled { CGEvent.tapEnable(tap: tap, enable: true) }
            releaseFakeCmdIfCtrlIsUp()
            return pass
        }

        var flags = event.flags

        if fakeCmdHeld {
            // User let go of Ctrl -> let go of our fake Cmd so the switcher picks the app.
            if type == .flagsChanged && !flags.contains(.maskControl) {
                releaseFakeCmd()
                return pass
            }
            // While the switcher is open, the held Ctrl acts as Cmd for every key, so
            // Tab / Shift+Tab / Q / H / arrows all behave like they would with real Cmd,
            // and pressing Shift doesn't make the switcher think Cmd was released.
            flags.remove(.maskControl)
            flags.insert(.maskCommand)
            event.flags = flags
            return pass
        }

        guard type == .keyDown || type == .keyUp,
              CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == Self.kTab
        else { return pass }

        let cmd = flags.contains(.maskCommand)
        let ctrl = flags.contains(.maskControl)

        // Only Cmd or Ctrl (optionally + Shift), no Option.
        if flags.contains(.maskAlternate) || cmd == ctrl { return pass }

        if cmd {
            // Cmd+Tab -> Ctrl+Tab (next browser tab)
            flags.remove(.maskCommand)
            flags.insert(.maskControl)
        } else {
            // Ctrl+Tab -> Cmd+Tab (app switcher)
            flags.remove(.maskControl)
            flags.insert(.maskCommand)
            if type == .keyDown {
                fakeCmdHeld = true
                postCmd(down: true)
            }
        }
        event.flags = flags
        return pass
    }

    /// Backstop against a stuck Cmd key: if the physical Ctrl key isn't held, release.
    private func releaseFakeCmdIfCtrlIsUp() {
        if fakeCmdHeld && !CGEventSource.flagsState(.hidSystemState).contains(.maskControl) {
            releaseFakeCmd()
        }
    }

    private func releaseFakeCmd() {
        guard fakeCmdHeld else { return }
        fakeCmdHeld = false
        postCmd(down: false)
    }

    /// Posted below our HID-level tap, so we never see our own synthetic events.
    private func postCmd(down: Bool) {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: Self.kLeftCmd, keyDown: down)
        e?.flags = down ? .maskCommand : []
        e?.post(tap: .cgSessionEventTap)
    }
}
