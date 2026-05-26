import SwiftUI

/// Floating popover anchored to the world-clock strip's "…" overflow
/// button. Lists the user's current cities with drag handles + ✕ remove,
/// and a search field at the bottom to add a new city. Matches the
/// reference UI (dark surface, "CURRENT" / "Drag to reorder" labels,
/// grip-style drag handle).
struct WorldClockManagerPopover: View {
    @EnvironmentObject var settings: SettingsManager
    @State private var query: String = ""
    @State private var draggingId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text("CURRENT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(.secondary.opacity(0.65))
                Text("Drag to reorder")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.55))
            }

            // Current cities list
            VStack(spacing: 4) {
                ForEach(settings.worldClockCities) { city in
                    cityRow(city)
                        .onDrag {
                            draggingId = city.id
                            return NSItemProvider(object: city.id.uuidString as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: CityDropDelegate(
                                target: city,
                                cities: $settings.worldClockCities,
                                draggingId: $draggingId
                            )
                        )
                }
            }

            // Add new city
            Divider().opacity(0.2)
            Text("ADD A CITY")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(.secondary.opacity(0.65))
            TextField("Search…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            if !suggestions.isEmpty {
                VStack(spacing: 2) {
                    ForEach(suggestions, id: \.id) { city in
                        Button {
                            add(city)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                Text(city.label)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(ForgeTheme.Colors.textPrimary)
                                Spacer()
                                Text(city.timeZoneId)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.secondary.opacity(0.06))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func cityRow(_ city: WorldClockCity) -> some View {
        HStack(spacing: 10) {
            // Grip — pure visual cue, drag is bound to the whole row.
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.5))
            Text(city.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(ForgeTheme.Colors.textPrimary)
            Spacer()
            Button {
                settings.worldClockCities.removeAll { $0.id == city.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(draggingId == city.id
                      ? Color.blue.opacity(0.10)
                      : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// Filter the preset list against the query, excluding cities the
    /// user already has on the strip.
    private var suggestions: [WorldClockCity] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let existing = Set(settings.worldClockCities.map(\.id))
        let presets = WorldClockCity.presets.filter { !existing.contains($0.id) }
        if trimmed.isEmpty {
            return Array(presets.prefix(6))
        }
        return Array(presets.filter {
            $0.label.lowercased().contains(trimmed)
                || $0.timeZoneId.lowercased().contains(trimmed)
        }.prefix(6))
    }

    private func add(_ city: WorldClockCity) {
        settings.worldClockCities.append(city)
        query = ""
    }
}

/// Drop delegate that swaps cities into the order they're released
/// over. Uses the dragging row's id (stored at drag start) to find
/// the source row in the array.
private struct CityDropDelegate: DropDelegate {
    let target: WorldClockCity
    @Binding var cities: [WorldClockCity]
    @Binding var draggingId: UUID?

    func dropEntered(info: DropInfo) {
        guard
            let draggingId,
            draggingId != target.id,
            let from = cities.firstIndex(where: { $0.id == draggingId }),
            let to = cities.firstIndex(where: { $0.id == target.id })
        else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            let moved = cities.remove(at: from)
            cities.insert(moved, at: to)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }
}
