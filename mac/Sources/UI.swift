import AppKit
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

extension Destination: Identifiable { var id: String { inbox } }

/// "just now" for the last minute (also covers small clock differences between Macs).
func ago(_ date: Date) -> String {
    abs(date.timeIntervalSinceNow) < 60 ? "just now"
        : RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
}

/// Dialogs started from a SwiftUI button run after the button's action returns.
func later(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

enum SettingsTab: Hashable { case general, receiving, sending, security }

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var app: AppDelegate
    @State private var dropTargeted = false
    @State private var targetInbox: String?

    /// Where the popover's actions send: the picked Mac, or the default.
    private var target: Destination? {
        app.destinations.first { $0.inbox == targetInbox } ?? app.destinations.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 12) {
                if !app.updateAvailable.isEmpty { updateBanner }
                if app.config == nil { receivingOffBanner }
                ForEach(app.pairRequests) { PairRequestCard(request: $0, app: app) }
                dropZone
                actions
            }
            .padding(12)
            if !app.history.entries.isEmpty {
                Divider()
                recent
            }
            Divider()
            footer
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true) // as tall as the content, no taller
        .overlay(alignment: .bottom) { toast }
        .animation(.easeOut(duration: 0.18), value: app.toast)
        .animation(.easeOut(duration: 0.18), value: app.pairRequests.count)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Pigeon").font(.headline)
                StatusLine(app: app)
            }
            Spacer()
            if app.sendingCount > 0 {
                ProgressView().controlSize(.small).help("Sending…")
            }
            Button { app.showSettingsAction() } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var updateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available").font(.callout.weight(.medium))
                Text(app.updateAvailable.first ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if app.updating {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Update") { app.installUpdate() }.controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
        .help(app.updateAvailable.map { "• " + $0 }.joined(separator: "\n"))
    }

    private var receivingOffBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray").foregroundStyle(.secondary)
            Text("Receiving is off on this Mac").font(.callout)
            Spacer()
            Button("Set Up…") { app.afterClosingPopover { app.setup() } }
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    // MARK: Drop zone

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: dropTargeted ? "arrow.down.doc.fill" : "arrow.up.doc")
                .font(.system(size: 26))
                .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
            if let target {
                Text(dropTargeted ? "Release to send" : "Drop files here, or click to choose")
                    .font(.callout.weight(.medium))
                targetPicker(target)
            } else {
                Text("Add a Mac to send to").font(.callout.weight(.medium))
                Button("Add a Mac…") { app.afterClosingPopover { app.addDestination() } }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if target != nil { app.chooseAndSendFiles(to: target) } }
        .onHover { inside in if target != nil { inside ? NSCursor.pointingHand.push() : NSCursor.pop() } }
        .help(target == nil ? "" : "Click to choose files or folders to send")
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35)))
        .onDrop(of: [.fileURL, .image, .data, .utf8PlainText, .plainText], isTargeted: $dropTargeted) { providers in
            guard target != nil else { return false }
            app.sendDropped(providers, to: target)
            return true
        }
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }

    @ViewBuilder
    private func targetPicker(_ target: Destination) -> some View {
        if app.destinations.count > 1 {
            Menu {
                ForEach(app.destinations) { d in
                    Button { targetInbox = d.inbox } label: {
                        if d.inbox == target.inbox { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                    }
                }
            } label: {
                Text("to \(target.name)").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } else {
            Text("to \(target.name)").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private var actions: some View {
        Button { app.sendClipboard(to: target) } label: {
            Label("Send Clipboard", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
        }
        .help(app.shortcut(.sendClipboard).map { "\($0.label) from anywhere" } ?? "")
        .controlSize(.large)
        .disabled(target == nil)
    }

    // MARK: Recent

    private var recent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent").font(.subheadline.weight(.semibold))
                Spacer()
                if !app.history.entries.isEmpty {
                    Button("Clear") { app.history.clear() }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(app.history.entries) { HistoryRow(entry: $0, app: app) }
                }
                .padding(.horizontal, 6)
            }
            // Room for the newest three; scroll for the rest.
            .frame(height: CGFloat(min(app.history.entries.count, 3)) * (HistoryRow.height + Self.rowSpacing))
            .padding(.bottom, 6)
        }
    }

    static let rowSpacing: CGFloat = 1

    // MARK: Footer & toast

    private var footer: some View {
        HStack(spacing: 12) {
            Button { app.openDownloads() } label: {
                Label("Received Files", systemImage: "folder")
            }
            .help(app.downloadsDir.path)
            Spacer()
            if let s = app.shortcut(.openPigeon) {
                Text(s.label).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .help("Opens Pigeon from anywhere (change it in Settings)")
            }
            Menu {
                Button("Settings…") { app.showSettingsAction() }
                Button("Update Pigeon…") { app.afterClosingPopover { app.checkForUpdates() } }
                if app.config != nil {
                    Button("Pair a Device…") { app.afterClosingPopover { app.showPairing() } }
                }
                Button("Add a Mac to Send To…") { app.afterClosingPopover { app.addDestination() } }
                Divider()
                Button("Quit Pigeon") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var toast: some View {
        if let t = app.toast {
            Text(t)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .padding(.bottom, 50)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

struct StatusLine: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(short).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(app.statusText)
    }

    private var color: Color {
        switch app.connection {
        case .connected: return .green
        case .connecting: return .yellow
        case .offline: return .orange
        case .off: return .gray
        }
    }

    private var short: String {
        switch app.connection {
        case .connected: return "Receiving · \(app.config?.server.host ?? "")"
        case .connecting: return "Connecting…"
        case .offline: return "Offline, retrying…"
        case .off: return app.destinations.isEmpty ? "Not set up" : "Sending only"
        }
    }
}

struct PairRequestCard: View {
    let request: PairRequest
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(request.isUpdate ? "\(request.dest.name) has new keys" : "Send back to \(request.dest.name)?",
                  systemImage: request.isUpdate ? "key" : "arrow.left.arrow.right")
                .font(.callout.weight(.semibold))
            Text(request.isUpdate
                 ? "It says it reset its keys. Only allow this if you did that on \(request.dest.name)."
                 : "\(request.dest.name) added this Mac and asked to receive from it too.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Fingerprint \(request.dest.fingerprint), should match its pairing window")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now") { app.dismiss(request) }
                Button(request.isUpdate ? "Update" : "Allow") { app.accept(request) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.3)))
        .transition(.opacity)
    }
}

// MARK: - History row

/// "· Delivered" / "· Waiting…" / "· Not delivered" after a sent item.
struct DeliveryBadge: View {
    let entry: Entry

    var body: some View {
        if entry.delivered != nil {
            Label("Delivered", systemImage: "checkmark.circle.fill").labelStyle(Inline(tint: .green))
                .help("Picked up \(ago(entry.delivered!))")
        } else if entry.undelivered == true {
            Label("Not delivered", systemImage: "exclamationmark.circle.fill").labelStyle(Inline(tint: .orange))
                .help("It expired on the relay before the other Mac came online. Send it again.")
        } else if entry.relayId != nil, Date().timeIntervalSince(entry.ts) > 10 {
            Label("Waiting…", systemImage: "clock").labelStyle(Inline(tint: .secondary))
                .help("On the relay, waiting for the other Mac to come online")
        }
    }

    private struct Inline: LabelStyle {
        let tint: Color
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 2) {
                Text("·")
                configuration.icon.foregroundStyle(tint).imageScale(.small)
                configuration.title
            }
        }
    }
}

