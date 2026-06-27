import Foundation
import CoreGraphics
import SwiftData

/// The top-level container for a single book digitization effort.
///
/// A `Project` owns an ordered collection of `Page` models and serves as the
/// persistent root for SwiftData's autosave, background persistence, and
/// undo/redo support. Because it is an `@Model`, the entire
/// `Project -> Page -> ElementBlock` graph is tracked and persisted
/// automatically by SwiftData — no manual GCD or save coordination is
/// required, and mutations performed on the `@MainActor`-bound
/// `ModelContext` flow to disk in the background.
@Model
public final class Project {

    // MARK: - Identity

    /// Stable identifier for the project, independent of the SwiftData-managed
    /// `persistentModelID`.
    public var id: UUID

    /// Human-readable title of the digitized book.
    public var title: String

    /// Optional note describing the source of the scans (folder, archive, etc.).
    public var notes: String?

    // MARK: - Lifecycle

    /// When the project was first created.
    public var createdAt: Date

    /// When the project was last modified. Updated on every mutation so the
    /// UI can surface "autosaved a moment ago" feedback.
    public var updatedAt: Date

    // MARK: - Source Binding

    /// Absolute path of the folder that originally contained the project's
    /// source scans.
    ///
    /// Persisted so the system can detect a moved/renamed source folder on
    /// launch (use-case 6a) and prompt the Producer to re-locate it.
    public var sourceFolderPath: String?

    /// Typed accessor for the project's original source folder.
    public var sourceFolderURL: URL? {
        get { sourceFolderPath.map(URL.init(fileURLWithPath:)) }
        set { sourceFolderPath = newValue?.path }
    }

    // MARK: - Pages

    /// The ordered collection of pages in this project. Cascade-deleted with
    /// the project, which transitively cascade-deletes their `ElementBlock`s.
    @Relationship(deleteRule: .cascade, inverse: \Page.project)
    public var pages: [Page]

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String? = nil,
        sourceFolderURL: URL? = nil,
        pages: [Page] = []
    ) {
        let now = Date()
        self.id = id
        self.title = title
        self.notes = notes
        self.createdAt = now
        self.updatedAt = now
        self.sourceFolderPath = sourceFolderURL?.path
        self.pages = pages
    }
}
