import Foundation
import CoreGraphics

// MARK: - CRC-32 (IEEE 802.3, as used by ZIP)

enum CRC32 {
    static let table: [UInt32] = (0 ..< 256).map { (i: Int) -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 {
            c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        let t = table
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = t[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - ZIP (stored entries only)

/// Minimal ZIP writer: entries are stored without compression (method 0),
/// names are UTF-8 (general purpose flag bit 11). Enough for OOXML packages.
struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count = 0
    private let dosTime: UInt16
    private let dosDate: UInt16

    init(date: Date = Date()) {
        let calendar = Calendar(identifier: .gregorian)
        let c = calendar.dateComponents(in: TimeZone.current, from: date)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let month = c.month ?? 1
        let day = c.day ?? 1
        let hour = c.hour ?? 0
        let minute = c.minute ?? 0
        let second = c.second ?? 0
        dosDate = UInt16(truncatingIfNeeded: (year << 9) | (month << 5) | day)
        dosTime = UInt16(truncatingIfNeeded: (hour << 11) | (minute << 5) | (second / 2))
    }

    mutating func add(_ name: String, _ data: Data) throws {
        let nameData = Data(name.utf8)
        guard !nameData.isEmpty, nameData.count <= 0xFFFF, count < 0xFFFF,
              data.count < 0xFFFF_FFFF, body.count + data.count + nameData.count + 30 < 0xFFFF_FFFF else {
            throw ExportError.tooLarge
        }
        let crc = CRC32.checksum(data)
        let size = UInt32(data.count)
        let offset = UInt32(body.count)

        body.appendU32(0x0403_4B50) // local file header
        body.appendU16(20) // version needed to extract (2.0)
        body.appendU16(0x0800) // flags: UTF-8 names
        body.appendU16(0) // method: stored
        body.appendU16(dosTime)
        body.appendU16(dosDate)
        body.appendU32(crc)
        body.appendU32(size) // compressed size
        body.appendU32(size) // uncompressed size
        body.appendU16(UInt16(nameData.count))
        body.appendU16(0) // extra field length
        body.append(nameData)
        body.append(data)

        directory.appendU32(0x0201_4B50) // central directory header
        directory.appendU16(20) // version made by
        directory.appendU16(20) // version needed
        directory.appendU16(0x0800)
        directory.appendU16(0)
        directory.appendU16(dosTime)
        directory.appendU16(dosDate)
        directory.appendU32(crc)
        directory.appendU32(size)
        directory.appendU32(size)
        directory.appendU16(UInt16(nameData.count))
        directory.appendU16(0) // extra
        directory.appendU16(0) // comment
        directory.appendU16(0) // disk number start
        directory.appendU16(0) // internal attributes
        directory.appendU32(0) // external attributes
        directory.appendU32(offset)
        directory.append(nameData)
        count += 1
    }

    func finish() throws -> Data {
        guard body.count + directory.count + 22 < 0xFFFF_FFFF else { throw ExportError.tooLarge }
        var out = body
        out.append(directory)
        out.appendU32(0x0605_4B50) // end of central directory
        out.appendU16(0) // this disk
        out.appendU16(0) // disk with the central directory
        out.appendU16(UInt16(count))
        out.appendU16(UInt16(count))
        out.appendU32(UInt32(directory.count))
        out.appendU32(UInt32(body.count))
        out.appendU16(0) // comment length
        return out
    }
}

extension Data {
    mutating func appendU16(_ v: UInt16) {
        append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)])
    }

    mutating func appendU32(_ v: UInt32) {
        append(contentsOf: [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
                            UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)])
    }
}

// MARK: - Word (.docx)

/// Hand-written WordprocessingML: NSAttributedString's Office export drops
/// pictures, so the package is assembled here.
enum DocxExport {
    // A4 with 1-inch margins: text column 9026 twips = 6.27 in.
    static let pageWidthTwips = 11906
    static let pageHeightTwips = 16838
    static let marginTwips = 1440
    static let emuPerTwip = 635
    static var textWidthEMU: Int { (pageWidthTwips - 2 * marginTwips) * emuPerTwip }
    static let maxPictureHeightEMU = 8 * 914_400

