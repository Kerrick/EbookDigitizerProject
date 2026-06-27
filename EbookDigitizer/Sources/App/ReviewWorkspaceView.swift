import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import EbookDigitizerCore

/// The full synchronized review workspace (use-case 6).
///
/// Left pane: continuous image stream with annotation overlays (Phase 4).
/// Right pane: XHTML plaintext editor (Phase 3). The two are scroll-synced:
/// the editor's active-line hook drives the canvas, and the canvas's block
/// selection drives the editor.
struct ReviewWorkspaceView: View {

    @State var viewModel: WorkspaceViewModel
    @State private var showingFolderImporter = false
    @State private var showingRelocateImporter = false
    @State private var showingSavePanel = false
    @State private var showingCompletionGate = false
    @State private var pendingProjectTitle = ""

    init(viewModel: WorkspaceViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if viewModel.status == .empty {
                EmptyStateView(
                    recentProjects: viewModel.recentProjects,
                    onChoose: { title in
                        pendingProjectTitle = title
                        showingFolderImporter = true
                    },
                    onOpen: { id in viewModel.openProject(id) }
                )
                .onAppear { viewModel.loadRecentProjects() }
            } else {
                dualPane
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Bold") {
                    sendEditorAction(#selector(XHTMLTextView.toggleStrong(_:)))
                }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(viewModel.status != .ready)
                Button("Italic") {
                    sendEditorAction(#selector(XHTMLTextView.toggleItalics(_:)))
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(viewModel.status != .ready)
                Divider()
                Menu("Orientation") {
                    Button("Rotate Left") {
                        if let pageID = viewModel.currentPageID {
                            viewModel.rotate(pageID: pageID, by: -90)
                        }
                    }
                    Button("Rotate Right") {
                        if let pageID = viewModel.currentPageID {
                            viewModel.rotate(pageID: pageID, by: 90)
                        }
                    }
                    Divider()
                    Button("Flip Horizontal") {
                        if let pageID = viewModel.currentPageID {
                            viewModel.flip(pageID: pageID)
                        }
                    }
                }
                Button("Force Re-Extract Page") {
                    if let pageID = viewModel.currentPageID {
                        viewModel.reextractPage(pageID, force: true)
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Export…") { showingCompletionGate = true }
                    .disabled(viewModel.activeProjectID == nil)
            }
        }
        .fileImporter(
            isPresented: $showingFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        viewModel.ingest(folder: url, title: pendingProjectTitle)
                    }
                }
            case .failure(let error):
                viewModel.setError(error.localizedDescription)
            }
        }
        .fileImporter(
            isPresented: $showingRelocateImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        viewModel.rebind(to: url)
                    }
                }
            case .failure(let error):
                viewModel.setError(error.localizedDescription)
            }
        }
        .sheet(isPresented: $showingCompletionGate) {
            CompletionGateView(viewModel: viewModel) {
                showingCompletionGate = false
                showingSavePanel = true
            } onCancel: {
                showingCompletionGate = false
            }
        }
        .sheet(isPresented: $showingSavePanel) {
            ExportSheet { fileName in
                saveUsingPanel(fileName: fileName)
                showingSavePanel = false
            }
        }
        .alert(
            "Source Folder Missing",
            isPresented: Binding(
                get: { viewModel.missingFolderURL != nil },
                set: { if !$0 { viewModel.dismissMissingFolder() } }
            )
        ) {
            Button("Locate…") { showingRelocateImporter = true }
            Button("Cancel", role: .cancel) { viewModel.dismissMissingFolder() }
        } message: {
            Text("The folder containing this project's source scans can't be found. Locate it to restore editing and image bindings.")
        }
    }

    // MARK: - Dual Pane

    private var dualPane: some View {
        HSplitView {
            ImageCanvasPane(
                pages: viewModel.pageSnapshots,
                pageHeightFraction: viewModel.pageHeightFraction,
                scrollTargetPageID: viewModel.lastActiveBlockPageID,
                onPageHeightFractionChange: { value in viewModel.setPageHeightFraction(value) },
                onAnnotationChange: { blockID, rect in
                    if let pageID = viewModel.pageID(forBlockID: blockID) {
                        viewModel.commitIllustration(
                            pageID: pageID, blockID: blockID, normalizedRect: rect
                        )
                    }
                },
                onAnnotationCreate: { draft in
                    if let pageID = viewModel.pageID(forBlockID: draft.id)
                        ?? viewModel.pageSnapshots.first?.id {
                        viewModel.createIllustration(pageID: pageID, draft: draft)
                    }
                },
                onAnnotationDelete: { blockID in
                    if let pageID = viewModel.pageID(forBlockID: blockID) {
                        viewModel.deleteIllustration(pageID: pageID, blockID: blockID)
                    }
                },
                onCurrentPageChange: { id in viewModel.setCurrentPage(id) },
                onRotatePage: { id, angle in viewModel.rotate(pageID: id, by: angle) },
                onFlipPage: { id in viewModel.flip(pageID: id) },
                onReextractPage: { id in viewModel.reextractPage(id, force: true) }
            )
            .frame(minWidth: 420)

            XHTMLTextEditor(
                blocks: viewModel.renderedBlocks,
                isEditable: !viewModel.isEditingDisabled,
                scrollTargetBlockID: viewModel.scrollTargetBlockID,
                removeImageTagsForAsset: viewModel.pendingAssetTagRemoval,
                insertionFragment: viewModel.pendingInsertionFragment,
                onBlockTextChange: { id, text in viewModel.onBlockTextChange(id, text) },
                onBlockSplit: { original, newID, text in
                    viewModel.onBlockSplit(originalID: original, newID: newID, newText: text)
                },
                onBlockMerge: { kept, removed in
                    viewModel.onBlockMerge(keptID: kept, removedID: removed)
                },
                onActiveLineChange: { range in viewModel.editorActiveLineChanged(range) }
            )
            .frame(minWidth: 380)
        }
        .overlay(alignment: .top) {
            statusBanner
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch viewModel.status {
        case .processing(let completed, let total):
            ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                Text("Processing page \(completed) of \(total)…")
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(8)
        case .exporting:
            Text("Exporting…")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
        case .error(let message):
            Text("⚠︎ \(message)")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(8)
        default:
            EmptyView()
        }
    }

    // MARK: - Export

    /// Send a selector up the responder chain to the focused `XHTMLTextView`
    /// (use-case 7a.2: toolbar buttons trigger the same wrap macros as the
    /// keyboard shortcuts, via the native responder chain).
    @MainActor
    private func sendEditorAction(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    private func saveUsingPanel(fileName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(fileName).xhtml"
        panel.allowedContentTypes = [UTType(filenameExtension: "xhtml") ?? UTType.xml]
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.export(to: url)
        }
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    let recentProjects: [WorkspaceViewModel.ProjectSummary]
    var onChoose: (String) -> Void
    var onOpen: (UUID) -> Void
    @State private var title: String = "Untitled Book"

    var body: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(spacing: 24) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Digitize a Book")
                    .font(.title.bold())
                Text("Choose a folder of sequential scanned page images to begin.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TextField("Book Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button {
                    onChoose(title)
                } label: {
                    Label("Choose Folder…", systemImage: "folder")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !recentProjects.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent Projects")
                        .font(.headline)
                    List(recentProjects) { project in
                        Button {
                            onOpen(project.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(project.title).font(.body)
                                Text("\(project.pageCount) pages • \(project.updatedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
                .frame(maxWidth: 280, maxHeight: .infinity, alignment: .top)
                .background(.regularMaterial)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Completion Gate (use-case step 8)

private struct CompletionGateView: View {
    let viewModel: WorkspaceViewModel
    var onConfirm: () -> Void
    var onCancel: () -> Void

    private var unreviewed: [PageSnapshot] {
        viewModel.pageSnapshots.filter { $0.status != .ready }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm Completion")
                .font(.headline)
            if unreviewed.isEmpty {
                Text("All pages are ready for export. Confirm to proceed.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(unreviewed.count) page(s) are not yet ready:")
                    .font(.callout)
                List(unreviewed) { page in
                    HStack {
                        Text("Page \(page.sequence + 1)")
                        Spacer()
                        Text(page.status.displayName)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxHeight: 200)
                Text("You can still export, but these pages may be incomplete.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Export Anyway", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

extension PageStatus {
    var displayName: String {
        switch self {
        case .processing: "Processing"
        case .ready: "Ready"
        case .manualReviewRequired: "Manual Review Required"
        }
    }
}

// MARK: - Export Sheet

private struct ExportSheet: View {
    @State private var fileName: String = "book"
    var onExport: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Export XHTML").font(.headline)
            TextField("File name", text: $fileName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { onExport(fileName) }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { onExport(fileName) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}
