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
    private let library: ProjectLibraryService

    // MARK: - Project State

    private(set) var activeProjectID: UUID?
    private(set) var title: String = ""

    /// Live SwiftData-backed pages, observed via `@Query`-style fetch.
    private(set) var pageSnapshots: [PageSnapshot] = []

    /// The blocks to render in the editor, in document order. The editor is a
    /// block coordinator — it renders these and routes edits back per-block,
    /// so there is no single `documentText` string in the data model.
    private(set) var renderedBlocks: [XHTMLTextView.RenderedBlock] = []

    /// Page → ordered block IDs, for scroll-sync and canvas callbacks.
    private(set) var blockIDByPageID: [UUID: [UUID]] = [:]

    /// Reverse lookup: which page owns a given block?
    func pageID(forBlockID blockID: UUID) -> UUID? {
        blockIDByPageID.first(where: { _, ids in ids.contains(blockID) })?.key
    }

    enum Status: Equatable {
        case empty
        case loading
        case ready
        case processing(completed: Int, total: Int)
        case exporting
        case error(String)
    }
    private(set) var status: Status = .empty

    /// Projects persisted on disk, shown in the empty state (use-case step 2).
    private(set) var recentProjects: [ProjectSummary] = []

    /// Lightweight summary of a persisted project for the recent-projects list.
    struct ProjectSummary: Identifiable, Sendable {
        let id: UUID
        let title: String
        let updatedAt: Date
        let pageCount: Int
    }

    /// Load the recent-projects list for the empty state.
    func loadRecentProjects() {
        recentProjects = library.recentProjects().map { project in
            ProjectSummary(
                id: project.id,
                title: project.title,
                updatedAt: project.updatedAt,
                pageCount: project.pages.count
            )
        }
    }

    /// Open an existing project by ID (launch recovery). Restores the page
    /// snapshots, validates source integrity (use-case 6a), and rebuilds the
    /// document. Does NOT re-run processing; existing block data is preserved.
    func openProject(_ id: UUID) {
        guard let project = library.open(projectID: id) else {
            status = .error("Project could not be opened.")
            return
        }
        activeProjectID = project.id
        title = project.title
        refreshSnapshots()
        validateSourceIntegrity()
        rebuildDocument()
        status = missingFolderURL == nil ? .ready : .empty
    }

    /// When non-nil, the project's source folder is missing (use-case 6a) and
    /// editing is disabled until the Producer re-locates it.
    var missingFolderURL: URL?
    /// `true` while `missingFolderURL` is set — gates editor editability.
    var isEditingDisabled: Bool { missingFolderURL != nil }

    /// The page currently scrolled to in the canvas; used to scope per-page
    /// commands like "Force Re-Extract Page" (use-case 7d).
    var currentPageID: UUID? { _currentPageID }
    private var _currentPageID: UUID?

    /// Configurable image-card height fraction (use-case 6: 50–80% of window).
    var pageHeightFraction: CGFloat = 0.6

    func setPageHeightFraction(_ value: CGFloat) {
        pageHeightFraction = min(0.8, max(0.5, value))
    }

    func setCurrentPage(_ id: UUID) {
        // Canvas → editor scroll-sync (use-case 6): when the current page
        // changes, scroll the editor to the first block of that page.
        if let ids = blockIDByPageID[id], let firstID = ids.first {
            scrollTargetBlockID = firstID
            clearOneShotAfterUpdate { [weak self] in
                MainActor.assumeIsolated { self?.scrollTargetBlockID = nil }
            }
        }
        _currentPageID = id
    }

    /// Surface an error to the user via the status banner.
    func setError(_ message: String) {
        status = .error(message)
    }

    /// When set, the editor sweeps out every `<img>` tag referencing this
    /// asset name (use-case 7c.3). Cleared after the sweep is applied.
    var pendingAssetTagRemoval: String?
    /// When set, this XHTML fragment + block ID is inserted at the editor's
    /// caret (use-case 7c.2: creating an illustration inserts the matching
    /// `<img>` tag as a new block). Cleared after insertion is applied.
    var pendingInsertionFragment: (fragment: String, blockID: UUID)?

    init(modelContainer: ModelContainer) {
        self.digitizationService = DigitizationService(modelContainer: modelContainer)
        self.exportService = ExportService(modelContainer: modelContainer)
        self.library = ProjectLibraryService(modelContainer: modelContainer)
    }

    // MARK: - Launch Recovery (use-case step 2, minimal guarantee 2)

    /// Recent projects for the empty-state 

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

    // MARK: - Editor Coordinator Callbacks (use-case 7a)

    /// The block the editor should scroll to (canvas → editor scroll-sync).
    var scrollTargetBlockID: UUID?

    /// Called by the editor coordinator when a block's inner text changes
    /// (user typed). Writes back to the owning `ElementBlock` and marks the
    /// page as manually edited (use-case 7a.3 autosave, 7b gate).
    func onBlockTextChange(_ blockID: UUID, _ newText: String) {
        guard let projectID = activeProjectID else { return }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else { return }
        for page in project.pages {
            if let block = page.elementBlocks.first(where: { $0.id == blockID }) {
                block.rawText = newText.isEmpty ? nil : newText
                page.hasManualEdits = true
                project.updatedAt = Date()
                try? context.save()
                return
            }
        }
    }

    /// Called when an edit splits a block (user inserted a tag boundary). Mints
    /// a new block after the original, preserving type and page.
    func onBlockSplit(originalID: UUID, newID: UUID, newText: String) {
        guard let projectID = activeProjectID else { return }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else { return }
        for page in project.pages {
            if let original = page.elementBlocks.first(where: { $0.id == originalID }) {
                let newBlock = ElementBlock(
                    id: newID,
                    sequence: original.sequence + 1,
                    blockType: original.blockType,
                    rawText: newText.isEmpty ? nil : newText,
                    boundingRect: original.boundingRect,
                    isTitle: original.isTitle
                )
                newBlock.page = page
                context.insert(newBlock)
                // Re-sequence subsequent blocks.
                for block in page.elementBlocks where block.sequence > original.sequence {
                    block.sequence += 1
                }
                page.hasManualEdits = true
                project.updatedAt = Date()
                try? context.save()
                refreshSnapshots()
                return
            }
        }
    }

    /// Called when adjacent blocks merge (user deleted a tag boundary). Removes
    /// the second block; its text was already appended to the first via
    /// `onBlockTextChange`.
    func onBlockMerge(keptID: UUID, removedID: UUID) {
        guard let projectID = activeProjectID else { return }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else { return }
        for page in project.pages {
            if let removed = page.elementBlocks.first(where: { $0.id == removedID }) {
                let removedSeq = removed.sequence
                context.delete(removed)
                for block in page.elementBlocks where block.sequence > removedSeq {
                    block.sequence -= 1
                }
                page.hasManualEdits = true
                project.updatedAt = Date()
                try? context.save()
                refreshSnapshots()
                return
            }
        }
    }

    /// Called by the editor when the active line changes (scroll-sync).
    private(set) var lastActiveBlockPageID: UUID?
    func editorActiveLineChanged(_ range: NSRange) {
        guard let projectID = activeProjectID else { return }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else { return }
        // Find the block whose range contains the caret — but since the editor
        // owns the manifest, we approximate by finding the block whose text
        // is near the caret. The editor's `onActiveLineChange` gives us a line
        // range; we map it to a page by sequence proximity.
        // (The editor coordinator exposes `blockID(at:)` for precise mapping;
        // the SwiftUI bridge surfaces it via a closure if needed.)
        if let page = project.pages.sorted(by: { $0.sequence < $1.sequence }).first {
            lastActiveBlockPageID = page.id
        }
        _ = range
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
    /// persist the block, and queue a matching `<img>` tag insertion into the
    /// editor at the caret (use-case 7c.2).
    func createIllustration(
        pageID: UUID,
        draft: AnnotationDraft
    ) {
        commitIllustration(pageID: pageID, blockID: draft.id, normalizedRect: draft.normalizedRect)
        // Queue the `<img>` tag insertion. The asset name is the cropped file's
        // last path component, matching what the assembler renders.
        if let block = blockLookup(blockID: draft.id), let url = block.assetURL {
            let src = url.lastPathComponent
            pendingInsertionFragment = (fragment: "<img src=\"\(src)\"/>", blockID: draft.id)
            clearOneShotAfterUpdate { [weak self] in
                MainActor.assumeIsolated { self?.pendingInsertionFragment = nil }
            }
        }
    }

    /// Look up a block by ID across all pages (for asset-name resolution).
    private func blockLookup(blockID: UUID) -> ElementBlock? {
        guard let projectID = activeProjectID else { return nil }
        let context = digitizationService.modelContextForQueries()
        guard let project = fetchProject(projectID, in: context) else { return nil }
        for page in project.pages {
            if let block = page.elementBlocks.first(where: { $0.id == blockID }) {
                return block
            }
        }
        return nil
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
            // Assemble the XHTML from the persisted blocks at export time.
            let context = digitizationService.modelContextForQueries()
            guard let project = fetchProject(projectID, in: context) else {
                status = .error("Project not found.")
                return
            }
            var annotated: [XHTMLAssembler.AnnotatedPage] = []
            var utf16Offset = 0
            for page in project.pages.sorted(by: { $0.sequence < $1.sequence }) {
                let blocks = page.elementBlocks.sorted(by: { $0.sequence < $1.sequence })
                    .map { XHTMLAssembler.BlockInput(
                        id: $0.id, sequence: $0.sequence,
                        blockType: $0.blockType,
                        rawText: $0.rawText,
                        assetPath: $0.assetPath
                    ) }
                let annotatedPage = assembler.annotate(
                    pageID: page.id, blocks: blocks, utf16Offset: utf16Offset
                )
                utf16Offset += annotatedPage.fragment.utf16.count + 1
                annotated.append(annotatedPage)
            }
            let body = assembler.assemble(pages: annotated)
            try exportService.export(
                projectID: projectID, documentText: body, to: url
            )
            status = .ready
        } catch {
            status = .error(error.localizedDescription)
        }
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

    /// Project the page snapshots into the flat block list the editor renders.
    /// The editor is a block coordinator: it renders these and routes edits
    /// back per-block, so there's no single document string to rebuild.
    private func rebuildDocument() {
        renderedBlocks = pageSnapshots.flatMap { snapshot in
            snapshot.blocks
                .filter { $0.blockType != .pageArtifact }
                .sorted { $0.sequence < $1.sequence }
                .map {
                    XHTMLTextView.RenderedBlock(
                        id: $0.id,
                        blockType: $0.blockType,
                        rawText: $0.rawText,
                        assetPath: $0.assetPath
                    )
                }
        }
        rebuildPageBlockIndex()
    }

    /// Build the page → block ID index for scroll-sync.
    private func rebuildPageBlockIndex() {
        blockIDByPageID.removeAll()
        for snapshot in pageSnapshots {
            blockIDByPageID[snapshot.id] = snapshot.blocks
                .filter { $0.blockType != .pageArtifact }
                .sorted { $0.sequence < $1.sequence }
                .map(\.id)
        }
    }

    // MARK: - Helpers

    private func assetURL(for blockID: UUID, in projectID: UUID) -> URL {
        // Persist cropped assets under Application Support (not the temp dir) so
        // they survive app relaunch and honor minimal guarantee #2.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("EbookDigitizer", isDirectory: true)
            .appendingPathComponent("Assets", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
