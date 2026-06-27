import SwiftUI
import SwiftData
import EbookDigitizerCore

@main
struct EbookDigitizerApp: App {

    /// The shared SwiftData container. Configured for automatic background
    /// persistence + undo/redo out of the box. `@MainActor`-isolated because
    /// the App's `ModelContext` is bound to the main actor — no GCD.
    private let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: Project.self, Page.self, ElementBlock.self
            )
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            EditorPreviewView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .modelContainer(modelContainer)
    }
}

/// Lightweight dual-pane scaffold that exercises Phase 3's `XHTMLTextEditor`
/// so the keyboard macros and selection/active-line tracking are live during
/// development. Phase 4 will replace this with the real Canvas binding.
private struct EditorPreviewView: View {

    @State private var text = """
    <p>The quick brown fox jumps over the lazy dog.</p>
    <p>Select a word and press Cmd+B or Cmd+I.</p>
    """

    @State private var lastSelection: NSRange = NSRange(location: 0, length: 0)
    @State private var activeLine: NSRange = NSRange(location: 0, length: 0)

    var body: some View {
        HSplitView {
            XHTMLTextEditor(
                text: $text,
                onSelectionChange: { range in lastSelection = range },
                onActiveLineChange: { range in activeLine = range }
            )
            .frame(minWidth: 360)

            VStack(alignment: .leading, spacing: 16) {
                Text("Selection Diagnostics")
                    .font(.headline)
                LabeledContent("Length") { Text("\(lastSelection.length)") }
                LabeledContent("Location") { Text("\(lastSelection.location)") }
                LabeledContent("Active line location") { Text("\(activeLine.location)") }
                LabeledContent("Active line length") { Text("\(activeLine.length)") }
                Spacer()
            }
            .padding()
            .frame(minWidth: 240, alignment: .topLeading)
            .background(.regularMaterial)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Bold") { /* routed via Cmd+B responder chain */ }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { /* routed via Cmd+I responder chain */ }
                    .keyboardShortcut("i", modifiers: .command)
            }
        }
    }
}
