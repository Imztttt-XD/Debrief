import AppKit
import SwiftUI

@MainActor
final class BankUIState: ObservableObject {
    @Published var search = ""
    /// "all" or a ReviewQuestion category.
    @Published var category = "all"
    /// "all" or a BankQuestion.Mastery raw value.
    @Published var mastery = "all"
}

/// 题库: every question asked in real and mock interviews, merged and counted.
struct QuestionBankView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var nav: NavigationModel
    @ObservedObject var ui: BankUIState
    @StateObject private var feedback = ExportFeedback()

    private var visible: [BankQuestion] {
        let q = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.bank.items
            .filter { ui.category == "all" || $0.category == ui.category }
            .filter { ui.mastery == "all" || $0.mastery.rawValue == ui.mastery }
            .filter { q.isEmpty || $0.question.lowercased().contains(q) || $0.company.lowercased().contains(q)
                || ($0.resumeItem ?? "").lowercased().contains(q) }
            .sorted { ($0.timesAsked, $0.lastAskedAt) > ($1.timesAsked, $1.lastAskedAt) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack {
                        TextField(L10n.tr("bank.search"), text: $ui.search).textFieldStyle(.roundedBorder)
                        Button { addManual() } label: { Image(systemName: "plus") }
                            .help(L10n.tr("bank.add")).accessibilityLabel(L10n.tr("bank.add"))
                    }
                    HStack {
                        Picker(L10n.tr("bank.category"), selection: $ui.category) {
                            Text(L10n.tr("bank.allCategories")).tag("all")
                            ForEach(ReviewQuestion.categories, id: \.self) { Text(L10n.tr("review.category.\($0)")).tag($0) }
                        }
                        .labelsHidden()
                        Picker(L10n.tr("bank.masteryLabel"), selection: $ui.mastery) {
                            Text(L10n.tr("bank.allMastery")).tag("all")
                            ForEach(BankQuestion.Mastery.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden()
                    }
                    HStack {
                        Text(L10n.tr("bank.count", [String(visible.count)])).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let m = feedback.message { Text(m).font(.caption).foregroundStyle(.green) }
                        Menu(L10n.tr("export.menu")) {
                            Button(L10n.tr("bank.export.copy", [String(visible.count)])) {
                                ReviewExporter.copy(exportText)
                                feedback.show(L10n.tr("export.copied"))
                            }
                            Button(L10n.tr("mock.export.save")) {
                                do {
                                    if let url = try ReviewExporter.save(exportText, suggestedName: ReviewExporter.fileName(title: L10n.tr("nav.bank"))) {
                                        feedback.show(L10n.tr("export.saved", [url.lastPathComponent]))
                                    }
                                } catch { feedback.show(error.localizedDescription) }
                            }
                        }
                        .fixedSize()
                        .controlSize(.small)
                        .disabled(visible.isEmpty)
                    }
                }
                .padding(10)
                Divider()
                List {
                    ForEach(visible) { q in
                        BankRow(item: q).selectableRow(nav.selectedBankID == q.id) { nav.selectedBankID = q.id }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if store.bank.items.isEmpty {
                        Text(L10n.tr("bank.empty")).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 330, maxWidth: 420)

            Group {
                if let id = nav.selectedBankID, let binding = binding(for: id) {
                    BankEditor(item: binding, onDelete: { delete(id) }).id(id)
                } else {
                    Text(L10n.tr("bank.select")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if !store.bank.items.contains(where: { $0.id == nav.selectedBankID }) { nav.selectedBankID = visible.first?.id }
        }
    }

    /// Filtered questions in the same format as the other exports.
    private var exportText: String {
        let questions = visible.map {
            ReviewQuestion(question: $0.question, category: $0.category, resumeItem: $0.resumeItem, start: nil, answer: "",
                           answerStart: nil, followUps: $0.followUps.map { .init(question: $0, answer: "", start: nil) }, critique: nil)
        }
        return ReviewExporter.markdown(title: L10n.tr("nav.bank"), questions: questions)
    }

    private func binding(for id: UUID) -> Binding<BankQuestion>? {
        guard store.bank.items.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { store.bank.items.first { $0.id == id } ?? BankQuestion(question: "", category: "other", source: .manual) },
                       set: { new in if let i = store.bank.items.firstIndex(where: { $0.id == id }) { store.bank.items[i] = new } })
    }

    private func addManual() {
        let item = BankQuestion(question: "", category: "project", source: .manual)
        store.bank.items.append(item)
        ui.search = ""; ui.category = "all"; ui.mastery = "all"
        nav.selectedBankID = item.id
    }

    private func delete(_ id: UUID) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("bank.delete.confirm")
        alert.addButton(withTitle: L10n.tr("action.delete"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.bank.items.removeAll { $0.id == id }
        nav.selectedBankID = visible.first?.id
    }
}

private struct BankRow: View {
    let item: BankQuestion

    private var masteryColor: Color {
        switch item.mastery {
        case .new: .secondary
        case .review: Color(hex: 0xF08A24)
        case .mastered: Color(hex: 0x23A26D)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.question.isEmpty ? L10n.tr("bank.untitled") : item.question).lineLimit(2).font(.callout.weight(.medium))
            HStack(spacing: 6) {
                Pill(text: item.categoryTitle, color: Theme.accent)
                Pill(text: item.mastery.title, color: masteryColor)
                if item.timesAsked > 1 { Pill(text: "×\(item.timesAsked)", color: Theme.pink) }
                if !item.company.isEmpty { Text(item.company).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct BankEditor: View {
    @Binding var item: BankQuestion
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section {
                TextField(L10n.tr("bank.question"), text: $item.question, axis: .vertical).lineLimit(1...5)
                Picker(L10n.tr("bank.category"), selection: $item.category) {
                    ForEach(ReviewQuestion.categories, id: \.self) { Text(L10n.tr("review.category.\($0)")).tag($0) }
                }
                TextField(L10n.tr("bank.resumeItem"), text: Binding(get: { item.resumeItem ?? "" },
                                                                   set: { item.resumeItem = $0.isEmpty ? nil : $0 }))
                Picker(L10n.tr("bank.masteryLabel"), selection: $item.mastery) {
                    ForEach(BankQuestion.Mastery.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                ForEach(Array(item.followUps.enumerated()), id: \.offset) { i, _ in
                    HStack {
                        TextField("", text: Binding(get: { item.followUps.indices.contains(i) ? item.followUps[i] : "" },
                                                    set: { if item.followUps.indices.contains(i) { item.followUps[i] = $0 } }))
                        Button { item.followUps.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel(L10n.tr("action.delete"))
                    }
                }
                Button(L10n.tr("bank.addFollowUp")) { item.followUps.append("") }
            } header: { Text(L10n.tr("bank.followUps")) }

            Section {
                TextEditor(text: $item.myAnswer).frame(minHeight: 90).accessibilityLabel(L10n.tr("review.myAnswer"))
            } header: { Text(L10n.tr("review.myAnswer")) }

            Section {
                TextEditor(text: $item.betterAnswer).frame(minHeight: 110).accessibilityLabel(L10n.tr("review.betterAnswer"))
            } header: { Text(L10n.tr("review.betterAnswer")) }

            Section {
                TextEditor(text: $item.notes).frame(minHeight: 70).accessibilityLabel(L10n.tr("field.notes"))
            } header: { Text(L10n.tr("field.notes")) }

            Section {
                LabeledContent(L10n.tr("bank.meta.source"), value: item.source.title)
                LabeledContent(L10n.tr("bank.meta.times"), value: String(item.timesAsked))
                LabeledContent(L10n.tr("bank.meta.last"), value: item.lastAskedAt.formatted(date: .abbreviated, time: .omitted))
                if !item.company.isEmpty { LabeledContent(L10n.tr("field.company"), value: item.company) }
                if let s = item.lastScore { LabeledContent(L10n.tr("bank.meta.score"), value: String(format: "%.1f / 5", s)) }
                HStack {
                    Spacer()
                    Button(L10n.tr("bank.delete"), role: .destructive, action: onDelete)
                }
            }
        }
        .formStyle(.grouped)
    }
}
