import Foundation
import EbookDigitizerCore

/// Enumerates a user-selected folder of scanned page images into an ordered
/// list of file URLs, validating the supported types required by the use case
/// (JPG, PNG, TIFF).
///
/// Pure and `Sendable`; no SwiftData, no UI. Lives in the app layer so it can
/// be unit-tested without a `ModelContext`.
public struct ImageFolderIngestor: Sendable {

    /// File extensions the use case explicitly supports.
    public static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff"]

    public init() {}

    /// Returns the ordered list of supported image URLs in `folder`, sorted by
    /// filename (which the use case implies is sequential). Throws if the
    /// folder contains no supported images.
    public func imageURLs(in folder: URL) throws -> [URL] {
        let resourceValues = try folder.resourceValues(forKeys: [.isDirectoryKey])
        guard resourceValues.isDirectory == true else {
            throw IngestError.notAFolder(folder)
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        let images = contents
            .filter { url in
                Self.supportedExtensions.contains(url.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !images.isEmpty else {
            throw IngestError.noSupportedImages(folder)
        }
        return images
    }

    public enum IngestError: LocalizedError, Sendable {
        case notAFolder(URL)
        case noSupportedImages(URL)

        public var errorDescription: String? {
            switch self {
            case .notAFolder(let url):
                return "“\(url.lastPathComponent)” is not a folder."
            case .noSupportedImages(let url):
                return "No JPG, PNG, or TIFF images were found in “\(url.lastPathComponent)”."
            }
        }
    }
}
