enum AccountProvider: Equatable {
    case claude
    case codex

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

enum AccountActionPolicy {
    static func provider(for kind: AccountKind) -> AccountProvider? {
        switch kind {
        case .claudeMain, .claudeOAuth: return .claude
        case .codex, .codexOAuth: return .codex
        case .grok: return nil
        }
    }
}
