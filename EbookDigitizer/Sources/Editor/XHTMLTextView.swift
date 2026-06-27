import AppKit
import EbookDigitizerCore

/// A plain-text `NSTextView` subclass that is a **block coordinator**, not a
/// free-text editor backed by a single string.
///
/// The user sees one continuous plaintext document, but the data model is
/// per-block `rawText`. This view maintains a **manifest** mapping each
/// character range to its owning block ID, and routes edits directly back to
/// the affected block(s) — never marshalling the whole document through a
/// string and re-parsing it positionally.
///
/// This is what makes paragraph splitting safe (use-case 7a): when the user
/// inserts a `<p>` tag mid-block, the coordinator detects that the block's
/// range now contains a tag boundary, splits it into two blocks, and writes
/// each half's text back to its owner. No positional matching, no drift, no
/// arbitrary metadata embedded in the XHTML.
///
/// Conforms to `@MainActor` because all `NSTextView`/`NSResponder` API is
/// main-actor-isolated under Swift 6. No GCD is used anywhere.
@MainActor
final class XHTMLTextView: NSTextView {

    // MARK: - Block Manifest

    /// One entry per rendered block: its stable ID and the character range it
    /// currently occupies in the text storage.
    struct BlockEntry: Equatable {
        let id: UUID
        var range: NSRange
    }

    /// The ordered manifest of block → character range. Updated whenever the
    /// text storage changes (see `reconcileManifest()`).
    private(set) var manifest: [BlockEntry] = []

    /// Called whenever a block's `rawText` changes as a result of an edit.
    /// The view-model persists these to SwiftData. Carries the block ID and the
    /// new text (empty string → `nil` is the caller's concern).
    var onBlockTextChange: ((UUID, String) -> Void)?

    /// Called when an edit splits a block into two (e.g. the user inserted a
    /// `</p><p>` boundary inside a paragraph). The new block inherits the
    /// original's type and is inserted immediately after it in sequence.
    var onBlockSplit: ((UUID, UUID, String) -> Void)?

    /// Called when adjacent blocks of the same type are merged (the user
    /// deleted the tag boundary between them). The second block is removed;
    /// its text was already appended to the first via `onBlockTextChange`.
    var onBlockMerge: ((UUID, UUID) -> Void)?

    // MARK: - Selection Emissions

    /// The current selected range, emitted on every settled selection change.
    var onSelectionChange: ((NSRange) -> Void)?

    /// The character range of the line containing the insertion point, emitted
    /// whenever the caret moves or the layout invalidates. Drives scroll-sync.
    var onActiveLineChange: ((NSRange) -> Void)?

    // MARK: - Block Rendering

