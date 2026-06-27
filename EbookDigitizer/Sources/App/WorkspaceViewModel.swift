import Foundation
import SwiftUI
import SwiftData
import AppKit
import EbookDigitizerCore

/// The central view-model for the review workspace (use-case 6).
///
/// Owns the active project, drives ingestion/processing/export through the
/// service layer, exposes live `Page` snapshots to the canvas, maintains the
/// assembled XHTML text + per-block character ranges, and brokers every
/// cross-pane interaction: scroll-sync, illustration `<img>` insert/remove,
/// and per-page re-extraction.
///
/// `@MainActor` because it holds the `ModelContext`-derived state and all
/// SwiftData mutations must occur on the main actor. Structured concurrency
/// only — no GCD.
@MainActor
@Observable
final class WorkspaceViewModel {

    // MARK: - Dependencies

    private let digitizationService: DigitizationService
    private let exportService: ExportService
    private let assetService = IllustrationAssetService()
    private let assembler = XHTMLAssembler()
    private let validator = SourceAssetValidator()
    private let parser = DocumentParser()

    // MARK: - Project State

    private(set) var activeProjectID: UUID?
    private(set) var title: String = ""

    /// Live SwiftData-backed pages, observed via `@Query`-style fetch. We
    /// re-fetch on demand; the view observes this array directly.
    private(set) var pageSnapshots: [PageSnapshot] = []

    /// The continuous XHTML document text shown in the editor.
    var documentText: String = ""

    /// Character ranges of each block within `documentText`, keyed by block id.
    /// Drives scroll-synchronization: when the active line moves in the editor,
    /// we find the block whose range contains it and scroll the canvas to that
    /// page; conversely, when a block is selected on the canvas, we scroll the
    /// editor to its range.
    private(set) var blockRangesByBlockID: [UUID: NSRange] = [:]
    private(set) var blockIDByPageID: [UUID: [UUID]] = [:]

    enum Status: Equatable {
        case empty
        case loading
        case ready
        case processing(completed: Int, total: Int)
        case exporting
        case error(String)
    }
    private(set) var status: Status = .empty

    /// When non-nil, the project's source folder is missing (use-case 6a) and
    /// editing is disabled until the Producer re-locates it.
    var missingFolderURL: URL?
    /// `true` while `missingFolderURL` is set — gates editor editability.
    var isEditingDisabled: Bool { missingFolderURL != nil }

    /// The page currently scrolled to in the canvas; used to scope per-page
    /// commands like "Force Re-Extract Page" (use-case 7d).
    var currentPageID: UUID? { _currentPageID }
    private var _currentPageID: UUID?

    func setCurrentPage(_ id: UUID) {
        _currentPageID = id
    }

    /// Surface an error to the user via the status banner.
    func setError(_ message: String) {
        status = .error(message)
    }

    /// When set, the editor sweeps out every `<img>` tag referencing this
    /// asset name (use-case 7c.3). Cleared after the sweep is applied.
    var pendingAssetTagRemoval: String?

    init(modelContainer: ModelContainer) {
        self.digitizationService = DigitizationService(modelContainer: modelContainer)
        self.exportService = ExportService(modelContainer: modelContainer)
    }

    // MARK: - Ingestion (use-case step 1, 2)