    /// XML 1.0 text/attribute escaping; drops characters XML cannot carry.
    static func xml(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u.value {
            case 0x26: out += "&amp;"
            case 0x3C: out += "&lt;"
            case 0x3E: out += "&gt;"
            case 0x22: out += "&quot;"
            case 0x27: out += "&apos;"
            case 0x09, 0x0A, 0x0D: out.unicodeScalars.append(u)
            case 0x20 ... 0xD7FF, 0xE000 ... 0xFFFD, 0x10000 ... 0x10FFFF: out.unicodeScalars.append(u)
            default: break
            }
        }
        return out
    }

    static func run(_ text: String, style: String? = nil, bold: Bool = false) -> String {
        var props = ""
        if let style { props += "<w:rStyle w:val=\"\(style)\"/>" }
        if bold { props += "<w:b/><w:bCs/>" }
        let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
        return "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r>"
    }

    /// One run whose lines are separated by line breaks.
    static func multilineRun(_ text: String) -> String {
        var s = "<w:r>"
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 { s += "<w:br/>" }
            s += "<w:t xml:space=\"preserve\">\(xml(line))</w:t>"
        }
        return s + "</w:r>"
    }

    static func paragraph(_ content: String, style: String? = nil, keepNext: Bool = false) -> String {
        var props = ""
        if let style { props += "<w:pStyle w:val=\"\(style)\"/>" }
        if keepNext { props += "<w:keepNext/>" }
        let pPr = props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>"
        return "<w:p>\(pPr)\(content)</w:p>\n"
    }

    static func drawing(relationshipID: String, pictureID: Int, cx: Int, cy: Int, name: String, description: String) -> String {
        """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
        <wp:extent cx="\(cx)" cy="\(cy)"/>\
        <wp:effectExtent l="0" t="0" r="0" b="0"/>\
        <wp:docPr id="\(pictureID)" name="\(xml(name))" descr="\(xml(description))"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
        <pic:pic><pic:nvPicPr><pic:cNvPr id="\(pictureID)" name="\(xml(name))"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(relationshipID)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>\
        </a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    static func pictureExtent(width: Int, height: Int) -> (cx: Int, cy: Int) {
        guard width > 0, height > 0 else { return (cx: textWidthEMU, cy: textWidthEMU / 2) }
        var cx = textWidthEMU
        var cy = Int((Double(cx) * Double(height) / Double(width)).rounded())
        if cy > maxPictureHeightEMU {
            cy = maxPictureHeightEMU
            cx = Int((Double(cy) * Double(width) / Double(height)).rounded())
        }
        return (cx: max(1, cx), cy: max(1, cy))
    }

    static func data(_ doc: ExportDocument) throws -> Data {
        var media: [(name: String, relationshipID: String, data: Data)] = []
        var body = ""
        body += paragraph(run(doc.title), style: "Title")
        body += paragraph(run(doc.summary), style: "Caption")
        body += paragraph(run(ExportDocument.note), style: "Caption")

        for block in doc.blocks {
            switch block {
            case .speech(let i):
                var runs = ""
                for r in doc.runs(doc.paragraphs[i]) {
                    switch r.kind {
                    case .time: runs += run(r.text + " ", style: "Timecode")
                    case .speaker: runs += run(r.text + ": ", bold: true)
                    case .text: runs += run(r.text)
                    }
                }
                body += paragraph(runs)
            case .frame(let i):
                let f = doc.frames[i]
                let text = doc.frameText(f)
                body += paragraph(run(doc.frameCaption(f)), style: "Heading2", keepNext: true)
                let image = RichExport.scaled(f.image, maxWidth: 1600)
                if let jpeg = ReportExporter.jpegData(image, quality: 0.82) {
                    let number = media.count + 1
                    let rid = "rId\(number + 1)" // rId1 is the styles part
                    let file = "frame\(number).jpeg"
                    media.append((name: file, relationshipID: rid, data: jpeg))
                    let size = pictureExtent(width: image.width, height: image.height)
                    let picture = drawing(relationshipID: rid, pictureID: number, cx: size.cx, cy: size.cy,
                                          name: "Кадр \(f.id)", description: "Кадр \(f.id), \(doc.stamp(f.time))")
                    body += paragraph(picture, keepNext: !text.isEmpty)
                }
                if !text.isEmpty { body += paragraph(multilineRun(text), style: "OCR") }
            }
        }

        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let document = header + """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
        <w:body>

        """ + body + """
        <w:sectPr><w:pgSz w:w="\(pageWidthTwips)" w:h="\(pageHeightTwips)"/>\
        <w:pgMar w:top="\(marginTwips)" w:right="\(marginTwips)" w:bottom="\(marginTwips)" w:left="\(marginTwips)" \
        w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>
        </w:body>
        </w:document>

        """

        let contentTypes = header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Default Extension="jpeg" ContentType="image/jpeg"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        </Types>

        """

        let rootRels = header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        </Relationships>

        """

        var documentRels = header
            + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>\n"
        for m in media {
            documentRels += "<Relationship Id=\"\(m.relationshipID)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(m.name)\"/>\n"
        }
        documentRels += "</Relationships>\n"

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let created = formatter.string(from: doc.transcript?.created ?? Date())
        let core = header + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <dc:title>\(xml(doc.title))</dc:title>
        <dc:creator>Meteora</dc:creator>
        <dcterms:created xsi:type="dcterms:W3CDTF">\(created)</dcterms:created>
        </cp:coreProperties>

        """

        var zip = ZipWriter()
        try zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        try zip.add("_rels/.rels", Data(rootRels.utf8))
        try zip.add("docProps/core.xml", Data(core.utf8))
        try zip.add("word/document.xml", Data(document.utf8))
        try zip.add("word/styles.xml", Data((header + styles).utf8))
        try zip.add("word/_rels/document.xml.rels", Data(documentRels.utf8))
        for m in media {
            try zip.add("word/media/\(m.name)", m.data)
        }
        return try zip.finish()
    }

    static let font = "Arial"

    static let styles = """
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:docDefaults>
    <w:rPrDefault><w:rPr><w:rFonts w:ascii="\(font)" w:hAnsi="\(font)" w:eastAsia="\(font)" w:cs="\(font)"/>\
    <w:color w:val="16181B"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="ru-RU" w:eastAsia="ru-RU" w:bidi="ar-SA"/></w:rPr></w:rPrDefault>
    <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="288" w:lineRule="auto"/></w:pPr></w:pPrDefault>
    </w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>
    <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:spacing w:after="120" w:line="240" w:lineRule="auto"/></w:pPr>\
    <w:rPr><w:b/><w:bCs/><w:color w:val="16181B"/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:keepNext/><w:spacing w:before="280" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr>\
    <w:rPr><w:b/><w:bCs/><w:color w:val="33506B"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:spacing w:after="80"/></w:pPr>\
    <w:rPr><w:color w:val="5B6068"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:customStyle="1" w:styleId="OCR"><w:name w:val="OCR"/><w:basedOn w:val="Normal"/><w:qFormat/>\
    <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F3F2EF"/><w:spacing w:before="80" w:after="240" w:line="264" w:lineRule="auto"/></w:pPr>\
    <w:rPr><w:color w:val="5B6068"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>
    <w:style w:type="character" w:customStyle="1" w:styleId="Timecode"><w:name w:val="Timecode"/><w:basedOn w:val="DefaultParagraphFont"/>\
    <w:rPr><w:color w:val="8A8F96"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style>
    </w:styles>

    """
}
