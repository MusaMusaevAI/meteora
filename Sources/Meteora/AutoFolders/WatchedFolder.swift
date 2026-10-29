import Foundation
import MeteoraCore

/// Where the files made from a recording go.
enum OutputPlacement: Codable, Equatable, Hashable {
    /// Same folder as the recording: «<name>.docx» next to «<name>.webm».
    case besideRecording
    /// A subfolder of the watched folder (created on first use).
    case subfolder(String)

    static let defaultSubfolder = "Расшифровки"
    static let `default` = OutputPlacement.subfolder(defaultSubfolder)

    var title: String {
        switch self {
        case .besideRecording: return "Рядом с записью"
        case .subfolder(let name): return "В папке «\(name)»"
        }
    }

    /// The subfolder name, cleaned so it stays one level inside the folder.
    var subfolderName: String? {
        guard case .subfolder(let raw) = self else { return nil }
        let name = sanitizedBaseName(URL(fileURLWithPath: "/").appendingPathComponent(raw + ".dir"))
        return name.isEmpty ? Self.defaultSubfolder : name
    }
}

/// A folder Meteora watches for new recordings (Telemost saves meetings into
/// «Документы/Телемост»; any folder works, iCloud Drive included).
struct WatchedFolder: Codable, Identifiable, Equatable {
    var id: UUID
    /// Security-scoped, read-write, app-scope bookmark from the Open panel.
    /// nil only for folders the app can reach anyway (self-test in Downloads).
    var bookmark: Data?
    /// Last known path (for display and matching; the bookmark is the truth).
    var path: String
    var displayName: String
    var isEnabled: Bool
    var formats: Set<ExportFormat>
    /// Transcription always happens; these are the optional extra steps.
    var separateSpeakers: Bool
    var summarize: Bool
    var output: OutputPlacement
    /// Text layout for the files; nil = the app-wide export settings.
    var exportOptions: TranscriptExportOptions?
    /// Files that appeared before this moment are left alone unless the user
    /// asks «Обработать уже лежащие».
    var addedAt: Date

    init(id: UUID = UUID(), url: URL, bookmark: Data?, formats: Set<ExportFormat>,
         separateSpeakers: Bool = false, summarize: Bool = false,
         output: OutputPlacement = .default, exportOptions: TranscriptExportOptions? = nil,
         isEnabled: Bool = true, addedAt: Date = Date()) {
        self.id = id
        self.bookmark = bookmark
        self.path = url.standardizedFileURL.path
        self.displayName = WatchedFolder.displayName(for: url)
        self.isEnabled = isEnabled
        self.formats = formats.isEmpty ? [.docx] : formats
        self.separateSpeakers = separateSpeakers
        self.summarize = summarize
        self.output = output
        self.exportOptions = exportOptions
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, bookmark, path, displayName, isEnabled, formats, separateSpeakers, summarize, output, exportOptions, addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        path = try c.decode(String.self, forKey: .path)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? (path as NSString).lastPathComponent
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let raw = try c.decodeIfPresent([String].self, forKey: .formats) ?? []
        let f = Set(raw.compactMap(ExportFormat.init(rawValue:)))
        formats = f.isEmpty ? [.docx] : f
        separateSpeakers = try c.decodeIfPresent(Bool.self, forKey: .separateSpeakers) ?? false
        summarize = try c.decodeIfPresent(Bool.self, forKey: .summarize) ?? false
        output = (try? c.decodeIfPresent(OutputPlacement.self, forKey: .output)) ?? .default
        exportOptions = try? c.decodeIfPresent(TranscriptExportOptions.self, forKey: .exportOptions)
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(bookmark, forKey: .bookmark)
        try c.encode(path, forKey: .path)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(isEnabled, forKey: .isEnabled)
        // Unknown future formats are dropped on read, so store raw strings.
        try c.encode(orderedFormats.map(\.rawValue), forKey: .formats)
        try c.encode(separateSpeakers, forKey: .separateSpeakers)
        try c.encode(summarize, forKey: .summarize)
        try c.encode(output, forKey: .output)
        try c.encodeIfPresent(exportOptions, forKey: .exportOptions)
        try c.encode(addedAt, forKey: .addedAt)
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    /// Formats in the app's standard order.
    var orderedFormats: [ExportFormat] { ExportFormat.allCases.filter(formats.contains) }

    /// The folder lives in iCloud Drive (files may be cloud-only placeholders).
    var isICloud: Bool {
        path.contains("/Library/Mobile Documents/") || path.contains("/Library/CloudStorage/iCloud")
    }

    /// Where the files for a recording in this folder go.
    func destination(for recording: URL, root: URL) -> URL {
        switch output {
        case .besideRecording: return recording.deletingLastPathComponent()
        case .subfolder:
            return root.appendingPathComponent(output.subfolderName ?? OutputPlacement.defaultSubfolder, isDirectory: true)
        }
    }

    static func displayName(for url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? url.lastPathComponent : name
    }

    /// «Документы/Телемост» — where Yandex Telemost saves recordings.
    static var telemostURL: URL {
        Folders.realHome.appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Телемост", isDirectory: true)
    }
}

/// Optional steps for a folder, as one value for the settings UI.
struct AutoFolderOptions: Equatable {
    var separateSpeakers: Bool
    var summarize: Bool
    var output: OutputPlacement
    var exportOptions: TranscriptExportOptions?
}

extension WatchedFolder {
    var options: AutoFolderOptions {
        get { AutoFolderOptions(separateSpeakers: separateSpeakers, summarize: summarize, output: output, exportOptions: exportOptions) }
        set {
            separateSpeakers = newValue.separateSpeakers
            summarize = newValue.summarize
            output = newValue.output
            exportOptions = newValue.exportOptions
        }
    }
}
