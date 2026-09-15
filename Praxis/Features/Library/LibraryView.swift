import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

/// Two shelves: lessons the tutor wrote, and PDFs the learner added.
///
/// They sit together because they answer the same question — "where's that
/// thing I was reading?" — and both work with no network.
struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme

    let learner: Learner

    private enum Shelf: String, CaseIterable, Identifiable {
        case lessons, files
        var id: String { rawValue }

        var title: String {
            switch self {
            case .lessons: return String(localized: "Lessons", comment: "Library shelf: generated lessons")
            case .files:   return String(localized: "My files", comment: "Library shelf: PDFs the learner added")
            }
        }
    }

    @State private var shelf: Shelf = .lessons
    @State private var search = ""
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var importSummary: String?

    private var repository: LearningRepository { LearningRepository(context: modelContext) }

    private var query: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var lessons: [LessonRecord] {
        let all = repository.lessons(for: learner.id)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(query)
                || $0.conceptID.lowercased().contains(query)
                || $0.keyTakeaways.joined(separator: " ").lowercased().contains(query)
        }
    }

    private var documents: [LibraryDocument] {
        let all = repository.documents(for: learner.id)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.displayName.lowercased().contains(query)
                || $0.originalFilename.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Metrics.rowSpacing) {
                    Picker("Shelf", selection: $shelf) {
                        ForEach(Shelf.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 4)

                    switch shelf {
                    case .lessons: lessonShelf
                    case .files:   fileShelf
                    }
                }
                .padding(Metrics.gutter)
            }
            .canvasBackground()
            .navigationTitle("Library")
            .searchable(text: $search, prompt: shelf == .lessons
                        ? Text("Search lessons") : Text("Search your files"))
            .toolbar {
                if shelf == .files {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingImporter = true
                        } label: {
                            Label("Add PDF", systemImage: "plus")
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .alert("Couldn't add that file", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    // MARK: Lessons

    @ViewBuilder
    private var lessonShelf: some View {
        if lessons.isEmpty {
            Card {
                StatusMessage(
                    symbol: "books.vertical",
                    title: query.isEmpty
                        ? String(localized: "Nothing here yet", comment: "Empty lesson library")
                        : String(localized: "No matches", comment: "Lesson search found nothing"),
                    message: query.isEmpty
                        ? String(localized: "Lessons you read are kept here so you can come back to them.",
                                 comment: "Empty lesson library explanation")
                        : String(localized: "Try a different search.", comment: "Search found nothing")
                )
            }
        } else {
            ForEach(lessons) { lesson in
                NavigationLink {
                    ArchivedLessonView(lesson: lesson)
                } label: {
                    lessonRow(lesson)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func lessonRow(_ lesson: LessonRecord) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                if let concept = env.curriculum.concept(lesson.conceptID) {
                    TrackBadge(trackID: concept.trackID,
                               label: env.curriculum.trackTitle(concept.trackID))
                }
                Text(lesson.title)
                    .font(Typeface.semibold(16))
                    .foregroundStyle(Palette.ink(scheme))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let first = lesson.keyTakeaways.first {
                    Text(first)
                        .font(Typeface.body(13))
                        .foregroundStyle(Palette.inkSecondary(scheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Text(lesson.generatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(Typeface.micro())
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
    }

    // MARK: Files

    @ViewBuilder
    private var fileShelf: some View {
        if let summary = importSummary {
            Card(padding: 12) {
                Text(summary)
                    .font(Typeface.body(13))
                    .foregroundStyle(Palette.inkSecondary(scheme))
            }
        }

        if documents.isEmpty {
            Card {
                StatusMessage(
                    symbol: "doc.badge.plus",
                    title: query.isEmpty
                        ? String(localized: "No files yet", comment: "Empty PDF shelf")
                        : String(localized: "No matches", comment: "File search found nothing"),
                    message: query.isEmpty
                        ? String(localized: "Add PDFs — papers, specs, notes — and read them here. They're copied onto the device, so they work with no connection.",
                                 comment: "Empty PDF shelf explanation")
                        : String(localized: "Try a different search.", comment: "Search found nothing")
                )
            }
            if query.isEmpty {
                Button("Add a PDF") { showingImporter = true }
                    .buttonStyle(PrimaryButtonStyle())
            }
        } else {
            ForEach(documents) { document in
                NavigationLink {
                    DocumentReaderView(document: document)
                } label: {
                    documentRow(document)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) {
                        repository.delete(document)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Text("\(Format.count(documents.count)) files · \(Format.fileSize(DocumentStore.totalSize(of: documents))) on this device")
                .font(Typeface.micro())
                .foregroundStyle(Palette.inkTertiary(scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }

    private func documentRow(_ document: LibraryDocument) -> some View {
        let missing = !DocumentStore.fileExists(for: document)
        return Card {
            HStack(alignment: .top, spacing: 12) {
                thumbnail(for: document)

                VStack(alignment: .leading, spacing: 4) {
                    Text(document.displayName)
                        .font(Typeface.semibold(15))
                        .foregroundStyle(Palette.ink(scheme))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if missing {
                        Label("File missing", systemImage: "exclamationmark.triangle")
                            .font(Typeface.micro())
                            .foregroundStyle(Palette.warning)
                    } else {
                        Text("^[\(document.pageCount) page](inflect: true) · \(Format.fileSize(document.fileSize))")
                            .font(Typeface.micro())
                            .foregroundStyle(Palette.inkSecondary(scheme))
                    }

                    if document.lastPageIndex > 0, !missing {
                        Text("Last read on page \(Format.count(document.lastPageIndex + 1))")
                            .font(Typeface.micro())
                            .foregroundStyle(Palette.accent)
                    } else {
                        Text(document.addedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(Typeface.micro())
                            .foregroundStyle(Palette.inkTertiary(scheme))
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(Glyph.icon(12, weight: .semibold))
                    .foregroundStyle(Palette.inkTertiary(scheme))
            }
        }
        .opacity(missing ? 0.6 : 1)
    }

    @ViewBuilder
    private func thumbnail(for document: LibraryDocument) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        if let data = document.thumbnailData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 58)
                .clipShape(shape)
                .overlay(shape.stroke(Palette.hairline(scheme), lineWidth: 1))
        } else {
            shape
                .fill(Palette.well(scheme))
                .frame(width: 44, height: 58)
                .overlay(
                    Image(systemName: "doc.text")
                        .font(Glyph.icon(18))
                        .foregroundStyle(Palette.inkTertiary(scheme))
                )
        }
    }

    // MARK: Import

    private func handleImport(_ result: Result<[URL], Error>) {
        importSummary = nil
        switch result {
        case .failure(let error):
            importError = error.localizedDescription

        case .success(let urls):
            var added = 0
            var failures: [String] = []

            for url in urls {
                do {
                    let document = try DocumentStore.importDocument(from: url, learnerID: learner.id)
                    repository.insert(document)
                    added += 1
                } catch let error as DocumentImportError {
                    failures.append(error.errorDescription ?? "")
                } catch {
                    failures.append(error.localizedDescription)
                }
            }

            // Partial success is normal when several files are picked at once,
            // so the successes are kept and only the failures are reported.
            if !failures.isEmpty {
                importError = failures.joined(separator: "\n\n")
            }
            if added > 0 {
                importSummary = String(
                    localized: "Added ^[\(added) file](inflect: true).",
                    comment: "Confirmation after importing PDFs"
                )
            }
        }
    }
}

/// Read-only view of a lesson from the archive.
struct ArchivedLessonView: View {
    @Environment(\.colorScheme) private var scheme
    let lesson: LessonRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(lesson.title)
                    .font(Typeface.display(26))
                    .foregroundStyle(Palette.ink(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                Card(padding: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Worked example")
                        MarkdownView(markdown: lesson.workedExampleMarkdown)
                    }
                }

                MarkdownView(markdown: lesson.bodyMarkdown)

                if !lesson.keyTakeaways.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "Keep these")
                            ForEach(Array(lesson.keyTakeaways.enumerated()), id: \.offset) { _, point in
                                Text(MarkdownParser.inline("• " + point))
                                    .font(Typeface.body(15))
                                    .foregroundStyle(Palette.ink(scheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                UsageFooter(usage: lesson.usage, model: lesson.modelID,
                            provider: lesson.providerRaw, latency: lesson.latencySeconds)
            }
            .padding(Metrics.gutter)
        }
        .canvasBackground()
        .navigationTitle("Lesson")
        .navigationBarTitleDisplayMode(.inline)
    }
}