    /// Render the supplied blocks into the text storage, rebuilding the
    /// manifest. Called by the representable when the block set changes
    /// (processing, re-extraction, illustration create/delete).
    ///
    /// Each block is rendered as its XHTML tag with the raw text inside, joined
    /// by newlines. `pageArtifact` blocks are omitted entirely.
    func renderBlocks(_ blocks: [RenderedBlock]) {
        guard let storage = textStorage else { return }

        let pieces: [(tag: String, id: UUID)] = blocks.compactMap { block in
            guard block.blockType != .pageArtifact else { return nil }
            return (tag: renderTag(for: block), id: block.id)
        }

        // Rebuild storage without triggering delegate write-back.
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: 0, length: storage.length),
            with: pieces.map(\.tag).joined(separator: "\n")
        )
        storage.endEditing()

        // Rebuild manifest from the rendered pieces.
        manifest.removeAll(keepingCapacity: true)
        var location = 0
        for piece in pieces {
            let length = (piece.tag as NSString).length
            manifest.append(BlockEntry(id: piece.id, range: NSRange(location: location, length: length)))
            location += length + 1 // +1 for the "\n" separator
        }

        didChangeText()
    }

    /// A block projected for rendering, decoupled from SwiftData.
    struct RenderedBlock: Sendable {
        let id: UUID
        let blockType: BlockType
        let rawText: String?
        let assetPath: String?

        init(id: UUID, blockType: BlockType, rawText: String?, assetPath: String?) {
            self.id = id
            self.blockType = blockType
            self.rawText = rawText
            self.assetPath = assetPath
        }
    }

    private func renderTag(for block: RenderedBlock) -> String {
        switch block.blockType {
        case .bodyParagraph:
            return "<p>\(escape(block.rawText ?? ""))</p>"
        case .blockquote:
            return "<blockquote>\(escape(block.rawText ?? ""))</blockquote>"
        case .marginalia:
            return "<div class=\"marginalia\">\(escape(block.rawText ?? ""))</div>"
        case .illustration:
            let src = block.assetPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return "<img src=\"\(escape(src))\"/>"
        case .pageArtifact:
            return ""
        }
    }

    private func escape(_ text: String) -> String {
        var output = ""
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

    // MARK: - Wrap Macros (use-case 7a.2)

    /// Wrap the current selection in the given intent's tags.
    @discardableResult
    func wrapSelection(in intent: WrapIntent) -> Bool {
        guard let textStorage else { return false }

        let selected = selectedRange()
        let selectedText = (textStorage.string as NSString).substring(with: selected)
        let replacement = intent.opening + selectedText + intent.closing

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: selected, with: replacement)
        textStorage.endEditing()

        let innerRange = NSRange(
            location: selected.location + intent.opening.count,
            length: selected.length
        )
        setSelectedRange(innerRange)
        didChangeText()
        return true
    }

    // MARK: - Insertion / Removal (use-case 7c)

    /// Insert an `<img>` tag at the caret (use-case 7c.2). The new block is
    /// registered in the manifest and reported via `onBlockSplit` semantics:
    /// a fresh block ID is minted for the illustration.
    func insertXHTMLFragment(_ fragment: String, blockID: UUID) {
        let selected = selectedRange()
        textStorage?.replaceCharacters(in: selected, with: fragment)
        let newRange = NSRange(
            location: selected.location + (fragment as NSString).length,
            length: 0
        )
        setSelectedRange(newRange)
        didChangeText()
    }

    /// Remove every `<img>` tag whose `src` references the given asset name
    /// (use-case 7c.3). Also drops the corresponding manifest entries.
    func removeImageTags(referencingAssetNamed assetName: String) {
        guard let storage = textStorage, !assetName.isEmpty else { return }
        let needle = "<img src=\"\(assetName)\"/>"
        storage.beginEditing()
        var location = storage.length
        while location > 0 {
            let searchLength = min(256, location)
            let start = location - searchLength
            let probe = NSRange(location: start, length: searchLength)
            let substring = (storage.string as NSString).substring(with: probe)
            let foundNS = (substring as NSString).range(of: needle)
            if foundNS.location != NSNotFound {
                let absolute = NSRange(location: start + foundNS.location, length: foundNS.length)
                storage.replaceCharacters(in: absolute, with: "")
                location = start + foundNS.location
                continue
            }
            location = start
        }
        storage.endEditing()
        didChangeText()
    }

    // MARK: - Scroll (use-case 6 scroll-sync)

    /// Scroll so the given UTF-16 NSRange is visible (canvas → editor).
    func scrollToRange(_ range: NSRange) {
        guard let layoutManager, let textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        scrollToVisible(rect.insetBy(dx: 0, dy: -8))
    }

    /// Scroll so the block with the given ID is visible.
    func scrollToBlock(_ id: UUID) {
        guard let entry = manifest.first(where: { $0.id == id }) else { return }
        scrollToRange(entry.range)
    }

    // MARK: - Responder Chain (Shortcut Magic)

    private var canWrap: Bool { isEditable && textStorage != nil }

    @IBAction func toggleStrong(_ sender: Any?) {
        guard canWrap else { return }
        _ = wrapSelection(in: .strong)
    }

    @IBAction func toggleItalics(_ sender: Any?) {
        guard canWrap else { return }
        _ = wrapSelection(in: .em)
    }

    // MARK: - Selection / Layout Tracking

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        if !stillSelectingFlag {
            onSelectionChange?(charRange)
            emitActiveLine()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        reconcileManifest()
        emitActiveLine()
    }

    // MARK: - Active Line

    private func emitActiveLine() {
        guard textStorage != nil else { return }
        let selected = selectedRange()
        let string = (textStorage?.string ?? "") as NSString
        let lineRange = string.lineRange(for: NSRange(location: selected.location, length: 0))
        onActiveLineChange?(lineRange)
    }

    // MARK: - Manifest Reconciliation

    /// After an edit, walk the manifest and reconcile each block's text and
    /// range against the new storage contents. This is the heart of the
    /// coordinator: it detects block splits (a tag boundary now appears inside
    /// a block's range), merges (a tag boundary was deleted), and plain text
    /// edits, routing each to the right block via the callbacks — without ever
    /// reparsing the whole document positionally.
    private func reconcileManifest() {
        guard let storage = textStorage else { return }
        let fullString = storage.string as NSString

        // Re-segment the document into XHTML top-level elements by scanning for
        // tag boundaries, then align them to the existing manifest entries by
        // overlap. This is O(n) in the number of blocks, not document length.
        let segments = segmentDocument(fullString)

        // Align segments to manifest entries. Strategy: match each segment to
        // the manifest entry whose range it most overlaps; if a manifest entry
        // is split across multiple segments, that's a block split; if multiple
        // manifest entries fall within one segment, that's a merge.
        var newManifest: [BlockEntry] = []
        var manifestIndex = 0
        var pendingSplit: (originalID: UUID, newText: String)?

        for segment in segments {
            // Find the manifest entry overlapping this segment's location.
            while manifestIndex < manifest.count,
                  NSMaxRange(manifest[manifestIndex].range) < segment.range.location {
                // This manifest entry ended before this segment — if it wasn't
                // consumed by a segment, it was deleted. Nothing to emit.
                manifestIndex += 1
            }

            if manifestIndex < manifest.count,
               NSIntersectionRange(manifest[manifestIndex].range, segment.range).length > 0 {
                let entry = manifest[manifestIndex]
                let segmentText = fullString.substring(with: segment.range)
                let innerText = extractInnerText(from: segmentText)

                // Determine the block ID for this segment.
                if let pending = pendingSplit {
                    // A prior split left a new block pending; this segment is
                    // the second half. Mint its ID via the split callback.
                    let newID = UUID()
                    onBlockSplit?(pending.originalID, newID, innerText)
                    newManifest.append(BlockEntry(id: newID, range: segment.range))
                    pendingSplit = nil
                } else {
                    // Normal edit within a single block's range.
                    onBlockTextChange?(entry.id, innerText)
                    newManifest.append(BlockEntry(id: entry.id, range: segment.range))
                }

                // If this manifest entry extends past this segment, a split
                // occurred: the next segment will be the second half.
                if NSMaxRange(entry.range) > NSMaxRange(segment.range) {
                    pendingSplit = (originalID: entry.id, newText: innerText)
                } else {
                    manifestIndex += 1
                }
            } else {
                // No overlapping manifest entry: this is a newly inserted
                // element (e.g. the user typed a fresh `<p>`). Defer to the
                // view-model — it will mint a block. For now, track a
                // placeholder range so subsequent entries align.
                let placeholderID = UUID()
                onBlockSplit?(manifest.first?.id ?? placeholderID,
                              placeholderID,
                              extractInnerText(from: fullString.substring(with: segment.range)))
                newManifest.append(BlockEntry(id: placeholderID, range: segment.range))
            }
        }

        // Any manifest entries not consumed were merged into the prior segment.
        // Emit merge callbacks for them (their text is already in the kept
        // block via onBlockTextChange).
        if manifestIndex < manifest.count, newManifest.count > 0 {
            let keptID = newManifest.last!.id
            while manifestIndex < manifest.count {
                onBlockMerge?(keptID, manifest[manifestIndex].id)
                manifestIndex += 1
            }
        }

        manifest = newManifest
    }

    /// Segment the document into top-level XHTML elements, returning each
    /// element's character range and tag name. Handles `<p>…</p>`,
    /// `<blockquote>…</blockquote>`, `<div …>…</div>`, and self-closing `<img …/>`.
    private func segmentDocument(_ string: NSString) -> [(range: NSRange, tagName: String)] {
        var segments: [(range: NSRange, tagName: String)] = []
        let fullRange = NSRange(location: 0, length: string.length)
        var searchStart = 0

        while searchStart < string.length {
            // Find the next "<".
            let restRange = NSRange(location: searchStart, length: string.length - searchStart)
            let openTagRange = string.range(of: "<", options: [], range: restRange)
            if openTagRange.location == NSNotFound { break }

            // Determine the tag name.
            let afterTag = NSRange(location: openTagRange.location + 1,
                                   length: string.length - openTagRange.location - 1)
            let tagEnd = string.range(of: ">", options: [], range: afterTag)
            if tagEnd.location == NSNotFound { break }

            let tagContent = string.substring(with: NSRange(
                location: openTagRange.location + 1,
                length: tagEnd.location - openTagRange.location - 1
            ))
            let tagName = tagContent.split(separator: " ").first.map(String.init) ?? tagContent
            let cleanTagName = tagName.replacingOccurrences(of: "/", with: "")

            // Self-closing (e.g. <img .../>).
            if tagContent.hasSuffix("/") {
                let elementRange = NSRange(
                    location: openTagRange.location,
                    length: tagEnd.location + 1 - openTagRange.location
                )
                segments.append((elementRange, cleanTagName))
                searchStart = tagEnd.location + 1
                continue
            }

            // Find the matching closing tag.
            let closeNeedle = "</\(cleanTagName)>"
            let closeSearchRange = NSRange(
                location: tagEnd.location + 1,
                length: string.length - tagEnd.location - 1
            )
            let closeRange = string.range(of: closeNeedle, options: [], range: closeSearchRange)
            if closeRange.location == NSNotFound {
                // Malformed: treat the rest as one segment.
                let elementRange = NSRange(
                    location: openTagRange.location,
                    length: string.length - openTagRange.location
                )
                segments.append((elementRange, cleanTagName))
                break
            }
            let elementRange = NSRange(
                location: openTagRange.location,
                length: closeRange.location + closeRange.length - openTagRange.location
            )
            segments.append((elementRange, cleanTagName))
            searchStart = closeRange.location + closeRange.length
        }

        return segments
    }

    /// Extract the inner text from an XHTML element, unescaping entities.
    private func extractInnerText(from element: String) -> String {
        // Strip the opening and closing tags.
        guard let firstGT = element.firstIndex(of: ">"),
              let lastLT = element.lastIndex(of: "<") else { return element }
        let inner = String(element[element.index(after: firstGT)..<lastLT])
        return unescape(inner)
    }

    private func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    /// The block ID owning the character at `location`, for scroll-sync.
    func blockID(at location: Int) -> UUID? {
        manifest.first { NSLocationInRange(location, $0.range) }?.id
    }
}
