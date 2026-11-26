import StoreKit
import SwiftUI
import VisionKit

/// Scan the QR code from a Mac's Pair a Device window (or paste its link),
/// check the fingerprint, name it, add it.
struct AddMacView: View {
    @ObservedObject var macs: Macs
    var done: () -> Void
    @State private var link = ""
    @State private var found: Destination?
    @State private var name = "Mac"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let found {
                    confirm(found)
                } else {
                    if DataScannerViewController.isSupported {
                        Section {
                            QRScanner { use($0) }
                                .frame(height: 280)
                                .listRowInsets(EdgeInsets())
                        } footer: {
                            Text("Point the camera at the QR code in Pigeon's Pair a Device window on your Mac.")
                        }
                    }
                    Section {
                        TextField("https://…/#p=v1…", text: $link, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                        PasteButton(payloadType: String.self) { s in
                            if let s = s.first { link = s; use(s) }
                        }
                        Button("Add") { use(link) }.disabled(link.isEmpty)
                    } header: {
                        Text(DataScannerViewController.isSupported ? "Or paste the pairing link" : "Paste the pairing link")
                    } footer: {
                        Text("On the Mac: Pair a Device → Copy Link, then paste it here (Universal Clipboard works).")
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                }
            }
            .navigationTitle("Add a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
            }
        }
    }

    private func confirm(_ d: Destination) -> some View {
        Group {
            Section {
                TextField("Name", text: $name)
            } header: {
                Text("Name this Mac")
            }
            Section {
                LabeledContent("Fingerprint") { Text(d.fingerprint).font(.body.monospaced()) }
                LabeledContent("Relay", value: d.server.host ?? d.server.absoluteString)
            } footer: {
                Text("Check that the fingerprint matches the one under the QR code on your Mac. Anyone with this link can send to that Mac, so only use your own devices.")
            }
            Section {
                Button("Add \(name.isEmpty ? "Mac" : name)") {
                    var d = d
                    d.name = name.isEmpty ? "Mac" : name
                    macs.add(d)
                    done()
                }
                .bold()
                Button("Scan Again", role: .cancel) { found = nil; link = "" }
            }
        }
    }

    private func use(_ s: String) {
        guard found == nil else { return }
        if let d = Destination.parse(s, name: "Mac") {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            error = nil
            found = d
        } else {
            error = "That isn't a Pigeon pairing link. It should look like https://your-relay/#p=v1…"
        }
    }
}

