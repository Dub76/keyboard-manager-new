import Foundation

enum AppRoute: String, CaseIterable, Hashable, Identifiable, Sendable {
    case overview
    case capture
    case gallery
    case statistics
    case migration

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: L10n.text("Übersicht")
        case .capture: L10n.text("Erfassen")
        case .gallery: L10n.text("Galerie")
        case .statistics: L10n.text("Statistik")
        case .migration: L10n.text("V1-Migration")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "list.bullet.rectangle"
        case .capture: "square.and.pencil"
        case .gallery: "square.grid.2x2"
        case .statistics: "chart.bar"
        case .migration: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    static let primary: [AppRoute] = [.overview, .gallery, .capture]
}
