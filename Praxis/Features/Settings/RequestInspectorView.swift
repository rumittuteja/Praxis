import SwiftUI

/// Every model call made this run: provider, endpoint, model, tokens, cache
/// hits, latency, and an estimated cost.
///
/// Deliberately prominent rather than hidden behind a debug flag. A learner
/// studying AI engineering should be watching their own token spend and cache
/// behaviour, not reading about someone else's.
struct RequestInspectorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summary
                if env.requestLog.entries.isEmpty {
                    Card {
                        StatusMessage(
                            symbol: "list.bullet.rectangle",
                            title: "No calls yet",
                            message: "Requests appear here as you work through a session. The log is in memory only and clears when the app restarts."
                        )
                    }
                } else {
                    ForEach(env.requestLog.entries) { entry in
                        row(entry)
                    }
                }
            }
            .padding(Metrics.gutter)
        }
        .canvasBackground()
        .navigationTitle("Requests")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear") { env.requestLog.clear() }
                    .disabled(env.requestLog.entries.isEmpty)
            }
        }
    }

    private var summary: some View {
        let usage = env.requestLog.totalUsage
        let cost = env.requestLog.totalEstimatedCostUSD
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "This run")
                HStack(spacing: 18) {
                    stat("\(env.requestLog.entries.count)", "calls")
                    stat("\(usage.inputTokens + usage.cacheReadInputTokens)", "in")
                    stat("\(usage.outputTokens)", "out")
                    stat(String(format: "$%.3f", cost), "est.")
                }
                if usage.cacheHitRate > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cache hit rate \(Int((usage.cacheHitRate * 100).rounded()))%")
                            .font(Typeface.body(13))
                            .foregroundStyle(Palette.inkSecondary(scheme))
                        MasteryBar(value: usage.cacheHitRate, tint: Palette.success, height: 4)
                    }
                } else {
                    Text("No cache reads yet. The first call of a session writes the cache; later ones should read it. If this stays at zero after several lessons, something in the prompt prefix is changing between requests.")
                        .font(Typeface.body(12))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Cost is estimated at Anthropic list prices. Bedrock is billed separately by AWS at its own rates.")
                    .font(Typeface.micro())
                    .foregroundStyle(Palette.inkTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(Typeface.semibold(17))
                .foregroundStyle(Palette.ink(scheme))
            Text(label)
                .font(Typeface.nano(.regular))
                .foregroundStyle(Palette.inkTertiary(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ entry: RequestLogEntry) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(entry.purpose)
                        .font(Typeface.semibold(14))
                        .foregroundStyle(Palette.ink(scheme))
                        .lineLimit(1)
                    Spacer()
                    Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                        .font(Typeface.mono(11))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                }

                Text("\(entry.model)  ·  \(entry.endpoint)")
                    .font(Typeface.mono(11))
                    .foregroundStyle(Palette.inkSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                if let error = entry.errorDescription {
                    Text(error)
                        .font(Typeface.body(12))
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("in \(entry.usage.inputTokens) · out \(entry.usage.outputTokens) · cache r/w \(entry.usage.cacheReadInputTokens)/\(entry.usage.cacheCreationInputTokens) · \(String(format: "%.1f", entry.latencySeconds))s · ~\(String(format: "$%.4f", entry.estimatedCostUSD))")
                        .font(Typeface.mono(11))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