/// Small cache so image thumbnails aren't re-read from disk on every redraw.
@MainActor
enum Thumbnails {
    private static var cache: [String: NSImage] = [:]

    static func image(for path: String) -> NSImage? {
        if let img = cache[path] { return img }
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension), type.conforms(to: .image),
              let img = NSImage(contentsOfFile: path) else { return nil }
        cache[path] = img
        return img
    }
}

struct HistoryRow: View {
    static let height: CGFloat = 44
    let entry: Entry
    @ObservedObject var app: AppDelegate
    @State private var hover = false

    private var isFile: Bool { entry.kind == "file" }
    private var sent: Bool { entry.sent == true }
    private var who: String { entry.from.replacingOccurrences(of: "→ ", with: "") }
    private var title: String {
        isFile ? (entry.name ?? "File")
               : (entry.text ?? "").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? " " : title).font(.callout).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 3) {
                    Image(systemName: sent ? "arrow.up.right" : "arrow.down.left")
                        .font(.system(size: 8, weight: .bold))
                    Text("\(sent ? "To" : "From") \(who) · \(ago(entry.ts))")
                    if sent { DeliveryBadge(entry: entry) }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hover {
                HStack(spacing: 0) {
                    rowButton("doc.on.doc", "Copy") { app.copy(entry) }
                    if isFile {
                        rowButton("arrow.up.forward.app", "Open") { app.open(entry) }
                        rowButton("magnifyingglass", "Show in Finder") { app.reveal(entry) }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.07) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { isFile ? app.open(entry) : app.copy(entry) }
        .contextMenu {
            Button("Copy") { app.copy(entry) }
            if isFile {
                Button("Open") { app.open(entry) }
                Button("Show in Finder") { app.reveal(entry) }
            }
            Divider()
            Button("Remove from History") { app.history.remove(entry.id) }
        }
        .help(isFile ? (entry.path ?? "") : String((entry.text ?? "").prefix(500)))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if isFile, let p = entry.path, let img = Thumbnails.image(for: p) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            let tint: Color = sent ? .green : .accentColor
            Image(systemName: isFile ? "doc.fill" : "text.alignleft")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.14)))
        }
    }

    private func rowButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        TabView(selection: $app.settingsTab) {
            GeneralSettings(app: app)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ReceivingSettings(app: app)
                .tabItem { Label("Receiving", systemImage: "tray.and.arrow.down") }.tag(SettingsTab.receiving)
            SendingSettings(app: app)
                .tabItem { Label("Sending", systemImage: "paperplane") }.tag(SettingsTab.sending)
            SecuritySettings(app: app)
                .tabItem { Label("Security", systemImage: "lock.shield") }.tag(SettingsTab.security)
        }
        .frame(width: 560, height: 520)
    }
}

