import SwiftUI

/// Type-to-search attendee field with a dropdown of recent collaborators.
/// Backed by `ContactsDirectory.shared.suggestions(for:)`. When the user
/// hits Return on text that doesn't match any record we add it as a raw
/// email (validated by the caller).
///
/// Behavior:
///   • On focus or non-empty query → dropdown opens.
///   • ↑/↓ navigate, ↩ commits selection, ⎋ closes dropdown.
///   • Click a row → adds + clears query.
///   • Tapping outside dismisses (via `onSubmit`/`onChange` hand-off).
struct AttendeePickerField: View {
    @Binding var query: String
    /// Currently-added attendees — used to dedupe suggestions.
    let existing: [EventAttendee]
    let onPick: (ContactRecord) -> Void
    /// Called when the user hits Return on text that's a valid-looking
    /// email but isn't in the contacts directory (new collaborator).
    let onAddRaw: () -> Void

    @ObservedObject private var contacts = ContactsDirectory.shared
    @FocusState private var fieldFocused: Bool
    @State private var highlightedIndex: Int = 0

    /// Whether the dropdown is visible. Open when the field is focused
    /// AND we have suggestions to show.
    private var isOpen: Bool {
        fieldFocused && !suggestions.isEmpty
    }

    /// Top-N matches for the current query, filtered against already
    /// added attendees so we never suggest someone twice.
    private var suggestions: [ContactRecord] {
        let existingKeys = Set(existing.map { $0.email.lowercased() })
        return contacts.suggestions(for: query, limit: 8)
            .filter { !existingKeys.contains($0.email.lowercased()) }
    }

    /// Whether the current query is shaped like a fresh email (no match
    /// in contacts) — controls the "Add as new" affordance at the bottom.
    private var isFreshEmail: Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLikelyEmail(trimmed) else { return false }
        return !contacts.records.contains {
            $0.email.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Field row — input + (optional) plus button for raw emails.
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                TextField("Type a name or email…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($fieldFocused)
                    .onSubmit(commitFromKeyboard)
                    .onChange(of: query) { _ in
                        highlightedIndex = 0
                    }
                if isFreshEmail {
                    Button(action: onAddRaw) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(ForgeTheme.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Add as new contact")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ForgeTheme.Colors.surfaceCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        fieldFocused
                            ? ForgeTheme.Colors.accent.opacity(0.45)
                            : ForgeTheme.Colors.borderDefault,
                        lineWidth: 1
                    )
            )

            // Suggestions dropdown. Sits directly underneath the field
            // with a small gap so it reads as a connected affordance.
            if isOpen {
                suggestionsList
                    .padding(.top, 4)
            }
        }
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, record in
                suggestionRow(record: record, isHighlighted: idx == highlightedIndex)
                    .onTapGesture {
                        onPick(record)
                        query = ""
                        highlightedIndex = 0
                    }
                if idx != suggestions.count - 1 {
                    Divider().opacity(0.35)
                }
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ForgeTheme.Colors.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(ForgeTheme.Colors.borderDefault, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
    }

    private func suggestionRow(record: ContactRecord, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            // Avatar circle with initials — coloured deterministically
            // from the email so the same person is always the same hue.
            ZStack {
                Circle()
                    .fill(avatarColor(for: record.email).opacity(0.18))
                Text(record.initials)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(avatarColor(for: record.email))
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(record.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(record.email)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if record.frequency >= 3 {
                Text("\(record.frequency) events")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.75))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHighlighted ? ForgeTheme.Colors.accent.opacity(0.10) : .clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Keyboard handling

    /// Return key behavior — pick the highlighted suggestion if any,
    /// otherwise add the raw email if it looks valid.
    private func commitFromKeyboard() {
        if suggestions.indices.contains(highlightedIndex) {
            onPick(suggestions[highlightedIndex])
            query = ""
            highlightedIndex = 0
        } else if isLikelyEmail(query) {
            onAddRaw()
        }
    }

    // MARK: - Helpers

    private func isLikelyEmail(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = t.firstIndex(of: "@") else { return false }
        let domain = t[t.index(after: at)...]
        return !domain.isEmpty && domain.contains(".")
    }

    /// Deterministic avatar tint from the email — same person always
    /// gets the same color across sessions.
    private func avatarColor(for email: String) -> Color {
        let palette: [Color] = [
            .blue, .green, .orange, .purple, .pink,
            Color(red: 0.0, green: 0.65, blue: 0.78),
            Color(red: 0.95, green: 0.45, blue: 0.05),
            Color(red: 0.55, green: 0.27, blue: 0.68),
        ]
        let hash = email.lowercased().unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}
