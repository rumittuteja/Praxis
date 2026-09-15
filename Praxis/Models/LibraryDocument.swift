import Foundation
import SwiftData

/// A PDF the learner added themselves.
///
/// The file's *bytes* are copied into the app container on import and this row
/// points at that copy by filename. It deliberately does not hold the URL the
/// document picker handed over: those are security-scoped, may point into
/// iCloud Drive at a file that has not been downloaded, and stop resolving
/// once the picker's grant lapses. Copying is what makes "review it offline"
/// actually true.
@Model
final class LibraryDocument {
    @Attribute(.unique) var id: UUID
    var learnerID: UUID

    /// Shown in the list. Defaults to the original filename, editable.
    var displayName: String
    /// What the file was called when it was imported, kept for reference.
    var originalFilename: String
    /// Name of the copy inside the app container. UUID-based, so two files
    /// called "notes.pdf" cannot collide.
    var storedFilename: String

    var addedAt: Date
    var fileSize: Int
    var pageCount: Int

    var lastOpenedAt: Date?
    /// Zero-based page to resume on. Reopening a 300-page spec at page 1 every
    /// time makes it useless as a reference.
    var lastPageIndex: Int

    /// First-page thumbnail. `.externalStorage` keeps the blob out of the
    /// store file so the database stays small and queries stay fast.
    @Attribute(.externalStorage) var thumbnailData: Data?

    init(
        learnerID: UUID,
        displayName: String,
        originalFilename: String,
        storedFilename: String,
        fileSize: Int,
        pageCount: Int,
        thumbnailData: Data? = nil
    ) {
        self.id = UUID()
        self.learnerID = learnerID
        self.displayName = displayName
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.addedAt = Date()
        self.fileSize = fileSize
        self.pageCount = pageCount
        self.lastOpenedAt = nil
        self.lastPageIndex = 0
        self.thumbnailData = thumbnailData
    }
}
