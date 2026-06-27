import Foundation
import EbookDigitizerCore

/// Validates that the source image files referenced by a project still exist
/// on disk (use-case 6a: the project folder was moved or renamed).
///
/// Pure value-type results; no SwiftData coupling so it can be tested in
/// isolation. The view-model feeds it page paths and surfaces the result.
public struct SourceAssetValidator: Sendable {

    public init() {}

    /// Result of checking a project's source bindings.
    public struct ProjectIntegrity: Sendable {
        /// `true` when every source image exists at its recorded path.
        public let isIntact: Bool
        /// The first missing folder (if any) the user may need to re-locate.
        public let missingFolder: URL?
        /// Page IDs whose source image is missing.
        public let pagesWithMissingImages: [UUID]

        public init(isIntact: Bool, missingFolder: URL?, pagesWithMissingImages: [UUID]) {
            self.isIntact = isIntact
            self.missingFolder = missingFolder
            self.pagesWithMissingImages = pagesWithMissingImages
        }
    }

    /// Check whether a folder still exists.
    public func folderExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Check whether a file exists.
    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Validate the integrity of a project given its recorded source folder
    /// and the list of (pageID, imageURL) pairs.
    public func validate(
        sourceFolder: URL?,
        pages: [(pageID: UUID, imageURL: URL)]
    ) -> ProjectIntegrity {
        var missing: [UUID] = []
        for entry in pages {
            if !fileExists(at: entry.imageURL) {
                missing.append(entry.pageID)
            }
        }
        let folderOK = sourceFolder.map { folderExists(at: $0) } ?? true
        return ProjectIntegrity(
            isIntact: missing.isEmpty && folderOK,
            missingFolder: (folderOK ? nil : sourceFolder),
            pagesWithMissingImages: missing
        )
    }
}