private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct GeneralSettings: View {
    @ObservedObject var app: AppDelegate
    @State private var showTip = false

    var body: some View {
        Form {
            Section {
                Toggle("Open Pigeon when you log in", isOn: $app.launchAtLogin)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show Pigeon in the Dock", isOn: $app.showInDock)
                    Footnote("Handy if your menu bar is too full to show the pigeon. Drop files on the Dock icon to send them.")
                }
                Toggle("Show notifications", isOn: $app.notificationsOn)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Tell me when something I sent is delivered", isOn: $app.notifyDelivered)
                        .disabled(!app.notificationsOn)
                    Footnote("Only for things that had to wait because the other Mac was asleep or offline. Recent always shows Delivered or Waiting. Needs your relay updated to the latest version.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show a drop shelf when dragging files to the top of the screen", isOn: $app.dropShelfOn)
                    Footnote("A small panel slides out under the pigeon with a tile for each Mac. Drop there instead of on the menu bar, which opens the Spaces bar during a drag.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Keep Pigeon open when I click other apps", isOn: $app.keepPopoverOpen)
                    Footnote("So you can open Finder or the Dock's Downloads stack and drag a file in. Close it with the pigeon, Esc, or a right-click anywhere.")
                }
            }
            Section("History") {
                Picker("Delete text after", selection: $app.textKeepMinutes) {
                    Text("5 minutes").tag(5); Text("15 minutes").tag(15); Text("30 minutes").tag(30)
                    Text("1 hour").tag(60); Text("4 hours").tag(240); Text("1 day").tag(1440)
                    Text("Never").tag(0)
                }
                Picker("Show files from the last", selection: $app.fileKeepDays) {
                    Text("1 day").tag(1); Text("2 days").tag(2); Text("1 week").tag(7)
                    Text("30 days").tag(30); Text("All time").tag(0)
                }
                Footnote("Only Pigeon's history list is trimmed; files you received stay in their folder.")
                Button("Clear History", role: .destructive) { app.history.clear() }
            }
            Section("Keyboard shortcuts") {
                ForEach(ShortcutAction.allCases, id: \.self) { a in
                    LabeledContent(a.title) { ShortcutRecorder(action: a, app: app) }
                }
                Footnote("Click a shortcut, then press the new keys (include ⌘, ⌥ or ⌃). Delete turns it off; Esc cancels.")
            }
            Section("Updates") {
                LabeledContent("Installed version", value: app.buildCommit)
                Toggle("Check for updates automatically", isOn: $app.checkUpdatesAutomatically)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Install updates automatically", isOn: $app.installUpdatesAutomatically)
                        .disabled(!app.checkUpdatesAutomatically)
                    Footnote("Otherwise an orange dot on the pigeon means an update is ready. Checks every few hours.")
                }
                HStack {
                    if app.updating {
                        ProgressView().controlSize(.small)
                        Text("Updating…").foregroundStyle(.secondary)
                    } else {
                        Button("Update Pigeon…") { later { app.checkForUpdates() } }
                    }
                    Spacer()
                    if let last = app.lastUpdateCheck {
                        Text("Checked \(ago(last))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Footnote("Gets the latest version from the GitHub repo Pigeon was installed from, rebuilds it and restarts Pigeon. Builds are signed with your Apple Development certificate, so updates don't ask for Keychain access again.")
            }
            Section("About Pigeon") {
                HStack(spacing: 16) {
                    Link(destination: About.mailURL) { Label("Send Feedback", systemImage: "envelope") }
                    Link(destination: About.repoURL) { Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") }
                    if showTip {
                        Link(destination: About.tipURL) { Label("Leave a Tip", systemImage: "cup.and.saucer") }
                    }
                }
                Footnote(showTip
                         ? "Ideas, bugs, anything: email \(About.address). Pigeon is free; if it saves you time, you can buy me a coffee on Ko-fi."
                         : "Ideas, bugs, anything: email \(About.address).")
            }
            .task { showTip = await About.tipLinkAllowed() }
        }
        .formStyle(.grouped)
    }
}

struct ReceivingSettings: View {
    @ObservedObject var app: AppDelegate

    private var savePath: String {
        (app.downloadsDir.path as NSString).abbreviatingWithTildeInPath
    }
    private var customFolder: Bool { app.defaults.string(forKey: "downloadDir") != nil }

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Status") { StatusLine(app: app) }
                if let cfg = app.config {
                    LabeledContent("Relay", value: cfg.server.host ?? cfg.server.absoluteString)
                    HStack {
                        Button("Pair a Device…") { later { app.showPairing() } }
                        Button("Change Relay…") { later { app.setup() } }
                    }
                } else {
                    Footnote("Turn this on to receive text and files on this Mac. You'll need your relay's admin secret once.")
                    Button("Set Up Receiving…") { later { app.setup() } }
                }
            }
            Section("Received files") {
                LabeledContent("Save to") {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.downloadsDir.path))
                            .resizable().frame(width: 16, height: 16)
                        Text(savePath).lineLimit(1).truncationMode(.middle)
                    }
                }
                HStack {
                    Button("Choose Folder…") { later { app.chooseDownloadsDir() } }
                    Button("Show in Finder") { app.openDownloads() }
                    if customFolder { Button("Use Default") { app.resetDownloadsDir() } }
                }
                Picker("When a file arrives", selection: $app.afterReceive) {
                    ForEach(AfterReceive.allCases) { Text($0.label).tag($0) }
                }
                Footnote("Received files are marked as downloaded, so macOS still checks apps and scripts before they run.")
            }
            Section("Text") {
                Toggle("Copy received text to the clipboard", isOn: $app.autoCopy)
            }
        }
        .formStyle(.grouped)
    }
}

