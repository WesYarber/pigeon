import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Remappable keyboard shortcuts

enum ShortcutAction: String, CaseIterable {
    case openPigeon, sendClipboard

    var title: String {
        switch self {
        case .openPigeon: return "Open Pigeon"
        case .sendClipboard: return "Send the clipboard to your default Mac"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .openPigeon: return Shortcut(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey | cmdKey, key: "P")
        case .sendClipboard: return Shortcut(keyCode: kVK_ANSI_V, modifiers: controlKey | optionKey | cmdKey, key: "V")
        }
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: Int
    var modifiers: Int // Carbon flags (cmdKey, optionKey, ...)
    var key: String

    var label: String {
        var s = ""
        if modifiers & controlKey != 0 { s += "⌃" }
        if modifiers & optionKey != 0 { s += "⌥" }
        if modifiers & shiftKey != 0 { s += "⇧" }
        if modifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }

    /// From a key press; nil unless it includes ⌘, ⌥ or ⌃ (plain keys would hijack typing).
    init?(event e: NSEvent) {
        let f = e.modifierFlags
        guard !f.intersection([.command, .option, .control]).isEmpty else { return nil }
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        let special: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←",
                                      kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
                                      kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
                                      kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10"]
        let code = Int(e.keyCode)
        self.init(keyCode: code, modifiers: m,
                  key: special[code] ?? (e.charactersIgnoringModifiers ?? "?").uppercased())
    }
}

extension AppDelegate {
    /// The shortcut for an action, or nil if it's been turned off.
    func shortcut(_ a: ShortcutAction) -> Shortcut? {
        if defaults.bool(forKey: "shortcut.\(a.rawValue).off") { return nil }
        return defaults.data(forKey: "shortcut.\(a.rawValue)")
            .flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? a.defaultShortcut
    }

    func setShortcut(_ a: ShortcutAction, _ s: Shortcut?) {
        objectWillChange.send()
        defaults.set(s == nil, forKey: "shortcut.\(a.rawValue).off")
        if let s { defaults.set(try? JSONEncoder().encode(s), forKey: "shortcut.\(a.rawValue)") }
        registerHotKeys()
    }

    func registerHotKeys() {
        hotKeys.forEach { $0.unregister() }
        hotKeys = []
        hotKeyFailures = []
        for a in ShortcutAction.allCases {
            guard let s = shortcut(a) else { continue }
            let hk = HotKey(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] in
                guard let self else { return }
                switch a {
                case .openPigeon: self.togglePopover()
                case .sendClipboard: self.send(self.outgoing(from: .general), to: nil)
                }
            }
            if !hk.registered { hotKeyFailures.insert(a) }
            hotKeys.append(hk)
        }
    }

    /// While recording a new shortcut, the old ones mustn't fire.
    func suspendHotKeys() {
        hotKeys.forEach { $0.unregister() }
        hotKeys = []
    }
}

struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject var app: AppDelegate
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if app.hotKeyFailures.contains(action) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help("Another app is already using this shortcut. Pick a different one.")
            }
            Button { recording ? stop() : start() } label: {
                Text(recording ? "Type shortcut…" : (app.shortcut(action)?.label ?? "Off"))
                    .font(.body.monospaced())
                    .frame(minWidth: 110)
            }
            .help("Click, then press the new keys. Delete turns it off, Esc cancels.")
            if !recording, app.shortcut(action) != action.defaultShortcut {
                Button { app.setShortcut(action, action.defaultShortcut) } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Back to \(action.defaultShortcut.label)")
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        recording = true
        app.suspendHotKeys()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            switch Int(e.keyCode) {
            case kVK_Escape: stop()
            case kVK_Delete, kVK_ForwardDelete: app.setShortcut(action, nil); stop()
            default:
                if let s = Shortcut(event: e) { app.setShortcut(action, s); stop() } else { NSSound.beep() }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        app.registerHotKeys()
    }
}

// MARK: - History expiry

extension History {
    /// Drops text older than `textAge` and files older than `fileAge` (nil = keep).
    func prune(textAge: TimeInterval?, fileAge: TimeInterval?) {
        let now = Date()
        let before = entries.count
        let kept = entries.filter { e in
            let age = now.timeIntervalSince(e.ts)
            if e.kind == "file" { return fileAge.map { age < $0 } ?? true }
            return textAge.map { age < $0 } ?? true
        }
        if kept.count != before { replaceAll(kept) }
    }
}

