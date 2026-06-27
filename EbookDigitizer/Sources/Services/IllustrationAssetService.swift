import Foundation
import CoreGraphics
import ImageIO
import AppKit
import EbookDigitizerCore

/// Crops illustration regions from source page images and writes them to disk
/// as high-resolution PNG assets (use-case 7c + success guarantee #3).
///
/// The original source images are never mutated — we only read them via
/// `CGImageSource`, crop, and write a new file into the project's asset
/// folder. Pure value inputs/outputs; no SwiftData coupling.
public struct IllustrationAssetService: Sendable {

    public init() {}

    /// Crop the region described by `normalizedRect` (Vision lower-left space,
    /// `[0,1]`) out of the source image at `sourceURL`, writing a PNG to
    /// `destinationURL`. Returns the destination URL on success.
    public func crop(
        from sourceURL: URL,
        normalizedRect: CGRect,
        to destinationURL: URL
    ) throws -> URL {
        guard
            let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw AssetError.sourceImageUnreadable(sourceURL)
        }

        // Translate normalized lower-left rect into pixel space (top-left origin)
        // for CGImage.cropping(to:).
        let pixelW = CGFloat(cgImage.width)
        let pixelH = CGFloat(cgImage.height)
        let cropRect = CGRect(
            x: normalizedRect.minX * pixelW,
            y: (1.0 - normalizedRect.minY - normalizedRect.height) * pixelH,
            width: normalizedRect.width * pixelW,
            height: normalizedRect.height * pixelH
        )

        guard let cropped = cgImage.cropping(to: cropRect) else {
            throw AssetError.cropFailed
        }

        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard let dest = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            "public.png" as CFString,
            1, nil
        ) else {
            throw AssetError.destinationUnwritable(destinationURL)
        }
        CGImageDestinationAddImage(dest, cropped, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw AssetError.writeFailed(destinationURL)
        }
        return destinationURL
    }

    /// Delete a cropped asset from disk (use-case 7c "To Delete").
    public func delete(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public enum AssetError: LocalizedError, Sendable {
        case sourceImageUnreadable(URL)
        case cropFailed
        case destinationUnwritable(URL)
        case writeFailed(URL)

        public var errorDescription: String? {
            switch self {
            case .sourceImageUnreadable(let url):
                return "Could not read source image at \(url.lastPathComponent)."
            case .cropFailed:
                return "Could not crop the requested region from the source image."
            case .destinationUnwritable(let url):
                return "Could not create an asset file at \(url.path)."
            case .writeFailed(let url):
                return "Failed to write the cropped asset to \(url.path)."
            }
        }
    }
}
