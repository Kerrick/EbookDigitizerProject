import SwiftUI
import SwiftData
import EbookDigitizerCore

@main
struct EbookDigitizerApp: App {

    /// The shared SwiftData container. Configured for automatic background
    /// persistence + undo/redo out of the box. `@MainActor`-isolated because
    /// the App's `ModelContext` is bound to the main actor — no GCD.
    private let modelContainer: ModelContainer
    @State private var viewModel: WorkspaceViewModel

    init() {
        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: false)
            let container = try ModelContainer(
                for: Project.self, Page.self, ElementBlock.self,
                configurations: config
            )
            // Enable continuous background autosave (use-case minimal guarantee
            // #2). SwiftData handles the actual disk writes off the main actor.
            container.mainContext.autosaveEnabled = true
            modelContainer = container
            viewModel = WorkspaceViewModel(modelContainer: container)
        } catch {
            fatalError("Failed to initialize ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ReviewWorkspaceView(viewModel: viewModel)
                .frame(minWidth: 1000, minHeight: 650)
        }
        .modelContainer(modelContainer)
        .commands {
            AppCommands(viewModel: viewModel)
        }
    }
}
