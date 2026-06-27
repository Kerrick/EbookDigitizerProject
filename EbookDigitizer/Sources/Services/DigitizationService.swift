import Foundation
import SwiftData
import EbookDigitizerCore

/// The orchestration layer that bridges the pure `VisionProcessingActor` and
/// the main-actor SwiftData `ModelContext`.
///
/// All SwiftData mutations happen on `@MainActor` (the `ModelContext` is
/// main-bound); all CPU-bound Vision work happens off-isolation via the actor.
/// The two are connected with pure Swift 6 structured concurrency — no GCD,
/// no `Task.detached` for persistence, no completion handlers.
@MainActor
public final class DigitizationService {

    private let modelContainer: ModelContainer
    private let visionActor: VisionProcessingActor
    private let ingestor: ImageFolderIngestor

    public init(
        modelContainer: ModelContainer,
        visionActor: VisionProcessingActor = VisionProcessingActor(),
        ingestor: ImageFolderIngestor = ImageFolderIngestor()
    ) {
        self.modelContainer = modelContainer
        self.visionActor = visionActor
        self.ingestor = ingestor
    }

    /// Expose the main-bound `ModelContext` to the view-model for read-heavy
    /// queries (snapshots, block lookups) that live on the main actor.
    public func modelContextForQueries() -> ModelContext {
        modelContainer.mainContext
    }

    // MARK: - Project Creation (use-case steps 1 & 2)

    /// Create a new `Project` from a user-selected folder of scans.
    ///
    /// Enumerates the folder into ordered pages (one per supported image, each
    /// `status = .processing`), persists them, and returns the project's UUID
    /// so the caller can drive the UI off it.
    ///
    /// Does NOT trigger processing; call `process(projectID:)` afterwards.
    @discardableResult
    public func createProject(title: String, from folder: URL) throws -> UUID {
        let imageURLs = try ingestor.imageURLs(in: folder)

        let context = modelContainer.mainContext
        let project = Project(title: title, sourceFolderURL: folder)

        for (index, url) in imageURLs.enumerated() {
            let page = Page(
                sequence: index,
                sourceImageURL: url,
                status: .processing
            )
            page.project = project
            context.insert(page)
        }
        context.insert(project)
        try context.save()
        return project.id
    }

    // MARK: - Processing Pipeline (use-case steps 3, 4, 5 + extension 3a)

