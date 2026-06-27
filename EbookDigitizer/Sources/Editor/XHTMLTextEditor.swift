import AppKit
import SwiftUI
import EbookDigitizerCore

/// SwiftUI bridge for the XHTML plaintext editor (use-case 6, right pane).
///
/// The user sees one continuous plaintext document, but the data model is
/// per-block. This representable renders blocks into the `XHTMLTextView` and
/// routes edits back to the owning block(s) via the coordinator callbacks — no
/// global string marshalling, no positional parsing. This makes paragraph
/// splitting (use-case 7a) safe: inserting a `<p>` boundary splits the block,
/// it doesn't shift every subsequent block's positional match.
///
/// `Cmd+B`/`Cmd+I` flow through the responder chain into
/// `XHTMLTextView.toggleStrong(_:)` / `toggleItalics(_:)`.
///
/// All AppKit use is isolated to `@MainActor` — no GCD.
struct XHTMLTextEditor: NSViewRepresentable {

    /// The blocks to render, in document order. The coordinator renders each
    /// as its XHTML tag and tracks the character range → block ID mapping.
    var blocks: [XHTMLTextView.RenderedBlock]
    var isEditable: Bool = true

    /// When set, the editor scrolls so this block ID is visible. Drives the
    /// canvas → editor direction of scroll-sync.
    var scrollTargetBlockID: UUID? = nil
    /// When set, every `<img>` tag referencing this asset name is removed
    /// (use-case 7c.3 delete illustration).
    var removeImageTagsForAsset: String? = nil
    /// When set, this XHTML fragment is inserted at the caret as a new
    /// illustration block (use-case 7c.2 create illustration).
    var insertionFragment: (fragment: String, blockID: UUID)? = nil

    /// Emitted when a block's inner text changes (user typed in it).
    var onBlockTextChange: ((UUID, String) -> Void)? = nil
    /// Emitted when an edit splits a block into two (user inserted a tag
    /// boundary mid-paragraph). The VM creates a new `ElementBlock`.
    var onBlockSplit: ((UUID, UUID, String) -> Void)? = nil
    /// Emitted when adjacent blocks merge (user deleted a tag boundary).
    var onBlockMerge: ((UUID, UUID) -> Void)? = nil
    /// Emitted whenever the caret's enclosing line changes (scroll-sync).
    var onActiveLineChange: ((NSRange) -> Void)? = nil
    /// Emitted on every settled selection change.
    var onSelectionChange: ((NSRange) -> Void)? = nil

    func makeNSView(context: Context) -> XHTMLTextView {
        let textView = XHTMLTextView()
        textView.isEditable = isEditable
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.insertionPointColor = .controlAccentColor

        // Wire the coordinator's callbacks back to SwiftUI.
        textView.onBlockTextChange = context.coordinator.onBlockTextChange
        textView.onBlockSplit = context.coordinator.onBlockSplit
        textView.onBlockMerge = context.coordinator.onBlockMerge
        textView.onSelectionChange = context.coordinator.onSelectionChange
        textView.onActiveLineChange = context.coordinator.onActiveLineChange

        // Seed initial content from blocks.
        textView.renderBlocks(blocks)
        return textView
    }

    func updateNSView(_ nsView: XHTMLTextView, context: Context) {
        nsView.isEditable = isEditable

        // Re-bind callbacks in case they were rebuilt with new captures.
        context.coordinator.onBlockTextChange = onBlockTextChange
        context.coordinator.onBlockSplit = onBlockSplit
        context.coordinator.onBlockMerge = onBlockMerge
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onActiveLineChange = onActiveLineChange

        // Re-render blocks when the set changes (processing, illustration
        // create/delete, re-extraction). The coordinator preserves the user's
        // caret via best-effort restoration.
        let currentBlocks = nsView.manifest.map(\.id)
        let newBlocks = blocks.map(\.id)
        if currentBlocks != newBlocks || nsView.textStorage?.string.isEmpty == true {
            nsView.renderBlocks(blocks)
        }

        // Programmatic scroll request from the canvas.
        if let id = scrollTargetBlockID {
            nsView.scrollToBlock(id)
        }

        // Programmatic `<img>` removal for deleted illustrations.
        if let asset = removeImageTagsForAsset, !asset.isEmpty {
            nsView.removeImageTags(referencingAssetNamed: asset)
        }

        // Programmatic `<img>` insertion for created illustrations.
        if let insertion = insertionFragment, !insertion.fragment.isEmpty {
            nsView.insertXHTMLFragment(insertion.fragment, blockID: insertion.blockID)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var onBlockTextChange: ((UUID, String) -> Void)?
        var onBlockSplit: ((UUID, UUID, String) -> Void)?
        var onBlockMerge: ((UUID, UUID) -> Void)?
        var onSelectionChange: ((NSRange) -> Void)?
        var onActiveLineChange: ((NSRange) -> Void)?
    }
}
