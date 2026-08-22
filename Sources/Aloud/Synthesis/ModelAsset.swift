import Foundation

/// Pinned to a specific commit of mlalma/KokoroTestApp so the download URL
/// and checksums stay stable even if that repo's `main` branch changes.
/// See SPEC.md §9 (Open risks) — worth mirroring these files into Aloud's
/// own release assets once the app is stable.
enum ModelAsset {
    private static let pinnedCommit = "9dcd3b06468a3c1ecee6d09a33ca687c8e708566"

    static let modelFileName = "kokoro-v1_0.safetensors"
    static let voicesFileName = "voices.npz"

    static let modelURL = URL(
        string: "https://media.githubusercontent.com/media/mlalma/KokoroTestApp/\(pinnedCommit)/Resources/kokoro-v1_0.safetensors"
    )!
    static let voicesURL = URL(
        string: "https://raw.githubusercontent.com/mlalma/KokoroTestApp/\(pinnedCommit)/Resources/voices.npz"
    )!

    static let modelSHA256 = "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
    static let voicesSHA256 = "56dbfa2f2970af2e395397020393d368c5f441d09b3de4e9b77f6222e790f10f"

    static let modelSize: Int64 = 327_115_152
    static let voicesSize: Int64 = 14_629_684
}
