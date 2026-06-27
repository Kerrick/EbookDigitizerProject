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
    @State private var pendingProjectTitle = ""

    init(viewModel: WorkspaceViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        Group {
            if viewModel.status == .empty {
                EmptyStateView { title in
                    pendingProjectTitle = title
                    showingFolderImporter = true
                }
            } else {
                dualPane
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Bold") {}
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(viewModel.status != .ready)
                Button("Italic") {}
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
                Button("Export…") { showingSavePanel = true }
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
                pageHeightFraction: 0.6,
                scrollTargetPageID: viewModel.lastActiveBlockPageID,
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
                text: Binding(
                    get: { viewModel.documentText },
                    set: { viewModel.documentTextDidChange(to: $0) }
                ),
                isEditable: !viewModel.isEditingDisabled,
                scrollTarget: viewModel.blockIDForScrollSync
                    .flatMap { viewModel.range(forBlockID: $0) },
                removeImageTagsForAsset: viewModel.pendingAssetTagRemoval,
                onActiveLineChange: { range in
                    viewModel.editorActiveLineChanged(range)
                }
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
    @State private var title: String = "Untitled Book"
    var onChoose: (String) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Digitize a Book")
                .font(.largeTitle.bold())
            Text("Choose a folder of sequential scanned page images to begin.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("Book Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
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