    /// Run Vision extraction for every `processing` page in the project,
    /// streaming results back to SwiftData as each page completes.
    ///
    /// The caller observes progress via the returned `AsyncStream`; each yield
    /// carries the page UUID and its resolved `PageStatus`. The stream finishes
    /// when all pages have been processed.
    ///
    /// Per extension 3a: a low-confidence first pass yields a `.manualReviewRequired`
    /// status and an empty body block is created so the Producer can transcribe
    /// manually; a failed extraction also yields `.manualReviewRequired` with an
    /// empty block. Processing of subsequent pages never halts on a single
    /// failure.
    public func process(
        projectID: UUID
    ) -> AsyncStream<(pageID: UUID, status: PageStatus)> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.runProcessing(projectID: projectID, into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Re-extraction (use-case 7b orientation change, 7d force re-extract)

    /// Re-run extraction for a single page, optionally gated on whether the
    /// user has manually edited it.
    ///
    /// - Parameters:
    ///   - force: when `false` and `page.hasManualEdits == true`, the call is a
    ///     no-op (use-case 7b: preserve user text). When `true` (use-case 7d
    ///     "Force Re-Extract"), it always re-runs and overwrites.
    @discardableResult
    public func reextract(pageID: UUID, force: Bool = false) async -> Bool {
        let context = modelContainer.mainContext
        guard let page = fetchPage(pageID, in: context) else { return false }

        if !force && page.hasManualEdits {
            return false
        }

        let orientation = PageOrientation.from(
            rotationDegrees: page.imageRotationDegrees,
            horizontallyFlipped: page.imageIsHorizontallyFlipped
        )
        let input = PageInput(
            imageURL: page.sourceImageURL,
            pageID: page.id,
            orientation: orientation
        )

        let layout: PageLayout
        do {
            layout = try await visionActor.analyze(page: input)
        } catch {
            // On total failure, flag for manual review and create an empty
            // body block so the Producer has a place to type (extension 3a.2).
            replaceBlocks(on: page, with: [
                ElementBlock(sequence: 0, blockType: .bodyParagraph, rawText: "")
            ])
            page.status = .manualReviewRequired
            try? context.save()
            return true
        }

        applyLayout(layout, to: page, in: context)
        try? context.save()
        return true
    }

    // MARK: - Internals: Batch Run

    private func runProcessing(
        projectID: UUID,
        into continuation: AsyncStream<(pageID: UUID, status: PageStatus)>.Continuation
    ) async {
        let context = modelContainer.mainContext
        guard let project = fetchProject(projectID, in: context) else { return }

        // Snapshot the pages into pure value-type inputs so the Vision actor
        // never touches SwiftData reference types (and so mutations to the
        // context during processing don't race with the actor).
        let inputs: [PageInput] = project.pages
            .filter { $0.status == .processing }
            .sorted { $0.sequence < $1.sequence }
            .map { page in
                PageInput(
                    imageURL: page.sourceImageURL,
                    pageID: page.id,
                    orientation: PageOrientation.from(
                        rotationDegrees: page.imageRotationDegrees,
                        horizontallyFlipped: page.imageIsHorizontallyFlipped
                    )
                )
            }

        // Hop to the Vision actor to obtain the stream; the stream itself is
        // a value we can iterate off-actor. All persistence below stays on the
        // main actor where the ModelContext lives.
        let stream = await visionActor.analyze(pages: inputs)

        // Consume the stream; persist each result as it arrives. Because we
        // `await` yields one at a time on the main actor, every SwiftData
        // mutation is naturally serialized on the main context.
        for await (layout, outcome) in stream {
            guard let page = fetchPage(layout.pageID, in: context) else { continue }

            switch outcome {
            case .ready:
                applyLayout(layout, to: page, in: context)
                page.status = .ready
            case .manualReviewRequired:
                applyLayout(layout, to: page, in: context)
                // Ensure there's at least one empty body block to type into
                // (extension 3a.2) when nothing usable was extracted.
                if page.elementBlocks.isEmpty {
                    page.elementBlocks.append(
                        ElementBlock(sequence: 0, blockType: .bodyParagraph, rawText: "")
                    )
                }
                page.status = .manualReviewRequired
            case .failed:
                // Total failure: clear partial blocks, leave one empty body
                // block for manual entry, and flag for review.
                replaceBlocks(on: page, with: [
                    ElementBlock(sequence: 0, blockType: .bodyParagraph, rawText: "")
                ])
                page.status = .manualReviewRequired
            }

            try? context.save()
            continuation.yield((pageID: page.id, status: page.status))
        }

        // After all pages are processed, run the cross-page artifact
        // deduplication pass (use-case success guarantee #2): recurring
        // running headers that leaked into the body are reclassified so they
        // don't sprinkle the XHTML flow.
        applyCrossPageArtifactDedup(for: projectID)
        try? context.save()
    }

    // MARK: - Cross-Page Artifact Dedup (success guarantee #2)

    private func applyCrossPageArtifactDedup(for projectID: UUID) {
        let context = modelContainer.mainContext
        guard let project = fetchProject(projectID, in: context) else { return }
        let sortedPages = project.pages.sorted(by: { $0.sequence < $1.sequence })

        let snapshots = sortedPages.map { page in
            CrossPageArtifactDetector.PageSnapshot(
                id: page.id,
                sequence: page.sequence,
                blocks: page.elementBlocks.sorted(by: { $0.sequence < $1.sequence })
                    .map { block in
                        CrossPageArtifactDetector.BlockSnapshot(
                            id: block.id,
                            sequence: block.sequence,
                            blockType: block.blockType,
                            rawText: block.rawText,
                            boundingRect: block.boundingRect
                        )
                    }
            )
        }

        let detector = CrossPageArtifactDetector()
        let reclassifications = detector.detect(in: snapshots)
        guard !reclassifications.isEmpty else { return }

        let byPage = Dictionary(grouping: reclassifications, by: \.pageID)
        for page in sortedPages {
            guard let reclasses = byPage[page.id] else { continue }
            let idsToReclassify = Set(reclasses.map(\.blockID))
            for block in page.elementBlocks where idsToReclassify.contains(block.id) {
                block.blockType = .pageArtifact
            }
        }
    }

    // MARK: - Internals: Layout Persistence

    /// Replace a page's blocks with `ElementBlock`s projected from the
    /// `PageLayout`, preserving sequence order and bounding geometry.
    private func applyLayout(_ layout: PageLayout, to page: Page, in context: ModelContext) {
        let newBlocks = layout.blocks.enumerated().map { index, detected in
            ElementBlock(
                id: detected.id,
                sequence: index,
                blockType: detected.blockType,
                rawText: detected.rawText,
                boundingRect: detected.boundingRect
            )
        }
        replaceBlocks(on: page, with: newBlocks)
    }

    /// Atomically swap a page's element blocks. Old blocks are removed from the
    /// context (cascade rule handles orphans); new blocks are inserted and
    /// back-linked to the page.
    private func replaceBlocks(on page: Page, with newBlocks: [ElementBlock]) {
        for old in page.elementBlocks {
            modelContainer.mainContext.delete(old)
        }
        page.elementBlocks = newBlocks
        for block in newBlocks {
            block.page = page
            modelContainer.mainContext.insert(block)
        }
    }

    // MARK: - Internals: Fetches

    private func fetchProject(_ id: UUID, in context: ModelContext) -> Project? {
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }

    private func fetchPage(_ id: UUID, in context: ModelContext) -> Page? {
        let descriptor = FetchDescriptor<Page>(
            predicate: #Predicate { $0.id == id }
        )
        return try? context.fetch(descriptor).first
    }
}
