import SwiftUI

/// Settings → Voice → "Hearing you": the mic check, and (with a local model) which engine writes your words.
struct SpeechRecognitionSection: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Section("Hearing you") {
            HStack {
                Text("Does Poinky mishear you? Read eight short sentences and see what each speech engine heard, and how loud your mic is.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Check my microphone…") { MicCheckWindow.shared.show() }
            }
        }
    }
}
