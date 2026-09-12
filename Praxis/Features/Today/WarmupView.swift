import SwiftUI

/// Retrieval practice on due concepts.
///
/// Recall first, reveal second, self-rate third. Reversing that order — showing
/// the answer and asking "did you know this?" — feels easier and teaches far
/// less; the effort of retrieval is the mechanism, not a side effect.
struct WarmupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    let coordinator: SessionCoordinator

    @State private var index = 0
    @State private var revealed = false

    private var items: [WarmupItem] { coordinator.warmupItems }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if items.isEmpty {
                    Card {
                        StatusMessage(
                            symbol: "checkmark.circle",
                            title: "Nothing due",
                            message: "No concepts are scheduled for review today.",
                            tint: Palette.success
                        )
                    }
                } else if index < items.count {
                    card(items[index])
                }
            }
            .padding(Metrics.gutter)
        }
        .canvasBackground()
        .navigationTitle("Warm-up")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if items.isEmpty { coordinator.finishWarmup() } }
    }

    private func card(_ item: WarmupItem) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                TrackBadge(trackID: item.trackID, label: item.trackID)
                Spacer()
                Text("\(index + 1) of \(items.count)")
                    .font(Typeface.mono(12))
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }

            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.prompt)
                        .font(Typeface.display(21))
                        .foregroundStyle(Palette.ink(scheme))
                        .fixedSize(horizontal: false, vertical: true)

                    if revealed {
                        Divider().background(Palette.hairline(scheme))
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(item.reveal.enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle()
                                        .fill(Palette.accent)
                                        .frame(width: 4, height: 4)
                                        .offset(y: -3)
                                    Text(MarkdownParser.inline(point))
                                        .font(Typeface.body(15))
                                        .foregroundStyle(Palette.ink(scheme))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    } else {
                        Text("Answer out loud or in your head before revealing. The effort is the point.")
                            .font(Typeface.body(13))
                            .foregroundStyle(Palette.inkTertiary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if revealed {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "How did that go?")
                    HStack(spacing: 8) {
                        ForEach(RecallRating.allCases) { rating in
                            Button(rating.label) { record(rating, item: item) }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }
            } else {
                Button("Reveal") { withAnimation { revealed = true } }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func record(_ rating: RecallRating, item: WarmupItem) {
        coordinator.recordWarmup(conceptID: item.conceptID, rating: rating)
        revealed = false
        if index + 1 < items.count {
            index += 1
        } else {
            coordinator.finishWarmup()
            dismiss()
        }
    }
}
