import Foundation

/// Semantic classification for a single content region detected on a page.
///
/// Stored as a `String`-backed enum so SwiftData can persist it natively
/// (enums are encoded via their `Codable` conformance) while remaining
/// lightweight and queryable through predicates.
public enum BlockType: String, Codable, CaseIterable, Sendable {
    /// Continuous primary text flow of the book (paragraphs, headings, etc.).
    case bodyParagraph
    /// An offset quoted passage within the body flow.
    case blockquote
    /// Isolated notes or footnotes outside the main text flow.
    case marginalia
    /// Repeating running headers, footers, and page numbers to be excluded
    /// from the exported XHTML text flow.
    case pageArtifact
    /// A non-text illustration whose cropped asset is stored on disk.
    case illustration
}
