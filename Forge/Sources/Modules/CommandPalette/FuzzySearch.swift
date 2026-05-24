import Foundation

/// Fast fuzzy search engine for the Command Palette.
/// Matches characters in order but not necessarily adjacent.
/// Scores based on match quality: consecutive matches, word starts, and exact matches score highest.
enum FuzzySearch {

    struct ScoredCommand {
        let command: ForgeCommand
        let score: Int
    }

    /// Filter and rank commands by fuzzy match quality
    static func filter(commands: [ForgeCommand], query: String) -> [ForgeCommand] {
        let query = query.lowercased()

        // Check for special prefixes
        if query.starts(with: "=") {
            // Calculator mode — handle inline
            return commands.filter { $0.id.contains("calculator") }
        }

        let scored = commands.compactMap { command -> ScoredCommand? in
            let titleScore = fuzzyScore(text: command.title.lowercased(), query: query)
            let keywordScore = command.keywords
                .map { fuzzyScore(text: $0.lowercased(), query: query) }
                .max() ?? 0
            let subtitleScore = fuzzyScore(text: (command.subtitle ?? "").lowercased(), query: query)

            let bestScore = max(titleScore * 3, keywordScore * 2, subtitleScore) // Title matches weighted 3x
            guard bestScore > 0 else { return nil }

            return ScoredCommand(command: command, score: bestScore)
        }

        return scored
            .sorted { $0.score > $1.score }
            .map { $0.command }
    }

    /// Calculate a fuzzy match score. Returns 0 for no match.
    /// Higher scores = better matches.
    private static func fuzzyScore(text: String, query: String) -> Int {
        guard !query.isEmpty else { return 1 }
        guard !text.isEmpty else { return 0 }

        let textChars = Array(text)
        let queryChars = Array(query)

        var score = 0
        var queryIndex = 0
        var consecutiveMatches = 0
        var lastMatchIndex = -2

        for (i, char) in textChars.enumerated() {
            guard queryIndex < queryChars.count else { break }

            if char == queryChars[queryIndex] {
                // Base match score
                score += 1

                // Consecutive match bonus
                if i == lastMatchIndex + 1 {
                    consecutiveMatches += 1
                    score += consecutiveMatches * 5
                } else {
                    consecutiveMatches = 0
                }

                // Word start bonus (after space, hyphen, or at index 0)
                if i == 0 || textChars[i - 1] == " " || textChars[i - 1] == "-" || textChars[i - 1] == "_" {
                    score += 10
                }

                // Exact prefix bonus
                if i == queryIndex {
                    score += 15
                }

                // CamelCase bonus
                if i > 0 && textChars[i].isUppercase && textChars[i - 1].isLowercase {
                    score += 8
                }

                lastMatchIndex = i
                queryIndex += 1
            }
        }

        // All query characters must be found
        guard queryIndex == queryChars.count else { return 0 }

        // Bonus for shorter texts (more precise matches)
        score += max(0, 50 - textChars.count)

        return score
    }
}
