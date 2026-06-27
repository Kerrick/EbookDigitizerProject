import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Background Vision processing engine.
///
/// An `actor` (not a class) so all mutable state is isolated; all work is
/// dispatched using Swift 6 structured concurrency — `async let`, a `TaskGroup`,
/// and `AsyncStream` — with **no GCD** and no AppKit.
///
/// Targets the macOS 26 (Tahoe) Swift-native Vision API, where
/// `RecognizeTextRequest` is a `Sendable` struct whose `perform(on:orientation:)`
/// is natively `async`. That means OCR runs entirely off the actor's executor
/// with zero completion-handler bridges, zero `Task.detached`, and zero
/// `withCheckedThrowingContinuation` shims.
public actor VisionProcessingActor {

    /// Per-page OCR confidence threshold below which a page is flagged for
    /// manual review rather than yielded as a `.ready` result.
    public var manualReviewConfidenceThreshold: Float

    /// Maximum number of pages analyzed concurrently. Vision is CPU-bound and
    /// allocates significant intermediate buffers, so we bound the fan-out to
    /// keep memory pressure in check.
    public let maxConcurrentPages: Int

    private let classifier: LayoutClassifier

    public init(
        heuristics: LayoutHeuristics = .init(),
        manualReviewConfidenceThreshold: Float = 0.5,
        maxConcurrentPages: Int = 2
    ) {
        self.classifier = LayoutClassifier(heuristics: heuristics)
        self.manualReviewConfidenceThreshold = manualReviewConfidenceThreshold
        self.maxConcurrentPages = max(1, maxConcurrentPages)
    }

    // MARK: - Public API

    /// Analyze a single page and return its classified layout.
    ///
    /// The caller decides whether to persist the result; this actor performs
    /// no SwiftData work. Throws if the image cannot be loaded or Vision fails.
    public func analyze(page: PageInput) async throws -> PageLayout {
        let observations = try await runDocumentRecognition(for: page)
        let blocks = classifier.classify(observations)
        return PageLayout(pageID: page.pageID, blocks: blocks)
    }

    /// Analyze a batch of pages concurrently, yielding each `PageLayout` as soon
    /// as it completes.
    ///
    /// Concurrency is bounded by `maxConcurrentPages` using a counting pattern
    /// over a `TaskGroup` — no GCD. The stream is ordered by completion, not by
    /// input order, so the caller can render results progressively.
    public func analyze(
        pages: [PageInput]
    ) -> AsyncStream<(PageLayout, PageOutcome)> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.processBatch(pages, into: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Outcome of analyzing one page, surfaced alongside its layout so the
    /// caller can mark the `Page.status` accordingly.
    public enum PageOutcome: Sendable {
        case ready
        case manualReviewRequired
        case failed(any Error)
    }

    // MARK: - Batch

    private func processBatch(
        _ pages: [PageInput],
        into continuation: AsyncStream<(PageLayout, PageOutcome)>.Continuation
    ) async {
        // Snapshot actor-isolated config before spawning detached children so
        // child tasks never cross actor isolation to read it.
        let threshold = manualReviewConfidenceThreshold

        await withTaskGroup(of: Void.self) { group in
            var index = 0
            var inflight = 0

            while index < pages.count {
                if inflight < maxConcurrentPages {
                    let page = pages[index]
                    inflight += 1
                    index += 1
                    group.addTask { [weak self] in
                        guard let self else { return }
                        let outcome: (PageLayout, PageOutcome)
                        do {
                            let layout = try await self.analyze(page: page)
                            let meanConfidence: Float
                            if layout.blocks.isEmpty {
                                meanConfidence = 0
                            } else {
                                let sum = layout.blocks.map(\.confidence).reduce(0, +)
                                meanConfidence = sum / Float(layout.blocks.count)
                            }
                            if meanConfidence < threshold {
                                outcome = (layout, .manualReviewRequired)
                            } else {
                                outcome = (layout, .ready)
                            }
                        } catch {
                            outcome = (PageLayout(pageID: page.pageID, blocks: []), .failed(error))
                        }
                        continuation.yield(outcome)
                    }
                } else {
                    // Wait for any child to finish before spawning another.
                    _ = await group.next()
                    inflight -= 1
                }
            }
            await group.waitForAll()
        }
    }

    // MARK: - Vision Bridge

    /// Runs `RecognizeTextRequest` against the page image.
    ///
    /// The macOS 26 Vision API exposes OCR as a natively `async` call on a
    /// `Sendable` request struct, so this method is pure structured
    /// concurrency — the actor is free to service other `analyze` calls while
    /// Vision's CPU-bound work runs off-isolation.
    private func runDocumentRecognition(
        for page: PageInput
    ) async throws -> PageObservations {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let observations = try await request.perform(
            on: page.imageURL,
            orientation: page.orientation.cgImagePropertyOrientation
        )

        let textBlocks = observations.compactMap { observation -> TextObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextObservation(
                // Vision's `NormalizedRect` uses a lower-left origin in
                // `[0, 1]` space. We preserve that coordinate space verbatim;
                // the UI layer is responsible for flipping to Core Animation's
                // top-left origin when rendering.
                boundingRect: observation.boundingBox.cgRect,
                transcript: candidate.string,
                confidence: candidate.confidence
            )
        }
        return PageObservations(textBlocks: textBlocks)
    }
}

// MARK: - Errors

public enum VisionProcessingError: LocalizedError, Sendable {
    case imageLoadFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .imageLoadFailed(let url):
            return "Failed to load image at \(url.path)."
        }
    }
}
