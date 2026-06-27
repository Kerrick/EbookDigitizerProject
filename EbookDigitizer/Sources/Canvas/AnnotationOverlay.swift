import SwiftUI
import EbookDigitizerCore

/// The interaction mode the overlay is currently in. Mutually exclusive so the
/// gesture graph stays simple.
private enum DragMode: Equatable {
    case none
    case creating(UUID)            // User is drawing a new box on empty canvas.
    case moving(UUID)              // User is dragging the body of an existing box.
    case resizing(UUID, Handle)    // User is dragging a corner handle.
}

/// Which corner/edge handle is being dragged.
private enum Handle: Equatable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// The position of the handle for a given view-space rect.
    func anchor(for rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX,    y: rect.minY)
        case .top:          return CGPoint(x: rect.midX,    y: rect.minY)
        case .topRight:     return CGPoint(x: rect.maxX,    y: rect.minY)
        case .right:        return CGPoint(x: rect.maxX,    y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX,    y: rect.maxY)
        case .bottom:       return CGPoint(x: rect.midX,    y: rect.maxY)
        case .bottomLeft:  return CGPoint(x: rect.minX,    y: rect.maxY)
        case .left:         return CGPoint(x: rect.minX,    y: rect.midY)
        }
    }
}

/// A single page's annotation overlay: renders all bounding boxes for one
/// page image and handles every gesture in use-case 7c (draw, select, move,
/// resize, delete).
///
/// Mutates transient `AnnotationDraft` values during gestures and commits
/// back via `onChange`/`onCreate`/`onDelete` only when a gesture ends — so
/// SwiftData isn't thrashed mid-drag, and the model stays a clean record.
struct AnnotationOverlay: View {

    /// The drafts currently rendered (one per `ElementBlock` on the page).
    @Binding var drafts: [AnnotationDraft]

    /// Rendered size of the page image in points — used to translate between
    /// view-space gestures and the persisted normalized space.
    let imageSize: CGSize

    /// Emits the final normalized rect whenever an existing box finishes
    /// being moved or resized.
    var onChange: ((UUID, CGRect) -> Void)? = nil
    /// Emits the new box's draft when the user finishes drawing one.
    var onCreate: ((AnnotationDraft) -> Void)? = nil
    /// Emits the box ID to delete (use-case 7c "To Delete").
    var onDelete: ((UUID) -> Void)? = nil

    @State private var activeID: UUID?
    @State private var mode: DragMode = .none
    @State private var dragStart: CGPoint = .zero
    @State private var dragStartRect: CGRect = .zero

