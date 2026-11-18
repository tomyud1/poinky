import AVFoundation

/// Local speech models that can write the final text of a question (Settings → Voice → Speech recognition).
@MainActor
enum LocalModels {
    struct Info { let id: String; let label: String }
    /// How long a question may wait for the local model after you let go, before Apple's text goes instead.
    static var deadline: Double = 1.5

    /// The models installed on this Mac.
    static var installed: [Info] { [] }

    static func make(_ id: String) -> (any SpeechEngine)? { nil }

    static func engine(choice: String?, languages: [String]) -> (any SpeechEngine)? { nil }

    static func lastLanguage(_ engine: any SpeechEngine) -> String? { nil }
}
