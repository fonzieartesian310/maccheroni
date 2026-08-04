import SwiftUI

private enum GlossaryCategory: String, CaseIterable, Identifiable {
    case people
    case terms
    case places

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .people: appLocalized("People")
        case .terms: appLocalized("Terms")
        case .places: appLocalized("Places")
        }
    }
}

private struct GlossaryDraftEntry: Identifiable, Equatable {
    let id: UUID
    var term: String
    var category: GlossaryCategory
}

struct GlossaryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager
    let model: MaccheroniAppModel
    let profileID: AppProfileID
    @State private var entries: [GlossaryDraftEntry]
    @State private var newTerm = ""
    @State private var newCategory = GlossaryCategory.terms
    @State private var errorMessage: String?
    @FocusState private var focusedOnNewTerm: Bool

    init(model: MaccheroniAppModel, profileID: AppProfileID) {
        self.model = model
        self.profileID = profileID
        _entries = State(initialValue: Self.parse(model.loadGlossary(for: profileID)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(appLocalized("Glossary"))
                        .font(.title2)
                    Text(profileID.title)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(appLocalized("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(appLocalized("Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            List {
                ForEach(entries) { entry in
                    GlossaryEntryRow(entry: entry) {
                        remove(entry)
                    }
                }
                .onDelete(perform: remove)
            }
            .frame(minHeight: 260)

            Divider()

            HStack(spacing: 10) {
                TextField(appLocalized("Add a name, term, or place"), text: $newTerm)
                    .focused($focusedOnNewTerm)
                    .onSubmit(add)
                Picker(appLocalized("Category"), selection: $newCategory) {
                    ForEach(GlossaryCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Button(appLocalized("Add"), action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 420)
        .task { focusedOnNewTerm = true }
        .alert(appLocalized("Glossary Could Not Be Saved"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(appLocalized("OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty,
              !entries.contains(where: { $0.term.localizedCaseInsensitiveCompare(term) == .orderedSame })
        else { return }
        let entry = GlossaryDraftEntry(id: UUID(), term: term, category: newCategory)
        entries.append(entry)
        undoManager?.registerUndo(withTarget: UndoTarget { entries.removeAll { $0.id == entry.id } }) {
            $0.action()
        }
        newTerm = ""
        focusedOnNewTerm = true
    }

    private func remove(_ offsets: IndexSet) {
        let removed = offsets.map { entries[$0] }
        entries.remove(atOffsets: offsets)
        undoManager?.registerUndo(withTarget: UndoTarget { entries.append(contentsOf: removed) }) {
            $0.action()
        }
    }

    private func remove(_ entry: GlossaryDraftEntry) {
        guard let index = entries.firstIndex(of: entry) else { return }
        remove(IndexSet(integer: index))
    }

    private func save() {
        do {
            try model.saveGlossary(Self.serialize(entries), for: profileID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func parse(_ text: String) -> [GlossaryDraftEntry] {
        var category = GlossaryCategory.terms
        var entries: [GlossaryDraftEntry] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("# category: "),
               let parsed = GlossaryCategory(rawValue: String(line.dropFirst(12))) {
                category = parsed
            } else if !line.isEmpty, !line.hasPrefix("#") {
                entries.append(GlossaryDraftEntry(id: UUID(), term: line, category: category))
            }
        }
        return entries
    }

    private static func serialize(_ entries: [GlossaryDraftEntry]) -> String {
        var lines: [String] = []
        for category in GlossaryCategory.allCases {
            let terms = entries.filter { $0.category == category }.map(\.term)
            guard !terms.isEmpty else { continue }
            lines.append("# category: \(category.rawValue)")
            lines.append(contentsOf: terms)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }
}

private struct GlossaryEntryRow: View {
    let entry: GlossaryDraftEntry
    let remove: () -> Void

    var body: some View {
        HStack {
            Text(entry.term)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.category.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(appLocalized("Remove"), systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .accessibilityLabel(appLocalized("Remove \(entry.term)"))
        }
        .contextMenu {
            Button(appLocalized("Remove"), role: .destructive, action: remove)
        }
    }
}

private final class UndoTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}
