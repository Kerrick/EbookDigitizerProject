import Foundation
import SwiftData
import EbookDigitizerCore

/// Launch-time project discovery and recovery (use-case step 2 "establishing a
/// continuous background autosave state" + minimal guarantee 2).
///
/// SwiftData persists projects to the application's default store on disk. This
/// service enumerates existing `Project`s so the app can offer "recent projects"
/// on launch instead of always starting from the empty state.
@MainActor
public final class ProjectLibraryService {

    private let modelContainer: ModelContainer

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// All persisted projects, most-recently-modified first.
    public func recentProjects() -> [Project] {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 50
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Open an existing project by ID. Returns the project if found.
    public func open(projectID: UUID) -> Project? {
        let context = modelContainer.mainContext
        var descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == projectID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
