import Foundation

/// Speaker separation ("Спикер 1, 2…"): two small ONNX models run by
/// sherpa-onnx, downloaded on demand like GigaAM and verified the same way.
///
/// - Segmentation: pyannote/segmentation-3.0 (MIT), ONNX export by the
///   sherpa-onnx authors. Finds who-speaks-when inside 10 s windows,
///   including overlapping speech, for up to 3 local speakers per window.
/// - Embedding: 3D-Speaker CAM++ trained on VoxCeleb (Apache-2.0). VoxCeleb is
///   multilingual (thousands of speakers, 145 nationalities, Russian
///   included), so it does not depend on the language of the meeting; CAM++
///   is ~2–3× faster on CPU than ResNet34 at a lower error rate.
///
/// SHA-256 values are the Git LFS object ids published by Hugging Face
/// (API tree endpoint and the LFS pointer files — both checked). Every file is
/// verified before it is moved into place; a mismatch deletes the file.
public enum SpeakerModel {
    public static let id = "speaker-diarization-pyannote3-campplus"
    public static let displayName = "pyannote 3.0 + CAM++"
    public static let segmentationRepo = "csukuangfj/sherpa-onnx-pyannote-segmentation-3-0"
    public static let embeddingRepo = "csukuangfj/speaker-embedding-models"

    public static let segmentationFile = "pyannote-segmentation-3.0.onnx"
    public static let embeddingFile = "3dspeaker_campplus_sv_en_voxceleb_16k.onnx"

    public static let files: [ModelFile] = [
        ModelFile(name: segmentationFile, size: 5_992_913,
                  sha256: "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079",
                  source: "\(segmentationRepo)/resolve/main/model.onnx"),
        ModelFile(name: embeddingFile, size: 29_596_978,
                  sha256: "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b",
                  source: "\(embeddingRepo)/resolve/main/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx"),
    ]

    public static var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    public static let spec = ModelSpec(id: id, displayName: displayName, files: files,
                                       hosts: SpeechModel.hosts, repo: segmentationRepo)
}

extension ModelStore {
    /// The speaker-separation models (Application Support/Meteora/Models/<SpeakerModel.id>).
    /// Same API as `ModelStore.shared`: `isInstalled`, `install`, `remove`, `installedBytes`.
    public static let speakers = ModelStore(spec: SpeakerModel.spec)
}
