import SwiftUI

/// Create a profile. The prior-knowledge field is not decoration — it goes
/// into every generation prompt, so lessons start at the right altitude
/// instead of re-explaining things the learner already knows.
struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var onSave: (Learner) -> Void

    @State private var name = ""
    @State private var emoji = "🧠"
    @State private var priorKnowledge = ""
    @State private var dailyGoal = 20

    private let emojiChoices = ["🧠", "⚡️", "🛠", "🔭", "🧭", "📐", "🌱", "🦉", "🐙", "🚀"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Your name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("Avatar") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(emojiChoices, id: \.self) { choice in
                                Button { emoji = choice } label: {
                                    Text(choice)
                                        .font(Glyph.emoji(26))
                                        .frame(width: 44, height: 44)
                                        .background(
                                            Circle().fill(emoji == choice
                                                ? Palette.accentWash(scheme)
                                                : Color.clear)
                                        )
                                        .overlay(
                                            Circle().stroke(
                                                emoji == choice ? Palette.accent : Color.clear,
                                                lineWidth: 2)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Stepper("\(dailyGoal) minutes a day", value: $dailyGoal, in: 5...90, step: 5)
                } header: {
                    Text("Daily goal")
                } footer: {
                    Text("Sets how much fits in a session. Reviews always come first, so a smaller goal means fewer new concepts, not less retention.")
                }

                Section {
                    TextEditor(text: $priorKnowledge)
                        .frame(minHeight: 120)
                        .font(Typeface.body(15))
                } header: {
                    Text("What you already know")
                } footer: {
                    Text("Goes into every prompt so the tutor pitches lessons correctly. Be specific about both ends — what you're fluent in, and what you've never touched.")
                }
            }
            .navigationTitle("New profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let learner = Learner(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            avatarEmoji: emoji,
                            priorKnowledge: priorKnowledge.trimmingCharacters(in: .whitespacesAndNewlines),
                            dailyGoalMinutes: dailyGoal
                        )
                        onSave(learner)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
