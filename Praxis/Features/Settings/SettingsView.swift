import SwiftUI
import SwiftData

/// Credentials, provider choice, docs sync, and the request inspector.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext

    @Bindable var learner: Learner

    @State private var anthropicKey = ""
    @State private var awsAccessKey = ""
    @State private var awsSecret = ""
    @State private var awsSessionToken = ""
    @State private var githubToken = ""
    @State private var showingDeleteConfirm = false
    @State private var syncing = false

    private var repository: LearningRepository { LearningRepository(context: modelContext) }

    var body: some View {
        NavigationStack {
            Form {
                providerSection
                anthropicSection
                bedrockSection
                cadenceSection
                docsSection
                inspectorSection
                profileSection
            }
            .navigationTitle("Settings")
            .onAppear(perform: loadCredentialPlaceholders)
            .confirmationDialog(
                "Delete \(learner.name)?",
                isPresented: $showingDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete profile and all progress", role: .destructive) {
                    repository.deleteLearner(learner)
                    env.activeLearnerID = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every lesson, quiz, task and streak for this profile. It cannot be undone.")
            }
        }
    }

    // MARK: Provider

    private var providerSection: some View {
        Section {
            Picker("Provider", selection: Binding(
                get: { learner.preferredProvider },
                set: { learner.preferredProvider = $0; repository.save() }
            )) {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
        } header: {
            Text("Where requests go")
        } footer: {
            Text("Both are implemented. Switching changes the endpoint, the auth scheme, and the model ID format — the differences are the point, and the request inspector below shows them. If the chosen provider has no credentials, the app falls back to the other one rather than blocking your session.")
        }
    }

    private var anthropicSection: some View {
        Section {
            SecureField("sk-ant-...", text: $anthropicKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Picker("Model", selection: Binding(
                get: { learner.anthropicModel },
                set: { learner.anthropicModel = $0; repository.save() }
            )) {
                ForEach(ModelCatalog.anthropic) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            if let note = ModelCatalog.note(for: learner.anthropicModel, provider: .anthropic) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Button("Save key") {
                env.credentials.set(anthropicKey, for: .anthropicAPIKey)
                anthropicKey = ""
                loadCredentialPlaceholders()
            }
            .disabled(anthropicKey.isEmpty)
            if env.credentials.hasAnthropicCredentials {
                Button("Remove key", role: .destructive) {
                    env.credentials.remove(.anthropicAPIKey)
                    loadCredentialPlaceholders()
                }
            }
        } header: {
            Text("Anthropic API")
        } footer: {
            Text(env.credentials.hasAnthropicCredentials
                 ? "A key is saved in the Keychain, device-only, excluded from iCloud and backups."
                 : "No key saved. Get one from the Anthropic Console.")
        }
    }

    private var bedrockSection: some View {
        Section {
            SecureField("AKIA... (access key ID)", text: $awsAccessKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Secret access key", text: $awsSecret)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Session token (temporary credentials only)", text: $awsSessionToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Picker("Region", selection: Binding(
                get: { learner.bedrockRegion },
                set: { learner.bedrockRegion = $0; repository.save() }
            )) {
                ForEach(ModelCatalog.bedrockRegions, id: \.self) { region in
                    Text(region).tag(region)
                }
            }
            Picker("Model", selection: Binding(
                get: { learner.bedrockModel },
                set: { learner.bedrockModel = $0; repository.save() }
            )) {
                ForEach(ModelCatalog.bedrock) { entry in
                    Text(entry.displayName).tag(entry.id)
                }
            }
            if let note = ModelCatalog.note(for: learner.bedrockModel, provider: .bedrock) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }

            Button("Save credentials") {
                env.credentials.set(awsAccessKey, for: .awsAccessKeyID)
                env.credentials.set(awsSecret, for: .awsSecretAccessKey)
                env.credentials.set(awsSessionToken, for: .awsSessionToken)
                awsAccessKey = ""; awsSecret = ""; awsSessionToken = ""
                loadCredentialPlaceholders()
            }
            .disabled(awsAccessKey.isEmpty || awsSecret.isEmpty)

            if env.credentials.hasAWSCredentials {
                Button("Remove credentials", role: .destructive) {
                    env.credentials.remove(.awsAccessKeyID)
                    env.credentials.remove(.awsSecretAccessKey)
                    env.credentials.remove(.awsSessionToken)
                    loadCredentialPlaceholders()
                }
            }
        } header: {
            Text("Amazon Bedrock")
        } footer: {
            Text("Requests are SigV4-signed on device. The model must be enabled for this region in the Bedrock console, and the key needs bedrock:InvokeModel. Prefer temporary credentials with a session token over a long-lived key — that tradeoff is itself a lesson in the AWS track.")
        }
    }

    private var cadenceSection: some View {
        Section {
            Stepper("\(learner.dailyGoalMinutes) minutes a day", value: Binding(
                get: { learner.dailyGoalMinutes },
                set: { learner.dailyGoalMinutes = $0; repository.save() }
            ), in: 5...90, step: 5)
        } header: {
            Text("Daily goal")
        } footer: {
            Text("Reviews are scheduled first and new concepts fill what's left, so a smaller goal slows new material without weakening retention.")
        }
    }

    private var docsSection: some View {
        Section {
            HStack {
                Text("Documents cached")
                Spacer()
                Text("\(repository.corpus().count)")
                    .foregroundStyle(.secondary)
            }
            SecureField("GitHub token (optional)", text: $githubToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !githubToken.isEmpty {
                Button("Save token") {
                    env.credentials.set(githubToken, for: .githubToken)
                    githubToken = ""
                }
            }
            Button(syncing ? "Syncing…" : "Sync documentation now") {
                syncing = true
                Task {
                    _ = await env.syncDocs(repository: repository, force: true)
                    syncing = false
                }
            }
            .disabled(syncing)

            if let report = env.lastSyncReport {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(report.fetched) fetched · \(report.unchanged) unchanged · \(report.skipped) fresh · \(report.failed) failed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(report.messages.enumerated()), id: \.offset) { _, message in
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Source material")
        } footer: {
            Text("There is no curriculum API, so the app fetches Anthropic docs, the courses and cookbook repos, and the AWS Bedrock guide into a local corpus, then retrieves the relevant passages when writing a lesson. Conditional requests mean a refresh is mostly cheap. A GitHub token raises the anonymous 60-requests-per-hour limit; it is optional.")
        }
    }

    private var inspectorSection: some View {
        Section {
            NavigationLink("Request inspector") {
                RequestInspectorView()
            }
            Toggle("Show token usage in lessons", isOn: Binding(
                get: { learner.showsRequestInspector },
                set: { learner.showsRequestInspector = $0; repository.save() }
            ))
        } header: {
            Text("Under the hood")
        } footer: {
            Text("Every model call this app makes, with tokens, cache hits, latency and an estimated cost. Worth checking after a few lessons — the cache hit rate tells you whether the prompt layout is actually working.")
        }
    }

    private var profileSection: some View {
        Section {
            Button("Switch profile") { env.activeLearnerID = nil }
            Button("Delete this profile", role: .destructive) { showingDeleteConfirm = true }
        } header: {
            Text("Profile")
        }
    }

    /// Never read secrets back into the fields — the Keychain values stay
    /// write-only from the UI's point of view. This just refreshes the derived
    /// "is something saved" state the footers read.
    private func loadCredentialPlaceholders() {
        anthropicKey = ""
        awsAccessKey = ""
        awsSecret = ""
        awsSessionToken = ""
    }
}
