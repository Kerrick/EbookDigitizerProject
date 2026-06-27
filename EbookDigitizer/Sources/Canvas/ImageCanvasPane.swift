import SwiftUI
import EbookDigitizerCore

/// A single page's image rendered at a fitted aspect ratio, with its
/// annotation overlay on top.
private struct PageImageCard: View {
    let page: PageSnapshot
    let maxHeight: CGFloat

    var onAnnotationChange: ((UUID, CGRect) -> Void)?
    var onAnnotationCreate: ((AnnotationDraft) -> Void)?
    var onAnnotationDelete: ((UUID) -> Void)?
    var onRotate: ((Int) -> Void)? = nil
    var onFlip: (() -> Void)? = nil
    var onReextract: (() -> Void)? = nil

    @State private var drafts: [AnnotationDraft] = []

    var body: some View {
        Group {
            if let uiImage = page.image {
                GeometryReader { proxy in
                    let fitted = fittedSize(for: uiImage.size, in: proxy.size)
                    ZStack {
                        Image(nsImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: fitted.width, height: fitted.height)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        AnnotationOverlay(
                            drafts: $drafts,
                            imageSize: uiImage.size,
                            onChange: onAnnotationChange,
                            onCreate: onAnnotationCreate,
                            onDelete: onAnnotationDelete
                        )
                    }
                    .frame(width: fitted.width, height: fitted.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(height: maxHeight)
                .padding(.bottom, 1)
            } else {
                missingAssetPlaceholder
                    .frame(height: maxHeight * 0.5)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .topTrailing) {
            statusBadge
                .padding(8)
        }
        .contextMenu {
            Button("Rotate Left") { onRotate?(-90) }
            Button("Rotate Right") { onRotate?(90) }
            Divider()
            Button("Flip Horizontal") { onFlip?() }
            Divider()
            Button("Force Re-Extract Page") { onReextract?() }
        }
        .onAppear { syncDrafts() }
        .onChange(of: page.blocks.map(\.id)) { syncDrafts() }
    }

    // MARK: - Layout

    private func fittedSize(for imageSize: CGSize, in proxySize: CGSize) -> CGSize {
        let target = CGSize(width: proxySize.width, height: maxHeight)
        let scale = min(
            target.width / imageSize.width,
            target.height / imageSize.height
        )
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private var missingAssetPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Source image missing")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Locate the project folder to restore bindings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusBadge: some View {
        let (label, color) = statusInfo
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.white)
    }

    private var statusInfo: (String, Color) {
        switch page.status {
        case .processing:            return ("Processing", .orange)
        case .ready:                 return ("Ready", .green)
        case .manualReviewRequired:  return ("Manual Review", .red)
        }
    }

    // MARK: - Draft Sync

    /// Re-project the page's persisted blocks into transient overlay drafts.
    /// Called on appear and whenever the set of block IDs changes.
    private func syncDrafts() {
        drafts = page.blocks
            .sorted { $0.sequence < $1.sequence }
    }
}

/// Value-type snapshot of a `Page` and its illustration blocks for the canvas.
/// Decouples the view from SwiftData reference types so gestures mutate pure
/// values and only commit on gesture end.
struct PageSnapshot: Identifiable {
    let id: UUID
    let sequence: Int
    let status: PageStatus
    let image: NSImage?
    let blocks: [AnnotationDraft]
}

/// The continuous, vertically scrolling image stream (use-case 6, left pane).
///
/// Images are sized to a configurable percentage of the window height (default
/// 60%) so the boundary between adjacent pages is always visible, exactly as
/// the use case specifies. Each page image carries its annotation overlay.
///
/// Tracks the **current page** (use-case 7b/7d): the first page entirely in
/// view; if several are entirely in view, the first of those. Keyboard
/// shortcuts in `ReviewWorkspaceView` operate on this page.
struct ImageCanvasPane: View {

    let pages: [PageSnapshot]
    /// Height of each page card, as a fraction of the available height (0.5–0.8).
    var pageHeightFraction: CGFloat = 0.6
    /// When set, the canvas scrolls so the page with this ID is visible. Drives
    /// the editor -> canvas direction of scroll-sync.
    var scrollTargetPageID: UUID? = nil
    /// When the user adjusts the height slider (use-case 6: configurable %).
    var onPageHeightFractionChange: ((CGFloat) -> Void)? = nil

    var onAnnotationChange: ((UUID, CGRect) -> Void)?
    var onAnnotationCreate: ((AnnotationDraft) -> Void)?
    var onAnnotationDelete: ((UUID) -> Void)?
    /// Emitted whenever the current (first fully-in-view) page changes.
    var onCurrentPageChange: ((UUID) -> Void)? = nil
    /// Per-page actions surfaced via the context menu (use-case 7c/7d).
    var onRotatePage: ((UUID, Int) -> Void)? = nil
    var onFlipPage: ((UUID) -> Void)? = nil
    var onReextractPage: ((UUID) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let cardHeight = proxy.size.height * pageHeightFraction
                ScrollViewReader { scroller in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(pages) { page in
                                PageImageCard(
                                    page: page,
                                    maxHeight: cardHeight,
                                    onAnnotationChange: onAnnotationChange,
                                    onAnnotationCreate: onAnnotationCreate,
                                    onAnnotationDelete: onAnnotationDelete,
                                    onRotate: { angle in onRotatePage?(page.id, angle) },
                                    onFlip: { onFlipPage?(page.id) },
                                    onReextract: { onReextractPage?(page.id) }
                                )
                                .id(page.id)
                                Divider()
                            }
                        }
                    }
                    .onScrollGeometryChange(for: EquatableCurrentPageTracker.self) { geo in
                        let cardH = cardHeight
                        let visibleTop = geo.contentOffset.y
                        let firstFullIndex = max(0, Int((visibleTop / cardH).rounded(.up)))
                        let clamped = min(firstFullIndex, max(0, pages.count - 1))
                        return EquatableCurrentPageTracker(
                            index: clamped, id: pages[clamped].id
                        )
                    } action: { _, tracker in
                        onCurrentPageChange?(tracker.id)
                    }
                    .onChange(of: scrollTargetPageID) { _, newID in
                        if let newID {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                scroller.scrollTo(newID, anchor: .center)
                            }
                        }
                    }
                }
            }
            heightSlider
        }
    }

    /// Configurable image-height slider (use-case 6: 50–80% of window height).
    private var heightSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(pageHeightFraction) },
                set: { onPageHeightFractionChange?(CGFloat($0)) }
            ), in: 0.5...0.8)
            Text("\(Int(pageHeightFraction * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
    }
}

/// Equatable wrapper for `onScrollGeometryChange`'s `for:` type so it only
/// fires the action when the current-page index or ID actually changes.
private struct EquatableCurrentPageTracker: Equatable {
    let index: Int
    let id: UUID
}
