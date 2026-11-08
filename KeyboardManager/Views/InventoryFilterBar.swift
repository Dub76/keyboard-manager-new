import SwiftUI

struct InventoryFilterBar: View {
    var kind: InventoryItemKind
    var items: [InventoryItemSummary]
    @Binding var filters: InventoryFilters
    @Binding var sort: InventorySort
    var resultCount: Int

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                kindSpecificFilters

                Picker("Sortierung", selection: $sort) {
                    ForEach(InventorySort.available(for: kind)) { option in
                        Text(option.title(for: kind)).tag(option)
                    }
                }
                .frame(width: 210)

                if !filters.isEmpty(for: kind) {
                    Button("Filter zurücksetzen", systemImage: "line.3.horizontal.decrease.circle.fill") {
                        filters = InventoryFilters()
                    }
                }

                Text("\(resultCount) von \(items.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var kindSpecificFilters: some View {
        switch kind {
        case .board:
            stringPicker(
                title: "Hersteller",
                allTitle: "Alle Hersteller",
                selection: $filters.manufacturer,
                values: InventoryQuery.values(\.manufacturer, in: items)
            )
            stringPicker(
                title: "Format",
                allTitle: "Alle Formate",
                selection: $filters.format,
                values: InventoryQuery.values(\.format, in: items)
            )
            stringPicker(
                title: "Farbe",
                allTitle: "Alle Farben",
                selection: $filters.color,
                values: InventoryQuery.values(\.color, in: items)
            )
        case .keycapSet, .artisanSet:
            stringPicker(
                title: "Hersteller",
                allTitle: "Alle Hersteller",
                selection: $filters.manufacturer,
                values: InventoryQuery.values(\.manufacturer, in: items)
            )
            stringPicker(
                title: "Profil",
                allTitle: "Alle Profile",
                selection: $filters.profile,
                values: InventoryQuery.values(\.profile, in: items)
            )
            stringPicker(
                title: "Status",
                allTitle: "Alle Status",
                selection: $filters.status,
                values: InventoryQuery.values(\.status, in: items)
            )
        case .switchSet:
            stringPicker(
                title: "Typ",
                allTitle: "Alle Typen",
                selection: $filters.switchType,
                values: InventoryQuery.values(\.switchType, in: items)
            )
            stringPicker(
                title: "Betätigungskraft",
                allTitle: "Alle Kräfte",
                selection: $filters.operatingForce,
                values: InventoryQuery.values(\.operatingForce, in: items)
            )
            Picker("Pins", selection: $filters.pins) {
                Text("Alle Pins").tag(SwitchPins?.none)
                ForEach(SwitchPins.allCases) { pins in
                    Text(pins.displayName).tag(Optional(pins))
                }
            }
            .frame(width: 150)
        }
    }

    private func stringPicker(
        title: String,
        allTitle: String,
        selection: Binding<String>,
        values: [String]
    ) -> some View {
        Picker(title, selection: selection) {
            Text(allTitle).tag("")
            ForEach(values, id: \.self) { value in
                Text(value).tag(value)
            }
        }
        .frame(width: 190)
    }
}
