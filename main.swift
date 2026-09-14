import Cocoa
import CoreAudio
import CoreMediaIO
import EventKit

// LookAway Lite — a break reminder living in the menu bar.
// Every `workSeconds`, dim every screen and count down `breakSeconds`.
// Breaks are held back while you're in a meeting (mic in use, and optionally
// while a calendar event is running).

let defaultsWorkKey = "workMinutes"
let defaultsBreakKey = "breakSeconds"
let defaultsMicKey = "skipWhenMicActive"
let defaultsCalKey = "skipDuringCalendarEvents"
let defaultsCamKey = "skipWhenCameraActive"
let defaultsChromeKey = "skipDuringChromeCallTab"
let defaultsCompactKey = "compactStatusItem"
let defaultsSoundKey = "breakSoundsEnabled"
let defaultsStartSoundKey = "breakStartSoundEnabled"
let defaultsEndSoundKey = "breakEndSoundEnabled"
let defaultsCompletionCardKey = "breakCompletionCardEnabled"

/// Never suppress a break for longer than this, whatever the signals say — a wedged
/// camera process or a forgotten meeting tab shouldn't hold a break all afternoon.
let maxHoldSeconds = 90 * 60

/// True when any input device is actively capturing — i.e. some app holds the mic.
/// Conferencing apps mute in software, so this stays true through a mute.
func micIsInUse() -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
          size > 0 else { return false }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var devices = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr
    else { return false }

    for device in devices {
        // Only consider devices that actually have input streams.
        var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                    mScope: kAudioDevicePropertyScopeInput,
                                                    mElement: kAudioObjectPropertyElementMain)
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streamAddr, 0, nil, &streamSize) == noErr,
              streamSize > 0 else { continue }

        var runningAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &runningAddr, 0, nil, &runningSize, &running) == noErr, running != 0 {
            return true
        }
    }
    return false
}

/// True when any camera is capturing. Same trick as the mic check but via CoreMediaIO,
/// and unlike the audio property this is reliable regardless of Bluetooth audio routing —
/// which is what catches a browser Meet/Zoom call taken on AirPods.
func cameraIsInUse() -> Bool {
    var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                         mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                         mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr,
          size > 0 else { return false }

    let count = Int(size) / MemoryLayout<CMIOObjectID>.size
    var devices = [CMIOObjectID](repeating: 0, count: count)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices) == noErr
    else { return false }

    for device in devices where device != 0 {
        var runningAddr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var running: UInt32 = 0
        var runningUsed: UInt32 = 0
        let sz = UInt32(MemoryLayout<UInt32>.size)
        if CMIOObjectGetPropertyData(device, &runningAddr, 0, nil, sz, &runningUsed, &running) == noErr, running != 0 {
            return true
        }
    }
    return false
}

/// Looks for a live Meet/Zoom/Teams call in Chrome. Only the *active* tab of each window
/// counts — a stale meeting tab left open in the background shouldn't suppress breaks forever.
/// Requires one-time Automation permission for Chrome.
func chromeCallTabActive() -> Bool {
    let chromeRunning = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "com.google.Chrome"
    }
    guard chromeRunning else { return false }

    let source = """
    tell application "Google Chrome"
        set out to ""
        repeat with w in windows
            try
                set out to out & (URL of active tab of w) & "\n"
            end try
        end repeat
        return out
    end tell
    """
    guard let script = NSAppleScript(source: source) else { return false }
    var err: NSDictionary?
    let result = script.executeAndReturnError(&err)
    guard err == nil, let urls = result.stringValue?.lowercased() else { return false }

    // Require a real meeting path, not just the product's front page.
    for line in urls.split(separator: "\n") {
        let u = String(line)
        if u.contains("meet.google.com/"), !u.hasSuffix("meet.google.com/"), !u.contains("/landing") { return true }
        if u.contains("zoom.us/j/") || u.contains("zoom.us/wc") || u.contains("zoom.us/s/") { return true }
        if u.contains("teams.microsoft.com/l/meetup") || u.contains("teams.live.com/meet") { return true }
        if u.contains("whereby.com/") || u.contains("meet.zoho") { return true }
    }
    return false
}

/// Calendar-based meeting detection. Opt-in: asks for Calendar access on first enable.
final class CalendarWatch {
    private let store = EKEventStore()
    private var granted = false
    private var cachedBusy = false
    private var lastCheck = Date.distantPast