extension AppDelegate {
    /// Minutes before sent/received text disappears from history (0 = never).
    var textKeepMinutes: Int {
        get { (defaults.object(forKey: "textKeepMinutes") as? Int) ?? 30 }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "textKeepMinutes"); pruneHistory() }
    }
    /// Days of file transfers shown in history (0 = all). The files themselves stay on disk.
    var fileKeepDays: Int {
        get { (defaults.object(forKey: "fileKeepDays") as? Int) ?? 2 }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "fileKeepDays"); pruneHistory() }
    }

    func pruneHistory() {
        history.prune(textAge: textKeepMinutes > 0 ? TimeInterval(textKeepMinutes * 60) : nil,
                      fileAge: fileKeepDays > 0 ? TimeInterval(fileKeepDays * 86_400) : nil)
    }

    func startHistoryExpiry() {
        pruneHistory()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pruneHistory() }
        }
    }
}

// MARK: - Size the popover to its content

extension AppDelegate {
    func fittedPanelSize() -> NSSize {
        let fit = popoverHost.sizeThatFits(in: NSSize(width: 360, height: 5000))
        let screen = (statusItem.button?.window?.screen ?? NSScreen.main!).visibleFrame
        return NSSize(width: 360, height: min(ceil(fit.height), screen.height - 24))
    }

    /// Keeps the popover (or fallback panel) exactly as tall as what it shows.
    func refitPanels() {
        let size = fittedPanelSize()
        if popover.isShown, abs(popover.contentSize.height - size.height) > 0.5 {
            popover.contentSize = size
        }
        if let panel = fallbackPanel, panel.isVisible {
            let f = panel.frame
            let target = fallbackFrameSize(panel, fitting: size)
            if abs(f.height - target.height) > 0.5 { // keep the top edge where it is
                panel.setFrame(NSRect(x: f.minX, y: f.maxY - target.height, width: target.width, height: target.height),
                               display: true, animate: false)
            }
        }
    }

    /// The fallback panel draws under its (transparent) title bar, so add that height.
    func fallbackFrameSize(_ panel: NSPanel, fitting size: NSSize) -> NSSize {
        let titlebar = max(0, panel.frame.height - panel.contentLayoutRect.height)
        return NSSize(width: size.width, height: size.height + titlebar)
    }
}

// MARK: - Update from the GitHub repo it was installed from

extension AppDelegate {
    /// The git checkout this build came from (recorded by mac/build.sh).
    var sourceDir: URL? {
        guard let p = Bundle.main.object(forInfoDictionaryKey: "PigeonSourceDir") as? String,
              FileManager.default.fileExists(atPath: p + "/.git") else { return nil }
        return URL(fileURLWithPath: p, isDirectory: true)
    }

    var buildCommit: String { Bundle.main.object(forInfoDictionaryKey: "PigeonCommit") as? String ?? "unknown" }

    static let updateCheckInterval: TimeInterval = 6 * 3600

    /// Look for updates in the background every few hours (git fetch; the repo is private, so
    /// this uses the same GitHub sign-in as git on this Mac).
    var checkUpdatesAutomatically: Bool {
        get { defaults.object(forKey: "checkUpdates") as? Bool ?? true }
        set { setting("checkUpdates", newValue); startUpdateChecks() }
    }
    /// Install updates as soon as they're found instead of showing the orange dot.
    var installUpdatesAutomatically: Bool {
        get { defaults.bool(forKey: "autoUpdate") }
        set {
            setting("autoUpdate", newValue)
            if newValue, !updateAvailable.isEmpty { installUpdate() }
        }
    }
    var lastUpdateCheck: Date? { defaults.object(forKey: "lastUpdateCheck") as? Date }

    /// Checks shortly after launch, then whenever it's been 6 hours (an hourly
    /// timer, so a Mac that slept through a check catches up soon after waking).
    func startUpdateChecks() {
        updateTimer?.invalidate()
        updateTimer = nil
        guard checkUpdatesAutomatically, sourceDir != nil else { return }
        let due: @MainActor () -> Void = { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastUpdateCheck ?? .distantPast) >= Self.updateCheckInterval else { return }
            Task { await self.refreshUpdateStatus() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { MainActor.assumeIsolated { due() } }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { due() }
        }
    }

