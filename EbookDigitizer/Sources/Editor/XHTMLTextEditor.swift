import AppKit
import SwiftUI
import EbookDigitizerCore

/// SwiftUI bridge for the XHTML plaintext editor (use-case 6, right pane).
///
/// Implements `NSViewRepresentable` so SwiftUI owns the `NSTextView` lifecycle
/// while we keep native macOS keybind behavior: `Cmd+B`/`Cmd+I` flow through
/// the responder chain into `XHTMLTextView.toggleStrong(_:)` /
/// `toggleItalics(_:)`, with zero custom key-event swallowing.
///
/// All AppKit use is isolated to `@MainActor` — no GCD, no legacy run-loop
/// tricks. Text changes flow back to SwiftUI via a `Binding<String>` so the
/// SwiftData model (and autosave) stay in sync.
struct XHTMLTextEditor: NSViewRepresentable {

    @Binding var text: String
    var isEditable: Bool = true

    /// When set, the editor scrolls so this UTF-16 NSRange is visible. Drives
    /// the canvas -> editor direction of scroll-sync.
    var scrollTarget: NSRange? = nil
    /// When set, every `<img>` tag referencing this asset name is removed from
    /// the document. Drives use-case 7c.3 (delete illustration).
    var removeImageTagsForAsset: String? = nil
    /// When set, this XHTML fragment is inserted at the editor's caret (use-case
    /// 7c.2: creating an illustration inserts the matching `<img>` tag).
    var insertionFragment: String? = nil

    /// Emitted on every settled selection change.
    var onSelectionChange: ((NSRange) -> Void)? = nil
    /// Emitted whenever the caret's enclosing line changes (drives scroll-sync).
    var onActiveLineChange: ((NSRange) -> Void)? = nil

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
        textView.delegate = context.coordinator

        // Wire the subclass's closures back to SwiftUI-facing callbacks.
        textView.onSelectionChange = { [weak coordinator = context.coordinator] range in
            coordinator?.onSelectionChange?(range)
        }
        textView.onActiveLineChange = { [weak coordinator = context.coordinator] range in
            coordinator?.onActiveLineChange?(range)
        }

        // Seed initial content without triggering an undo or a coordinator
        // write-back (which would clobber the binding).
        textView.textStorage?.setAttributedString(
            NSAttributedString(
                string: text,
                attributes: [.font: textView.font ?? .systemFont(ofSize: 13)]
            )
        )

        return textView
    }

    func updateNSView(_ nsView: XHTMLTextView, context: Context) {
        // Re-apply editability in case it toggles at runtime.
        nsView.isEditable = isEditable

        // Re-bind closures in case they were rebuilt with new captures.
        context.coordinator.onSelectionChange = onSelectionChange
        context.coordinator.onActiveLineChange = onActiveLineChange

        // Programmatic scroll request from the canvas.
        if let scrollTarget {
            nsView.scrollToRange(scrollTarget)
        }

        // Programmatic `<img>` sweep for deleted illustrations.
        if let asset = removeImageTagsForAsset, !asset.isEmpty {
            nsView.removeImageTags(referencingAssetNamed: asset)
        }

        // Programmatic `<img>` insertion for created illustrations (7c.2).
        if let fragment = insertionFragment, !fragment.isEmpty {
            nsView.insertXHTMLFragment(fragment)
        }

        // Reflect external text mutations (e.g. from a "Force Re-Extract"
        // command in use-case 7d) without disturbing the user's caret when the
        // text is identical to what the view already shows.
        let current = nsView.textStorage?.string ?? ""
        if current != text {
            let selected = nsView.selectedRange()
            nsView.textStorage?.setAttributedString(
                NSAttributedString(
                    string: text,
                    attributes: [.font: nsView.font ?? .systemFont(ofSize: 13)]
                )
            )
            // Best-effort caret restoration.
            let clamped = NSMakeRange(
                min(selected.location, text.count),
                min(selected.length, max(0, text.count - selected.location))
            )
            nsView.setSelectedRange(clamped)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var text: Binding<String>
        var onSelectionChange: ((NSRange) -> Void)?
        var onActiveLineChange: ((NSRange) -> Void)?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? XHTMLTextView else { return }
            text.wrappedValue = textView.textStorage?.string ?? ""
        }

        // `textViewDidChangeSelection` is emitted by the text view's own delegate path;
        // we don't strictly need it here because the subclass emits via closure,
        // but it's a stable hook for future overlay rendering.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? XHTMLTextView else { return }
            onSelectionChange?(textView.selectedRange())
        }
    }
}
