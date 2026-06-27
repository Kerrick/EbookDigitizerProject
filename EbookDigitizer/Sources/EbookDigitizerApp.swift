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
            ReviewWorkspaceView()
                .frame(minWidth: 1000, minHeight: 650)
        }
        .modelContainer(modelContainer)
    }
}

/// Dual-pane review workspace (use-case 6): image stream on the left, XHTML
/// plaintext editor on the right.
///
/// This Phase 4 scaffold renders synthetic page snapshots so the gesture
/// surface is live during development. Phase 5 will swap in real SwiftData
/// query results and wire scroll-synchronization through the active-line hook.
private struct ReviewWorkspaceView: View {

    @State private var text = """
    <p>The quick brown fox jumps over the lazy dog.</p>
    <p>Select a word and press Cmd+B or Cmd+I.</p>
    <p>Drag on the left canvas to draw an illustration box.</p>
    """

    @State private var pages: [PageSnapshot] = ReviewWorkspaceView.samplePages

    var body: some View {
        HSplitView {
            ImageCanvasPane(
                pages: pages,
                pageHeightFraction: 0.6,
                onAnnotationChange: { id, rect in
                    print("Box \(id) moved/resized → \(rect)")
                },
                onAnnotationCreate: { draft in
                    print("New illustration box created: \(draft.id) at \(draft.normalizedRect)")
                },
                onAnnotationDelete: { id in
                    print("Box \(id) deleted")
                }
            )
            .frame(minWidth: 420)

            XHTMLTextEditor(text: $text)
                .frame(minWidth: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Bold") {}
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") {}
                    .keyboardShortcut("i", modifiers: .command)
            }
        }
    }

    // MARK: - Sample Data

    /// Synthetic snapshots so the gesture surface is exercised at runtime
    /// before Phase 5 wires in real SwiftData queries.
    private static var samplePages: [PageSnapshot] {
        let image = makeSampleImage()
        return (0..<3).map { index in
            PageSnapshot(
                id: UUID(),
                sequence: index,
                status: index == 1 ? .manualReviewRequired : .ready,
                image: image,
                blocks: [
                    AnnotationDraft(
                        id: UUID(),
                        sequence: 0,
                        blockType: .illustration,
                        normalizedRect: CGRect(x: 0.15, y: 0.45, width: 0.30, height: 0.20)
                    )
                ]
            )
        }
    }

    /// Generates a placeholder `NSImage` so the canvas has something to render
    /// without bundling assets.
    private static func makeSampleImage() -> NSImage {
        let size = NSSize(width: 800, height: 1100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]
        let str = NSAttributedString(string: "Sample Page", attributes: attrs)
        str.draw(in: NSRect(x: 0, y: size.height / 2 - 20, width: size.width, height: 40))
        image.unlockFocus()
        return image
    }
}
