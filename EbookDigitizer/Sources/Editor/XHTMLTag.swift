import Foundation

/// XHTML tags applied by the keyboard macros (`Cmd+B`, `Cmd+I`, etc.).
///
/// Kept in the app layer — not `EbookDigitizerCore` — because they are an
/// editor-concern, mapping to the structural tags the use case requires in the
/// exported document.
public enum XHTMLTag: String, CaseIterable, Sendable {
    case strong = "strong"   // Cmd+B  — bold
    case em     = "em"       // Cmd+I  — italics
    case blockquote = "blockquote"
    case paragraph  = "p"

    /// The opening tag, e.g. `<strong>`.
    public var opening: String { "<\(rawValue)>" }
    /// The closing tag, e.g. `</strong>`.
    public var closing: String { "</\(rawValue)>" }
}

/// Identifies which XHTML tag the user wants to wrap a selection in.
public enum WrapIntent: Sendable {
    case strong
    case em
    case custom(tag: String)

    public var tag: XHTMLTag? {
        switch self {
        case .strong: return .strong
        case .em:     return .em
        case .custom: return nil
        }
    }

    public var opening: String {
        switch self {
        case .strong: return XHTMLTag.strong.opening
        case .em:     return XHTMLTag.em.opening
        case .custom(let tag): return "<\(tag)>"
        }
    }

    public var closing: String {
        switch self {
        case .strong: return XHTMLTag.strong.closing
        case .em:     return XHTMLTag.em.closing
        case .custom(let tag): return "</\(tag)>"
        }
    }
}
