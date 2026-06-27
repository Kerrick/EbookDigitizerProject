import Foundation
import CoreGraphics
import ImageIO

/// Value-type results produced by the Vision processing engine.
///
/// These DTOs are intentionally decoupled from SwiftData: the processing actor
/// emits plain `Sendable` values, and the caller (the app layer) is responsible
/// for inserting them into a `ModelContext` as `ElementBlock` models. This keeps
/// the OCR/layout pipeline testable, free of persistence side-effects, and safe
/// to run concurrently off the main actor.

// MARK: - Orientation

/// Source-image orientation handed to Vision.
///
/// Mirrors `CGImagePropertyOrientation` but is `Sendable` and ergonomic to
/// construct from the user-facing rotation/flip state stored on `Page`.
public enum PageOrientation: Sendable {
    case up
    case upMirrored
    case down
    case downMirrored
    case leftMirrored
    case right
    case rightMirrored
    case left

    /// The CoreGraphics orientation Vision expects.
    public var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up:            return .up
        case .upMirrored:    return .upMirrored
        case .down:          return .down
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .right:         return .right
        case .rightMirrored: return .rightMirrored
        case .left:          return .left
        }
    }

    /// Build the orientation from the `Page` model's persisted
    /// rotation/flip fields (use-case 7b: re-orientation triggers re-extraction).
    public static func from(rotationDegrees: Int, horizontallyFlipped: Bool) -> PageOrientation {
        let normalized = ((rotationDegrees % 360) + 360) % 360
        switch normalized {
        case 0:   return horizontallyFlipped ? .upMirrored    : .up
        case 90:  return horizontallyFlipped ? .leftMirrored  : .right
        case 180: return horizontallyFlipped ? .downMirrored  : .down
        case 270: return horizontallyFlipped ? .rightMirrored : .left
        default:  return horizontallyFlipped ? .upMirrored    : .up
        }
    }
}

// MARK: - Inputs / Outputs

/// A single page submitted for analysis.
public struct PageInput: Sendable {
    public let imageURL: URL
    public let pageID: UUID
    public let orientation: PageOrientation

    public init(imageURL: URL, pageID: UUID, orientation: PageOrientation = .up) {
        self.imageURL = imageURL
        self.pageID = pageID
        self.orientation = orientation
    }
}

/// One classified region of a page, ready to be persisted as an `ElementBlock`.
///
/// `boundingRect` is expressed in Vision's **normalized image coordinate
/// space** (origin at the bottom-left of the image, units in `[0, 1]`). The UI
/// layer is responsible for flipping to Core Animation's top-left space when
/// rendering; the value is stored verbatim so geometry round-trips losslessly.
public struct DetectedBlock: Sendable {
    public let id: UUID
    public var sequence: Int
    public var blockType: BlockType
    public var rawText: String?
    public var confidence: Float
    public var boundingRect: CGRect
    /// `true` when Vision identified this text as a title. Carried through so the
    /// cross-page artifact detector can keep a real title in the body even when
    /// its text matches a recurring running header.
    public var isTitle: Bool

    public init(
        id: UUID = UUID(),
        sequence: Int,
        blockType: BlockType,
        rawText: String? = nil,
        confidence: Float = 1.0,
        boundingRect: CGRect,
        isTitle: Bool = false
    ) {
        self.id = id
        self.sequence = sequence
        self.blockType = blockType
        self.rawText = rawText
        self.confidence = confidence
        self.boundingRect = boundingRect
        self.isTitle = isTitle
    }
}

/// The complete analysis result for one page.
public struct PageLayout: Sendable {
    public let pageID: UUID
    public let blocks: [DetectedBlock]

    public init(pageID: UUID, blocks: [DetectedBlock]) {
        self.pageID = pageID
        self.blocks = blocks
    }
}