    /// Create a project from a user-selected folder and immediately kick off
    /// processing. The folder URL is provided by a `.fileImporter` in the view.
    func ingest(folder: URL, title: String) {
        do {
            let id = try digitizationService.createProject(title: title, from: folder)
            activeProjectID = id
            self.title = title
            refreshSnapshots()
            validateSourceIntegrity()
            rebuildDocument()
            if missingFolderURL == nil {
                beginProcessing()
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Moved-Folder Resilience (use-case 6a)

    /// Re-bind a project's missing source images to a newly selected folder,
    /// matching by filename. Called after the user re-locates the folder via
    /// a `.fileImporter`.
    func rebind(to newFolder: URL) {
        guard let projectID = activeProjectID else { return }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else { return }

        let newFiles = (try? FileManager.default.contentsOfDirectory(
            at: newFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let byName = Dictionary(uniqueKeysWithValues: newFiles.map { ($0.lastPathComponent, $0) })

        var anyRebound = false
        for page in project.pages {
            let name = page.sourceImageURL.lastPathComponent
            if let newURL = byName[name] {
                page.sourceImageURL = newURL
                anyRebound = true
            }
        }
        if anyRebound {
            project.sourceFolderURL = newFolder
            missingFolderURL = nil
            try? context.save()
        }
        refreshSnapshots()
        rebuildDocument()
        if missingFolderURL == nil {
            beginProcessing()
        }
    }

    /// Check every page's source image exists; set `missingFolderURL` if not.
    private func validateSourceIntegrity() {
        guard let projectID = activeProjectID else { return }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else { return }
        let entries = project.pages.map { (pageID: $0.id, imageURL: $0.sourceImageURL) }
        let integrity = validator.validate(
            sourceFolder: project.sourceFolderURL, pages: entries
        )
        missingFolderURL = integrity.missingFolder
    }

    // MARK: - Processing (use-case step 3, 4, 5 + extension 3a)

    private func beginProcessing() {
        guard let projectID = activeProjectID else { return }
        let total = pageSnapshots.count
        var completed = 0
        status = .processing(completed: completed, total: total)

        Task { [weak self] in
            guard let self else { return }
            for await update in self.digitizationService.process(projectID: projectID) {
                self.refreshSnapshots()
                self.rebuildDocument()
                completed += 1
                self.status = .processing(completed: completed, total: total)
            }
            self.status = .ready
        }
    }

    // MARK: - Re-extraction (use-case 7b, 7d)

    func reextractPage(_ pageID: UUID, force: Bool) {
        Task { [weak self] in
            guard let self else { return }
            let didRun = await self.digitizationService.reextract(pageID: pageID, force: force)
            if didRun {
                self.refreshSnapshots()
                self.rebuildDocument()
            }
        }
    }

    // MARK: - Orientation (use-case 7b)

    /// Apply a rotation/flip to a page, persist it, and re-run extraction
    /// unless the user has manually edited that page's text.
    func applyOrientation(
        pageID: UUID,
        rotationDegrees: Int? = nil,
        flip: Bool? = nil
    ) {
        guard let projectID = activeProjectID else { return }
        let context = digitizationService.modelContextForQueries()
        guard let page = fetchPage(pageID, in: context) else { return }
        if let rotationDegrees { page.imageRotationDegrees = rotationDegrees }
        if let flip { page.imageIsHorizontallyFlipped = flip }
        try? context.save()
        refreshSnapshots()
        reextractPage(pageID, force: false)
        _ = projectID
    }

    /// Rotate a page's image by `delta` degrees (use-case 7b). Persists the new
    /// orientation and conditionally re-extracts text.
    func rotate(pageID: UUID, by delta: Int) {
        let context = digitizationService.modelContextForQueries()
        guard let page = fetchPage(pageID, in: context) else { return }
        let newRotation = ((page.imageRotationDegrees + delta) % 360 + 360) % 360
        applyOrientation(pageID: pageID, rotationDegrees: newRotation)
    }

    /// Toggle horizontal flip on a page (use-case 7b).
    func flip(pageID: UUID) {
        let context = digitizationService.modelContextForQueries()
        guard let page = fetchPage(pageID, in: context) else { return }
        applyOrientation(pageID: pageID, flip: !page.imageIsHorizontallyFlipped)
    }

    /// Clear the missing-folder alert without re-binding (the user dismissed it).
    func dismissMissingFolder() {
        missingFolderURL = nil
    }

    // MARK: - Editor Text Binding (use-case 7a, 7b)

    /// Called by the SwiftUI binding when the user edits the document text.
    /// Parses the edited XHTML back into per-block `rawText` updates and
    /// persists them (use-case 7a.3: autosaves text manipulation instantly),
    /// then marks the affected page as manually edited so 7b's re-extraction
    /// gate preserves the user's work.
    func documentTextDidChange(to newText: String) {
        documentText = newText
        syncEditsBackToBlocks()
    }

    /// Parse the current `documentText` and write `rawText` back to the
    /// matching `ElementBlock`s, then mark their pages as manually edited.
    /// Debounced via `Task.yield()` so rapid typing doesn't thrash SwiftData.
    private var pendingSyncTask: Task<Void, Never>?

    private func syncEditsBackToBlocks() {
        pendingSyncTask?.cancel()
        let snapshot = documentText
        let orderedIDs = renderedBlockIDsInOrder()
        pendingSyncTask = Task { [weak self] in
            guard let self else { return }
            // Debounce: coalesce bursts of typing into a single parse pass.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self.applyParsedEdits(snapshot: snapshot, orderedIDs: orderedIDs)
        }
    }

    /// The block IDs that the assembler renders into the document, in order,
    /// excluding `pageArtifact` blocks (which are never emitted).
    private func renderedBlockIDsInOrder() -> [UUID] {
        guard let projectID = activeProjectID else { return [] }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else { return [] }
        return project.pages
            .sorted(by: { $0.sequence < $1.sequence })
            .flatMap { page in
                page.elementBlocks
                    .filter { $0.blockType != .pageArtifact }
                    .sorted(by: { $0.sequence < $1.sequence })
                    .map(\.id)
            }
    }

    private func applyParsedEdits(snapshot: String, orderedIDs: [UUID]) {
        guard let projectID = activeProjectID, !orderedIDs.isEmpty else { return }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else { return }

        let updates = parser.parse(documentText: snapshot, renderedBlockIDs: orderedIDs)
        var touchedPageIDs = Set<UUID>()

        for update in updates {
            guard let page = project.pages.first(where: { $0.elementBlocks.contains(where: { $0.id == update.blockID }) }),
                  let block = page.elementBlocks.first(where: { $0.id == update.blockID }) else { continue }
            block.rawText = update.rawText
            if let assetPath = update.assetPath, block.blockType == .illustration {
                block.assetPath = assetPath
            }
            touchedPageIDs.insert(page.id)
        }

        for page in project.pages where touchedPageIDs.contains(page.id) {
            page.hasManualEdits = true
        }
        project.updatedAt = Date()
        try? context.save()
    }

    // MARK: - Illustration Gestures (use-case 7c)

    /// Called when the user finishes drawing or moving/resizing an illustration
    /// box. Crops the asset to disk and writes the path back to the block.
    func commitIllustration(
        pageID: UUID,
        blockID: UUID,
        normalizedRect: CGRect
    ) {
        guard let projectID = activeProjectID else { return }
        let context = digitizationService.modelContextForQueries()
        guard let page = fetchPage(pageID, in: context) else { return }

        let block: ElementBlock
        if let existing = page.elementBlocks.first(where: { $0.id == blockID }) {
            block = existing
            block.boundingRect = normalizedRect
        } else {
            block = ElementBlock(
                id: blockID,
                sequence: page.elementBlocks.count,
                blockType: .illustration,
                boundingRect: normalizedRect
            )
            block.page = page
            context.insert(block)
        }

        let destURL = assetURL(for: blockID, in: projectID)
        do {
            try assetService.crop(
                from: page.sourceImageURL,
                normalizedRect: normalizedRect,
                to: destURL
            )
            block.assetPath = destURL.path
        } catch {
            status = .error(error.localizedDescription)
        }
        try? context.save()
        refreshSnapshots()
        rebuildDocument()
    }

    /// Called when the user creates a new illustration box: crop the asset,
    /// persist the block, and insert a matching `<img>` tag into the document
    /// flow at the correct sequence position.
    func createIllustration(
        pageID: UUID,
        draft: AnnotationDraft
    ) {
        commitIllustration(pageID: pageID, blockID: draft.id, normalizedRect: draft.normalizedRect)
    }

    /// Called when the user deletes an illustration box: delete the asset from
    /// disk, remove the block, and request the editor sweep out the matching
    /// `<img>` tag (use-case 7c.3).
    func deleteIllustration(pageID: UUID, blockID: UUID) {
        guard let projectID = activeProjectID else { return }
        let context = digitizationService.modelContextForQueries()
        guard let page = fetchPage(pageID, in: context) else { return }
        guard let block = page.elementBlocks.first(where: { $0.id == blockID }) else { return }

        let assetName: String? = block.assetURL.map { $0.lastPathComponent }
        if let url = block.assetURL {
            try? assetService.delete(at: url)
        }
        context.delete(block)
        try? context.save()
        refreshSnapshots()
        rebuildDocument()
        // Ask the editor to remove the `<img>` tag referencing the deleted
        // asset. The document rebuild above already dropped the block from the
        // assembled string; this sweep handles the case where the user has
        // typed custom markup that still references the asset.
        if let assetName {
            pendingAssetTagRemoval = assetName
            clearOneShotAfterUpdate { [weak self] in
                MainActor.assumeIsolated { self?.pendingAssetTagRemoval = nil }
            }
        }
        _ = projectID
    }

    // MARK: - Export (use-case step 9)

    func export(to url: URL) {
        guard let projectID = activeProjectID else { return }
        status = .exporting
        do {
            try exportService.export(
                projectID: projectID, documentText: documentText, to: url
            )
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Document <-> Editor Bridge

    /// Called by the editor when the active line changes (Phase 3 hook).
    /// Maps the line's UTF-16 location to the block whose range contains it,
    /// then notifies the view to scroll the canvas to that block's page.
    var blockIDForScrollSync: UUID?
    private(set) var lastActiveBlockPageID: UUID?

    func editorActiveLineChanged(_ range: NSRange) {
        let location = range.location
        // Find the block whose UTF-16 range contains the caret.
        let hit = blockRangesByBlockID.first { _, nsRange in
            NSLocationInRange(location, nsRange) || nsRange.location == location
        }
        if let (blockID, _) = hit {
            blockIDForScrollSync = blockID
            lastActiveBlockPageID = pageID(forBlockID: blockID)
            // One-shot: clear the editor scroll target after SwiftUI applies it.
            clearOneShotAfterUpdate { [weak self] in
                MainActor.assumeIsolated { self?.blockIDForScrollSync = nil }
            }
        }
    }

    /// Reverse lookup: which page owns a given block?
    func pageID(forBlockID blockID: UUID) -> UUID? {
        blockIDByPageID.first(where: { _, ids in ids.contains(blockID) })?.key
    }

    /// The UTF-16 NSRange of a block in the document, for editor scrolling.
    func range(forBlockID blockID: UUID) -> NSRange? {
        blockRangesByBlockID[blockID]
    }

    // MARK: - Refresh & Rebuild

    /// Re-fetch pages from SwiftData and project into value snapshots.
    private func refreshSnapshots() {
        guard let projectID = activeProjectID else {
            pageSnapshots = []
            return
        }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else {
            pageSnapshots = []
            return
        }
        pageSnapshots = project.pages.sorted(by: { $0.sequence < $1.sequence }).map { page in
            PageSnapshot(
                id: page.id,
                sequence: page.sequence,
                status: page.status,
                image: loadImage(at: page.sourceImageURL),
                blocks: page.elementBlocks.sorted(by: { $0.sequence < $1.sequence })
                    .map { $0.draft }
            )
        }
    }

    /// Reassemble the XHTML document from the current page snapshots and record
    /// per-block UTF-16 ranges for scroll-sync + `<img>` insertion/removal.
    ///
    /// Guarded: if the user has manually edited any page (use-case 7b), the
    /// document text is preserved as-is so the system never clobbers the
    /// Producer's work; only the range index is rebuilt so scroll-sync keeps
    /// working as best it can against the (possibly edited) text.
    private func rebuildDocument() {
        var annotated: [XHTMLAssembler.AnnotatedPage] = []
        var utf16Offset = 0
        for snapshot in pageSnapshots {
            let blocks = snapshot.blocks.map {
                XHTMLAssembler.BlockInput(
                    id: $0.id,
                    sequence: $0.sequence,
                    blockType: $0.blockType,
                    rawText: $0.rawText,
                    assetPath: $0.assetPath
                )
            }
            let page = assembler.annotate(
                pageID: snapshot.id, blocks: blocks, utf16Offset: utf16Offset
            )
            utf16Offset += page.fragment.utf16.count + 1 // +1 for the "\n" separator
            annotated.append(page)
        }

        // Don't clobber user edits (use-case 7b). During initial processing
        // (before any edit) this guard is inert; after the user edits, the
        // live `documentText` is the source of truth for export.
        if !anyPageHasManualEdits {
            documentText = assembler.assemble(pages: annotated)
        }
        rebuildRangeIndex(from: annotated)
    }

    /// True if any page on disk has `hasManualEdits == true`.
    private var anyPageHasManualEdits: Bool {
        guard let projectID = activeProjectID else { return false }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else { return false }
        return project.pages.contains { $0.hasManualEdits }
    }

    private func rebuildRangeIndex(from pages: [XHTMLAssembler.AnnotatedPage]) {
        blockRangesByBlockID.removeAll()
        blockIDByPageID.removeAll()
        for page in pages {
            var ids: [UUID] = []
            for range in page.blockRanges {
                blockRangesByBlockID[range.blockID] = NSRange(location: range.utf16Lower, length: range.utf16Upper - range.utf16Lower)
                ids.append(range.blockID)
            }
            blockIDByPageID[page.pageID] = ids
        }
    }

    // MARK: - Helpers

    private func assetURL(for blockID: UUID, in projectID: UUID) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EbookDigitizer-Assets", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
        return dir.appendingPathComponent("\(blockID.uuidString).png")
    }

    private func loadImage(at url: URL) -> NSImage? {
        NSImage(contentsOf: url)
    }

    private func fetchProject(_ id: UUID, in context: ModelContext) -> Project? {
        var descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchPage(_ id: UUID, in context: ModelContext) -> Page? {
        var descriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Defer a closure to run after the current SwiftUI update pass completes,
    /// so one-shot signals (scroll targets, tag-removal requests) can be
    /// cleared after the representable has observed them. Uses structured
    /// concurrency — `Task.yield()` — rather than GCD.
    private func clearOneShotAfterUpdate(_ action: @escaping () -> Void) {
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }
}
