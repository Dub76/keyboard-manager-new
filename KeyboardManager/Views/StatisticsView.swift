import SwiftUI

/// Key figures of the keyboard collection: headline numbers as tiles and one
/// ranked bar list per property. Every bar shows its count as text, so no
/// information depends on color or on reading the bar length.
struct StatisticsView: View {
    @Bindable var store: InventoryStore

    private var statistics: InventoryStatistics { store.statistics }

    var body: some View {
        Group {
            if store.snapshot.boards.isEmpty {
                ContentUnavailableView(
                    "Noch keine Keyboards",
                    systemImage: "chart.bar",
                    description: Text("Sobald Keyboards erfasst sind, erscheinen hier die Kennzahlen.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        tiles
                        Text("Wert und Auswertungen zählen vorhandene und bestellte Keyboards. Verkaufte und Wunschliste erscheinen nur beim Status.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)],
                            alignment: .leading,
                            spacing: 16
                        ) {
                            breakdown("Status", statistics.byStatus)
                            breakdown("Hersteller", statistics.byManufacturer)
                            breakdown("Format", statistics.byFormat)
                            breakdown("Farbe", statistics.byColor)
                            breakdown("Gewicht-Material", statistics.byWeightMaterial)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityIdentifier("statistics")
    }

    private var tiles: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180), spacing: 16)],
            alignment: .leading,
            spacing: 16
        ) {
            tile(
                "Sammlungswert",
                BoardValueFormat.displayPrice(statistics.collectionValue),
                detail: statistics.unpricedBoardCount > 0
                    ? L10n.text("%lld ohne Preis", arguments: statistics.unpricedBoardCount)
                    : nil
            )
            tile("Keyboards in der Sammlung", statistics.collectionBoardCount.formatted())
            tile(
                "Durchschnittspreis",
                statistics.averagePrice.map { BoardValueFormat.displayPrice($0) } ?? "–"
            )
        }
    }

    private func tile(_ title: LocalizedStringKey, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func breakdown(_ title: LocalizedStringKey, _ buckets: [InventoryStatistics.Bucket]) -> some View {
        let maximum = max(buckets.map(\.count).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            if buckets.isEmpty {
                Text("Keine Daten")
                    .foregroundStyle(.secondary)
            }
            ForEach(buckets) { bucket in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(bucket.label)
                            .lineLimit(1)
                        Spacer()
                        Text(bucket.count, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor)
                            .frame(
                                width: max(6, geometry.size.width * Double(bucket.count) / Double(maximum)),
                                height: 6
                            )
                    }
                    .frame(height: 6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(bucket.label): \(bucket.count)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }
}
