import Foundation

/// Brief phrases bias Apple's recognizer without changing the user's language or sending audio elsewhere.
enum SpeechVocabulary {
    static let builtIn = ["GitHub", "GitLab", "git", "Codex", "Claude", "Claude Code", "ChatGPT", "OpenAI",
                          "Cove", "SwiftUI", "Xcode", "JavaScript", "TypeScript", "Python", "npm",
                          "pull request", "repository", "terminal", "commit", "localhost", "API"]

    static func phrases(custom: [String] = [], folder: URL? = nil, repos: [String] = []) -> [String] {
        let projects = (folder.map { [$0.lastPathComponent] } ?? []) + repos.map { String($0.split(separator: "/").last ?? "") }
        var seen = Set<String>()
        return Array((builtIn + custom + projects).compactMap { phrase in
            let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, phrase.count <= 80, seen.insert(phrase.lowercased()).inserted else { return nil }
            return phrase
        }.prefix(100))
    }

    /// Narrow corrections for the common split-word rendering of GitHub. Avoid fuzzy replacements
    /// such as "get up" that could change the meaning of an ordinary request.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)\b(?:git[ -]+hub|get hub)\b"#, with: "GitHub", options: .regularExpression)
    }
}
