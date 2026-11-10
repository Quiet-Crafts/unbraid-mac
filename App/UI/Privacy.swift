import SwiftUI

/// A secret stays masked until its eye is pressed, and is masked again when the field leaves.
struct SecretField: View {
    let label: String
    @Binding var text: String
    var prompt: Text?
    @State private var reveal = false

    init(_ label: String, text: Binding<String>, prompt: Text? = nil) {
        self.label = label
        _text = text
        self.prompt = prompt
    }

    var body: some View {
        HStack {
            Group {
                if reveal { TextField(label, text: $text, prompt: prompt) }
                else { SecureField(label, text: $text, prompt: prompt) }
            }
            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                .buttonStyle(.quiet).help("\(reveal ? "Hide" : "Show") \(label)")
                .accessibilityLabel("\(reveal ? "Hide" : "Show") \(label)")
        }
        .onDisappear { reveal = false }
    }
}
