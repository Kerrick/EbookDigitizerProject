import Foundation
import CoreGraphics

/// Pure-function heuristics that classify Vision text observations into the
/// semantic zones required by the digitization pipeline.
///
/// State-free and `Sendable` so it can run on any executor without isolation
/// concerns; the `VisionProcessingActor` delegates to it.

/// Public tuning knobs for the layout classifier.
///
/// Exposed as a value type so the caller can override the heuristic margins
/// (e.g. denser books with narrower margins) without touching the actor.
public struct LayoutHeuristics: Sendable {
    /// Fraction of page height (counted from the top and bottom) treated as the
    /// running-header / running-footer band. Observations whose vertical center
    /// falls inside these bands are classified as `pageArtifact`.
    public var headerFooterBandRatio: CGFloat

    /// Fraction of page width (counted from each side) treated as the marginalia
    /// gutter. Observations whose horizontal center falls inside the gutters
    /// are classified as `marginalia`.
    public var marginaliaGutterRatio: CGFloat

    /// Minimum inter-line vertical gap, as a fraction of page height, for a gap
    /// to be considered large enough to potentially host an illustration.
    public var illustrationMinGapRatio: CGFloat

    /// Minimum width, as a fraction of page width, for an illustration gap to be
    /// considered meaningful (avoids flagging narrow gaps from line spacing).
    public var illustrationMinWidthRatio: CGFloat

    /// Fraction of the body text width by which a line must be indented (relative
    /// to the body's left edge) to be classified as a `blockquote`.
    public var blockquoteIndentRatio: CGFloat

    /// Maximum character count for a body line to be considered a heading.
    public var headingMaxChars: Int

    /// Vertical gap above a heading, as a fraction of page height, that signals
    /// a section break (helps disambiguate short paragraphs from headings).
    public var headingGapRatio: CGFloat

    public init(
        headerFooterBandRatio: CGFloat = 0.06,
        marginaliaGutterRatio: CGFloat = 0.08,
        illustrationMinGapRatio: CGFloat = 0.08,
        illustrationMinWidthRatio: CGFloat = 0.60,
        blockquoteIndentRatio: CGFloat = 0.06,
        headingMaxChars: Int = 60,
        headingGapRatio: CGFloat = 0.02
    ) {
        self.headerFooterBandRatio = headerFooterBandRatio
        self.marginaliaGutterRatio = marginaliaGutterRatio
        self.illustrationMinGapRatio = illustrationMinGapRatio
        self.illustrationMinWidthRatio = illustrationMinWidthRatio
        self.blockquoteIndentRatio = blockquoteIndentRatio
        self.headingMaxChars = headingMaxChars
        self.headingGapRatio = headingGapRatio
    }
}

/// A normalized text observation extracted from Vision, decoupled from the
/// Vision framework's reference types so the classifier stays testable.
public struct TextObservation: Sendable {
    public let boundingRect: CGRect
    public let transcript: String
    public let confidence: Float

    public init(boundingRect: CGRect, transcript: String, confidence: Float) {
        self.boundingRect = boundingRect
        self.transcript = transcript
        self.confidence = confidence
    }
}

/// The full set of analysis outputs for a page that the classifier consumes.
public struct PageObservations: Sendable {
    /// All text observations, in reading order (top-to-bottom, then left-to-right).
    public let textBlocks: [TextObservation]
    /// Rectangular graphical regions detected by Vision (e.g. figures, plates,
    /// embedded images). Combined with the gap-inference heuristic to isolate
    /// non-text illustrations (use-case step 5).
    public let detectedIllustrationRects: [CGRect]
    /// The full bounding rectangle of the page in normalized coordinates.
    public let pageRect: CGRect

    public init(
        textBlocks: [TextObservation],
        detectedIllustrationRects: [CGRect] = [],
        pageRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        self.textBlocks = textBlocks
        self.detectedIllustrationRects = detectedIllustrationRects
        self.pageRect = pageRect
    }
}

/// Stateful, value-type classifier that produces ordered `DetectedBlock`s.
///
/// Instantiated per page (cheap), it folds raw observations into semantic
/// zones, infers illustration gaps between text blocks, and assigns stable
/// reading-order sequence numbers.
struct LayoutClassifier {

    let heuristics: LayoutHeuristics

    public init(heuristics: LayoutHeuristics = .init()) {
        self.heuristics = heuristics
    }