struct SendingSettings: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        Form {
            Section("Macs you can send to") {
                if app.destinations.isEmpty {
                    Footnote("None yet. Add one with the link from the other Mac's Pair a Device window.")
                }
                ForEach(app.destinations) { d in
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(d.name)
                                if d == app.destinations.first {
                                    Text("Default").font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                }
                            }
                            Text(d.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            if d != app.destinations.first { Button("Make Default") { app.makeDefault(d) } }
                            Button("Rename…") { app.rename(d) }
                            Divider()
                            Button("Remove", role: .destructive) { app.remove(d) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                Button("Add a Mac…") { later { app.addDestination() } }
            }
            Section("Two-way") {
                Toggle("When I add a Mac, ask it to send back to this one", isOn: $app.offerPairBack)
                    .disabled(app.config == nil)
                Footnote(app.config == nil
                         ? "Set up receiving on this Mac first (Receiving tab)."
                         : "The other Mac gets a request it can approve, then it can send to this Mac too.")
            }
            Section("Clipboard") {
                Toggle("Share everything I copy with my default Mac", isOn: $app.autoShare)
                    .disabled(app.destinations.isEmpty)
                Footnote("Skips copies from password managers, pairing links, and anything Pigeon just received.")
            }
        }
        .formStyle(.grouped)
    }
}

