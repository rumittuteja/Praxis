import SwiftUI
import PDFKit

/// PDFKit's `PDFView`, bridged into SwiftUI.
///
/// PDFKit is used rather than a `QuickLook` preview because this needs to
/// report the current page back out so reading position can be saved, and
/// QuickLook does not expose that.
struct PDFKitView: UIViewRepresentable {

    let url: URL
    /// Page to open on, zero-based.
    let initialPage: Int
    /// Called as the reader moves through the document.
    var onPageChange: (Int) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)
        view.backgroundColor = .systemBackground

        if let document = PDFDocument(url: url) {
            view.document = document
            // Restoring position has to happen after the document is set,
            // and the index has to be re-clamped: a file can be replaced by a
            // shorter one, and PDFKit will happily accept an out-of-range page
            // and then show nothing.
            let target = min(max(initialPage, 0), max(document.pageCount - 1, 0))
            if let page = document.page(at: target) {
                view.go(to: page)
            }
        }

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        context.coordinator.pdfView = view
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.onPageChange = onPageChange
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: uiView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPageChange: onPageChange) }

    final class Coordinator: NSObject {
        var onPageChange: (Int) -> Void
        weak var pdfView: PDFView?

        init(onPageChange: @escaping (Int) -> Void) {
            self.onPageChange = onPageChange
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = pdfView,
                  let document = view.document,
                  let current = view.currentPage else { return }
            onPageChange(document.index(for: current))
        }
    }
}

/// Full-screen reader for one imported PDF.
struct DocumentReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.modelContext) private var modelContext

    let document: LibraryDocument

    @State private var currentPage: Int = 0
    @State private var showingRename = false
    @State private var draftName = ""

    private var repository: LearningRepository { LearningRepository(context: modelContext) }

    var body: some View {
        Group {
            if let url = DocumentStore.url(for: document), DocumentStore.fileExists(for: document) {
                PDFKitView(url: url, initialPage: document.lastPageIndex) { page in
                    currentPage = page
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                ScrollView {
                    Card {
                        StatusMessage(
                            symbol: "doc.questionmark",
                            title: String(localized: "File missing",
                                          comment: "The PDF row exists but its file is gone"),
                            message: String(localized: "The PDF for this entry isn't on the device any more. Remove the entry and add the file again.",
                                            comment: "Explains a missing PDF file"),
                            tint: Palette.warning
                        )
                    }
                    .padding(Metrics.gutter)
                }
                .canvasBackground()
            }
        }
        .navigationTitle(document.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        draftName = document.displayName
                        showingRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if let url = DocumentStore.url(for: document), DocumentStore.fileExists(for: document) {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .alert("Rename", isPresented: $showingRename) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    document.displayName = trimmed
                    repository.save()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            currentPage = document.lastPageIndex
            document.lastOpenedAt = Date()
            repository.save()
        }
        .onDisappear {
            // Saved on the way out rather than on every scroll: a page change
            // fires constantly while reading, and writing the store each time
            // would be pointless churn.
            document.lastPageIndex = currentPage
            document.lastOpenedAt = Date()
            repository.save()
        }
    }
}
