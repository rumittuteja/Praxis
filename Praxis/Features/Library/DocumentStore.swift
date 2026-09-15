import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Why an import was rejected. Each case maps to something the learner can act
/// on rather than a generic failure.
enum DocumentImportError: LocalizedError, Equatable {
    case notAPDF(String)
    case unreadable(String)
    case couldNotAccess(String)
    case copyFailed(String)
    case noStorageLocation

    var errorDescription: String? {
        switch self {
        case .notAPDF(let name):
            return String(localized: "\(name) isn't a PDF. Only PDFs can be added.",
                          comment: "Import rejected: wrong file type. Placeholder is a filename.")
        case .unreadable(let name):
            return String(localized: "\(name) couldn't be opened. It may be damaged or password-protected.",
                          comment: "Import rejected: the PDF could not be parsed")
        case .couldNotAccess(let name):
            return String(localized: "Couldn't read \(name). If it lives in iCloud Drive, open it once in the Files app first so it downloads.",
                          comment: "Import rejected: the file could not be opened for reading")
        case .copyFailed(let detail):
            return String(localized: "Couldn't save the file: \(detail)",
                          comment: "Import rejected: copying into the app failed")
        case .noStorageLocation:
            return String(localized: "Couldn't find anywhere to store the file.",
                          comment: "Import rejected: no writable directory")
        }
    }
}

/// Everything on disk for learner-added PDFs.
///
/// Files live in Application Support, not Caches: the system may evict Caches
/// under storage pressure, and silently deleting something a learner imported
/// for offline reading is the one thing this feature must never do.
struct DocumentStore: Sendable {

    static let folderName = "UserLibrary"

    /// Redirects storage somewhere else. Set by tests so they work in a
    /// temporary directory instead of writing PDFs into the real container and
    /// leaving them there. Never set in the app.
    static var directoryOverride: URL?

    /// The folder holding imported PDFs, created on first use.
    static func directory() -> URL? {
        let base: URL
        if let directoryOverride {
            base = directoryOverride
        } else if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) {
            base = support
        } else {
            return nil
        }

        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }

    static func url(for document: LibraryDocument) -> URL? {
        directory()?.appendingPathComponent(document.storedFilename)
    }

    /// Whether the bytes are actually present.
    ///
    /// A row can outlive its file — restoring a backup that excluded the
    /// documents folder, or a failed write. The UI shows those as unavailable
    /// instead of opening an empty viewer.
    static func fileExists(for document: LibraryDocument) -> Bool {
        guard let url = url(for: document) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Importing

    /// Copy a picked file into the container and describe it.
    ///
    /// - Parameter sourceURL: a URL from the document picker. Security-scoped
    ///   access is opened and closed around the read.
    static func importDocument(from sourceURL: URL, learnerID: UUID) throws -> LibraryDocument {
        let filename = sourceURL.lastPathComponent

        // Check the actual content, not just the extension — a renamed file
        // would otherwise produce a library entry that cannot be opened.
        guard sourceURL.pathExtension.lowercased() == "pdf" else {
            throw DocumentImportError.notAPDF(filename)
        }
        guard let folder = directory() else {
            throw DocumentImportError.noStorageLocation
        }

        // Files from other apps and iCloud Drive need the scoped grant held
        // open for the whole read.
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: sourceURL) else {
            throw DocumentImportError.couldNotAccess(filename)
        }
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else {
            throw DocumentImportError.unreadable(filename)
        }

        let storedFilename = "\(UUID().uuidString).pdf"
        let destination = folder.appendingPathComponent(storedFilename)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw DocumentImportError.copyFailed(error.localizedDescription)
        }

        return LibraryDocument(
            learnerID: learnerID,
            displayName: filename.replacingOccurrences(of: ".pdf", with: "",
                                                       options: [.caseInsensitive, .backwards]),
            originalFilename: filename,
            storedFilename: storedFilename,
            fileSize: data.count,
            pageCount: pdf.pageCount,
            thumbnailData: thumbnail(from: pdf)
        )
    }

    /// First-page thumbnail, sized for the list row on a 3x screen.
    static func thumbnail(from pdf: PDFDocument) -> Data? {
        guard let page = pdf.page(at: 0) else { return nil }
        let image = page.thumbnail(of: CGSize(width: 180, height: 240), for: .cropBox)
        return image.pngData()
    }

    // MARK: Removing

    static func deleteFile(for document: LibraryDocument) {
        guard let url = url(for: document) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Remove every stored file for a learner.
    ///
    /// Called when a profile is deleted. Deleting the rows alone would leave
    /// orphaned PDFs consuming storage forever, with nothing left pointing at
    /// them to clean them up.
    static func deleteFiles(_ documents: [LibraryDocument]) {
        for document in documents { deleteFile(for: document) }
    }

    /// Total bytes used by the given documents.
    static func totalSize(of documents: [LibraryDocument]) -> Int {
        documents.reduce(0) { $0 + $1.fileSize }
    }
}
