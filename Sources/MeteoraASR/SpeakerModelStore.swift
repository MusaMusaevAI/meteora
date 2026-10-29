import Foundation

/// Speaker separation ("Спикер 1, 2…"): ONNX models run by sherpa-onnx,
/// downloaded on demand like GigaAM and verified the same way.
///
/// - Segmentation (shared by both tiers): pyannote/segmentation-3.0 (MIT),
///   ONNX export by the sherpa-onnx authors. Finds who-speaks-when inside
///   10 s windows, including overlapping speech, up to 3 local speakers.
/// - Voice embedding, one per tier (`SpeakerModelTier`): NVIDIA NeMo
///   TitaNet (CC-BY-4.0), trained on VoxCeleb 1+2, Fisher, Switchboard,
///   LibriSpeech and NIST SRE — thousands of speakers, studio, web and
///   telephone audio. Embeddings describe the voice, not the language.
///
/// Why TitaNet and not 3D-Speaker CAM++ (the model used before): on
/// sherpa-onnx's own speaker test set (sr-data, 3 speakers × 4–5 clips plus
/// the 3D-Speaker demo clips) both VoxCeleb CAM++ exports ranked
/// same-speaker vs other-speaker pairs correctly only ~75 % of the time
/// (same-voice cosine down to 0.08, other-voice up to 0.97), which is what
/// split one person into two. TitaNet-S and TitaNet-L separated every pair
/// (same ≥ 0.58, other ≤ 0.40).
///
/// SHA-256 values are the Git LFS object ids published by Hugging Face
/// (API tree endpoint and the `/raw/` LFS pointer files — both checked) and
/// match the same files in the sherpa-onnx GitHub release
/// `speaker-recongition-models`. Every file is verified before it is moved
/// into place; a mismatch deletes the file.
public enum SpeakerModel {
    public static let segmentationRepo = "csukuangfj/sherpa-onnx-pyannote-segmentation-3-0"
    public static let embeddingRepo = "csukuangfj/speaker-embedding-models"

    public static let segmentationFile = "pyannote-segmentation-3.0.onnx"

    public static let segmentationSpec = ModelSpec(
        id: "speaker-segmentation-pyannote3", displayName: "pyannote 3.0",
        files: [ModelFile(name: segmentationFile, size: 5_992_913,
                          sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
                          source: "\(segmentationRepo)/resolve/main/model.onnx")],
        hosts: SpeechModel.hosts, repo: segmentationRepo)

    /// Folder of the previous single-model layout (pyannote + CAM++). Its
    /// segmentation file is moved into the shared folder; the rest is removed.
    static let legacyID = "speaker-diarization-pyannote3-campplus"

    /// The tier used when the user has not chosen one.
    public static let defaultTier: SpeakerModelTier = .standard

    // Compatibility with code written for a single model.
    public static var displayName: String { defaultTier.displayName }
    public static var totalSize: Int64 { defaultTier.totalSize }
}

