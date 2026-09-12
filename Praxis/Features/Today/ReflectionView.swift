import SwiftUI

/// Closing step: explain today's material in your own words.
///
/// Self-explanation is one of the cheapest interventions with a real effect on
/// transfer. It is stored but never graded — the value is in the writing, and
/// grading it would turn it into a performance.
struct ReflectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let coordinator: SessionCoordinator

    @State private var text = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Card(padding: 18) {
                    Text(coordinator.reflectionPrompt)
                        .font(Typeface.display(20))
                        .foregroundStyle(Palette.ink(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Card(padding: 12) {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .font(Typeface.body(15))
                        .scrollContentBackground(.hidden)
                }

                Text("Not graded, not sent anywhere. Writing it is the point — if you can't explain it plainly, you'll find out here rather than in a code review.")
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                Button("Finish session") {
                    coordinator.saveReflection(text)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())

                Button("Skip") {
                    coordinator.saveReflection("")
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(Metrics.gutter)
        }
        .canvasBackground()
        .navigationTitle("Reflect")
        .navigationBarTitleDisplayMode(.inline)
    }
}
