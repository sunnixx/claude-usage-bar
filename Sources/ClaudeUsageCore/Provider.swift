import Foundation

/// A usage source. The order of the cases is the order the menu bar and the
/// dropdown present them, so it is deliberately fixed rather than sorted.
public enum Provider: String, CaseIterable, Sendable {
    case anthropic
    case codex

    public var displayName: String {
        switch self {
        case .anthropic: return "Claude"
        case .codex: return "Codex"
        }
    }
}