    var authorized: Bool { granted }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { ok, _ in
            DispatchQueue.main.async {
                self.granted = ok
                self.lastCheck = .distantPast
                done(ok)
            }
        }
    }

    func refreshAuthorization() {
        granted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// An event counts as a meeting if it's happening now, isn't all-day, and you haven't declined it.
    func inMeeting(now: Date) -> Bool {
        guard granted else { return false }
        if now.timeIntervalSince(lastCheck) < 30 { return cachedBusy }
        lastCheck = now

        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-60 * 60 * 12),
                                                 end: now.addingTimeInterval(60 * 60),
                                                 calendars: nil)
        cachedBusy = store.events(matching: predicate).contains { ev in
            guard !ev.isAllDay, ev.status != .canceled else { return false }
            guard let start = ev.startDate, let end = ev.endDate, start <= now, end > now else { return false }
            if ev.availability == .free { return false }
            // Declined invites shouldn't block breaks.
            if let me = ev.attendees?.first(where: { $0.isCurrentUser }), me.participantStatus == .declined {
                return false
            }
            return true
        }
        return cachedBusy
    }
}

final class OverlayPanel: NSPanel {
    var onClick: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            onClick?()
            return
        }
        super.sendEvent(event)
    }
}

final class Overlay {
    private var panels: [OverlayPanel] = []
    private var headlineLabel: NSTextField?
    private var countdownLabel: NSTextField?
    private var hintLabel: NSTextField?
    var onSkip: (() -> Void)?

    var isShowing: Bool { !panels.isEmpty }

