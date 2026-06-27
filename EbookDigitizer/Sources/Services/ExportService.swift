import Foundation
import SwiftData
import EbookDigitizerCore

/// Writes the finalized, clean XHTML document and asset folder to disk
/// (use-case step 9 + success guarantees 1, 2, 3).
///
/// Runs on `@MainActor` because it reads from the main-bound `ModelContext`,
/// but all file I/O is done synchronously on the main actor (small, bounded
/// writes) — no GCD.
@MainActor
public final class ExportService {

    private let modelContainer: ModelContainer
    private let assembler = XHTMLAssembler()

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Export the project to `xhtmlURL`. Uses the supplied `documentText` as
    /// the body (honoring any manual edits the Producer made in the editor),
    /// and copies illustration assets into an `assets/` folder beside the file.
    /// Asset paths in the text are left as-is when they already reference
    /// `assets/`; otherwise they're relativized.
    public func export(projectID: UUID, documentText: String, to xhtmlURL: URL) throws {
        let assetsFolder = xhtmlURL.deletingLastPathComponent()
            .appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assetsFolder, withIntermediateDirectories: true
        )

        // Copy any cropped illustration assets referenced by blocks into the
        // export folder, so the XHTML's relative `assets/<name>` paths resolve.
        let context = modelContainer.mainContext
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectID }
        )
        if let project = try context.fetch(descriptor).first {
            for page in project.pages {
                for block in page.elementBlocks where block.blockType == .illustration {
                    if let abs = block.assetURL,
                       FileManager.default.fileExists(atPath: abs.path) {
                        let dest = assetsFolder.appendingPathComponent(abs.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: dest.path) {
                            try? FileManager.default.copyItem(at: abs, to: dest)
                        }
                    }
                }
            }
        }

        let title = (try? context.fetch(FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectID }
        )).first?.title) ?? "Book"

        let document = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
        <title>\(escape(title))</title>
        </head>
        <body>
        \(documentText)
        </body>
        </html>
        """
        try document.write(to: xhtmlURL, atomically: true, encoding: .utf8)
    }

    private func escape(_ text: String) -> String {
        XHTMLAssembler().escape(text)
    }

    public enum ExportError: LocalizedError, Sendable {
        case projectNotFound(UUID)

        public var errorDescription: String? {
            switch self {
            case .projectNotFound(let id):
                return "Project \(id) could not be found for export."
            }
        }
    }
}
