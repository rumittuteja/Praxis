import Testing
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif
@testable import Praxis

/// Imported PDFs touch the filesystem, so every test here runs against a
/// temporary directory and cleans up after itself.
@Suite("Document library", .serialized)
struct DocumentLibraryTests {

    // MARK: Fixtures

    /// A genuinely valid PDF, rendered rather than hand-written, so PDFKit
    /// parses it the same way it would a real file.
    private func makePDF(pages: Int = 3) -> Data {
        #if canImport(UIKit)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 260))
        return renderer.pdfData { context in
            for page in 1...pages {
                context.beginPage()
                ("Page \(page)" as NSString).draw(
                    at: CGPoint(x: 20, y: 20),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 14)]
                )
            }
        }
        #else
        return Data()
        #endif
    }

    private func withTemporaryStore<T>(_ body: (URL) throws -> T) rethrows -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("praxis-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        DocumentStore.directoryOverride = root
        defer {
            DocumentStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: root)
        }
        return try body(root)
    }

    /// Write a file into a temp location so it can stand in for a picked URL.
    private func stage(_ data: Data, named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try data.write(to: url)
        return url
    }

    // MARK: Importing

    @Test("A valid PDF imports with its page count, size and thumbnail")
    func importsValidPDF() throws {
        let data = makePDF(pages: 3)
        try withTemporaryStore { _ in
            let source = try stage(data, named: "Attention Is All You Need.pdf")
            defer { try? FileManager.default.removeItem(at: source) }

            let document = try DocumentStore.importDocument(from: source, learnerID: UUID())
            #expect(document.pageCount == 3)
            #expect(document.fileSize == data.count)
            #expect(document.originalFilename.hasSuffix(".pdf"))
            #expect(DocumentStore.fileExists(for: document))
            #expect(document.thumbnailData != nil)
        }
    }

    @Test("The .pdf extension is stripped from the display name")
    func stripsExtensionForDisplay() throws {
        try withTemporaryStore { _ in
            let source = try stage(makePDF(), named: "Bedrock Guide.pdf")
            defer { try? FileManager.default.removeItem(at: source) }
            let document = try DocumentStore.importDocument(from: source, learnerID: UUID())
            #expect(!document.displayName.lowercased().hasSuffix(".pdf"))
            #expect(document.displayName.contains("Bedrock Guide"))
        }
    }

    @Test("The bytes are copied, so deleting the original does not break it")
    func copiesRatherThanReferences() throws {
        // The whole point of the feature: a picked URL can be a security-scoped
        // handle to an iCloud file. Referencing it would fail offline.
        try withTemporaryStore { _ in
            let source = try stage(makePDF(), named: "temp.pdf")
            let document = try DocumentStore.importDocument(from: source, learnerID: UUID())

            try FileManager.default.removeItem(at: source)

            #expect(DocumentStore.fileExists(for: document))
            let stored = try #require(DocumentStore.url(for: document))
            #expect(PDFDocument(url: stored)?.pageCount == 3)
        }
    }

    @Test("Two files with the same name do not collide")
    func handlesDuplicateNames() throws {
        try withTemporaryStore { _ in
            let first = try stage(makePDF(pages: 1), named: "notes.pdf")
            let second = try stage(makePDF(pages: 5), named: "notes.pdf")
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }
            let a = try DocumentStore.importDocument(from: first, learnerID: UUID())
            let b = try DocumentStore.importDocument(from: second, learnerID: UUID())

            #expect(a.storedFilename != b.storedFilename)
            #expect(a.pageCount == 1)
            #expect(b.pageCount == 5, "the second import must not have overwritten the first")
            #expect(DocumentStore.fileExists(for: a))
            #expect(DocumentStore.fileExists(for: b))
        }
    }

    // MARK: Rejection

    @Test("A non-PDF extension is rejected")
    func rejectsNonPDFExtension() throws {
        try withTemporaryStore { _ in
            let source = try stage(Data("not a pdf".utf8), named: "notes.txt")
            defer { try? FileManager.default.removeItem(at: source) }
            #expect(throws: DocumentImportError.self) {
                try DocumentStore.importDocument(from: source, learnerID: UUID())
            }
        }
    }

    @Test("A file renamed to .pdf but holding junk is rejected")
    func rejectsDisguisedFile() throws {
        // Extension checks alone would create a library entry that can never
        // be opened, so the content is parsed before the row is made.
        try withTemporaryStore { _ in
            let source = try stage(Data(repeating: 0x41, count: 4096), named: "disguised.pdf")
            defer { try? FileManager.default.removeItem(at: source) }
            #expect(throws: DocumentImportError.self) {
                try DocumentStore.importDocument(from: source, learnerID: UUID())
            }
        }
    }

    @Test("A missing source file is reported, not crashed on")
    func handlesMissingSource() throws {
        try withTemporaryStore { _ in
            let ghost = FileManager.default.temporaryDirectory
                .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")
            #expect(throws: DocumentImportError.self) {
                try DocumentStore.importDocument(from: ghost, learnerID: UUID())
            }
        }
    }

    @Test("Import errors all produce a readable message")
    func errorsAreReadable() {
        let errors: [DocumentImportError] = [
            .notAPDF("a.txt"), .unreadable("b.pdf"), .couldNotAccess("c.pdf"),
            .copyFailed("disk full"), .noStorageLocation
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
    }

    // MARK: Deletion and accounting

    @Test("Deleting removes the file from disk")
    func deleteRemovesFile() throws {
        try withTemporaryStore { _ in
            let source = try stage(makePDF(), named: "delete-me.pdf")
            defer { try? FileManager.default.removeItem(at: source) }
            let document = try DocumentStore.importDocument(from: source, learnerID: UUID())
            #expect(DocumentStore.fileExists(for: document))

            DocumentStore.deleteFile(for: document)
            #expect(!DocumentStore.fileExists(for: document))
        }
    }

    @Test("Deleting a whole set clears every file")
    func deletesInBulk() throws {
        try withTemporaryStore { _ in
            var documents: [LibraryDocument] = []
            for index in 0..<3 {
                let source = try stage(makePDF(pages: 1), named: "file\(index).pdf")
                defer { try? FileManager.default.removeItem(at: source) }
                documents.append(try DocumentStore.importDocument(from: source, learnerID: UUID()))
            }
            DocumentStore.deleteFiles(documents)
            #expect(documents.allSatisfy { !DocumentStore.fileExists(for: $0) })
        }
    }

    @Test("A row whose file has vanished reports as missing rather than opening empty")
    func detectsOrphanedRow() throws {
        try withTemporaryStore { _ in
            let source = try stage(makePDF(), named: "vanishing.pdf")
            defer { try? FileManager.default.removeItem(at: source) }
            let document = try DocumentStore.importDocument(from: source, learnerID: UUID())

            // Simulates a backup restored without the documents folder.
            if let url = DocumentStore.url(for: document) {
                try FileManager.default.removeItem(at: url)
            }
            #expect(!DocumentStore.fileExists(for: document))
        }
    }

    @Test("Total size sums the set")
    func totalSize() {
        let documents = [1_000, 2_500, 500].map {
            LibraryDocument(learnerID: UUID(), displayName: "d", originalFilename: "d.pdf",
                            storedFilename: "\(UUID().uuidString).pdf",
                            fileSize: $0, pageCount: 1)
        }
        #expect(DocumentStore.totalSize(of: documents) == 4_000)
    }

    @Test("A new document starts unread at page zero")
    func startsUnread() {
        let document = LibraryDocument(learnerID: UUID(), displayName: "d", originalFilename: "d.pdf",
                                       storedFilename: "x.pdf", fileSize: 10, pageCount: 4)
        #expect(document.lastPageIndex == 0)
        #expect(document.lastOpenedAt == nil)
    }
}

@Suite("File size formatting")
struct FileSizeFormattingTests {

    @Test("Sizes render with a unit")
    func rendersUnits() {
        let formatted = Format.fileSize(2_400_000, locale: Locale(identifier: "en_US"))
        #expect(formatted.uppercased().contains("MB"))
    }

    @Test("Small sizes stay in bytes or kilobytes")
    func smallSizes() {
        let formatted = Format.fileSize(512, locale: Locale(identifier: "en_US"))
        #expect(!formatted.isEmpty)
        #expect(formatted.contains("512") || formatted.uppercased().contains("KB"))
    }
}
