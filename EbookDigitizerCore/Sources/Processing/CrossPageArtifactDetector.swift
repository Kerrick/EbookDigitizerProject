import Foundation
import CoreGraphics
import EbookDigitizerCore

/// Cross-page artifact deduplication (use-case success guarantee #2: "Repeating
/// page artifacts (page numbers, running headers) are identified and excluded
/// from the continuous XHTML text flow").
///
/// The per-page `LayoutClassifier` already tags top/bottom-band observations as
/// `pageArtifact`. This pass goes further: it detects text that **recurs across
/// pages** (e.g. a Book Title or Chapter Title that appears as a running header
/// on every page) and reclassifies any *body* block whose text matches a
/// recurring header — **but only when its font size matches the running-header
/// size**, so a real, larger chapter title on its first appearance stays in the
/// body flow instead of being sprinkled through every page.
///
/// Pure value-type: operates on snapshots and returns reclassification updates;
/// the service layer applies them to SwiftData.
public struct CrossPageArtifactDetector: Sendable {

    public init() {}

    /// A reclassification to apply: change the block with `blockID` (on
    /// `pageID`) from its current type to `pageArtifact`.
    public struct Reclassification: Sendable {
        public let pageID: UUID
        public let blockID: UUID
    }

    /// Snapshot of a page's blocks fed into the detector.
    public struct PageSnapshot: Sendable {
        public let id: UUID
        public let sequence: Int
        public let blocks: [BlockSnapshot]

        public init(id: UUID, sequence: Int, blocks: [BlockSnapshot]) {
            self.id = id
            self.sequence = sequence
            self.blocks = blocks
        }
    }

    public struct BlockSnapshot: Sendable {
        public let id: UUID
        public let sequence: Int
        public let blockType: BlockType
        public let rawText: String?
        /// Normalized bounding rect; its `height` is a proxy for font size
        /// (units are fractions of page height, since Vision's space is
        /// normalized to `[0, 1]`).
        public let boundingRect: CGRect
        /// Vision's own title detection — the primary signal that a body block is
        /// a real title (kept in the flow) rather than a recurring header copy.
        public let isTitle: Bool

        public init(id: UUID, sequence: Int, blockType: BlockType, rawText: String?, boundingRect: CGRect, isTitle: Bool = false) {
            self.id = id
            self.sequence = sequence
            self.blockType = blockType
            self.rawText = rawText
            self.boundingRect = boundingRect
            self.isTitle = isTitle
        }
    }

    // MARK: - Tuning

    /// Minimum number of pages a text must recur on to be considered a running
    /// header/artifact pattern.
    public var minRecurrencePages: Int = 3
    /// Maximum normalized edit-distance ratio for two strings to be considered
    /// the "same" recurring header (handles OCR noise across pages).
    public var maxEditDistanceRatio: Double = 0.25
    /// A body block is reclassified as an artifact only if its font size (bbox
    /// height ratio) is within this factor of the recurring header's median
    /// font size. A real chapter title is typically larger and stays in body.
    public var fontSizeTolerance: Double = 1.5
    /// A body block whose font size exceeds this multiple of the recurring
    /// header median is always considered a real title (kept in body), regardless
    /// of text match.
    public var realTitleSizeMultiple: Double = 1.6

    public init(
        minRecurrencePages: Int = 3,
        maxEditDistanceRatio: Double = 0.25,
        fontSizeTolerance: Double = 1.5,
        realTitleSizeMultiple: Double = 1.6
    ) {
        self.minRecurrencePages = minRecurrencePages
        self.maxEditDistanceRatio = maxEditDistanceRatio
        self.fontSizeTolerance = fontSizeTolerance
        self.realTitleSizeMultiple = realTitleSizeMultiple
    }