struct SecuritySettings: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        Form {
            Section("This Mac's key") {
                if let key = ReceiverKey.current, app.config != nil {
                    LabeledContent("Fingerprint", value: key.fingerprint).font(.body.monospaced())
                    LabeledContent("Stored in", value: key.isHardwareBacked ? "Secure Enclave (can't be exported)" : "Keychain")
                } else {
                    Footnote("This Mac doesn't receive yet, so it has no key.")
                }
            }
            Section("How it works") {
                Footnote("Everything is encrypted on the sending device to the receiving Mac's key (P-256 ECDH, HKDF-SHA256, AES-256-GCM), with a fresh key for each item. The relay only ever stores ciphertext and deletes it once it's delivered. History on this Mac is encrypted too.")
            }
            Section {
                Button("Reset Keys & Unpair All Devices…", role: .destructive) { later { app.resetKeys() } }
                    .disabled(app.config == nil)
                Footnote("Makes a new key and inbox. Every device has to pair again. Use it if a pairing link may have leaked.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Feedback and tip links (Settings → General → About Pigeon).
enum About {
    static let address = "pigeon@wesyarber.net"
    static let repoURL = URL(string: "https://github.com/WesYarber/pigeon")!
    static let tipURL = URL(string: "https://ko-fi.com/wesyarber")!

    /// Shown only for the US App Store storefront, where outside payment links
    /// are allowed; hidden everywhere else (no in-app purchases or tip jar).
    static func tipLinkAllowed() async -> Bool {
        await Storefront.current?.countryCode == "USA"
    }

    static var mailURL: URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        let v = ProcessInfo.processInfo.operatingSystemVersion
        c.queryItems = [
            URLQueryItem(name: "subject", value: "Pigeon feedback"),
            URLQueryItem(name: "body", value: "\n\n\n—\nPigeon \(Bundle.main.object(forInfoDictionaryKey: "PigeonCommit") as? String ?? "?") · macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"),
        ]
        return c.url!
    }
}
