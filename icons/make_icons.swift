// Generates every Pigeon icon from one drawing (the folded-paper pigeon):
//   swift icons/make_icons.swift <out dir>
// Writes AppIcon.icns, AppIcon-iOS.png, MenuBarIcon(+Badge)[@2x].png, and web icons (icon.svg + PNGs).
import AppKit
import Foundation

// MARK: - Artwork (128×128 units, y down): a folded-paper pigeon on an indigo tile.

struct Facet { let points: [CGPoint]; let hex: String }

func facet(_ pts: [Double], _ hex: String) -> Facet {
    Facet(points: stride(from: 0, to: pts.count, by: 2).map { CGPoint(x: pts[$0], y: pts[$0 + 1]) }, hex: hex)
}

let tileHex = "#3C3489"
/// Drawn in order: the beak first, so its base tucks under the head fold.
let beak = facet([96, 39, 115, 46, 97, 53], "#EF9F27")
let tail = facet([12, 72, 40, 62, 40, 78], "#AFA9EC")
let back = facet([38, 62, 78, 50, 92, 72, 40, 78], "#EEEDFE")
let wing = facet([40, 64, 72, 36, 84, 70], "#FFFFFF")
let belly = facet([40, 78, 92, 72, 70, 98], "#CECBF6")
let head = facet([78, 50, 92, 34, 103, 46, 92, 72], "#FFFFFF")
let neck = facet([92, 72, 103, 46, 96, 74], "#CECBF6")
let facets = [beak, tail, back, wing, belly, head, neck]
/// The silhouette's bounds, for fitting it into the menu bar.
let birdBounds = CGRect(x: 12, y: 34, width: 103, height: 64)

