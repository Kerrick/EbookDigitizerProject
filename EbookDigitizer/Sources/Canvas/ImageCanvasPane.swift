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
struct ImageCanvasPane: View {

    let pages: [PageSnapshot]
    /// Height of each page card, as a fraction of the available height (0.5–0.8).
    var pageHeightFraction: CGFloat = 0.6

    var onAnnotationChange: ((UUID, CGRect) -> Void)?
    var onAnnotationCreate: ((AnnotationDraft) -> Void)?
    var onAnnotationDelete: ((UUID) -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let cardHeight = proxy.size.height * pageHeightFraction
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pages) { page in
                        PageImageCard(
                            page: page,
                            maxHeight: cardHeight,
                            onAnnotationChange: onAnnotationChange,
                            onAnnotationCreate: onAnnotationCreate,
                            onAnnotationDelete: onAnnotationDelete
                        )
                        Divider()
                    }
                }
            }
        }
    }
}
