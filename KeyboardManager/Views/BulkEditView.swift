import SwiftUI

/// Sets chosen fields on several entries at once. Only ticked fields are
/// changed; a ticked empty field clears the value on all entries.
struct BulkEditView: View {
    @Bindable var store: InventoryStore
    var kind: InventoryItemKind
    var ids: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Set<BulkEditField> = []
    @State private var values: [BulkEditField: String] = [:]
    @State private var isApplying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(ids.count) \(kind.displayName) gemeinsam bearbeiten")
                    .font(.title2.weight(.semibold))
                Text("Nur angehakte Felder werden geändert. Ein angehaktes leeres Feld wird bei allen Einträgen geleert.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            Form {
                ForEach(BulkEditField.fields(for: kind)) { field in
                    row(for: field)
                }
            }
            .formStyle(.grouped)

            if case let .failed(message) = store.editorSaveState, !isBusy {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Text(names)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Abbrechen", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("\(ids.count) Einträge ändern") {
                    apply()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(enabled.isEmpty || isApplying)
            }
            .padding(16)
        }
        .onAppear {
            if case .failed = store.editorSaveState { store.clearEditorStatus() }
        }
        .frame(width: 560, height: 620)
    }

    @ViewBuilder
    private var isBusy: Bool { isApplying }

    private func row(for field: BulkEditField) -> some View {
        HStack(spacing: 12) {
            Toggle(isOn: enabledBinding(field)) {
                Text(field.title)
                    .frame(width: 130, alignment: .leading)
            }
            .toggleStyle(.checkbox)

            Group {
                if field == .boardStatus {
                    Picker(field.title, selection: valueBinding(field, default: BoardStatus.owned.rawValue)) {
                        ForEach(BoardStatus.allCases) { status in
                            Text(status.title).tag(status.rawValue)
                        }
                    }
                    .labelsHidden()
                } else {
                    HStack {
                        TextField(field.title, text: valueBinding(field, default: ""))
                            .labelsHidden()
                        let suggestions = suggestions(for: field)
                        if !suggestions.isEmpty {
                            Menu {
                                ForEach(suggestions, id: \.self) { value in
                                    Button(value) {
                                        values[field] = value
                                        enabled.insert(field)
                                    }
                                }
                            } label: {
                                Label("Vorhandene Werte", systemImage: "chevron.down")
                                    .labelStyle(.iconOnly)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }
            }
            .disabled(!enabled.contains(field))
        }
    }

    private func enabledBinding(_ field: BulkEditField) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(field) },
            set: { isOn in
                if isOn { enabled.insert(field) } else { enabled.remove(field) }
            }
        )
    }

    private func valueBinding(_ field: BulkEditField, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { values[field] ?? defaultValue },
            set: { values[field] = $0 }
        )
    }

    private func suggestions(for field: BulkEditField) -> [String] {
        switch field {
        case .weightMaterial: store.weightMaterialSuggestions()
        case .mounting: store.mountingSuggestions()
        case .caseMaterial: store.caseMaterialSuggestions()
        case .layout: store.layoutSuggestions()
        default: field.libraryKey(for: kind).map(store.libraryValues(for:)) ?? []
        }
    }

    private var names: String {
        InventoryQuery.items(in: store.snapshot, kind: kind)
            .filter { ids.contains($0.id) }
            .map(\.name)
            .joined(separator: ", ")
    }

    private func apply() {
        var changes: [BulkEditField: String] = [:]
        for field in enabled {
            changes[field] = values[field] ?? (field == .boardStatus ? BoardStatus.owned.rawValue : "")
        }
        isApplying = true
        Task {
            let succeeded = await store.applyBulkEdit(changes, kind: kind, ids: ids)
            isApplying = false
            if succeeded {
                dismiss()
            }
        }
    }
}