/// Voice-embedding model used to tell speakers apart.
public enum SpeakerModelTier: String, CaseIterable, Codable, Sendable, Identifiable {
    /// TitaNet-S: 40 MB, fast. VoxCeleb1 EER 1.15 % (TitaNet paper, Table 2).
    case standard
    /// TitaNet-L: 101 MB, ~2× slower. VoxCeleb1 EER 0.66–0.68 % (NeMo model
    /// card / paper).
    case accurate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: return "Стандартная"
        case .accurate: return "Точная"
        }
    }

    public var detail: String {
        switch self {
        case .standard: return "Быстро и мало места. Хватает для большинства встреч."
        case .accurate: return "Лучше различает похожие голоса и большие встречи. Примерно вдвое медленнее."
        }
    }

    /// Name of the voice model alone ("TitaNet-S").
    public var embeddingName: String {
        switch self {
        case .standard: return "TitaNet-S"
        case .accurate: return "TitaNet-L"
        }
    }

    /// "pyannote 3.0 + TitaNet-S".
    public var displayName: String { "pyannote 3.0 + \(embeddingName)" }

    public var embeddingFile: ModelFile {
        switch self {
        case .standard:
            return ModelFile(name: "nemo_en_titanet_small.onnx", size: 40_257_283,
                             sha256: "ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e",
                             source: "\(SpeakerModel.embeddingRepo)/resolve/main/nemo_en_titanet_small.onnx")
        case .accurate:
            return ModelFile(name: "nemo_en_titanet_large.onnx", size: 101_405_493,
                             sha256: "d51abcf31717ef28162f26acb9d44dd4127c3d44c9b8624f699f3425daca8e77",
                             source: "\(SpeakerModel.embeddingRepo)/resolve/main/nemo_en_titanet_large.onnx")
        }
    }

    public var embeddingSpec: ModelSpec {
        ModelSpec(id: "speaker-embedding-\(embeddingName.lowercased())", displayName: embeddingName,
                  files: [embeddingFile], hosts: SpeechModel.hosts, repo: SpeakerModel.embeddingRepo)
    }

    /// The tier's own folder (the voice model only).
    public var store: ModelStore { ModelStore.speakerEmbedding(self) }

    /// Download size including the shared segmentation model.
    public var totalSize: Int64 { SpeakerModel.segmentationSpec.totalSize + embeddingFile.size }

    /// What still has to be downloaded (0 when installed).
    public var missingSize: Int64 {
        (ModelStore.speakerSegmentation.isInstalled ? 0 : SpeakerModel.segmentationSpec.totalSize)
            + (store.isInstalled ? 0 : embeddingFile.size)
    }

    /// Both the shared segmentation model and this tier's voice model are
    /// on disk and verified.
    public var isInstalled: Bool { ModelStore.speakerSegmentation.isInstalled && store.isInstalled }

    /// Downloads and verifies whatever is missing (segmentation, then the
    /// voice model). Progress is over the bytes of both.
    public func install(progress: @escaping @Sendable (Double) -> Void,
                        isCancelled: @escaping @Sendable () -> Bool) async throws {
        ModelStore.migrateLegacySpeakerModels()
        let seg = ModelStore.speakerSegmentation
        let segShare = Double(SpeakerModel.segmentationSpec.totalSize) / Double(max(1, totalSize))
        if !seg.isInstalled {
            try await seg.install(progress: { p in progress(p * segShare) }, isCancelled: isCancelled)
        }
        progress(segShare)
        if !store.isInstalled {
            try await store.install(progress: { p in progress(segShare + p * (1 - segShare)) }, isCancelled: isCancelled)
        }
        progress(1)
    }

    /// Removes this tier's voice model. The shared segmentation model stays
    /// while the other tier is installed.
    public func remove() throws {
        try store.remove()
        if SpeakerModelTier.allCases.allSatisfy({ !$0.store.isInstalled }) {
            try ModelStore.speakerSegmentation.remove()
        }
    }
}

extension ModelStore {
    /// pyannote segmentation, shared by both tiers.
    public static let speakerSegmentation = ModelStore(spec: SpeakerModel.segmentationSpec)
    private static let speakerEmbeddingStandard = ModelStore(spec: SpeakerModelTier.standard.embeddingSpec)
    private static let speakerEmbeddingAccurate = ModelStore(spec: SpeakerModelTier.accurate.embeddingSpec)

    /// Voice model of one tier (Application Support/Meteora/Models/<id>).
    public static func speakerEmbedding(_ tier: SpeakerModelTier) -> ModelStore {
        switch tier {
        case .standard: return speakerEmbeddingStandard
        case .accurate: return speakerEmbeddingAccurate
        }
    }

    /// Moves the segmentation model out of the old combined folder (it is
    /// re-verified by `install`, so nothing is downloaded again) and
    /// deletes the rest of that folder (the CAM++ model is no longer used).
    public static func migrateLegacySpeakerModels() {
        let fm = FileManager.default
        let legacy = speakerSegmentation.directory.deletingLastPathComponent()
            .appendingPathComponent(SpeakerModel.legacyID, isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else { return }
        let old = legacy.appendingPathComponent(SpeakerModel.segmentationFile)
        let new = speakerSegmentation.path(SpeakerModel.segmentationFile)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            try? fm.createDirectory(at: speakerSegmentation.directory, withIntermediateDirectories: true)
            try? fm.moveItem(at: old, to: new)
        }
        try? fm.removeItem(at: legacy)
    }
}
