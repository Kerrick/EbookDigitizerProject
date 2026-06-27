import Foundation
import CoreGraphics
import SwiftData

/// A single semantic content region detected on a `Page`.
///
/// `ElementBlock` is the atom of the document model: every paragraph, quote,
/// marginal note, page artifact, or illustration on a page is represented by
/// one element block. Blocks are ordered within their owning page via
/// `sequence` and carry the geometric `CGRect` (persisted as four primitive
/// `Double` values for predicate-friendly querying) so the system always
/// remembers where the bounding box lives on the source image.
@Model
public final class ElementBlock {

    // MARK: - Identity & Ordering

    /// Stable, unique identifier for the block, independent of the
    /// SwiftData-managed `persistentModelID`. Useful for cross-referencing
    /// blocks with editor markup and on-disk assets.
    public var id: UUID

    /// Zero-based ordering of this block within its owning page's reading flow.
    public var sequence: Int

    // MARK: - Semantic Type

    /// Semantic classification of this region (paragraph, quote, artifact, ...).
    public var blockType: BlockType

    // MARK: - Text Content

    /// Raw extracted text for this block. `nil` for non-text blocks such as
    /// illustrations, or for blocks awaiting manual entry.
    public var rawText: String?

    // MARK: - Illustration Asset

    /// Filesystem reference to the cropped illustration asset on disk.
    ///
    /// Stored as a `String` (a file URL's absolute path) so it is lightweight,
    /// portable across launches, and predicate-queryable. Exposed to
    /// callers as a typed `URL?` via `assetURL`.
    public var assetPath: String?

    /// Typed accessor for the cropped illustration asset reference.
    public var assetURL: URL? {
        get { assetPath.map(URL.init(fileURLWithPath:)) }
        set { assetPath = newValue?.path }
    }

    // MARK: - Geometry

    /// Bounding-box origin X, in normalized source-image coordinate space.
    public var originX: Double
    /// Bounding-box origin Y, in normalized source-image coordinate space.
    public var originY: Double
    /// Bounding-box width, in normalized source-image coordinate space.
    public var width: Double
    /// Bounding-box height, in normalized source-image coordinate space.
    public var height: Double

    /// `true` when Vision identified this text as a title (use-case: keep real
    /// chapter titles in the body even when their text matches a recurring
    /// running header). Persisted so the cross-page detector can run after a
    /// relaunch without re-running Vision.
    public var isTitle: Bool

    /// The full bounding rectangle, reconstructed from the persisted
    /// primitive `Double` components.
    public var boundingRect: CGRect {
        get { CGRect(x: originX, y: originY, width: width, height: height) }
        set {
            originX = newValue.origin.x
            originY = newValue.origin.y
            width = newValue.size.width
            height = newValue.size.height
        }
    }

    // MARK: - Ownership

    /// The page that owns this block. Inverse of `Page.elementBlocks`.
    public var page: Page?

    // MARK: - Init

    public init(
        id: UUID = UUID(),
        sequence: Int,
        blockType: BlockType,
        rawText: String? = nil,
        assetURL: URL? = nil,
        boundingRect: CGRect = .zero,
        isTitle: Bool = false
    ) {
        self.id = id
        self.sequence = sequence
        self.blockType = blockType
        self.rawText = rawText
        self.assetPath = assetURL?.path
        self.originX = boundingRect.origin.x
        self.originY = boundingRect.origin.y
        self.width = boundingRect.size.width
        self.height = boundingRect.size.height
        self.isTitle = isTitle
    }
}
