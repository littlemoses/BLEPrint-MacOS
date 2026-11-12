import AppKit
import CoreImage
import CoreText
import Foundation

/// How label text looks: font, weight, size, alignment and an optional frame.
public struct TextStyle: Equatable {
    public enum Align: Int, CaseIterable, Identifiable {
        case left, center, right
        public var id: Int { rawValue }
    }

    public var family = "Arial"
    public var bold = true
    /// Font size in points (1/72 inch); nil = as large as the label allows. A size that doesn't fit is reduced.
    public var sizePt: Double?
    public var align = Align.center
    /// Frame around the label (text mode only).
    public var border = false

    public init(family: String = "Arial", bold: Bool = true, sizePt: Double? = nil, align: Align = .center,
                border: Bool = false) {
        self.family = family; self.bold = bold; self.sizePt = sizePt; self.align = align; self.border = border
    }

    /// Both printers print 8 dots per mm (203 dpi).
    public static let dotsPerPt = 8 * 25.4 / 72
    static let borderLine = 3, borderPad = 5

    func font(size: CGFloat) -> NSFont {
        let fm = NSFontManager.shared
        let traits: NSFontTraitMask = bold ? .boldFontMask : .unboldFontMask
        return fm.font(withFamily: family, traits: traits, weight: bold ? 9 : 5, size: size)
            ?? fm.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }
}

