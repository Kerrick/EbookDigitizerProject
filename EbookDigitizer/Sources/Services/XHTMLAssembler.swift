import Foundation
import EbookDigitizerCore

/// Assembles the continuous XHTML document from a project's ordered
/// `ElementBlock` graph (use-case 6: "a continuous plaintext editor
/// containing the full XHTML document").
///
/// Pure, `Sendable`, and free of SwiftData — operates on plain value snapshots
/// so it can run off the main actor and be unit-tested.
public struct XHTMLAssembler: Sendable {

    public init() {}

    /// A single block projected into the assembler's value domain.
    public struct BlockInput: Sendable {
        public let id: UUID
        public let sequence: Int
        public let blockType: BlockType
        public let rawText: String?
        public let assetPath: String?

        public init(id: UUID, sequence: Int, blockType: BlockType, rawText: String?, assetPath: String?) {
            self.id = id
            self.sequence = sequence
            self.blockType = blockType
            self.rawText = rawText
            self.assetPath = assetPath
        }
    }

    /// Character range of a block within the assembled document, in UTF-16
    /// offset terms (matching `NSRange` semantics used by `NSTextView`).
    public struct BlockRange: Sendable {
        public let blockID: UUID
        /// UTF-16 offset of the block's start within the full document.
        public let utf16Lower: Int
        /// UTF-16 offset of the block's end within the full document.
        public let utf16Upper: Int
    }

    /// A page's assembled fragment plus the absolute ranges of its blocks.
    public struct AnnotatedPage: Sendable {
        public let pageID: UUID
        public let fragment: String
        public let blockRanges: [BlockRange]

        public init(pageID: UUID, fragment: String, blockRanges: [BlockRange]) {
            self.pageID = pageID
            self.fragment = fragment
            self.blockRanges = blockRanges
        }
    }

    /// Assemble the full document from per-page annotated fragments.
    public func assemble(pages: [AnnotatedPage]) -> String {
        pages.map(\.fragment).joined(separator: "\n")
    }

    /// Build the annotated page from raw block inputs.
    ///
    /// - `utf16Offset`: starting UTF-16 offset of this page's fragment within
    ///   the full document, so the returned ranges are absolute.
    public func annotate(
        pageID: UUID,
        blocks: [BlockInput],
        utf16Offset: Int
    ) -> AnnotatedPage {
        var fragment = ""
        var ranges: [BlockRange] = []

        for block in blocks.sorted(by: { $0.sequence < $1.sequence }) {
            let rendered = render(block)
            let lower = fragment.utf16.count
            fragment += rendered
            let upper = fragment.utf16.count
            if lower != upper {
                ranges.append(BlockRange(
                    blockID: block.id,
                    utf16Lower: utf16Offset + lower,
                    utf16Upper: utf16Offset + upper
                ))
            }
        }

        return AnnotatedPage(pageID: pageID, fragment: fragment, blockRanges: ranges)
    }

    // MARK: - Rendering

    /// Render a single block to its XHTML representation.
    ///
    /// `pageArtifact` blocks are excluded from the text flow entirely (use-case
    /// success guarantee #2). Illustrations become `<img>` tags referencing
    /// the cropped asset (success guarantee #3).
    public func render(_ block: BlockInput) -> String {
        switch block.blockType {
        case .bodyParagraph:
            return "<p>\(escape(block.rawText ?? ""))</p>"
        case .blockquote:
            return "<blockquote>\(escape(block.rawText ?? ""))</blockquote>"
        case .marginalia:
            // Marginalia emitted as review-visible notes; the exporter may
            // relocate them out of the main flow.
            return "<div class=\"marginalia\">\(escape(block.rawText ?? ""))</div>"
        case .pageArtifact:
            return ""
        case .illustration:
            let src = block.assetPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return "<img src=\"\(escape(src))\"/>"
        }
    }

    /// Escape the five XML-significant characters for safe XHTML embedding.
    public func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&apos;"
            default: output.append(char)
            }
        }
        return output
    }
}
