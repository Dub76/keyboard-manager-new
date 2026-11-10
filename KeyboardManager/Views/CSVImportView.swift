import SwiftUI

struct CSVImportRequest: Identifiable {
    let id = UUID()
    var kind: InventoryItemKind
    var fileName: String
    var text: String
}

/// Shows what a CSV file would create before anything is written.
struct CSVImportView: View {
    @Bindable var store: InventoryStore
    var request: CSVImportRequest
    @Environment(\.dismiss) private var dismiss
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CSV-Import: \(request.kind.displayName)")
                    .font(.title2.weight(.semibold))
                Text(request.fileName)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            switch preview {
            case let .success(preview):
                content(preview)
            case let .failure(error):
                ContentUnavailableView(
                    "Datei kann nicht importiert werden",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.localizedDescription)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if case let .failed(message) = store.editorSaveState, !isBusy {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Text("Neue Einträge werden angelegt; vorhandene werden nicht verändert. Fotos und Verknüpfungen werden nicht importiert.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Abbrechen", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("\(newCount) Einträge importieren") {
                    importRows()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(newCount == 0 || isImporting)
            }
            .padding(16)
        }
        .onAppear {
            if case .failed = store.editorSaveState { store.clearEditorStatus() }
        }
        .frame(width: 620, height: 560)
    }

    private var isBusy: Bool { isImporting }

    private func content(_ preview: InventoryCSVImportPreview) -> some View {
        List {
            Section {
                LabeledContent("Neue Einträge", value: preview.drafts.count.formatted())
                LabeledContent("Schon vorhanden, übersprungen", value: preview.duplicates.count.formatted())
                LabeledContent("Fehlerhafte Zeilen", value: preview.errors.count.formatted())
                if !preview.ignoredColumns.isEmpty {
                    LabeledContent("Nicht übernommene Spalten") {
                        Text(preview.ignoredColumns.joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            if !preview.drafts.isEmpty {
                Section("Wird angelegt") {
                    ForEach(preview.drafts, id: \.id) { draft in
                        Text(draft.normalizedName)
                    }
                }
            }
            if !preview.errors.isEmpty {
                Section("Fehler (werden nicht importiert)") {
                    ForEach(preview.errors, id: \.self) { issue in
                        issueRow(issue, systemImage: "exclamationmark.triangle.fill", color: .red)
                    }
                }
            }
            if !preview.duplicates.isEmpty {
                Section("Übersprungen") {
                    ForEach(preview.duplicates, id: \.self) { issue in
                        issueRow(issue, systemImage: "equal.circle", color: .secondary)
                    }
                }
            }
        }
    }

    private func issueRow(
        _ issue: InventoryCSVImportPreview.RowIssue,
        systemImage: String,
        color: Color
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Zeile \(issue.row)\(issue.name.isEmpty ? "" : " · \(issue.name)")")
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
        }
    }

    private var preview: Result<InventoryCSVImportPreview, Error> {
        Result { try store.previewCSVImport(request.text, kind: request.kind) }
    }

    private var newCount: Int {
        (try? preview.get().drafts.count) ?? 0
    }

    private func importRows() {
        isImporting = true
        Task {
            let succeeded = await store.importCSV(request.text, kind: request.kind)
            isImporting = false
            if succeeded {
                dismiss()
            }
        }
    }
}