/// Label rendering: text fitted by its real ink box, and QR codes. Mirrors bleprint.py, supvan.py
/// and qrlabel.py.
public enum Render {
    /// Draw (multi-line) text at `size` points and return just its ink, or nil if blank.
    static func inkText(_ text: String, size: CGFloat, style: TextStyle) -> GrayImage? {
        let para = NSMutableParagraphStyle()
        para.alignment = [.left, .center, .right][style.align.rawValue]
        let attr = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [
            .font: style.font(size: size) as CTFont, .foregroundColor: NSColor.black, .paragraphStyle: para,
        ])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                                                               CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), nil)
        let pad = size
        let w = Int(ceil(fit.width + 2 * pad)), h = Int(ceil(fit.height + 2 * pad))
        guard w > 0, h > 0, w * h < 60_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: pad, y: pad, width: ceil(fit.width), height: ceil(fit.height)), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        guard let cg = ctx.makeImage(), let img = GrayImage(cgImage: cg), let b = img.inkBounds() else { return nil }
        return img.crop(x: b.x, y: b.y, w: b.w, h: b.h)
    }

    /// Rendering of `text` whose ink fits within maxW x maxH: at the style's size if it fits, otherwise
    /// the largest that does (font size capped at maxSize).
    public static func fittedText(_ text: String, maxW: Int, maxH: Int, maxSize: CGFloat = 400,
                                  style: TextStyle = TextStyle()) -> GrayImage? {
        guard maxW > 2, maxH > 2 else { return nil }
        var cap = maxSize
        if let pt = style.sizePt {
            cap = min(maxSize, CGFloat(pt * TextStyle.dotsPerPt))
            if let img = inkText(text, size: cap, style: style), img.width <= maxW && img.height <= maxH { return img }
        }
        guard let probe = inkText(text, size: 100, style: style) else { return nil }
        var size = min(cap, 100 * min(CGFloat(maxW) / CGFloat(probe.width), CGFloat(maxH) / CGFloat(probe.height)))
        for _ in 0..<12 {
            guard size >= 4, let img = inkText(text, size: size, style: style) else { return nil }
            if img.width <= maxW && img.height <= maxH { return img }
            size *= 0.97
        }
        return nil
    }

    /// Text label `height` dots tall and `width` long (nil = as long as the text). `hMargin` stays blank at
    /// each end, `vMargin` at top and bottom; the frame, if any, sits on those margins.
    static func textLabel(_ text: String, width: Int?, height: Int, hMargin: Int, vMargin: Int, maxSize: CGFloat,
                          style: TextStyle) -> GrayImage {
        let inset = style.border ? TextStyle.borderLine + TextStyle.borderPad : 0
        let ink = fittedText(text, maxW: width.map { $0 - 2 * (hMargin + inset) } ?? 8000,
                             maxH: height - 2 * (vMargin + inset), maxSize: maxSize, style: style)
        let w = width ?? ink.map { $0.width + 2 * (hMargin + inset) } ?? 16
        var canvas = GrayImage(width: w, height: height)
        if let ink {
            let x = [hMargin + inset, (w - ink.width) / 2, w - hMargin - inset - ink.width][style.align.rawValue]
            canvas.paste(ink, x: x, y: (height - ink.height) / 2)
        }
        if style.border {
            let l = TextStyle.borderLine, bw = w - 2 * hMargin, bh = height - 2 * vMargin
            canvas.fillRect(x: hMargin, y: vMargin, w: bw, h: l)
            canvas.fillRect(x: hMargin, y: height - vMargin - l, w: bw, h: l)
            canvas.fillRect(x: hMargin, y: vMargin, w: l, h: bh)
            canvas.fillRect(x: w - hMargin - l, y: vMargin, w: l, h: bh)
        }
        return canvas
    }

    // MARK: Nelko (TSPL): landscape canvas, rotated to head_dots wide x feed_dots tall

    /// Canvas = the 96 printable head dots (centred on the label) x the label length; text stays 6 dots
    /// inside the head and 2.25 mm from each end of the label.
    public static func nelkoText(_ text: String, headMM: Double, feedMM: Double, style: TextStyle = TextStyle()) -> GrayImage {
        textLabel(text, width: Nelko.dots(feedMM), height: Nelko.printDots(headMM), hMargin: Nelko.feedMarginDots,
                  vMargin: 6, maxSize: 200, style: style).rotatedCCW()
    }

    public static func nelkoQR(_ text: String, headMM: Double, feedMM: Double, showText: Bool,
                               style: TextStyle = TextStyle()) -> GrayImage {
        qrLabel(text, height: Nelko.printDots(headMM), width: Nelko.dots(feedMM), margin: Nelko.feedMarginDots,
                showText: showText, style: style).rotatedCCW()
    }

    // MARK: Supvan (88 dots tall, width = length along the tape)

    /// lengthMM nil = fit the label to the text, edge to edge (1 mm margin each end).
    public static func supvanText(_ text: String, lengthMM: Double?, style: TextStyle = TextStyle()) -> GrayImage {
        textLabel(text, width: lengthMM.map { max(8, Int(($0 * 8).rounded())) }, height: Supvan.printDots,
                  hMargin: 8, vMargin: 1, maxSize: 400, style: style)
    }

    public static func supvanQR(_ text: String, lengthMM: Double?, showText: Bool, style: TextStyle = TextStyle()) -> GrayImage {
        qrLabel(text, height: Supvan.printDots, width: lengthMM.map { Int(($0 * 8).rounded()) }, showText: showText,
                style: style)
    }

    // MARK: QR

    static let ciContext = CIContext(options: [.useSoftwareRenderer: true])

    /// QR modules (true = dark), no quiet zone, error correction L.
    public static func qrMatrix(_ text: String) -> [[Bool]]? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data((text.isEmpty ? " " : text).utf8), forKey: "inputMessage")
        f.setValue("L", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage, let cg = ciContext.createCGImage(out, from: out.extent),
              let img = GrayImage(cgImage: cg), let b = img.inkBounds() else { return nil }
        let n = max(b.w, b.h)                       // the finder patterns span the whole symbol
        return (0..<n).map { y in (0..<n).map { x in img.isDark(b.x + x, b.y + y) } }
    }

    /// Square QR exactly `height` dots tall; modules are spread over the full height.
    public static func qrImage(_ text: String, height: Int) -> GrayImage {
        var img = GrayImage(width: height, height: height)
        guard let m = qrMatrix(text) else { return img }
        let n = m.count
        let edge = (0...n).map { Int((Double($0) * Double(height) / Double(n)).rounded(.toNearestOrEven)) }
        for y in 0..<n { for x in 0..<n where m[y][x] {
            img.fillRect(x: edge[x], y: edge[y], w: edge[x + 1] - edge[x], h: edge[y + 1] - edge[y])
        } }
        return img
    }

    /// QR on the left at full height, text on the right. width nil = fit to content.
    public static func qrLabel(_ text: String, height: Int, width: Int?, margin: Int = 8, gap: Int = 10,
                               showText: Bool = true, style: TextStyle = TextStyle()) -> GrayImage {
        let t = text.trimmingCharacters(in: .newlines)
        let qr = qrImage(t, height: height)
        var ink: GrayImage?
        if showText && !t.isEmpty {
            let room = width.map { $0 - 2 * margin - qr.width - gap } ?? 8000
            if room > 16 { ink = fittedText(t, maxW: room, maxH: height - 4, style: style) }
        }
        let content = qr.width + (ink.map { gap + $0.width } ?? 0)
        let w = width.map { max($0, 8) } ?? content + 2 * margin
        var canvas = GrayImage(width: w, height: height)
        let x0 = (w - content) / 2
        canvas.paste(qr, x: x0, y: (height - qr.height) / 2)
        if let ink { canvas.paste(ink, x: x0 + qr.width + gap, y: (height - ink.height) / 2) }
        return canvas
    }
}
