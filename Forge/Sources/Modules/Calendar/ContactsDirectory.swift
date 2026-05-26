import Foundation
import Combine

/// One person Forge knows about from past Google Calendar interactions.
/// We dedupe by lowercase email and rank by how often the user has
/// invited or co-attended them — so the autocomplete surfaces the
/// people the user actually works with first.
struct ContactRecord: Identifiable, Equatable {
    let email: String
    var displayName: String?
    /// Number of events this person has been on (with the current user).
    /// Higher = "closer" colleague, shown earlier in suggestions.
    var frequency: Int
    /// Most recent event this person appeared on. Tie-breaker when
    /// frequency matches — favours recently-active collaborators.
    var lastSeen: Date
    /// `displayName` if present, otherwise the email's local-part with
    /// "." swapped to " " and title-cased ("first.last@…" → "First Last").
    var displayLabel: String {
        if let name = displayName, !name.isEmpty { return name }
        let local = String(email.split(separator: "@").first ?? "")
        return local
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
    /// Two-letter initials for the avatar circle in the picker dropdown.
    var initials: String {
        let label = displayLabel
        let words = label.split(separator: " ").prefix(2)
        return words.map { $0.prefix(1).uppercased() }.joined()
    }
    var id: String { email.lowercased() }
}

/// Builds + caches a deduplicated, ranked list of `ContactRecord`s
/// pulled from the user's past calendar events. Refreshes whenever
/// `CalendarModule.events` changes (the module already syncs Google
/// events into this array).
///
/// We deliberately keep this in-memory: it's recomputed on demand,
/// cheap (≤ a few thousand attendees in practice), and avoids a
/// separate sync layer that would have to be invalidated.
final class ContactsDirectory: ObservableObject {
    static let shared = ContactsDirectory()
    @Published private(set) var records: [ContactRecord] = []

    private init() {}

    /// Re-index from the current event list. Call this after
    /// `CalendarModule.loadEvents()` and whenever the list changes.
    /// We use lowercase email as the dedupe key, take the best
    /// available displayName, and bump frequency for each hit.
    func rebuild(from events: [CalendarEvent], myEmails: Set<String>) {
        var index: [String: ContactRecord] = [:]
        let myEmailsLower = Set(myEmails.map { $0.lowercased() })

        for event in events {
            for attendee in event.attendees {
                let key = attendee.email.lowercased()
                // Skip the current user — autocompleting yourself
                // when adding attendees is just confusing.
                if myEmailsLower.contains(key) { continue }

                if var existing = index[key] {
                    existing.frequency += 1
                    if event.startDate > existing.lastSeen {
                        existing.lastSeen = event.startDate
                    }
                    // Prefer the version that has a display name.
                    if existing.displayName == nil,
                       let name = attendee.displayName, !name.isEmpty {
                        existing.displayName = name
                    }
                    index[key] = existing
                } else {
                    index[key] = ContactRecord(
                        email: attendee.email,
                        displayName: attendee.displayName,
                        frequency: 1,
                        lastSeen: event.startDate
                    )
                }
            }
        }

        // Sort: frequency desc, then lastSeen desc (most recent
        // collaborators near the top when frequency ties).
        let sorted = index.values.sorted { a, b in
            if a.frequency != b.frequency { return a.frequency > b.frequency }
            return a.lastSeen > b.lastSeen
        }
        DispatchQueue.main.async {
            self.records = sorted
        }
    }

    /// Top-K matches for the given query string. Empty query returns
    /// the top-K most-frequent contacts — useful for showing
    /// suggestions on first focus.
    func suggestions(for query: String, limit: Int = 8) -> [ContactRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return Array(records.prefix(limit))
        }
        let matches = records.filter { record in
            record.email.lowercased().contains(trimmed)
                || (record.displayName?.lowercased().contains(trimmed) ?? false)
                || record.displayLabel.lowercased().contains(trimmed)
        }
        return Array(matches.prefix(limit))
    }
}