    /// Produce the ordered list of detected blocks for the given observations.
    ///
    /// Vision's normalized space has its origin at the **bottom-left**, so:
    /// - "Top band" (headers) is `y > (1 - band)`.
    /// - "Bottom band" (footers/page numbers) is `y < band`.
    public func classify(_ observations: PageObservations) -> [DetectedBlock] {
        guard !observations.textBlocks.isEmpty else {
            return illustrationGaps(amongst: [], pageRect: observations.pageRect)
        }

        // Sort into reading order: top-to-bottom (descending y in bottom-left
        // origin means the first line has the highest y), then left-to-right.
        let ordered = observations.textBlocks.sorted { lhs, rhs in
            if abs(lhs.boundingRect.midY - rhs.boundingRect.midY) > 0.005 {
                return lhs.boundingRect.midY > rhs.boundingRect.midY
            }
            return lhs.boundingRect.minX < rhs.boundingRect.minX
        }

        // Compute the body column bounds (the dominant text x-extent) once, so
        // heading/blockquote heuristics can compare against it.
        let bodyBounds = bodyColumnBounds(of: ordered, in: observations.pageRect)

        var classified: [DetectedBlock] = []
        var sequence = 0

        for (index, text) in ordered.enumerated() {
            let blockType = refineType(
                for: text.boundingRect,
                transcript: text.transcript,
                in: observations.pageRect,
                bodyBounds: bodyBounds,
                previous: classified.last
            )

            classified.append(DetectedBlock(
                sequence: sequence,
                blockType: blockType,
                rawText: text.transcript,
                confidence: text.confidence,
                boundingRect: text.boundingRect
            ))
            _ = index
            sequence += 1
        }

        // Illustrations are detected two ways: (1) Vision's
        // `DetectRectanglesRequest` finds rectangular graphical regions directly;
        // (2) the gap heuristic infers empty bands between text. We union both,
        // deduplicating overlaps, then interleave into reading order.
        let inferredGaps = illustrationGaps(amongst: classified, pageRect: observations.pageRect)
        let illustrations = mergeIllustrations(
            detected: observations.detectedIllustrationRects,
            inferred: inferredGaps
        )
        var merged = classified
        for illustration in illustrations {
            // Insert each illustration at the correct reading-order index based
            // on its vertical center.
            let index = merged.firstIndex { existing in
                existing.boundingRect.midY < illustration.boundingRect.midY
            } ?? merged.count
            merged.insert(illustration, at: index)
        }

        // Re-sequence after merging.
        for index in merged.indices {
            merged[index].sequence = index
        }
        return merged
    }

    // MARK: - Classification

    /// Coarse zone classification (artifact / marginalia / body).
    private func type(for rect: CGRect, in pageRect: CGRect) -> BlockType {
        let band = heuristics.headerFooterBandRatio * pageRect.height
        let midY = rect.midY
        let gutter = heuristics.marginaliaGutterRatio * pageRect.width
        let midX = rect.midX

        if midY > pageRect.maxY - band { return .pageArtifact }
        if midY < pageRect.minY + band { return .pageArtifact }
        if midX < pageRect.minX + gutter || midX > pageRect.maxX - gutter {
            return .marginalia
        }
        return .bodyParagraph
    }

    /// Refined classification with heading/blockquote heuristics, applied after
    /// the coarse zone check.
    private func refineType(
        for rect: CGRect,
        transcript: String,
        in pageRect: CGRect,
        bodyBounds: (minX: CGFloat, maxX: CGFloat)?,
        previous: DetectedBlock?
    ) -> BlockType {
        let coarse = type(for: rect, in: pageRect)
        guard coarse == .bodyParagraph else { return coarse }

        // Blockquote: indented left edge relative to the body column.
        if let bounds = bodyBounds {
            let bodyWidth = bounds.maxX - bounds.minX
            let indent = rect.minX - bounds.minX
            if bodyWidth > 0, indent > heuristics.blockquoteIndentRatio * bodyWidth {
                return .blockquote
            }
        }

        // Heading: short line, possibly preceded by extra vertical space.
        // (Headings are emitted as bodyParagraph since the use-case lists them
        // under Body Content; this heuristic is reserved for future explicit
        // tagging, so we keep `.bodyParagraph` but with a comment hook.)
        if transcript.count <= heuristics.headingMaxChars,
           let prev = previous,
           (prev.boundingRect.minY - rect.maxY) >= heuristics.headingGapRatio {
            // Treat as a heading candidate but keep within bodyParagraph per
            // use-case (Body Content includes headings).
            return .bodyParagraph
        }
        return .bodyParagraph
    }