func color(_ hex: String) -> CGColor {
    let v = Int(hex.dropFirst(), radix: 16)!
    return CGColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func path(_ f: Facet) -> CGPath {
    let p = CGMutablePath()
    p.addLines(between: f.points)
    p.closeSubpath()
    return p
}

// MARK: - Rendering

func bitmap(_ px: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        .retagging(with: .sRGB)! // draw in sRGB so the hex colours come out exact
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    // Flip to y-down so the artwork coordinates match SVG.
    cg.translateBy(x: 0, y: CGFloat(px)); cg.scaleBy(x: 1, y: -1)
    draw(cg)
    NSGraphicsContext.current = nil
    return rep
}

func save(_ rep: NSBitmapImageRep, _ url: URL) {
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// Full-colour icon. `inset` is the fraction of empty margin (macOS icons use ~10%; web/iOS use 0).
func drawAppIcon(_ cg: CGContext, size: CGFloat, inset: CGFloat, rounded: Bool) {
    let m = size * inset, s = size - 2 * m
    let tile = CGRect(x: m, y: m, width: s, height: s)
    let tilePath = rounded ? CGPath(roundedRect: tile, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
                           : CGPath(rect: tile, transform: nil)
    if rounded { // macOS-style drop shadow under the tile
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
        cg.addPath(tilePath); cg.setFillColor(color(tileHex)); cg.fillPath()
        cg.restoreGState()
    }
    cg.saveGState()
    cg.addPath(tilePath); cg.clip()
    cg.setFillColor(color(tileHex)); cg.fill(tile)
    cg.translateBy(x: m, y: m)
    cg.scaleBy(x: s / 128, y: s / 128)
    for f in facets { cg.addPath(path(f)); cg.setFillColor(color(f.hex)); cg.fillPath() }
    cg.restoreGState()
}

/// Monochrome template glyph for the menu bar (black on transparent; macOS tints it).
/// The update badge sits bottom-right, where the bird leaves room.
func drawMenuGlyph(_ cg: CGContext, size: CGFloat, badge: Bool) {
    cg.saveGState()
    let k = size * 0.98 / birdBounds.width
    cg.translateBy(x: (size - birdBounds.width * k) / 2 - birdBounds.minX * k,
                   y: (size - birdBounds.height * k) / 2 - birdBounds.minY * k)
    cg.scaleBy(x: k, y: k)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    cg.setFillColor(.black)
    for f in facets where f.hex != neck.hex || f.points != neck.points { cg.addPath(path(f)); cg.fillPath() }
    // a thin cut around the wing so the fold still reads at 18 pt
    cg.setBlendMode(.clear); cg.setLineWidth(5); cg.setLineJoin(.round)
    cg.addPath(path(wing)); cg.strokePath()
    cg.setBlendMode(.normal)
    cg.addPath(path(wing)); cg.fillPath()
    cg.endTransparencyLayer()
    cg.restoreGState()
    if badge {
        let r = size * 0.13
        let c = CGPoint(x: size - r - size * 0.03, y: size - r - size * 0.05)
        // knock out a ring so the dot reads separately from the bird
        cg.setBlendMode(.clear)
        cg.fillEllipse(in: CGRect(x: c.x - r * 1.45, y: c.y - r * 1.45, width: r * 2.9, height: r * 2.9))
        cg.setBlendMode(.normal)
        cg.setFillColor(.black)
        cg.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
}

// MARK: - SVG export (web icon, same artwork)

func svgIcon() -> String {
    let polys = facets.map { f in
        "<polygon points=\"\(f.points.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " "))\" fill=\"\(f.hex)\"/>"
    }.joined()
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">\
    <rect width="128" height="128" rx="29" fill="\(tileHex)"/>\(polys)</svg>

    """
}

// MARK: - Main

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icons/out", isDirectory: true)
let fm = FileManager.default
try? fm.removeItem(at: out)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let web = out.appendingPathComponent("web", isDirectory: true)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
try! fm.createDirectory(at: web, withIntermediateDirectories: true)

// macOS app icon (Big Sur grid: ~10% margin, rounded tile, shadow)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = bitmap(px) { drawAppIcon($0, size: CGFloat(px), inset: 0.098, rounded: true) }
        save(rep, iconset.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run(); iconutil.waitUntilExit()

// Menu bar template glyphs (18pt)
for (name, badge) in [("MenuBarIcon", false), ("MenuBarIconBadge", true)] {
    save(bitmap(18) { drawMenuGlyph($0, size: 18, badge: badge) }, out.appendingPathComponent("\(name).png"))
    save(bitmap(36) { drawMenuGlyph($0, size: 36, badge: badge) }, out.appendingPathComponent("\(name)@2x.png"))
}

// Web: iOS home screen PNG (full-bleed square; iOS rounds the corners) and the SVG everything else uses
save(bitmap(180) { drawAppIcon($0, size: 180, inset: 0, rounded: false) }, web.appendingPathComponent("apple-touch-icon.png"))
try! svgIcon().write(to: web.appendingPathComponent("icon.svg"), atomically: true, encoding: .utf8)

// iPhone app icon: one full-bleed 1024 square (iOS rounds the corners itself)
save(bitmap(1024) { drawAppIcon($0, size: 1024, inset: 0, rounded: false) }, out.appendingPathComponent("AppIcon-iOS.png"))

// Preview sheet for review
let sheet = bitmap(1200) { cg in
    cg.setFillColor(CGColor(gray: 0.93, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 1200, height: 600))
    cg.setFillColor(CGColor(gray: 0.12, alpha: 1)); cg.fill(CGRect(x: 0, y: 600, width: 1200, height: 600))
    cg.saveGState(); cg.translateBy(x: 40, y: 40); drawAppIcon(cg, size: 520, inset: 0.098, rounded: true); cg.restoreGState()
    var x: CGFloat = 600
    for s in [256.0, 128.0, 64.0, 32.0, 16.0] as [CGFloat] {
        cg.saveGState(); cg.translateBy(x: x, y: 300 - s / 2); drawAppIcon(cg, size: s, inset: 0.098, rounded: true); cg.restoreGState()
        x += s + 16
    }
    // menu bar glyphs on light and dark strips, at 1x-ish and 4x for detail
    for (row, dark) in [(0, false), (1, true)] {
        let y = CGFloat(640 + row * 270)
        cg.setFillColor(dark ? CGColor(gray: 0.2, alpha: 1) : CGColor(gray: 0.86, alpha: 1))
        cg.fill(CGRect(x: 40, y: y, width: 1120, height: 240))
        for (i, badge) in [false, true].enumerated() {
            cg.saveGState()
            cg.translateBy(x: 80 + CGFloat(i) * 260, y: y + 220); cg.scaleBy(x: 1, y: -1);
            let layer = bitmap(200) { drawMenuGlyph($0, size: 200, badge: badge) }
            let img = layer.cgImage!
            cg.clip(to: CGRect(x: 0, y: 0, width: 200, height: 200), mask: img)
            cg.setFillColor(dark ? .white : .black); cg.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            cg.restoreGState()
            cg.saveGState()
            cg.translateBy(x: 640 + CGFloat(i) * 120, y: y + 136); cg.scaleBy(x: 1, y: -1)
            let small = bitmap(36) { drawMenuGlyph($0, size: 36, badge: badge) }.cgImage!
            cg.clip(to: CGRect(x: 0, y: 0, width: 36, height: 36), mask: small)
            cg.setFillColor(dark ? .white : .black); cg.fill(CGRect(x: 0, y: 0, width: 36, height: 36))
            cg.restoreGState()
        }
    }
}
save(sheet, out.appendingPathComponent("preview.png"))
print("wrote icons to \(out.path)")
