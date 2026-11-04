import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var log: SentLog
    @State private var photos: [PhotosPickerItem] = []
    @State private var pickingFiles = false
    @State private var adding = false
    @State private var showingSettings = false

    init(model: AppModel) {
        self.model = model
        _log = ObservedObject(wrappedValue: model.log)
    }

    var body: some View {
        NavigationStack {
            List {
                if model.macs.list.isEmpty {
                    welcome
                } else {
                    sendSection
                    recentSection
                }
            }
            .navigationTitle("Pigeon")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .refreshable { await model.refreshReceipts() }
            .sheet(isPresented: $adding) { AddMacView(macs: model.macs) { adding = false; model.objectWillChange.send() } }
            .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
            .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.enqueue(urls.compactMap(Self.copyPicked)) }
            }
            .onChange(of: photos) { _, picked in
                guard !picked.isEmpty else { return }
                photos = []
                Task { await sendPhotos(picked) }
            }
            .overlay(alignment: .bottom) { banner }
            .animation(.easeOut(duration: 0.2), value: model.message)
        }
    }

    // MARK: Sections

    private var welcome: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "desktopcomputer").font(.largeTitle).foregroundStyle(.tint)
                Text("Add your Mac").font(.title2.bold())
                Text("On your Mac, click the pigeon in the menu bar, then **… → Pair a Device**. Scan the QR code it shows, or paste its link.")
                    .foregroundStyle(.secondary)
                Button("Add a Mac") { adding = true }.buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 8)
        } footer: {
            Text("Then share files, photos and links to your Mac from any app's Share button.")
        }
    }

    private var sendSection: some View {
        Section {
            if model.macs.list.count > 1 {
                Picker("Send to", selection: Binding(get: { model.target?.inbox }, set: { model.targetInbox = $0 })) {
                    ForEach(model.macs.list) { Text($0.name).tag(Optional($0.inbox)) }
                }
            } else {
                LabeledContent("Send to", value: model.target?.name ?? "")
            }
            PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                Label("Photos & Videos", systemImage: "photo.on.rectangle")
            }
            Button { pickingFiles = true } label: { Label("Files", systemImage: "folder") }
            PasteButton(supportedContentTypes: [.url, .plainText, .image]) { providers in
                Task { await sendPasted(providers) }
            }
            if let p = model.progress {
                ProgressView(value: p) { Text("Sending \(model.sendingTitle)…").lineLimit(1) }
            }
        } footer: {
            Text("Tip: in other apps, use the Share button and pick Pigeon.")
        }
        .disabled(model.progress != nil)
    }

    private var recentSection: some View {
        Section("Recent") {
            if log.items.isEmpty {
                Text("Things you send show up here.").foregroundStyle(.secondary)
            }
            ForEach(log.items) { SentRow(item: $0) }
        }
    }

    @ViewBuilder private var banner: some View {
        if let m = model.message {
            Text(m)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Picking

    /// Files from the picker are only readable while their scope is open, so copy them.
    static func copyPicked(_ url: URL) -> Outgoing? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            return .file(copy, name: url.lastPathComponent)
        } catch {
            return nil
        }
    }

    private func sendPhotos(_ picked: [PhotosPickerItem]) async {
        var items: [Outgoing] = []
        for p in picked {
            if let f = try? await p.loadTransferable(type: PickedFile.self) { items.append(.file(f.url, name: f.url.lastPathComponent)) }
        }
        model.enqueue(items)
    }

    private func sendPasted(_ providers: [NSItemProvider]) async {
        var texts: [String] = [], items: [Outgoing] = []
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = await p.loadURL(), !url.isFileURL {
                texts.append(url.absoluteString)
            } else if let s = await p.loadString(), !s.isEmpty {
                texts.append(s)
            } else if p.canLoadObject(ofClass: UIImage.self),
                      let img = try? await withCheckedThrowingContinuation({ (c: CheckedContinuation<UIImage?, Error>) in
                          _ = p.loadObject(ofClass: UIImage.self) { o, e in e.map { c.resume(throwing: $0) } ?? c.resume(returning: o as? UIImage) }
                      }), let png = img.pngData() {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted Image \(Int(Date().timeIntervalSince1970)).png")
                if (try? png.write(to: url)) != nil { items.append(.file(url, name: url.lastPathComponent)) }
            }
        }
        if !texts.isEmpty { items.append(.text(texts.joined(separator: "\n"))) }
        model.enqueue(items)
    }
}

/// A photo or video from the library as its original file (name and format kept).
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try copy($0) }
        FileRepresentation(importedContentType: .image) { try copy($0) }
    }

    private static func copy(_ received: ReceivedTransferredFile) throws -> PickedFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(received.file.lastPathComponent)
        try FileManager.default.copyItem(at: received.file, to: dest)
        return PickedFile(url: dest)
    }
}

struct SentRow: View {
    let item: SentItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == "file" ? "doc.fill" : "text.alignleft")
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text("To \(item.to) · \(item.ts.formatted(.relative(presentation: .named)))")
                    status
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if item.delivered != nil {
            Label("Delivered", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green)
        } else if item.undelivered == true {
            Label("Not delivered", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        } else if item.relayId != nil, Date().timeIntervalSince(item.ts) > 10 {
            Label("Waiting…", systemImage: "clock")
        }
    }
}
