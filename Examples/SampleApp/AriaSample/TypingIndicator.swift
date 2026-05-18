import SwiftUI

// MARK: - TypingIndicator

/// Three-dot "the model is thinking" animation rendered inside the
/// assistant bubble while content is still streaming. Replaces the
/// empty grey pill the prior bubble showed before the first token
/// arrived.
///
/// Each dot scales + fades on a 1.0s loop, staggered 0.2s apart, so
/// the indicator reads as motion without burning frames. Animation
/// runs as long as the view is mounted.
struct TypingIndicator: View {
    var color: Color = .secondary
    var dotSize: CGFloat = 7
    var spacing: CGFloat = 4

    @State private var animating = false

    var body: some View {
        HStack(spacing: self.spacing) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(self.color)
                    .frame(width: self.dotSize, height: self.dotSize)
                    .opacity(self.animating ? 1.0 : 0.4)
                    .scaleEffect(self.animating ? 1.0 : 0.7)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: self.animating
                    )
            }
        }
        .onAppear { self.animating = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thinking")
    }
}
