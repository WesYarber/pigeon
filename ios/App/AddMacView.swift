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
    @State private var deviceName = Settings.deviceName
    @State private var adding = false
    @State private var renaming: Destination?
    @State private var newName = ""

    init(model: AppModel) {
        self.model = model
        _macs = ObservedObject(wrappedValue: model.macs)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(macs.list) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(d.name)
                                if d == macs.list.first, macs.list.count > 1 {
                                    Text("Default").font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                }
                            }
                            Text(d.fingerprint).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { macs.remove(d) }
                            Button("Rename") { newName = d.name; renaming = d }.tint(.gray)
                        }
                        .contextMenu {
                            if d != macs.list.first { Button("Make Default") { macs.makeDefault(d) } }
                            Button("Rename") { newName = d.name; renaming = d }
                            Button("Remove", role: .destructive) { macs.remove(d) }
                        }
                    }
                    Button("Add a Mac") { adding = true }
                } header: {
                    Text("Your Macs")
                } footer: {
                    Text("Swipe or touch and hold a Mac to rename, remove or make it the default.")
                }
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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $adding) { AddMacView(macs: macs) { adding = false } }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") { if let d = renaming, !newName.isEmpty { macs.rename(d, to: newName) }; renaming = nil }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }
}
