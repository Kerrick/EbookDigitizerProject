import CoreGraphics
import Foundation
import EbookDigitizerCore

/// Pure coordinate-space helpers for the image canvas.
///
/// All persisted `ElementBlock` geometry is stored in Vision's **normalized,
/// lower-left origin** space (`[0, 1]`). The canvas renders top-down, so this
/// file owns the lossless translation between the persisted normalized space
/// and the view-local `CGRect` (in points) used for drawing and gestures.
enum CanvasGeometry {

    /// Convert a normalized lower-left rect to a view-local top-left rect.
    ///
    /// - Parameters:
    ///   - normalized: The block's bounding rect, with origin at lower-left,
    ///     units in `[0, 1]`.
    ///   - viewSize: The size, in points, of the rendered image area.
    static func normalizedToView(_ normalized: CGRect, in viewSize: CGSize) -> CGRect {
        let viewY = (1.0 - normalized.minY - normalized.height) * viewSize.height
        return CGRect(
            x: normalized.minX * viewSize.width,
            y: viewY,
            width: normalized.width * viewSize.width,
            height: normalized.height * viewSize.height
        )
    }

    /// Inverse of `normalizedToView`: convert a view-local top-left rect (e.g.
    /// a box the user just dragged out) back into persisted normalized space.
    static func viewToNormalized(_ view: CGRect, in viewSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let normalizedY = 1.0 - (view.minY + view.height) / viewSize.height
        return CGRect(
            x: view.minX / viewSize.width,
            y: normalizedY,
            width: view.width / viewSize.width,
            height: view.height / viewSize.height
        )
    }

    /// Clamp a normalized rect to the page's `[0, 1]` bounds with a minimum
    /// size so the user can never drag a box off-page or shrink it to nothing.
    static func clamp(_ rect: CGRect, minSize: CGFloat = 0.01) -> CGRect {
        let x = max(0, min(rect.minX, 1 - minSize))
        let y = max(0, min(rect.minY, 1 - minSize))
        let width = max(minSize, min(rect.width, 1 - x))
        let height = max(minSize, min(rect.height, 1 - y))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Snapshot view-model used by the overlay layer.
///
/// Mirrors the persisted fields of `ElementBlock` so the gesture layer can
/// mutate pure values during an in-flight drag and only commit to SwiftData
/// once the gesture ends. Keeps the model layer free of transient state.
struct AnnotationDraft: Identifiable, Equatable {
    let id: UUID
    var sequence: Int
    var blockType: BlockType
    /// Normalized, lower-left origin bounding rect (matches `ElementBlock.boundingRect`).
    var normalizedRect: CGRect
    /// Raw text content for text blocks; `nil` for illustrations.
    var rawText: String?
    /// Filesystem path to the cropped illustration asset; `nil` for text blocks.
    var assetPath: String?
    /// `true` when Vision identified this text as a title.
    var isTitle: Bool = false

    /// Convenience for the overlay layer.
    func viewRect(in size: CGSize) -> CGRect {
        CanvasGeometry.normalizedToView(normalizedRect, in: size)
    }
}

extension ElementBlock {
    /// Project the persisted block into a transient overlay draft.
    var draft: AnnotationDraft {
        AnnotationDraft(
            id: id,
            sequence: sequence,
            blockType: blockType,
            normalizedRect: boundingRect,
            rawText: rawText,
            assetPath: assetPath,
            isTitle: isTitle
        )
    }
}