    func show(remaining: Int) {
        guard panels.isEmpty, let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let cardSize = NSSize(width: 320, height: 132)
        let margin: CGFloat = 24
        let frame = NSRect(x: screen.visibleFrame.maxX - cardSize.width - margin,
                           y: screen.visibleFrame.minY + margin,
                           width: cardSize.width,
                           height: cardSize.height)
        let panel = OverlayPanel(contentRect: frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hidesOnDeactivate = false
        panel.onClick = { [weak self] in self?.onSkip?() }

        let content = NSVisualEffectView(frame: NSRect(origin: .zero, size: cardSize))
        content.material = .hudWindow
        content.blendingMode = .withinWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 16
        content.layer?.masksToBounds = true
        panel.contentView = content

        let headline = NSTextField(labelWithString: "Take a break")
        headline.font = .systemFont(ofSize: 16, weight: .semibold)
        headline.textColor = .labelColor
        headline.alignment = .center

        let countdown = NSTextField(labelWithString: "\(remaining)")
        countdown.font = .monospacedDigitSystemFont(ofSize: 52, weight: .medium)
        countdown.textColor = .labelColor
        countdown.alignment = .center
        countdown.setContentCompressionResistancePriority(.required, for: .vertical)

        let hint = NSTextField(labelWithString: "click to skip")
        hint.font = .systemFont(ofSize: 11, weight: .regular)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center

        let stack = NSStackView(views: [headline, countdown, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
        }

        panels = [panel]
        countdownLabel = countdown
        headlineLabel = headline
        hintLabel = hint
    }

    func update(remaining: Int) {
        countdownLabel?.stringValue = "\(remaining)"
    }

    func finish() {
        let old = panels
        panels.removeAll()
        headlineLabel?.stringValue = "Break complete"
        countdownLabel?.stringValue = "✓"
        hintLabel?.stringValue = "back to work"
        headlineLabel = nil
        countdownLabel = nil
        hintLabel = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                for panel in old { panel.animator().alphaValue = 0 }
            }, completionHandler: {
                for panel in old { panel.orderOut(nil) }
            })
        }
    }

    func hide() {
        let old = panels
        panels.removeAll()
        headlineLabel = nil
        countdownLabel = nil
        hintLabel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            for panel in old { panel.animator().alphaValue = 0 }
        }, completionHandler: {
            for panel in old { panel.orderOut(nil) }
        })
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let overlay = Overlay()
    private var timer: Timer?

    private var workSeconds = 20 * 60
    private var breakSeconds = 20
    private var remaining = 0
    private var onBreak = false
    private var paused = false

    private var skipWhenMic = true
    private var skipWhenCamera = true
    private var skipDuringChromeCall = false
    private var skipDuringEvents = false
    private let calendar = CalendarWatch()
    private var heldForMeeting = false
    private var holdStarted: Date?
    private var compactStatus = true
    private var startSoundEnabled = true
    private var endSoundEnabled = true
    private var completionCardEnabled = true
    private weak var statusHeader: NSMenuItem?
    private var micCache = (value: false, at: Date.distantPast)
    private var camCache = (value: false, at: Date.distantPast)
    private var chromeCache = (value: false, at: Date.distantPast)

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        overlay.onSkip = { [weak self] in self?.skip() }

        let d = UserDefaults.standard
        if d.object(forKey: defaultsWorkKey) != nil { workSeconds = d.integer(forKey: defaultsWorkKey) * 60 }
        if d.object(forKey: defaultsBreakKey) != nil { breakSeconds = d.integer(forKey: defaultsBreakKey) }
        // Testing hook: LOOKAWAY_TEST_SECONDS=3 makes the first work interval tiny.
        if let t = ProcessInfo.processInfo.environment["LOOKAWAY_TEST_SECONDS"], let n = Int(t) { workSeconds = n }
        if let t = ProcessInfo.processInfo.environment["LOOKAWAY_TEST_BREAK_SECONDS"], let n = Int(t) { breakSeconds = n }
        if d.object(forKey: defaultsMicKey) != nil { skipWhenMic = d.bool(forKey: defaultsMicKey) }
        if d.object(forKey: defaultsCamKey) != nil { skipWhenCamera = d.bool(forKey: defaultsCamKey) }
        skipDuringChromeCall = d.bool(forKey: defaultsChromeKey)
        if d.object(forKey: defaultsCompactKey) != nil { compactStatus = d.bool(forKey: defaultsCompactKey) }
        let legacySounds = d.object(forKey: defaultsSoundKey).map { _ in d.bool(forKey: defaultsSoundKey) }
        startSoundEnabled = d.object(forKey: defaultsStartSoundKey) != nil
            ? d.bool(forKey: defaultsStartSoundKey) : (legacySounds ?? true)
        endSoundEnabled = d.object(forKey: defaultsEndSoundKey) != nil
            ? d.bool(forKey: defaultsEndSoundKey) : (legacySounds ?? true)
        if d.object(forKey: defaultsCompletionCardKey) != nil { completionCardEnabled = d.bool(forKey: defaultsCompletionCardKey) }
        skipDuringEvents = d.bool(forKey: defaultsCalKey)
        calendar.refreshAuthorization()
        if skipDuringEvents && !calendar.authorized {
            calendar.requestAccess { [weak self] ok in
                if !ok { self?.skipDuringEvents = false }
                self?.rebuildMenu()
            }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        rebuildMenu()

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.onBreak, event.keyCode == 53 else { return event }  // esc
            self.startWork()
            return nil
        }

        startWork()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: clock

    /// Device checks are cheap but not free; sample them every few seconds.
    /// AppleScript into Chrome is the expensive one, so it gets a longer interval.
    private func inMeeting() -> Bool {
        let now = Date()

        // Safety valve: a hold that has run absurdly long is treated as a stuck signal.
        if let started = holdStarted, now.timeIntervalSince(started) > Double(maxHoldSeconds) {
            return false
        }

        if skipWhenMic {
            if now.timeIntervalSince(micCache.at) >= 3 { micCache = (micIsInUse(), now) }
            if micCache.value { return true }
        }
        if skipWhenCamera {
            if now.timeIntervalSince(camCache.at) >= 3 { camCache = (cameraIsInUse(), now) }
            if camCache.value { return true }
        }
        if skipDuringChromeCall {
            if now.timeIntervalSince(chromeCache.at) >= 15 { chromeCache = (chromeCallTabActive(), now) }
            if chromeCache.value { return true }
        }
        if skipDuringEvents && calendar.inMeeting(now: now) { return true }
        return false
    }

    private func tick() {
        guard !paused else { return }

        // A meeting starting mid-break pulls the overlay down immediately.
        if onBreak, inMeeting() {
            startWork()
            return
        }

        remaining -= 1
        if remaining <= 0 {
            if onBreak {
                startWork(completedBreak: true)
            } else if inMeeting() {
                // Hold the break; re-check shortly and fire once the meeting ends.
                if holdStarted == nil { holdStarted = Date() }
                heldForMeeting = true
                remaining = 10
                refreshTitle()
            } else {
                heldForMeeting = false
                startBreak()
            }
            return
        }
        if onBreak { overlay.update(remaining: remaining) }
        refreshTitle()
    }

    private func playBreakSound(named name: NSSound.Name) {
        NSSound(named: name)?.play()
    }

    private func startWork(completedBreak: Bool = false) {
        let wasOnBreak = onBreak
        onBreak = false
        heldForMeeting = false
        holdStarted = nil
        remaining = workSeconds
        if completedBreak && wasOnBreak && !inMeeting() {
            if endSoundEnabled { playBreakSound(named: NSSound.Name("Glass")) }
            if completionCardEnabled {
                overlay.finish()
            } else {
                overlay.hide()
            }
        } else {
            overlay.hide()
        }
        refreshTitle()
    }

    private func startBreak() {
        onBreak = true
        remaining = breakSeconds
        if startSoundEnabled && !inMeeting() { playBreakSound(named: NSSound.Name("Tink")) }
        overlay.show(remaining: remaining)
        refreshTitle()
    }

    /// Human-readable state, used for the menu header and the item's tooltip.
    private func stateDescription() -> String {
        if paused { return "Paused" }
        if heldForMeeting { return "Break held — meeting in progress" }
        if onBreak { return "Break: \(remaining)s left" }
        let mins = remaining / 60, secs = remaining % 60
        return mins == 0 ? "Next break in \(secs)s" : "Next break in \(mins)m"
    }

    private func refreshTitle() {
        // The menu bar is a scarce resource — on a notched Mac a wide item is silently
        // dropped when the bar fills up. Stay one glyph wide unless asked otherwise.
        let glyph = paused ? "❙❙" : (heldForMeeting ? "✆" : (onBreak ? "◉" : "◔"))
        if compactStatus {
            statusItem.button?.title = glyph
        } else {
            let mins = remaining / 60, secs = remaining % 60
            let clock = onBreak || mins == 0 ? "\(secs)s" : "\(mins)m"
            // No space before the number: every point of width helps the item
            // survive a full menu bar.
            statusItem.button?.title = heldForMeeting ? "\(glyph)call" : "\(glyph)\(clock)"
        }
        statusItem.button?.toolTip = "LookAwayLite — \(stateDescription())"
        statusHeader?.title = stateDescription()
    }

    // MARK: menu

    private func rebuildMenu() {
        let menu = NSMenu()

        // Countdown lives here so the menu bar item can stay a single glyph.
        let header = NSMenuItem(title: stateDescription(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        statusHeader = header
        menu.addItem(.separator())

        menu.addItem(withTitle: paused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(withTitle: "Break now", action: #selector(breakNow), keyEquivalent: "")
        menu.addItem(withTitle: "Skip to next break", action: #selector(skip), keyEquivalent: "")
        menu.addItem(.separator())

        let workMenu = NSMenu()
        for m in [5, 10, 15, 20, 30, 45, 60] {
            let item = NSMenuItem(title: "\(m) min", action: #selector(setWork(_:)), keyEquivalent: "")
            item.tag = m
            item.state = workSeconds == m * 60 ? .on : .off
            workMenu.addItem(item)
        }
        let workParent = NSMenuItem(title: "Work interval", action: nil, keyEquivalent: "")
        workParent.submenu = workMenu
        menu.addItem(workParent)

        let breakMenu = NSMenu()
        for s in [20, 30, 60, 120, 300] {
            let title = s < 60 ? "\(s) sec" : "\(s / 60) min"
            let item = NSMenuItem(title: title, action: #selector(setBreak(_:)), keyEquivalent: "")
            item.tag = s
            item.state = breakSeconds == s ? .on : .off
            breakMenu.addItem(item)
        }
        let breakParent = NSMenuItem(title: "Break length", action: nil, keyEquivalent: "")
        breakParent.submenu = breakMenu
        menu.addItem(breakParent)

        menu.addItem(.separator())

        let micItem = NSMenuItem(title: "Never break while mic is in use",
                                 action: #selector(toggleMic), keyEquivalent: "")
        micItem.state = skipWhenMic ? .on : .off
        menu.addItem(micItem)

        let camItem = NSMenuItem(title: "Never break while camera is in use",
                                 action: #selector(toggleCamera), keyEquivalent: "")
        camItem.state = skipWhenCamera ? .on : .off
        menu.addItem(camItem)

        let chromeItem = NSMenuItem(title: "Never break during a Meet/Zoom tab in Chrome",
                                    action: #selector(toggleChrome), keyEquivalent: "")
        chromeItem.state = skipDuringChromeCall ? .on : .off
        menu.addItem(chromeItem)

        let calItem = NSMenuItem(title: "Never break during calendar events",
                                 action: #selector(toggleCalendar), keyEquivalent: "")
        calItem.state = skipDuringEvents ? .on : .off
        menu.addItem(calItem)

        let compactItem = NSMenuItem(title: "Show countdown in menu bar",
                                     action: #selector(toggleCompact), keyEquivalent: "")
        compactItem.state = compactStatus ? .off : .on
        menu.addItem(compactItem)

        let startSoundItem = NSMenuItem(title: "Play sound when break starts",
                                        action: #selector(toggleStartSound), keyEquivalent: "")
        startSoundItem.state = startSoundEnabled ? .on : .off
        menu.addItem(startSoundItem)

        let endSoundItem = NSMenuItem(title: "Play sound when break ends",
                                      action: #selector(toggleEndSound), keyEquivalent: "")
        endSoundItem.state = endSoundEnabled ? .on : .off
        menu.addItem(endSoundItem)

        let completionItem = NSMenuItem(title: "Show break completion card",
                                        action: #selector(toggleCompletionCard), keyEquivalent: "")
        completionItem.state = completionCardEnabled ? .on : .off
        menu.addItem(completionItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        for sub in [workMenu, breakMenu] {
            for item in sub.items { item.target = self }
        }
        statusItem.menu = menu
        refreshTitle()
    }

    @objc private func togglePause() {
        paused.toggle()
        if paused { overlay.hide(); onBreak = false } else { startWork() }
        rebuildMenu()
    }

    @objc private func breakNow() {
        paused = false
        startBreak()
        rebuildMenu()
    }

    @objc private func skip() {
        paused = false
        startWork()
        rebuildMenu()
    }

    @objc private func setWork(_ sender: NSMenuItem) {
        workSeconds = sender.tag * 60
        UserDefaults.standard.set(sender.tag, forKey: defaultsWorkKey)
        startWork()
        rebuildMenu()
    }

    @objc private func toggleMic() {
        skipWhenMic.toggle()
        UserDefaults.standard.set(skipWhenMic, forKey: defaultsMicKey)
        micCache.at = .distantPast
        rebuildMenu()
    }

    @objc private func toggleCompact() {
        compactStatus.toggle()
        UserDefaults.standard.set(compactStatus, forKey: defaultsCompactKey)
        rebuildMenu()
    }

    @objc private func toggleStartSound() {
        startSoundEnabled.toggle()
        UserDefaults.standard.set(startSoundEnabled, forKey: defaultsStartSoundKey)
        UserDefaults.standard.set(startSoundEnabled || endSoundEnabled, forKey: defaultsSoundKey)
        rebuildMenu()
    }

    @objc private func toggleEndSound() {
        endSoundEnabled.toggle()
        UserDefaults.standard.set(endSoundEnabled, forKey: defaultsEndSoundKey)
        UserDefaults.standard.set(startSoundEnabled || endSoundEnabled, forKey: defaultsSoundKey)
        rebuildMenu()
    }

    @objc private func toggleCompletionCard() {
        completionCardEnabled.toggle()
        UserDefaults.standard.set(completionCardEnabled, forKey: defaultsCompletionCardKey)
        rebuildMenu()
    }

    @objc private func toggleCamera() {
        skipWhenCamera.toggle()
        UserDefaults.standard.set(skipWhenCamera, forKey: defaultsCamKey)
        camCache.at = .distantPast
        rebuildMenu()
    }

    @objc private func toggleChrome() {
        skipDuringChromeCall.toggle()
        UserDefaults.standard.set(skipDuringChromeCall, forKey: defaultsChromeKey)
        chromeCache.at = .distantPast
        // Trigger the one-time Automation prompt now rather than mid-meeting.
        if skipDuringChromeCall { _ = chromeCallTabActive() }
        rebuildMenu()
    }

    @objc private func toggleCalendar() {
        if skipDuringEvents {
            skipDuringEvents = false
            UserDefaults.standard.set(false, forKey: defaultsCalKey)
            rebuildMenu()
            return
        }
        calendar.refreshAuthorization()
        if calendar.authorized {
            skipDuringEvents = true
            UserDefaults.standard.set(true, forKey: defaultsCalKey)
            rebuildMenu()
            return
        }
        calendar.requestAccess { [weak self] ok in
            guard let self else { return }
            self.skipDuringEvents = ok
            UserDefaults.standard.set(ok, forKey: defaultsCalKey)
            if !ok {
                let alert = NSAlert()
                alert.messageText = "Calendar access denied"
                alert.informativeText = "Enable LookAwayLite under System Settings › Privacy & Security › Calendars, then turn this back on."
                alert.runModal()
            }
            self.rebuildMenu()
        }
    }

    @objc private func setBreak(_ sender: NSMenuItem) {
        breakSeconds = sender.tag
        UserDefaults.standard.set(sender.tag, forKey: defaultsBreakKey)
        rebuildMenu()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
