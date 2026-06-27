import Foundation
import SwiftData

/// Lifecycle state of a single digitized page within its `Project`.
///
/// `String`-backed so SwiftData persists it natively and so the state is
/// queryable through predicates (e.g. fetching every page requiring manual
/// review).
public enum PageStatus: String, Codable, CaseIterable, Sendable {
    /// Vision extraction is currently running for this page.
    case processing
    /// Extraction completed successfully and the page is ready for review/export.
    case ready
    /// Extraction failed (including the high-accuracy fallback OCR pass) and
    /// the page is flagged for manual transcription.
    case manualReviewRequired
}

/// A single digitized page within a `Project`.
///
/// Each page binds to its original source image on disk (which is never
/// modified by the system), tracks its processing lifecycle via `status`,
/// and owns an ordered collection of `ElementBlock` regions.
@Model
public final class Page {

    // MARK: - Identity & Ordering

    /// Stable identifier for the page, independent of the SwiftData-managed
    /// `persistentModelID`.
    public var id: UUID

    /// Zero-based position of this page within the project's reading flow.
    public var sequence: Int

    // MARK: - Source Image

    /// Absolute path of the original source image file on disk.
    ///
    /// Stored as a `String` (rather than a `URL`) for SwiftData
    /// portability and predicate queryability; surfaced to callers as the
    /// typed `sourceImageURL`.
    public var sourceImagePath: String

    /// Typed accessor for the original source image reference.
    ///
    /// Per the use-case minimal guarantees, the file this points to is never
    /// written to by the system.
    public var sourceImageURL: URL {
        get { URL(fileURLWithPath: sourceImagePath) }
        set { sourceImagePath = newValue.path }
    }

    /// User-applied rotation of the source image in degrees (0, 90, 180, 270).
    /// Persisted so the Canvas restores its orientation across launches.
    public var imageRotationDegrees: Int

    /// Whether the source image has been horizontally mirrored by the user.
    public var imageIsHorizontallyFlipped: Bool

    // MARK: - Lifecycle

    /// Current processing state of the page.
    public var status: PageStatus

    /// Whether the Producer has manually edited any text block on this page.
    ///
    /// Drives the system decision in use-case 7b: when `true`, a re-orientation
    /// must NOT overwrite the user's text; when `false`, the system may
    /// safely re-run extraction on the re-oriented image.
    public var hasManualEdits: Bool

    // MARK: - Content

    /// The ordered semantic content regions detected on this page.
    @Relationship(deleteRule: .cascade, inverse: \ElementBlock.page)
    public var elementBlocks: [ElementBlock]

    // MARK: - Ownership

    /// The project that owns this page. Inverse of `Project.pages`.
    public var project: Project?

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        sequence: Int,
        sourceImageURL: URL,
        imageRotationDegrees: Int = 0,
        imageIsHorizontallyFlipped: Bool = false,
        status: PageStatus = .processing,
        hasManualEdits: Bool = false,
        elementBlocks: [ElementBlock] = []
    ) {
        self.id = id
        self.sequence = sequence
        self.sourceImagePath = sourceImageURL.path
        self.imageRotationDegrees = imageRotationDegrees
        self.imageIsHorizontallyFlipped = imageIsHorizontallyFlipped
        self.status = status
        self.hasManualEdits = hasManualEdits
        self.elementBlocks = elementBlocks
    }
}
