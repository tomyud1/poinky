import SwiftUI

/// Settings → Voice → "Hearing you": who writes your words, the languages you speak, and the mic check.
struct SpeechRecognitionSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var installer = SpeechModelInstaller.shared

    private var installed: Bool { !LocalModels.installed.isEmpty || installer.state == .done }
    private var otherLanguage: Binding<String> {
        Binding(get: { (model.config.otherLanguages ?? SpeechLanguages.defaults(main: model.config.language)).first ?? "" },
                set: { model.config.otherLanguages = $0.isEmpty ? [] : [$0] })
    }

    var body: some View {
        Section("Hearing you") {
            Picker("Speech recognition", selection: $model.config.speechEngine) {
                Text(installed ? "Automatic (Parakeet for English, Apple for the rest)" : "Automatic").tag("auto")
                Text("Apple (built in)").tag("apple")
                if installed { Text("Parakeet (English, on this Mac)").tag("parakeet") }
            }
            if !installed { installRow }
            Picker("I also speak", selection: otherLanguage) {
                Text("Only \(Self.name(model.config.language))").tag("")
                ForEach(Self.choices.filter { $0.prefix(2) != model.config.language.prefix(2) }, id: \.self) { Text(Self.name($0)).tag($0) }
            }
            Text("Poinky listens for both and answers in the one you used. Apple's engine downloads a language's model the first time (once).")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Does Poinky mishear you? Read eight short sentences and see what each engine heard, and how loud your mic is.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Check my microphone…") { MicCheckWindow.shared.show() }
            }
        }
    }

    static let choices = ["he-IL", "ar-SA", "ru-RU", "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ja-JP", "zh-CN", "en-US"]
    static func name(_ id: String) -> String { Locale.current.localizedString(forIdentifier: id) ?? id }

    @ViewBuilder private var installRow: some View {
        switch installer.state {
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: installer.progress)
                Text(installer.step).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Text("The install didn't finish: \(why)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Try again") { installer.start() }
            }
        case .idle, .done:
            HStack {
                Text("Parakeet hears English (also accents, soft voices and technical words) much better than Apple's engine. A one-time download of about 465 MB plus a few minutes to set up; it runs on this Mac, offline.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Install") { installer.start() }
            }
        }
    }
}