/// Live QR scanning with VisionKit.
struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                           qualityLevel: .balanced, isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(_ onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                if let s = code.payloadStringValue { onCode(s); return }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var macs: Macs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var deviceName = Settings.deviceName
    @State private var showTip = false
    @ObservedObject private var receiver = Receiver.shared
    @State private var settingUpReceiving = false
    @State private var confirmingTurnOff = false
    @State private var addToPhotos = ReceiveSettings.addMediaToPhotos
    @State private var copyText = ReceiveSettings.copyText
    @State private var adding = false

    init(model: AppModel) {
        self.model = model
        _macs = ObservedObject(wrappedValue: model.macs)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(macs.list) { d in
                        // Tapping opens the Mac's own page (the chevron says so).
                        NavigationLink(value: d.inbox) { MacRow(mac: d, isDefault: d == macs.list.first && macs.list.count > 1) }
                            .swipeActions { Button("Remove", role: .destructive) { macs.remove(d) } }
                    }
                    .onMove { macs.move(fromOffsets: $0, toOffset: $1) } // touch and hold, then drag
                    Button("Add a Mac") { adding = true }
                } header: {
                    Text("Your Macs")
                } footer: {
                    Text(macs.list.count > 1
                         ? "Tap a Mac to rename or remove it. Touch and hold to drag them into order; the top one is your default."
                         : "Tap a Mac to rename or remove it.")
                }
                receiveSection
                Section {
                    TextField("iPhone", text: $deviceName)
                        .onChange(of: deviceName) { _, v in Settings.deviceName = v }
                } header: {
                    Text("This iPhone's name")
                } footer: {
                    Text("Your Mac shows this as who it's from.")
                }
                Section {
                    Button("Clear Recent", role: .destructive) { model.log.clear() }
                }
                Section {
                    Button { openURL(Feedback.mailURL) } label: {
                        Label("Send Feedback", systemImage: "envelope")
                    }
                    Link(destination: Feedback.repoURL) {
                        Label("Pigeon on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: Feedback.privacyURL) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    if showTip {
                        Link(destination: Feedback.tipURL) {
                            Label("Leave a Tip", systemImage: "cup.and.saucer")
                        }
                    }
                    LabeledContent("Version", value: Feedback.version)
                } header: {
                    Text("Feedback")
                } footer: {
                    Text(showTip
                         ? "Ideas, bugs, anything: email \(Feedback.address). Pigeon is free; if it saves you time, you can buy me a coffee on Ko-fi."
                         : "Ideas, bugs, anything: email \(Feedback.address).")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task { showTip = await Feedback.tipLinkAllowed() }
            .navigationDestination(for: String.self) { inbox in MacDetailView(macs: macs, inbox: inbox) }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $adding) { AddMacView(macs: macs) { adding = false } }
            .sheet(isPresented: $settingUpReceiving) { ReceiveSetupView(macs: macs) { settingUpReceiving = false } }
            .confirmationDialog("Turn off receiving?", isPresented: $confirmingTurnOff, titleVisibility: .visible) {
                Button("Turn Off", role: .destructive) { receiver.turnOff() }
            } message: {
                Text("This iPhone forgets its key and inbox. Remove it from your Macs too (Settings → Sending).")
            }
        }
    }

    @ViewBuilder private var receiveSection: some View {
        Section {
            if receiver.isOn {
                LabeledContent("Status") {
                    switch receiver.status {
                    case .connected: Label("Receiving", systemImage: "circle.fill").foregroundStyle(.green)
                    case .connecting: Text("Connecting…")
                    case .offline: Label("Offline, retrying", systemImage: "circle.fill").foregroundStyle(.orange)
                    case .off: Text("Off")
                    }
                }
                .labelStyle(.titleOnly)
                Toggle("Add photos and videos to Photos", isOn: $addToPhotos)
                    .onChange(of: addToPhotos) { _, v in ReceiveSettings.addMediaToPhotos = v }
                Toggle("Copy received text to the clipboard", isOn: $copyText)
                    .onChange(of: copyText) { _, v in ReceiveSettings.copyText = v }
                Button("Ask My Macs to Send Here") { Task { await receiver.askToPair(macs.list); model.flash("Approve the request in each Mac's Pigeon popover") } }
                NavigationLink("This iPhone's Pairing Link") { PairingLinkView() }
                Button("Turn Off Receiving", role: .destructive) { confirmingTurnOff = true }
            } else {
                Button("Turn On Receiving…") { settingUpReceiving = true }
            }
        } header: {
            Text("Receive on This iPhone")
        } footer: {
            Text(receiver.isOn
                 ? "Your Macs list this iPhone once you approve its request in their Pigeon popover. Things arrive right away while Pigeon is open; otherwise iOS checks from time to time and shows a notification. Files go to Files → On My iPhone → Pigeon."
                 : "Let your Macs send files, photos and text to this iPhone too. You'll need your relay's admin secret once.")
        }
    }
}