    /// What's newer than this build: commit subjects (empty = up to date), or an error message.
    private func pendingChanges(in dir: URL) async -> Result<[String], UpdateError> {
        let fetch = await Self.run(["git", "fetch", "--quiet"], in: dir)
        guard fetch.status == 0 else { return .failure(UpdateError(message: String(fetch.output.prefix(400)))) }
        defaults.set(Date(), forKey: "lastUpdateCheck")
        objectWillChange.send()
        let behind = Int(await Self.run(["git", "rev-list", "--count", "HEAD..@{u}"], in: dir)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if behind > 0 {
            let log = await Self.run(["git", "log", "--format=%s", "HEAD..@{u}", "-n", "8"], in: dir).output
            return .success(log.split(separator: "\n").map(String.init))
        }
        let head = await Self.run(["git", "rev-parse", "--short", "HEAD"], in: dir)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(head == buildCommit.replacingOccurrences(of: "+", with: "")
                        ? [] : ["The source folder has a newer version than the one installed."])
    }

    struct UpdateError: Error { let message: String }

    /// Background check: shows the orange dot (and a notification the first
    /// time), or installs straight away if that's turned on.
    func refreshUpdateStatus() async {
        guard let dir = sourceDir, !updating, case .success(let changes) = await pendingChanges(in: dir) else { return }
        let isNew = updateAvailable.isEmpty && !changes.isEmpty
        updateAvailable = changes
        guard !changes.isEmpty else { return }
        if installUpdatesAutomatically {
            installUpdate()
        } else if isNew {
            notify("A Pigeon update is available", changes.first ?? "Click the pigeon to update.")
        }
    }

    /// Settings → Update Pigeon…: check now and ask before installing.
    func checkForUpdates() {
        guard let dir = sourceDir else {
            return fail("Pigeon doesn't know which folder it was installed from. Install it once with ./install.sh from your pigeon folder; after that, updates work from here.")
        }
        showToast("Checking for updates…")
        Task {
            let changes: [String]
            switch await pendingChanges(in: dir) {
            case .failure(let e): return fail("Couldn't check GitHub for updates.\n\n\(e.message)")
            case .success(let c): changes = c
            }
            updateAvailable = changes
            NSApp.activate(ignoringOtherApps: true)
            if changes.isEmpty {
                let a = NSAlert()
                a.messageText = "Pigeon is up to date"
                a.informativeText = "You have the latest version (\(buildCommit))."
                a.runAndClose()
                return
            }
            let a = NSAlert()
            a.messageText = "Update Pigeon?"
            a.informativeText = "\(changes.map { "• " + $0 }.joined(separator: "\n"))\n\nPigeon will download the latest version, rebuild it (about a minute) and restart."
            a.addButton(withTitle: "Update")
            a.addButton(withTitle: "Not Now")
            guard a.runAndClose() == .alertFirstButtonReturn else { return }
            installUpdate()
        }
    }

    /// Pulls the latest source and runs the installer, which rebuilds, quits
    /// this copy and opens the new one.
    func installUpdate() {
        guard !updating, let dir = sourceDir else { return }
        guard sendingCount == 0 else {
            // Don't cut off a send in progress; try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.installUpdate() }
            return
        }
        updating = true
        Task {
            let pull = await Self.run(["git", "pull", "--ff-only", "--quiet"], in: dir)
            guard pull.status == 0 else {
                updating = false
                return fail("Couldn't update the source folder (\(dir.path)).\n\n\(pull.output.prefix(400))")
            }
            runInstaller(in: dir)
        }
    }

    /// The menu bar glyph with a small orange dot: an update is waiting.
    func updateBadgeIcon(_ base: NSImage) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            base.draw(in: r)
            NSColor.labelColor.set() // template glyphs draw black; tint to match the menu bar
            r.fill(using: .sourceAtop)
            let dot = NSRect(x: r.maxX - 7, y: r.minY, width: 7, height: 7) // bottom-right, clear of the beak
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemOrange.set()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        img.accessibilityDescription = "Pigeon, update available"
        return img
    }

    /// Runs ./install.sh detached: it rebuilds, quits this copy and opens the new one.
    private func runInstaller(in dir: URL) {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Pigeon-update.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", "./install.sh"]
        p.currentDirectoryURL = dir
        p.environment = Self.toolEnvironment
        p.standardInput = FileHandle.nullDevice
        let log = FileHandle(forWritingAtPath: logURL.path)
        p.standardOutput = log
        p.standardError = log
        // Only reached if the build fails (on success the installer quits this app first).
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                if status != 0 {
                    self.updating = false
                    self.fail("The update didn't build, so Pigeon is unchanged. Details are in ~/Library/Logs/Pigeon-update.log.")
                }
            }
        }
        do {
            try p.run()
            showToast("Updating… Pigeon will restart in about a minute")
        } catch {
            updating = false
            fail("Couldn't start the update: \(error.localizedDescription)")
        }
    }

    nonisolated static var toolEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["GIT_TERMINAL_PROMPT"] = "0" // never hang waiting for a password
        return env
    }

    nonisolated static func run(_ args: [String], in dir: URL) async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                p.arguments = args
                p.currentDirectoryURL = dir
                p.environment = toolEnvironment
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { return cont.resume(returning: (-1, error.localizedDescription)) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
