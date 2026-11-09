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
    @State private var dropTargeted = false

    /// At or above this width (an unfolded iPhone Duo, an iPad, landscape)
    /// sending and Recent sit side by side.
    static let twoPaneWidth: CGFloat = 600

    init(model: AppModel) {
        self.model = model
        _log = ObservedObject(wrappedValue: model.log)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if model.macs.list.isEmpty {
                    List { welcome }
                } else if geo.size.width >= Self.twoPaneWidth {
                    twoPane(width: geo.size.width)
                } else {
                    List {
                        sendSection
                        recentSection
                    }
                    .onDrop(of: [.item], isTargeted: $dropTargeted, perform: sendDropped)
                    .overlay { if dropTargeted { dropHighlight } }
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

    // MARK: Two panes (unfolded)

    private func twoPane(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    targetPicker
                    HStack(spacing: 12) {
                        PhotosPicker(selection: $photos, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                            tile("Photos & Videos", "photo.on.rectangle")
                        }
                        Button { pickingFiles = true } label: { tile("Files", "folder") }
                    }
                    .buttonStyle(.plain)
                    PasteButton(supportedContentTypes: [.url, .plainText, .image]) { providers in
                        Task { await sendPasted(providers) }
                    }
                    .frame(maxWidth: .infinity)
                    dropZone
                    if let p = model.progress {
                        ProgressView(value: p) { Text("Sending \(model.sendingTitle)…").lineLimit(1) }
                    }
                    Text("Tip: open Files or Photos next to Pigeon and drag things onto the drop zone, or use any app's Share button.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(20)
                .disabled(model.progress != nil)
            }
            .frame(width: min(max(width * 0.45, 300), 420))
            .background(Color(.systemGroupedBackground))
            Divider()
            List { recentSection }
                .listStyle(.insetGrouped) // rounded rows with margins, clear of the divider and the status strip
        }
    }

    @ViewBuilder private var targetPicker: some View {
        if model.macs.list.count > 1 {
            Picker("Send to", selection: Binding(get: { model.target?.inbox }, set: { model.targetInbox = $0 })) {
                ForEach(model.macs.list) { Text($0.name).tag(Optional($0.inbox)) }
            }
            .pickerStyle(.menu)
        } else {
            Label("Sending to \(model.target?.name ?? "")", systemImage: "desktopcomputer")
                .font(.headline)
        }
    }

    private func tile(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30))
            Text(title).font(.callout.weight(.medium)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.tint)
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
        .contentShape(Rectangle())
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: dropTargeted ? "arrow.down.circle.fill" : "tray.and.arrow.down")
                .font(.system(size: 34))
            Text(dropTargeted ? "Release to send" : "Drop files, photos or links here")
                .font(.callout.weight(.medium))
        }
        .foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(dropTargeted ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
        .onDrop(of: [.item], isTargeted: $dropTargeted, perform: sendDropped)
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 20)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.accentColor.opacity(0.08)))
            .overlay(Label("Release to send", systemImage: "arrow.down.circle.fill").font(.headline).foregroundStyle(.tint))
            .padding(8)
            .allowsHitTesting(false)
    }

    /// Drops from other apps (Files, Photos, Safari side by side) go through the
    /// same reader as the Share sheet, so names and formats are kept.
    private func sendDropped(_ providers: [NSItemProvider]) -> Bool {
        guard model.target != nil else { return false }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        Task { model.enqueue(await ItemReader.read(providers, into: scratch)) }
        return true
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