    private let handleSize: CGFloat = 12
    private let hitPadding: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let size = resolveImageSize(in: proxy.size)
            ZStack {
                // Tap-to-create-draw surface. Sits behind the boxes so that a
                // drag starting on empty space begins a new rectangle.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(createGesture(in: size))
                    .onTapGesture { handleCanvasTap() }

                ForEach(drafts) { draft in
                    boxView(for: draft, in: size)
                }
            }
            .frame(width: size.width, height: size.height)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .focusable()
        .onKeyPress(.delete) {
            guard let activeID else { return .ignored }
            deleteBox(activeID)
            return .handled
        }
    }

    // MARK: - Sizing

    /// The overlay fills the geometry reader but draws boxes against the same
    /// aspect-ratio-fitted size the image uses, so coordinates line up.
    private func resolveImageSize(in proxySize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return proxySize }
        let scale = min(proxySize.width / imageSize.width, proxySize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    // MARK: - Box Rendering

    @ViewBuilder
    private func boxView(for draft: AnnotationDraft, in size: CGSize) -> some View {
        let rect = draft.viewRect(in: size)
        let isActive = draft.id == activeID

        ZStack {
            // Filled hit area (transparent unless active) — the move gesture
            // attaches here so it doesn't fight the resize handles.
            Rectangle()
                .fill(isActive ? Color.accentColor.opacity(0.12) : .clear)
                .contentShape(Rectangle())
                .gesture(moveGesture(for: draft.id, in: size))

            // Border.
            Rectangle()
                .stroke(
                    isActive ? Color.accentColor : Color.secondary.opacity(0.7),
                    style: StrokeStyle(lineWidth: isActive ? 2.5 : 1.5, dash: isActive ? [] : [4, 3])
                )
                .allowsHitTesting(false)

            // Label chip with the semantic type.
            typeChip(draft.blockType, at: .topLeading)
                .allowsHitTesting(false)
                .padding(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Resize handles only for the active box.
            if isActive {
                ForEach(Handle.allCases, id: \.self) { handle in
                    handleDot(at: handle.anchor(for: rect))
                        .gesture(resizeGesture(for: draft.id, handle: handle, in: size))
                }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
        .onTapGesture { activeID = draft.id }
    }

    private func typeChip(_ type: BlockType, at alignment: Alignment) -> some View {
        Text(type.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.primary)
    }

    private func handleDot(at point: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: handleSize, height: handleSize)
            .position(point)
    }

    // MARK: - Gestures: Create

    private func createGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in beginCreate(at: value.startLocation, in: size) }
            .onEnded { value in endCreate(from: value.startLocation, to: value.location, in: size) }
    }

    private func beginCreate(at start: CGPoint, in size: CGSize) {
        guard mode == .none else { return }
        let id = UUID()
        let normalizedStart = CanvasGeometry.viewToNormalized(
            CGRect(origin: start, size: .zero), in: size
        )
        let draft = AnnotationDraft(
            id: id, sequence: drafts.count, blockType: .illustration,
            normalizedRect: normalizedStart
        )
        drafts.append(draft)
        activeID = id
        mode = .creating(id)
        dragStart = start
    }

    private func endCreate(from start: CGPoint, to end: CGPoint, in size: CGSize) {
        guard case .creating(let id) = mode else { return }
        defer { mode = .none }

        let viewRect = CanvasGeometry.normalizeRect(
            from: start, to: end, minSize: handleSize + 4, in: size
        )
        let normalized = CanvasGeometry.clamp(
            CanvasGeometry.viewToNormalized(viewRect, in: size)
        )

        // Treat drags smaller than the minimum as accidental taps — drop them.
        if viewRect.width < 6 || viewRect.height < 6 {
            drafts.removeAll { $0.id == id }
            activeID = nil
            return
        }

        if let index = drafts.firstIndex(where: { $0.id == id }) {
            drafts[index].normalizedRect = normalized
            onCreate?(drafts[index])
        }
    }

    // MARK: - Gestures: Move

    private func moveGesture(for id: UUID, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in updateMove(id, by: value.translation, in: size) }
            .onEnded { _ in commitMove(id) }
    }

    private func updateMove(_ id: UUID, by translation: CGSize, in size: CGSize) {
        guard mode == .none || mode == .moving(id),
              let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        if mode == .none {
            mode = .moving(id)
            dragStartRect = drafts[index].viewRect(in: size)
        }
        var newView = dragStartRect
        newView.origin.x += translation.width
        newView.origin.y += translation.height
        // Clamp to the page bounds in view space.
        newView.origin.x = max(0, min(newView.origin.x, size.width - newView.width))
        newView.origin.y = max(0, min(newView.origin.y, size.height - newView.height))
        drafts[index].normalizedRect = CanvasGeometry.viewToNormalized(newView, in: size)
    }

    private func commitMove(_ id: UUID) {
        guard case .moving = mode,
              let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        mode = .none
        onChange?(drafts[index].id, drafts[index].normalizedRect)
    }

    // MARK: - Gestures: Resize

    private func resizeGesture(for id: UUID, handle: Handle, in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in updateResize(id, handle: handle, by: value.translation, in: size) }
            .onEnded { _ in commitResize(id) }
    }

    private func updateResize(_ id: UUID, handle: Handle, by translation: CGSize, in size: CGSize) {
        guard mode == .none || mode == .resizing(id, handle),
              let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        if mode == .none {
            mode = .resizing(id, handle)
            dragStartRect = drafts[index].viewRect(in: size)
        }

        var new = dragStartRect
        switch handle {
        case .topLeft:      new.origin.x += translation.width; new.origin.y += translation.height
                            new.size.width -= translation.width; new.size.height -= translation.height
        case .top:          new.origin.y += translation.height; new.size.height -= translation.height
        case .topRight:     new.origin.y += translation.height
                            new.size.width += translation.width; new.size.height -= translation.height
        case .right:        new.size.width += translation.width
        case .bottomRight: new.size.width += translation.width; new.size.height += translation.height
        case .bottom:       new.size.height += translation.height
        case .bottomLeft:  new.origin.x += translation.width; new.size.width -= translation.width
                            new.size.height += translation.height
        case .left:         new.origin.x += translation.width; new.size.width -= translation.width
        }

        // Don't allow the box to invert (negative size) — clamp at a minimum.
        let minSide: CGFloat = 12
        if new.width < minSide {
            if [.topLeft, .bottomLeft, .left].contains(handle) {
                new.origin.x = dragStartRect.maxX - minSide
            }
            new.size.width = minSide
        }
        if new.height < minSide {
            if [.topLeft, .top, .topRight].contains(handle) {
                new.origin.y = dragStartRect.maxY - minSide
            }
            new.size.height = minSide
        }
        // Clamp to page.
        new.origin.x = max(0, new.origin.x)
        new.origin.y = max(0, new.origin.y)
        if new.maxX > size.width { new.size.width = size.width - new.origin.x }
        if new.maxY > size.height { new.size.height = size.height - new.origin.y }

        drafts[index].normalizedRect = CanvasGeometry.viewToNormalized(new, in: size)
    }

    private func commitResize(_ id: UUID) {
        guard case .resizing = mode,
              let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        mode = .none
        onChange?(drafts[index].id, drafts[index].normalizedRect)
    }

    // MARK: - Tap-to-Select / Delete

    private func handleCanvasTap() {
        // A tap on empty space deselects the active box.
        activeID = nil
    }

    private func deleteBox(_ id: UUID) {
        drafts.removeAll { $0.id == id }
        if activeID == id { activeID = nil }
        onDelete?(id)
    }

}

// MARK: - Shared Geometry Helpers

extension CanvasGeometry {
    /// Build a positive rect from two arbitrary drag endpoints, honoring a
    /// minimum size so accidental micro-drags don't produce junk boxes.
    static func normalizeRect(
        from start: CGPoint, to end: CGPoint, minSize: CGFloat, in size: CGSize
    ) -> CGRect {
        let minX = min(start.x, end.x)
        let minY = min(start.y, end.y)
        let maxX = max(start.x, end.x)
        let maxY = max(start.y, end.y)
        return CGRect(
            x: minX, y: minY,
            width: max(maxX - minX, minSize),
            height: max(maxY - minY, minSize)
        )
    }
}

// MARK: - BlockType Display

extension BlockType {
    /// Short human-readable label shown in the annotation chip.
    var displayName: String {
        switch self {
        case .bodyParagraph:     return "Body"
        case .blockquote:        return "Quote"
        case .marginalia:        return "Margin"
        case .pageArtifact:      return "Artifact"
        case .illustration:      return "Illustration"
        }
    }
}