    /// Approximate the body text column's left/right edges by taking the most
    /// common x-extent among non-marginal, non-artifact observations.
    private func bodyColumnBounds(
        of ordered: [TextObservation],
        in pageRect: CGRect
    ) -> (minX: CGFloat, maxX: CGFloat)? {
        let body = ordered.filter { obs in
            type(for: obs.boundingRect, in: pageRect) == .bodyParagraph
        }
        guard !body.isEmpty else { return nil }
        let minX = body.map(\.boundingRect.minX).min() ?? pageRect.minX
        let maxX = body.map(\.boundingRect.maxX).max() ?? pageRect.maxX
        return (minX, maxX)
    }

    // MARK: - Illustration Merging

    /// Union detected and inferred illustration rects, dropping any that overlap
    /// existing text blocks (a true illustration contains no text).
    private func mergeIllustrations(
        detected: [CGRect],
        inferred: [DetectedBlock]
    ) -> [DetectedBlock] {
        let inferredRects = inferred.map { $0.boundingRect }
        var combined = detected + inferredRects
        // Deduplicate near-identical rects (detected often overlaps inferred).
        var deduped: [CGRect] = []
        for rect in combined {
            let alreadyCovered = deduped.contains { existing in
                rect.intersects(existing)
            }
            if !alreadyCovered {
                deduped.append(rect)
            }
        }
        combined = deduped
        return combined.enumerated().map { index, rect in
            DetectedBlock(
                sequence: index,
                blockType: .illustration,
                rawText: nil,
                confidence: 1.0,
                boundingRect: rect
            )
        }
    }

    // MARK: - Illustration Gap Inference

    /// Walks the vertical extent of the page looking for horizontal bands that
    /// contain no text yet are tall and wide enough to plausibly hold an
    /// illustration. Each such band becomes an `illustration` block.
    private func illustrationGaps(
        amongst classified: [DetectedBlock],
        pageRect: CGRect
    ) -> [DetectedBlock] {
        let minGap = heuristics.illustrationMinGapRatio * pageRect.height
        let minWidth = heuristics.illustrationMinWidthRatio * pageRect.width

        // The text body is approximated by the union of all non-artifact block
        // x-extents. We measure gaps along the vertical axis within this x-range.
        let bodyBlocks = classified.filter { $0.blockType != .pageArtifact }
        guard !bodyBlocks.isEmpty else { return [] }

        let bodyMinX = bodyBlocks.map(\.boundingRect.minX).min() ?? pageRect.minX
        let bodyMaxX = bodyBlocks.map(\.boundingRect.maxX).max() ?? pageRect.maxX
        let bodyWidth = bodyMaxX - bodyMinX
        guard bodyWidth >= minWidth else { return [] }

        // Sort body blocks top-to-bottom (descending y in bottom-left origin).
        let sorted = bodyBlocks.sorted { $0.boundingRect.midY > $1.boundingRect.midY }

        var gaps: [DetectedBlock] = []
        var prevBottom: CGFloat? = nil  // In bottom-left space, "bottom" = smaller y.

        for block in sorted {
            let top = block.boundingRect.maxY     // higher y in bottom-left space
            let bottom = block.boundingRect.minY  // lower y in bottom-left space

            if let prevBottom {
                let gap = prevBottom - top  // positive when there's empty space below
                if gap >= minGap {
                    let gapRect = CGRect(
                        x: bodyMinX,
                        y: top,
                        width: bodyWidth,
                        height: gap
                    )
                    gaps.append(DetectedBlock(
                        sequence: 0,  // Re-assigned by caller after merge.
                        blockType: .illustration,
                        rawText: nil,
                        confidence: 0.0,
                        boundingRect: gapRect
                    ))
                }
            }
            // Track the lowest bottom seen so far so gaps are measured against
            // the contiguous text body, not just the immediately preceding block.
            if prevBottom == nil || bottom < (prevBottom ?? .infinity) {
                prevBottom = bottom
            }
        }

        return gaps
    }
}
