import Foundation
import SwiftSoup
import EbookDigitizerCore

/// Parses the live-edited XHTML document back into per-block `rawText` updates,
/// closing the round-trip from the `XHTMLAssembler` (use-case 7a: edits must
/// persist back to the model so the system remembers them).
///
/// Uses SwiftSoup (a Swift port of Jsoup) because it tolerates malformed input —
/// essential while the Producer is mid-edit and the document may be momentarily
/// ill-formed. The parser walks the body's top-level child nodes in document
/// order and matches them to the supplied block IDs by sequence.
///
/// `@MainActor`-free and `Sendable`-friendly: pure value in, pure values out.
public struct DocumentParser: Sendable {

    public init() {}

    /// A single block update to apply to SwiftData.
    public struct BlockUpdate: Sendable {
        public let blockID: UUID
        public let rawText: String?
        public let assetPath: String?

        public init(blockID: UUID, rawText: String?, assetPath: String?) {
            self.blockID = blockID
            self.rawText = rawText
            self.assetPath = assetPath
        }
    }

    /// Parse `documentText` and produce updates for the blocks identified by
    /// `orderedBlockIDs` (one per top-level node in the body, in sequence).
    ///
    /// Nodes are matched positionally to the ordered block IDs. If the document
    /// has more nodes than blocks (the user added new tags), the extras are
    /// ignored; if fewer (the user deleted tags), the trailing blocks keep
    /// their previous values. `pageArtifact` blocks are not present in the
    /// document, so the caller must pass only the *rendered* block IDs in order.
    public func parse(
        documentText: String,
        renderedBlockIDs: [UUID]
    ) -> [BlockUpdate] {
        guard let doc = try? SwiftSoup.parse(documentText) else {
            return []
        }
        guard let body = doc.body() else { return [] }
        // `children()` returns the top-level Element children of <body>.
        // Our assembler emits only block elements (no free text nodes), so this
        // aligns 1:1 with the rendered block IDs in order.
        let nodes = body.children()

        var updates: [BlockUpdate] = []
        let count = min(nodes.size(), renderedBlockIDs.count)

        for index in 0..<count {
            let element = nodes.get(index)
            let blockID = renderedBlockIDs[index]
            if let update = update(for: element, blockID: blockID) {
                updates.append(update)
            }
        }

        return updates
    }

    // MARK: - Node → Update

    private func update(for element: Element, blockID: UUID) -> BlockUpdate? {
        let tagName = element.tagName().lowercased()

        switch tagName {
        case "p":
            return BlockUpdate(blockID: blockID, rawText: text(of: element), assetPath: nil)
        case "blockquote":
            return BlockUpdate(blockID: blockID, rawText: text(of: element), assetPath: nil)
        case "div":
            return BlockUpdate(blockID: blockID, rawText: text(of: element), assetPath: nil)
        case "img":
            let src = (try? element.attr("src")) ?? ""
            return BlockUpdate(blockID: blockID, rawText: nil, assetPath: src.isEmpty ? nil : src)
        default:
            return nil
        }
    }

    private func text(of element: Element) -> String? {
        let raw = (try? element.text()) ?? ""
        return raw.isEmpty ? nil : raw
    }
}
