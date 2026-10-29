import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import CoreGraphics
import CoreText
import ImageIO

/// RTF and PDF renderers plus shared image helpers.
enum RichExport {
    // MARK: Palette (Meteora, light)

    struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
        init(_ hex: Int) {
            r = CGFloat((hex >> 16) & 0xFF) / 255
            g = CGFloat((hex >> 8) & 0xFF) / 255
            b = CGFloat(hex & 0xFF) / 255
        }
        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        #if canImport(AppKit)
        var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
        #else
        var nsColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }
        #endif
    }

    static let ink = RGB(0x16181B)
    static let secondary = RGB(0x5B6068)
    static let accent = RGB(0x33506B)
    static let timecode = RGB(0x8A8F96)
    static let hairline = RGB(0xD9D7D2)

    // MARK: Images

    /// Downscales to at most `maxWidth` pixels wide (aspect kept, opaque).
    static func scaled(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard image.width > maxWidth, image.width > 0, image.height > 0, maxWidth > 0 else { return image }
        let w = maxWidth
        let h = max(1, Int((Double(image.height) * Double(maxWidth) / Double(image.width)).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// JPEG-recompressed copy (smaller PDFs), falling back to the original.
    static func jpegImage(_ image: CGImage, maxWidth: Int, quality: Double) -> CGImage {
        let small = scaled(image, maxWidth: maxWidth)
        guard let data = ReportExporter.jpegData(small, quality: quality),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return small }
        return decoded
    }

    // MARK: RTF

    static func rtfFont(_ size: CGFloat, bold: Bool = false) -> PlatformFont {
        let names = bold ? ["HelveticaNeue-Medium", "Helvetica-Bold"] : ["HelveticaNeue", "Helvetica"]
        for name in names {
            if let f = PlatformFont(name: name, size: size) { return f }
        }
        return PlatformFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    static func rtfData(_ doc: ExportDocument) throws -> Data {
        let out = NSMutableAttributedString()

        func paragraphStyle(before: CGFloat, after: CGFloat) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacingBefore = before
            p.paragraphSpacing = after
            p.lineHeightMultiple = 1.15
            return p
        }

        func append(_ text: String, font: PlatformFont, color: PlatformColor, style: NSParagraphStyle) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            out.append(NSAttributedString(string: text, attributes: attrs))
        }

        let body = paragraphStyle(before: 0, after: 9)
        append(doc.title + "\n", font: rtfFont(20, bold: true), color: ink.nsColor, style: paragraphStyle(before: 0, after: 6))
        append(doc.summary + "\n", font: rtfFont(10), color: secondary.nsColor, style: paragraphStyle(before: 0, after: 4))
        append(ExportDocument.note + "\n", font: rtfFont(9), color: secondary.nsColor, style: paragraphStyle(before: 0, after: 16))

        for block in doc.blocks {
            switch block {
            case .speech(let i):
                for run in doc.runs(doc.paragraphs[i]) {
                    switch run.kind {
                    case .time: append(run.text + "  ", font: rtfFont(9), color: timecode.nsColor, style: body)
                    case .speaker: append(run.text + ": ", font: rtfFont(11.5, bold: true), color: ink.nsColor, style: body)
                    case .text: append(run.text, font: rtfFont(11.5), color: ink.nsColor, style: body)
                    }
                }
                append("\n", font: rtfFont(11.5), color: ink.nsColor, style: body)
            case .frame(let i):
                let f = doc.frames[i]
                append(doc.frameCaption(f) + "\n", font: rtfFont(11, bold: true), color: accent.nsColor,
                       style: paragraphStyle(before: 10, after: 4))
                let text = doc.frameText(f)
                if !text.isEmpty {
                    // Line breaks inside OCR text stay inside one paragraph.
                    let lines = text.replacingOccurrences(of: "\n", with: "\u{2028}")
                    append(lines + "\n", font: rtfFont(9.5), color: secondary.nsColor, style: paragraphStyle(before: 0, after: 12))
                }
            }
        }

        let range = NSRange(location: 0, length: out.length)
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf,
        ]
        #if canImport(AppKit)
        attributes[.title] = doc.title
        #endif
        return try out.data(from: range, documentAttributes: attributes)
    }

    // MARK: PDF

    static func ctFont(_ size: CGFloat, bold: Bool = false) -> CTFont {
        PlatformFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular) as CTFont
    }

    static func lineHeightStyle(_ multiple: CGFloat) -> CTParagraphStyle {
        withUnsafePointer(to: multiple) { ptr in
            var setting = CTParagraphStyleSetting(spec: .lineHeightMultiple, valueSize: MemoryLayout<CGFloat>.size, value: ptr)
            return CTParagraphStyleCreate(&setting, 1)
        }
    }

    static func attributed(_ text: String, font: CTFont, color: CGColor) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return NSAttributedString(string: text, attributes: attrs)
    }

    static func withLineHeight(_ s: NSAttributedString, _ multiple: CGFloat) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        m.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String),
                       value: lineHeightStyle(multiple), range: NSRange(location: 0, length: m.length))
        return m
    }

    /// Flows text and pictures down A4 portrait pages.
    final class PDFLayout {
        let ctx: CGContext
        let page: CGRect
        let margin: CGFloat = 56
        let footerSpace: CGFloat = 24
        private(set) var y: CGFloat = 0
        private(set) var pageNumber = 0
        private var isOpen = false

        init(ctx: CGContext, page: CGRect) {
            self.ctx = ctx
            self.page = page
        }

        var width: CGFloat { page.width - margin * 2 }
        var top: CGFloat { page.height - margin }
        var bottom: CGFloat { margin + footerSpace }

        func newPage() {
            if isOpen { ctx.endPDFPage() }
            ctx.beginPDFPage(nil)
            isOpen = true
            pageNumber += 1
            y = top
            drawPageNumber()
        }

        func finish() {
            if isOpen { ctx.endPDFPage() }
            isOpen = false
            ctx.closePDF()
        }

        func gap(_ h: CGFloat) {
            if !isOpen { newPage() }
            y -= h
        }

        /// Starts a new page unless `h` points still fit.
        func ensure(_ h: CGFloat) {
            if !isOpen || (y - h < bottom && y < top - 0.5) { newPage() }
        }

        private func drawPageNumber() {
            let s = RichExport.attributed("\(pageNumber)", font: RichExport.ctFont(9), color: RichExport.secondary.cgColor)
            let line = CTLineCreateWithAttributedString(s)
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: page.midX - w / 2, y: margin - 20)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        /// Draws text at the cursor, continuing on new pages as needed.
        func text(_ s: NSAttributedString) {
            let length = s.length
            guard length > 0 else { return }
            if !isOpen { newPage() }
            let framesetter = CTFramesetterCreateWithAttributedString(s)
            var location = 0
            var emptyPages = 0
            while location < length {
                let available = y - bottom
                if available < 16 { newPage(); continue }
                let rect = CGRect(x: margin, y: bottom, width: width, height: available)
                let path = CGPath(rect: rect, transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length <= 0 {
                    // Nothing fits even on an empty page: give up rather than loop.
                    if y >= top - 0.5 { emptyPages += 1 }
                    if emptyPages > 1 { return }
                    newPage()
                    continue
                }
                ctx.saveGState()
                ctx.textMatrix = .identity
                CTFrameDraw(frame, ctx)
                ctx.restoreGState()
                y = rect.minY + PDFLayout.textBottom(frame)
                location += visible.length
                if location < length { newPage() }
            }
        }

        /// Lowest point of the drawn text, relative to the frame's path origin.
        static func textBottom(_ frame: CTFrame) -> CGFloat {
            guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return 0 }
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            var descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(lines[lines.count - 1], nil, &descent, nil)
            return origins[lines.count - 1].y - descent
        }

        /// Size of a picture scaled to the text column (never taller than `maxHeight`).
        func pictureSize(_ image: CGImage, maxHeight: CGFloat) -> CGSize {
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            guard iw > 0, ih > 0 else { return .zero }
            var w = width
            var h = w * ih / iw
            let cap = min(maxHeight, top - bottom)
            if h > cap {
                h = cap
                w = h * iw / ih
            }
            return CGSize(width: w, height: h)
        }

        func picture(_ image: CGImage, size: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            ensure(size.height)
            let r = CGRect(x: margin, y: y - size.height, width: size.width, height: size.height)
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.draw(image, in: r)
            ctx.setStrokeColor(RichExport.hairline.cgColor)
            ctx.setLineWidth(0.5)
            ctx.stroke(r)
            ctx.restoreGState()
            y -= size.height
        }
    }

    static func pdfData(_ doc: ExportDocument) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89) // A4 portrait, points
        let data = NSMutableData()
        var box = page
        let info: [CFString: Any] = [kCGPDFContextTitle: doc.title, kCGPDFContextCreator: "Meteora"]
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary) else { return Data() }
        let layout = PDFLayout(ctx: ctx, page: page)
        layout.newPage()

        layout.text(withLineHeight(attributed(doc.title, font: ctFont(20, bold: true), color: ink.cgColor), 1.1))
        layout.gap(6)
        layout.text(withLineHeight(attributed(doc.summary, font: ctFont(9.5), color: secondary.cgColor), 1.2))
        layout.gap(3)
        layout.text(withLineHeight(attributed(ExportDocument.note, font: ctFont(8.5), color: secondary.cgColor), 1.2))
        layout.gap(18)

        let bodyFont = ctFont(10.5)
        let boldFont = ctFont(10.5, bold: true)
        let timeFont = ctFont(8.5)
        for block in doc.blocks {
            switch block {
            case .speech(let i):
                let m = NSMutableAttributedString()
                for run in doc.runs(doc.paragraphs[i]) {
                    switch run.kind {
                    case .time: m.append(attributed(run.text + "  ", font: timeFont, color: timecode.cgColor))
                    case .speaker: m.append(attributed(run.text + ": ", font: boldFont, color: ink.cgColor))
                    case .text: m.append(attributed(run.text, font: bodyFont, color: ink.cgColor))
                    }
                }
                layout.text(withLineHeight(m, 1.3))
                layout.gap(8)
            case .frame(let i):
                let f = doc.frames[i]
                let image = jpegImage(f.image, maxWidth: 1600, quality: 0.82)
                let size = layout.pictureSize(image, maxHeight: 420)
                layout.gap(4)
                layout.ensure(size.height + 22) // keep the caption with its picture
                layout.text(attributed(doc.frameCaption(f), font: ctFont(9.5, bold: true), color: accent.cgColor))
                layout.gap(5)
                layout.picture(image, size: size)
                let text = doc.frameText(f)
                if !text.isEmpty {
                    layout.gap(6)
                    layout.text(withLineHeight(attributed(text, font: ctFont(8.5), color: secondary.cgColor), 1.25))
                }
                layout.gap(16)
            }
        }
        layout.finish()
        return data as Data
    }
}
