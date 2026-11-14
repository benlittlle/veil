import AppKit
import SwiftUI

/// The Veil mark as a monochrome template glyph: a chat bubble with a veil draped over its top
/// half. Drawn from the same vector paths as the app icon (Branding/icon/
/// make_icon.py), so it stays crisp at menu bar size in light and dark menu bars.
enum VeilGlyph {
    enum Style { case normal, paused, attention }

    // 1024-unit artwork, y pointing down (SVG coordinates).
    private static let bubble = "M560 400 C672 400 760 486 760 596 C760 706 672 790 560 790 C530 790 502 784 476 773 L404 818 C392 825 380 815 384 802 L404 738 C376 703 360 651 360 596 C360 486 448 400 560 400 Z"
    private static let veil = "M512 300 C640 300 720 380 744 470 C756 516 772 548 808 572 C826 584 820 600 800 604 C770 610 742 600 716 588 C670 566 640 552 600 560 C548 570 512 610 456 622 C400 634 352 624 312 650 C290 664 266 658 276 636 C292 602 300 570 304 530 C312 410 392 300 512 300 Z"
    /// At menu bar size the veil sits a little higher than in the app icon, so more of the bubble shows.
    private static let veilLift: CGFloat = 50
    /// The artwork's bounds, with room for the stroke and the attention dot.
    private static let art = CGRect(x: 248, y: 205, width: 620, height: 638)

    private static var images: [String: NSImage] = [:]

    /// A template image for the status item (`size` in points). Made once per style and size.
    static func menuBarImage(_ style: Style = .normal, size: CGFloat = 18) -> NSImage {
        let key = "\(style)-\(size)"
        if let hit = images[key] { return hit }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(style, in: rect, color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Veil"
        images[key] = image
        return image
    }

    /// Draws the mark filling `rect` (a flipped context).
    static func draw(_ style: Style, in rect: CGRect, color: NSColor) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState(); defer { ctx.restoreGraphicsState() }
        let scale = min(rect.width / art.width, rect.height / art.height)
        let t = NSAffineTransform()
        t.translateX(by: rect.midX - art.midX * scale, yBy: rect.midY - art.midY * scale)
        t.scale(by: scale)
        t.concat()

        // In artwork units: about 1.4 pt of line and 0.9 pt of gap at 18 pt.
        let stroke: CGFloat = 48, gap: CGFloat = 30
        let bubblePath = path(bubble), veilPath = path(veil)
        let lift = AffineTransform(translationByX: 0, byY: -veilLift)
        veilPath.transform(using: lift)
        for p in [bubblePath, veilPath] { p.lineJoinStyle = .round; p.lineCapStyle = .round }

        // Paused: the same mark, dimmed, like an inactive menu bar item.
        let cg = ctx.cgContext
        cg.setAlpha(style == .paused ? 0.4 : 1)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { cg.endTransparencyLayer() }

        color.set()
        bubblePath.fill()
        // Cut the veil (plus a thin gap) out of the bubble, then draw the veil's outline.
        ctx.compositingOperation = .clear
        veilPath.fill()
        veilPath.lineWidth = stroke + gap * 2; veilPath.stroke()
        ctx.compositingOperation = .sourceOver
        veilPath.lineWidth = stroke; veilPath.stroke()

        if style == .attention {
            // Top right, clear of the veil's outline.
            let r: CGFloat = 62, c = CGPoint(x: 806, y: 268), ring = r + gap * 1.2
            ctx.compositingOperation = .clear
            NSBezierPath(ovalIn: CGRect(x: c.x - ring, y: c.y - ring, width: ring * 2, height: ring * 2)).fill()
            ctx.compositingOperation = .sourceOver
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
        }
    }

    /// Parses the small SVG subset used above (absolute M, L, C, Z).
    private static func path(_ d: String) -> NSBezierPath {
        let p = NSBezierPath()
        let spaced = d.replacingOccurrences(of: "([MLCZ])", with: " $1 ", options: .regularExpression)
        var tokens = spaced.split(separator: " ").map(String.init)[...]
        var command = ""
        func num() -> CGFloat { CGFloat(Double(tokens.popFirst() ?? "0") ?? 0) }
        while let tok = tokens.first {
            if Double(tok) == nil { command = tok; tokens.removeFirst() }
            switch command {
            case "M": p.move(to: CGPoint(x: num(), y: num()))
            case "L": p.line(to: CGPoint(x: num(), y: num()))
            case "C":
                let c1 = CGPoint(x: num(), y: num()), c2 = CGPoint(x: num(), y: num()), e = CGPoint(x: num(), y: num())
                p.curve(to: e, controlPoint1: c1, controlPoint2: c2)
            case "Z": p.close()
            default: tokens.removeFirst()
            }
        }
        return p
    }
}

/// The mark in SwiftUI, tinted like an SF Symbol (used on the accent tiles in the app).
struct VeilMark: View {
    var style: VeilGlyph.Style = .normal
    var body: some View {
        Image(nsImage: VeilGlyph.menuBarImage(style, size: 36)).resizable().renderingMode(.template).interpolation(.high)
    }
}

/// The app icon for the current accent, as a small tile (menu header, sidebar).
/// Falls back to the drawn mark on an accent tile when the bundle has no icons (e.g. `swift run`).
struct AppIconTile: View {
    @EnvironmentObject var model: AppModel
    var size: CGFloat
    var dimmed = false

    private static var cache: [AccentChoice: NSImage] = [:]
    static func image(for accent: AccentChoice) -> NSImage? {
        if let hit = cache[accent] { return hit }
        guard let url = accent.iconURL, let img = NSImage(contentsOf: url) else { return nil }
        cache[accent] = img
        return img
    }

    var body: some View {
        Group {
            if let img = Self.image(for: model.accent) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                VeilMark().foregroundStyle(.white).padding(size * 0.17)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0 : 1).opacity(dimmed ? 0.55 : 1)
    }
}
