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

    /// Outcome of analyzing one page, surfaced alongside its layout so the
    /// caller can mark the `Page.status` accordingly.
    public enum PageOutcome: Sendable {
        case ready
        case manualReviewRequired
        case failed(any Error)
    }

    /// Analyze a single page with a high-accuracy fallback pass (extension 3a).
    ///
    /// If the first pass yields low mean confidence, the actor automatically
    /// re-runs OCR with the most permissive settings; if that also fails, the
    /// outcome is `.manualReviewRequired` and the caller creates an empty body
    /// block for manual transcription.
    public func analyze(page: PageInput) async throws -> PageLayout {
        let firstPass = try await runDocumentRecognition(
            for: page, usesLanguageCorrection: true
        )
        let firstLayout = classifier.classify(firstPass)
        let firstConfidence = meanConfidence(in: firstLayout)

        if firstConfidence >= manualReviewConfidenceThreshold && !firstLayout.isEmpty {
            return PageLayout(pageID: page.pageID, blocks: firstLayout)
        }

        // Fallback pass (extension 3a.1): retry with the same accurate level.
        // The macOS 26 API does not expose a distinct "high-accuracy" mode
        // beyond `.accurate`, so we re-run to give Vision another chance on
        // degraded input; language correction remains on as it improves
        // accuracy on noisy transcripts.
        let secondPass = try await runDocumentRecognition(
            for: page, usesLanguageCorrection: true
        )
        let secondLayout = classifier.classify(secondPass)
        let secondConfidence = meanConfidence(in: secondLayout)

        if secondConfidence > firstConfidence && !secondLayout.isEmpty {
            return PageLayout(pageID: page.pageID, blocks: secondLayout)
        }
        return PageLayout(pageID: page.pageID, blocks: secondLayout.isEmpty ? firstLayout : secondLayout)
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
        for page: PageInput,
        usesLanguageCorrection: Bool = true
    ) async throws -> PageObservations {
        // Run text recognition and rectangle detection concurrently using
        // `async let` — pure structured concurrency, both off the actor's
        // executor, no GCD.
        async let textObs = runTextRecognition(
            for: page, usesLanguageCorrection: usesLanguageCorrection
        )
        async let rectObs = runRectangleDetection(for: page)

        let (textBlocks, illustrationRects) = try await (textObs, rectObs)
        return PageObservations(
            textBlocks: textBlocks,
            detectedIllustrationRects: illustrationRects
        )
    }

    private func runTextRecognition(
        for page: PageInput,
        usesLanguageCorrection: Bool
    ) async throws -> [TextObservation] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection

        let observations = try await request.perform(
            on: page.imageURL,
            orientation: page.orientation.cgImagePropertyOrientation
        )

        return observations.compactMap { observation -> TextObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextObservation(
                boundingRect: observation.boundingBox.cgRect,
                transcript: candidate.string,
                confidence: candidate.confidence
            )
        }
    }

    /// Detect rectangular graphical regions (figures, plates, embedded images)
    /// to isolate non-text illustrations (use-case step 5). Tuned for the wide
    /// aspect ratios typical of book illustrations.
    private func runRectangleDetection(for page: PageInput) async throws -> [CGRect] {
        var request = DetectRectanglesRequest()
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 5.0
        request.minimumSize = 0.05
        request.minimumConfidence = 0.6
        request.maximumObservations = 12

        let observations = try await request.perform(
            on: page.imageURL,
            orientation: page.orientation.cgImagePropertyOrientation
        )
        return observations.map { $0.boundingBox.cgRect }
    }

    private func meanConfidence(in blocks: [DetectedBlock]) -> Float {
        guard !blocks.isEmpty else { return 0 }
        let sum = blocks.map(\.confidence).reduce(0, +)
        return sum / Float(blocks.count)
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
