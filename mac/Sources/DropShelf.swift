import AppKit
import os

/// `log stream --predicate 'subsystem == "net.wesyarber.pigeon"'` shows these.
let dragLog = Logger(subsystem: "net.wesyarber.pigeon", category: "drag")
import SwiftUI
import UniformTypeIdentifiers

// Dragging a file onto the menu bar itself doesn't work well: touching the top
// edge mid-drag opens Mission Control's Spaces bar. Instead, while you drag files
// toward the top of the screen, a small shelf slides out just under the pigeon
// with one tile per Mac. Drop there and it's sent.
//
// The same mouse watching keeps the popover open when a click outside it starts
// a file drag (so you can open Pigeon, then drag files in from Finder).

extension AppDelegate {
    /// Pasteboard types that count as "something we can send" being dragged.
    static let sendableDragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .png, .tiff]

    var panelShown: Bool { popover.isShown || (fallbackPanel?.isVisible ?? false) }

    func startDragWatch() {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        // Global monitors see mouse events going to other apps (Finder etc.).
        // Mouse monitors need no Accessibility permission.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseDragged, .leftMouseUp], handler: { [weak self] e in
            let type = e.type
            MainActor.assumeIsolated { self?.watchMouse(type) }
        }) { eventMonitors.append(m) }
        // Our own windows: mouse-up ends a drag that dropped on us; Escape closes the popover.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown], handler: { [weak self] e in
            let type = e.type, isEscape = e.type == .keyDown && e.keyCode == 53
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                if isEscape, self.panelShown { self.closePopover(); return true }
                if type == .leftMouseUp { self.dragEnded() }
                return false
            }
            return consumed ? nil : e
        }) { eventMonitors.append(m) }
        startDragPoll()
    }

    /// Drags that start in the Dock (a folder stack such as Downloads) don't
    /// reach the event monitors above, and the Dock doesn't use the shared drag
    /// pasteboard either, so neither reveals them. What does: while the Dock is
    /// dragging something it shows the drag image in a window of its own at the
    /// system's dragging level. The pasteboard check also catches other apps'
    /// file drags that the monitors miss. While the button is up this is a single
    /// cheap button-state read.
    private func startDragPoll() {
        var wasDown = false
        var pressPoint = NSPoint.zero
        var ticks = 0
        dragCountAtRelease = NSPasteboard(name: .drag).changeCount
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let down = NSEvent.pressedMouseButtons & 1 != 0
                defer { wasDown = down }
                let mouse = NSEvent.mouseLocation
                if down {
                    let pb = NSPasteboard(name: .drag)
                    if !wasDown { pressPoint = mouse; ticks = 0 }
                    ticks += 1
                    if !self.fileDragActive {
                        // Only drags begun during this press count (the pasteboard
                        // can't change between a release and the next press).
                        if pb.changeCount != self.dragCountAtRelease, pb.changeCount != self.dragChangeCount {
                            self.dragChangeCount = pb.changeCount
                            self.fileDragActive = pb.types?.contains(where: Self.sendableDragTypes.contains) ?? false
                            dragLog.notice("poll: pasteboard drag sendable=\(self.fileDragActive)")
                        } else if ticks % 2 == 0, hypot(mouse.x - pressPoint.x, mouse.y - pressPoint.y) > 20,
                                  Self.dockIsDragging() {
                            self.fileDragActive = true
                            dragLog.notice("poll: drag out of the Dock")
                        }
                        if self.fileDragActive { self.outsideClickPending = false }
                    }
                    if self.fileDragActive { self.updateShelf(at: mouse) }
                } else if wasDown {
                    DispatchQueue.main.async { self.dragEnded() }
                    // A drop arrives around the release; sendDropped compares against
                    // this baseline, so only move it once the drop has been handled.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if NSEvent.pressedMouseButtons & 1 == 0 { self.dragCountAtRelease = NSPasteboard(name: .drag).changeCount }
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common) // keep running during drags and menu tracking
    }

    /// Whether the Dock is in the middle of a drag: it has a window up at the
    /// dragging level (holding the drag image) only while one is going on.
    static func dockIsDragging() -> Bool {
        let level = Int(CGWindowLevelForKey(.draggingWindow))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowOwnerName as String] as? String) == "Dock" && ($0[kCGWindowLayer as String] as? Int) == level }
    }

    private func watchMouse(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            // A click outside the popover closes it, unless it turns into a file
            // drag or "keep open" is on (so you can dig through Finder or the
            // Dock's Downloads stack first).
            outsideClickPending = panelShown
        case .rightMouseDown:
            if panelShown { closePopover() }
        case .leftMouseDragged:
            let pb = NSPasteboard(name: .drag)
            if pb.changeCount != dragChangeCount {
                // A new drag-and-drop session started (window moves and text selection don't touch this pasteboard).
                dragChangeCount = pb.changeCount
                fileDragActive = pb.types?.contains(where: Self.sendableDragTypes.contains) ?? false
                if fileDragActive { outsideClickPending = false }
            }
            if fileDragActive { updateShelf(at: NSEvent.mouseLocation) }
        case .leftMouseUp:
            if outsideClickPending && !fileDragActive && !keepPopoverOpen { closePopover() }
            outsideClickPending = false
            dragEnded()
        default:
            break
        }
    }

    private func dragEnded() {
        guard fileDragActive || (dropShelf?.isVisible ?? false) else { return }
        fileDragActive = false
        // Give a drop on the shelf a moment to be delivered before it goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.fileDragActive else { return }
            self.hideShelf()
        }
    }

    // MARK: Shelf

    private func updateShelf(at p: NSPoint) {
        guard dropShelfOn, !destinations.isEmpty, !panelShown else {
            dragLog.debug("shelf skipped: on=\(self.dropShelfOn) macs=\(self.destinations.count) panelShown=\(self.panelShown)")
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main!
        let distanceFromTop = screen.frame.maxY - p.y
        if distanceFromTop < 220, dropShelf?.isVisible != true { dragLog.debug("shelf: showing at y=\(p.y)") }
        if distanceFromTop < 220 {
            showShelf(on: screen, pointerX: p.x)
        } else if distanceFromTop > 420 {
            hideShelf() // dragged back down: get out of the way
        }
    }

    private func showShelf(on screen: NSScreen, pointerX: CGFloat) {
        if let s = dropShelf, s.isVisible, s.screen == screen { return }
        let width = min(max(240, CGFloat(destinations.count) * 150 + 24), 640)
        let height: CGFloat = 132
        let panel = dropShelf ?? {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            let host = NSHostingController(rootView: DropShelfView(app: self))
            host.sizingOptions = []
            p.contentViewController = host
            dropShelf = p
            return p
        }()
        panel.setContentSize(NSSize(width: width, height: height))

        // Centre under the pigeon if macOS is showing it on this screen, else under the pointer.
        var midX = pointerX
        if let bw = statusItem.button?.window, bw.isVisible, bw.screen == screen { midX = bw.frame.midX }
        let visible = screen.visibleFrame
        let x = min(max(midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        let top = visible.maxY - 6 // just under the menu bar
        panel.setFrameOrigin(NSPoint(x: x, y: top - height + 10))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(NSPoint(x: x, y: top - height))
        }
    }

    func hideShelf() {
        guard let panel = dropShelf, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }

    // MARK: Drops (shared by the shelf and the popover)

    func sendDropped(_ providers: [NSItemProvider], to dest: Destination?) {
        // Read the system drag pasteboard directly: it has Finder's real file
        // references. (SwiftUI's providers for a picture only exposed the image
        // data, so the file arrived renamed and re-encoded.) But only if this
        // drag actually used it: the Dock doesn't, and then the pasteboard still
        // holds the previous drag, which would send the wrong thing.
        let pb = NSPasteboard(name: .drag)
        if pb.changeCount != dragCountAtRelease {
            let dragged = outgoing(from: pb)
            if !dragged.isEmpty { return send(dragged, to: dest) }
        }
        for p in providers {
            // A dragged file should arrive as itself (name and bytes), so try the
            // file reference first; Finder also offers image data for pictures.
            guard p.canLoadObject(ofClass: URL.self) else { sendDroppedContent(p, to: dest, link: nil); continue }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                Task { @MainActor in
                    if let url, url.isFileURL { self.send([.file(url)], to: dest) }
                    else { self.sendDroppedContent(p, to: dest, link: url) }
                }
            }
        }
    }

    /// Non-file drops: an image, else text, else the dragged web link itself.
    /// Drops that didn't come with a file reference: the Dock's legacy list of
    /// paths, else the item's own data sent as-is (a JPEG stays a JPEG, under its
    /// real name; nothing is re-encoded), else text, else the dragged web link.
    /// The name travels inside the encrypted envelope, and the receiving Mac
    /// sanitises it before saving.
    private func sendDroppedContent(_ p: NSItemProvider, to dest: Destination?, link: URL?) {
        let types = p.registeredTypeIdentifiers
        dragLog.notice("drop: types=\(types.joined(separator: ","), privacy: .public)")
        if types.contains("NSFilenamesPboardType") {
            p.loadDataRepresentation(forTypeIdentifier: "NSFilenamesPboardType") { data, _ in
                let paths = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String] } ?? []
                Task { @MainActor in
                    if paths.isEmpty { self.sendDroppedData(p, types: types, to: dest, link: link) }
                    else { self.send(paths.map { .file(URL(fileURLWithPath: $0)) }, to: dest) }
                }
            }
            return
        }
        sendDroppedData(p, types: types, to: dest, link: link)
    }

    private func sendDroppedData(_ p: NSItemProvider, types: [String], to dest: Destination?, link: URL?) {
        // Types are listed best first, so the first data type is the original
        // (e.g. public.jpeg before any converted public.png/public.tiff).
        if let t = types.first(where: { id in
            guard let u = UTType(id), u.conforms(to: .data) else { return false }
            return !u.conforms(to: .text) && !u.conforms(to: .url)
        }) {
            let type = UTType(t)
            let suggested = p.suggestedName
            _ = p.loadFileRepresentation(forTypeIdentifier: t) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { return }
                let ext = type?.preferredFilenameExtension ?? url.pathExtension
                var name = suggested ?? url.deletingPathExtension().lastPathComponent
                if name.isEmpty { name = "file" }
                if !ext.isEmpty, (name as NSString).pathExtension.lowercased() != ext.lowercased(),
                   UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: type ?? .data) != true {
                    name += "." + ext
                }
                let mime = type?.preferredMIMEType ?? "application/octet-stream"
                Task { @MainActor in self.send([.data(data, name: name, type: mime)], to: dest) }
            }
        } else if p.canLoadObject(ofClass: String.self) {
            _ = p.loadObject(ofClass: String.self) { s, _ in
                guard let s, !s.isEmpty else { return }
                Task { @MainActor in self.send([.text(s)], to: dest) }
            }
        } else if let link {
            send([.text(link.absoluteString)], to: dest)
        }
    }
}

// MARK: - Shelf view

struct DropShelfView: View {
    @ObservedObject var app: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16, height: 16)
                Text("Drop to send").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(app.destinations) { ShelfTile(dest: $0, app: app) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct ShelfTile: View {
    let dest: Destination
    @ObservedObject var app: AppDelegate
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: targeted ? "arrow.down.circle.fill" : "desktopcomputer")
                .font(.system(size: 22))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text(dest.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(targeted ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35)))
        .scaleEffect(targeted ? 1.03 : 1)
        .animation(.easeOut(duration: 0.12), value: targeted)
        .onDrop(of: [.fileURL, .image, .data, .utf8PlainText, .plainText], isTargeted: $targeted) { providers in
            app.sendDropped(providers, to: dest)
            app.hideShelf()
            return true
        }
    }
}

/// Native translucent background (SwiftUI materials don't blur behind a borderless panel).
private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
