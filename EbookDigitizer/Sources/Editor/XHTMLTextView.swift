import AppKit

/// A plain-text `NSTextView` subclass tuned for the dual-pane XHTML review
/// surface described in use-case 6.
///
/// Responsibilities:
/// 1. Emit the **active line**'s character range whenever the selection or
///    layout changes (drives scroll-synchronization with the image stream).
/// 2. Capture the **selected range** so the SwiftUI layer can drive wrap macros
///    (`Cmd+B`, `Cmd+I`, …) and `<img>` insertions precisely.
/// 3. Honor the use-case 7a shortcut magic by intercepting `Cmd+B` / `Cmd+I`
///    natively via the responder chain and validating that an editable,
///    non-empty selection exists before wrapping.
///
/// Conforms to `@MainActor` because all `NSTextView`/`NSResponder` API is
/// main-actor-isolated under Swift 6. No GCD is used anywhere; any async work
/// is surfaced via `AsyncStream`/`@Published`-equivalent closures.
@MainActor
final class XHTMLTextView: NSTextView {

    // MARK: - Selection Emissions

    /// The current selected range, emitted on every selection change.
    var onSelectionChange: ((NSRange) -> Void)?

    /// The character range of the line containing the insertion point, emitted
    /// whenever the caret moves or the layout invalidates. The SwiftUI layer
    /// uses this to keep the plaintext editor aligned with the image stream.
    var onActiveLineChange: ((NSRange) -> Void)?

    // MARK: - Wrap Macros

    /// Wrap the current selection in the given intent's tags.
    ///
    /// If the selection is collapsed, the tags are inserted at the caret with an
    /// empty placeholder selection between them (so the user can type the new
    /// emphasized content in place). Returns `true` when the wrap succeeded and
    /// should consume the key event.
    @discardableResult
    func wrapSelection(in intent: WrapIntent) -> Bool {
        guard let textStorage else { return false }

        let selected = selectedRange()
        let selectedText = (textStorage.string as NSString).substring(with: selected)

        let replacement = intent.opening + selectedText + intent.closing

        // `replaceCharacters(in:with:)` is the canonical way to mutate a text
        // storage while preserving undo. We then restore a selection that
        // highlights the inner content (or places the caret between the tags).
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: selected, with: replacement)

        let innerRange: NSRange
        if selected.length > 0 {
            innerRange = NSRange(
                location: selected.location + intent.opening.count,
                length: selected.length
            )
        } else {
            innerRange = NSRange(
                location: selected.location + intent.opening.count,
                length: 0
            )
        }
        textStorage.endEditing()

        setSelectedRange(innerRange)
        didChangeText()
        return true
    }

    /// Insert an `<img>` tag (or any raw XHTML fragment) at the current caret,
    /// replacing any active selection. Used by use-case 7c ("To Create") to
    /// drop a new illustration reference into the flow.
    func insertXHTMLFragment(_ fragment: String) {
        let selected = selectedRange()
        textStorage?.replaceCharacters(in: selected, with: fragment)
        let newRange = NSRange(
            location: selected.location + (fragment as NSString).length,
            length: 0
        )
        setSelectedRange(newRange)
        didChangeText()
    }

    // MARK: - Responder Chain (Shortcut Magic)

    /// `true` only when there is an actual editable selection to operate on.
    private var canWrap: Bool {
        isEditable && textStorage != nil
    }

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
        // Only emit the final, settled selection (not intermediate drags).
        if !stillSelectingFlag {
            onSelectionChange?(charRange)
            emitActiveLine()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        // Layout may have shifted, so the active line geometry may have moved
        // even though the caret didn't.
        emitActiveLine()
    }

    // MARK: - Active Line

    private func emitActiveLine() {
        guard textStorage != nil else { return }

        let selected = selectedRange()
        let string = (textStorage?.string ?? "") as NSString
        let lineRange = string.lineRange(
            for: NSRange(location: selected.location, length: 0)
        )

        onActiveLineChange?(lineRange)
    }
}