/// Turn on receiving: create this iPhone's key and inbox on your relay.
struct ReceiveSetupView: View {
    @ObservedObject var macs: Macs
    var done: () -> Void
    @State private var server = ""
    @State private var secret = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://relay.example.com", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField("Admin secret", text: $secret)
                } footer: {
                    Text("The admin secret (RELAY_ADMIN_SECRET on your server) is used once to create this iPhone's inbox and isn't stored. Then each of your Macs gets a request to send here.")
                }
                if let error { Text(error).foregroundStyle(.orange) }
                Section {
                    Button {
                        Task { await turnOn() }
                    } label: {
                        if working { ProgressView() } else { Text("Turn On Receiving").bold() }
                    }
                    .disabled(working || secret.isEmpty || URL(string: server)?.scheme != "https")
                }
            }
            .navigationTitle("Receive on This iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) } }
            .onAppear { if server.isEmpty { server = macs.list.first?.server.absoluteString ?? "" } }
        }
    }

    private func turnOn() async {
        // Pasted values often carry a stray space or line break (e.g. copied from Terminal).
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            try await Receiver.shared.turnOn(server: url, adminSecret: secret.trimmingCharacters(in: .whitespacesAndNewlines), macs: macs.list)
            done()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// This iPhone's pairing link and QR code, for adding it on a Mac by hand.
struct PairingLinkView: View {
    @ObservedObject private var receiver = Receiver.shared
    @State private var copied = false

    var body: some View {
        Form {
            if let link = receiver.pairingLink {
                Section {
                    if let qr = Self.qr(link) {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(maxWidth: 260).frame(maxWidth: .infinity)
                    }
                    LabeledContent("Fingerprint") { Text(receiver.fingerprint ?? "").font(.body.monospaced()) }
                } footer: {
                    Text("On a Mac: click the pigeon → … → Add a Mac to Send To, and paste this link. Anyone with it can send to this iPhone, so keep it to your own devices.")
                }
                Section {
                    Button(copied ? "Copied" : "Copy Link") { UIPasteboard.general.string = link; copied = true }
                }
            }
        }
        .navigationTitle("Pairing Link")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func qr(_ text: String) -> UIImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(text.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

private struct MacRow: View {
    let mac: Destination
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(mac.name)
                    if isDefault {
                        Text("Default").font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                }
                Text(mac.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }
}

/// One Mac's page: rename it, check its fingerprint, make it the default, or remove it.
struct MacDetailView: View {
    @ObservedObject var macs: Macs
    let inbox: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmingRemove = false

    private var mac: Destination? { macs.list.first { $0.inbox == inbox } }
    private var isDefault: Bool { macs.list.first?.inbox == inbox }

    var body: some View {
        Form {
            if let mac {
                Section("Name") {
                    TextField("Name", text: $name)
                        .submitLabel(.done)
                        .onSubmit(save)
                }
                Section {
                    LabeledContent("Fingerprint") { Text(mac.fingerprint).font(.body.monospaced()) }
                    LabeledContent("Relay", value: mac.server.host ?? mac.server.absoluteString)
                } footer: {
                    Text("The fingerprint should match the one under the QR code in this Mac's Pair a Device window.")
                }
                if macs.list.count > 1 {
                    Section {
                        if isDefault {
                            Label("This is your default Mac", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        } else {
                            Button("Make Default") { macs.makeDefault(mac) }
                        }
                    } footer: {
                        Text("Your default Mac is the one at the top of the list. The Share sheet and the Send buttons use it unless you pick another.")
                    }
                }
                Section {
                    Button("Remove This Mac", role: .destructive) { confirmingRemove = true }
                }
            }
        }
        .navigationTitle(mac?.name ?? "Mac")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { name = mac?.name ?? "" }
        .onDisappear(perform: save)
        .confirmationDialog("Remove \(mac?.name ?? "this Mac")?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let mac { macs.remove(mac) }
                dismiss()
            }
        } message: {
            Text("This iPhone will stop sending to it. You can add it again with its pairing link.")
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let mac, !trimmed.isEmpty, trimmed != mac.name { macs.rename(mac, to: trimmed) }
    }
}

/// Where feedback goes, and a little context that helps with bug reports
/// (versions and phone model only; nothing personal).
enum Feedback {
    static let address = "pigeon@wesyarber.net"
    static let repoURL = URL(string: "https://github.com/WesYarber/pigeon")!
    static let tipURL = URL(string: "https://ko-fi.com/wesyarber")!
    static let privacyURL = URL(string: "https://github.com/WesYarber/pigeon/blob/main/PRIVACY.md")!

    /// The Ko-fi link appears only for the US App Store, where Apple allows
    /// links to outside payment (guideline 3.1.1(a)). Elsewhere it's hidden:
    /// no in-app purchases, no tip jar.
    static func tipLinkAllowed() async -> Bool {
        await Storefront.current?.countryCode == "USA"
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static var model: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var mailURL: URL {
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = address
        c.queryItems = [
            URLQueryItem(name: "subject", value: "Pigeon feedback"),
            URLQueryItem(name: "body", value: "\n\n\n—\nPigeon \(version) · iOS \(UIDevice.current.systemVersion) · \(model)"),
        ]
        return c.url!
    }
}
