import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Pigeon in the iOS share sheet.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum State: Equatable {
        case loading, ready, sending(Double), done, queued, failed(String)
    }

    @Published var state: State = .loading
    @Published var items: [Outgoing] = []
    @Published var target: Destination?
    let macs = Macs()
    let log = SentLog()
    private let context: NSExtensionContext?
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

    init(context: NSExtensionContext?) {
        self.context = context
        target = macs.list.first
    }

    // MARK: Reading what was shared

    func load() async {
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        var files: [Outgoing] = [], texts: [String] = []
        for p in providers {
            switch await read(p) {
            case .file(let url, let name)?: files.append(.file(url, name: name))
            case .text(let s)?: if !texts.contains(s) { texts.append(s) }
            case nil: break
            }
        }
        // Several text bits (e.g. a page title and its link) go as one message.
        items = files + (texts.isEmpty ? [] : [.text(texts.joined(separator: "\n"))])
        if items.isEmpty { state = .failed("Nothing Pigeon can send was shared."); return }
        state = .ready
        if macs.list.count == 1 { await send() } // one Mac: no need to ask
    }

    private func read(_ p: NSItemProvider) async -> Outgoing? {
        let types = p.registeredTypeIdentifiers.compactMap(UTType.init)
        // A web link (Safari, most apps): send the link itself.
        if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }), !types.contains(where: isFileData) {
            if let url = await p.loadURL(), !url.isFileURL { return .text(url.absoluteString) }
        }
        // A file, photo or video: its original bytes and name, best type first.
        if let t = types.first(where: isFileData) {
            let suggested = p.suggestedName
            return await withCheckedContinuation { cont in
                _ = p.loadFileRepresentation(forTypeIdentifier: t.identifier) { url, _ in
                    guard let url else { return cont.resume(returning: nil) }
                    let name = Self.fileName(suggested: suggested, url: url, type: t)
                    let copy = self.scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    // The provided file is deleted when this closure returns, so keep a copy.
                    do {
                        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
                        let dest = copy.appendingPathComponent(name)
                        try FileManager.default.copyItem(at: url, to: dest)
                        cont.resume(returning: .file(dest, name: name))
                    } catch {
                        cont.resume(returning: nil)
                    }
                }
            }
        }
        if let s = await p.loadString(), !s.isEmpty { return .text(s) }
        return nil
    }

    private func isFileData(_ t: UTType) -> Bool {
        (t.conforms(to: .data) || t.conforms(to: .directory)) && !t.conforms(to: .text) && !t.conforms(to: .url)
            || t.conforms(to: .image) || t.conforms(to: .audiovisualContent) || t.conforms(to: .pdf)
    }

    /// The real name with an extension that matches the data ("IMG_0042.HEIC").
    nonisolated static func fileName(suggested: String?, url: URL, type: UTType) -> String {
        var name = (suggested?.isEmpty == false ? suggested! : url.lastPathComponent)
            .components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "_")
        let ext = (name as NSString).pathExtension
        let hasMatchingExt = !ext.isEmpty && (UTType(filenameExtension: ext)?.conforms(to: type) ?? false || type.preferredFilenameExtension == nil)
        if !hasMatchingExt, let want = type.preferredFilenameExtension ?? (url.pathExtension.isEmpty ? nil : url.pathExtension) {
            name += "." + want
        }
        return name
    }

    // MARK: Sending

    func send() async {
        guard let dest = target else { return }
        state = .sending(0)
        var queued = false
        do {
            for (i, item) in items.enumerated() {
                if case .file(let url, let name) = item, Sender.size(of: url) > Sender.shareExtensionLimit {
                    try Outbox.add(url, name: name, to: dest) // too big for here; the app sends it
                    queued = true
                    continue
                }
                let share = 1.0 / Double(items.count), base = Double(i) * share
                try await Sender.send(item, to: dest, log: log) { p in
                    Task { @MainActor in self.state = .sending(base + p * share) }
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = queued ? .queued : .done
        try? await Task.sleep(nanoseconds: queued ? 2_500_000_000 : 700_000_000)
        finish()
    }

    func finish() {
        try? FileManager.default.removeItem(at: scratch)
        context?.completeRequest(returningItems: nil)
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if model.macs.list.isEmpty {
                    ContentUnavailableView("No Macs yet", systemImage: "desktopcomputer",
                                           description: Text("Open Pigeon and add a Mac first."))
                } else {
                    summary
                    status
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Pigeon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.state == .done ? "Done" : "Cancel") { model.finish() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.state == .ready, !model.macs.list.isEmpty {
                        Button("Send") { Task { await model.send() } }.bold()
                    }
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.items.prefix(4).enumerated()), id: \.offset) { _, item in
                Label(item.title, systemImage: { if case .text = item { return "text.alignleft" } else { return "doc" } }())
                    .lineLimit(1)
            }
            if model.items.count > 4 { Text("and \(model.items.count - 4) more").foregroundStyle(.secondary) }
            HStack {
                Text("To").foregroundStyle(.secondary)
                if model.macs.list.count > 1 {
                    Picker("Mac", selection: $model.target) {
                        ForEach(model.macs.list) { Text($0.name).tag(Optional($0)) }
                    }
                    .disabled(model.state != .ready)
                } else {
                    Text(model.target?.name ?? "")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    @ViewBuilder private var status: some View {
        switch model.state {
        case .loading: ProgressView()
        case .ready: EmptyView()
        case .sending(let p):
            ProgressView(value: p) { Text("Sending to \(model.target?.name ?? "")…") }
        case .done:
            Label("Sent to \(model.target?.name ?? "")", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .queued:
            Label("Big files will send when you open Pigeon", systemImage: "tray.and.arrow.up.fill").foregroundStyle(.orange)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