    /// Detect recurring artifact text and return the body blocks that should be
    /// reclassified as `pageArtifact`.
    public func detect(in pages: [PageSnapshot]) -> [Reclassification] {
        guard pages.count >= minRecurrencePages else { return [] }

        // 1. Collect all artifact text (already-classified pageArtifact blocks),
        //    keyed by a normalized form, recording the distinct pages and the
        //    font sizes (bbox heights) of each occurrence.
        var headerPattern: [String: (pages: Set<UUID>, fontSizes: [CGFloat])] = [:]
        for page in pages {
            for block in page.blocks where block.blockType == .pageArtifact {
                guard let text = block.rawText?.normalizedForComparison, !text.isEmpty else { continue }
                var entry = headerPattern[text] ?? (pages: [], fontSizes: [])
                entry.pages.insert(page.id)
                entry.fontSizes.append(block.boundingRect.height)
                headerPattern[text] = entry
            }
        }

        // 2. A text is a "recurring header" if it appears on >= minRecurrencePages
        //    distinct pages. Keep its median font size for comparison.
        let recurringHeaders: [(text: String, medianFontSize: CGFloat)] = headerPattern.compactMap { text, entry in
            guard entry.pages.count >= minRecurrencePages, let median = entry.fontSizes.median() else {
                return nil
            }
            return (text: text, medianFontSize: median)
        }

        guard !recurringHeaders.isEmpty else { return [] }

        // 3. Find body blocks whose text matches (or is close to) a recurring
        //    header. Reclassify as artifact ONLY when the body block's font
        //    size is comparable to the running-header size — a larger, real
        //    chapter title stays in the body flow.
        var reclassifications: [Reclassification] = []
        for page in pages {
            for block in page.blocks where block.blockType != .pageArtifact {
                guard let text = block.rawText?.normalizedForComparison, !text.isEmpty else { continue }
                guard let header = bestMatch(for: text, in: recurringHeaders) else { continue }

                // Primary signal: Vision's `isTitle` says this is a real title.
                // Keep it in the body even though the text matches a running
                // header — it's the chapter heading, not the recurring header.
                if block.isTitle {
                    continue
                }

                let bodyFontSize = block.boundingRect.height
                let ratio = bodyFontSize / header.medianFontSize

                // A real title is significantly larger than the running header:
                // keep it in the body. Otherwise it's a header copy → artifact.
                if ratio >= realTitleSizeMultiple {
                    continue
                }
                // Within tolerance of the header size → reclassify.
                if ratio <= fontSizeTolerance || header.medianFontSize <= 0 {
                    reclassifications.append(Reclassification(pageID: page.id, blockID: block.id))
                }
            }
        }
        return reclassifications
    }

    // MARK: - Matching

    private func bestMatch(
        for text: String,
        in headers: [(text: String, medianFontSize: CGFloat)]
    ) -> (text: String, medianFontSize: CGFloat)? {
        var best: (text: String, medianFontSize: CGFloat, ratio: Double)?
        for header in headers {
            if text == header.text { return header }
            let ratio = editDistanceRatio(text, header.text)
            if ratio <= maxEditDistanceRatio, best == nil || ratio < best?.ratio ?? 1 {
                best = (header.text, header.medianFontSize, ratio)
            }
        }
        return best.map { ($0.text, $0.medianFontSize) }
    }

    /// Levenshtein distance / max-length ratio, in [0, 1].
    private func editDistanceRatio(_ a: String, _ b: String) -> Double {
        let aChars = Array(a), bChars = Array(b)
        let maxLen = max(aChars.count, bChars.count)
        guard maxLen > 0 else { return 0 }
        var previousRow = Array(0...bChars.count)
        for (i, aChar) in aChars.enumerated() {
            var currentRow = [i + 1] + Array(repeating: 0, count: bChars.count)
            for (j, bChar) in bChars.enumerated() {
                let cost = aChar == bChar ? 0 : 1
                currentRow[j + 1] = min(
                    currentRow[j] + 1,
                    previousRow[j + 1] + 1,
                    previousRow[j] + cost
                )
            }
            previousRow = currentRow
        }
        return Double(previousRow[bChars.count]) / Double(maxLen)
    }
}

// MARK: - Helpers

private extension String {
    /// Lowercased, whitespace-collapsed, trimmed — for rough cross-page equality.
    var normalizedForComparison: String {
        lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

private extension Array where Element == CGFloat {
    /// Median of a non-empty array.
    func median() -> CGFloat? {
        guard !isEmpty else { return nil }
        let sorted = self.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }
}
