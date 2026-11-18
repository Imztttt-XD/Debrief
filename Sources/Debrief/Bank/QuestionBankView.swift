import AppKit
import SwiftUI

@MainActor
final class BankUIState: ObservableObject {
    @Published var search = ""
    /// "all" or a ReviewQuestion category.
    @Published var category = "all"
    /// "all", "due" (今天待复习) or a BankQuestion.Mastery raw value.
    @Published var mastery = "all"
}

/// 题库: every question asked in real and mock interviews, merged and counted.
struct QuestionBankView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var nav: NavigationModel
    @ObservedObject var ui: BankUIState
    @ObservedObject var practice: PracticeEngine
    @StateObject private var feedback = ExportFeedback()

    private var visible: [BankQuestion] {
        let q = ui.search.trimmingCharacters(in: .whitespaces).lowercased()
        let now = Date()
        return store.bank.items
            .filter { ui.category == "all" || $0.category == ui.category }
            .filter { ui.mastery == "all" || (ui.mastery == "due" ? $0.isDue(at: now) : $0.mastery.rawValue == ui.mastery) }
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
                        MenuPicker(title: L10n.tr("bank.category"), selection: $ui.category,
                                   options: [.init(value: "all", title: L10n.tr("bank.allCategories"))]
                                       + ReviewQuestion.categories.map { .init(value: $0, title: L10n.tr("review.category.\($0)")) })
                        MenuPicker(title: L10n.tr("bank.masteryLabel"), selection: $ui.mastery,
                                   options: [.init(value: "all", title: L10n.tr("bank.allMastery")),
                                             .init(value: "due", title: L10n.tr("practice.filterDue"))]
                                       + BankQuestion.Mastery.allCases.map { .init(value: $0.rawValue, title: $0.title) })
                    }
                    HStack {
                        Text(L10n.tr("bank.count", [String(visible.count)])).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if let m = feedback.message { Text(m).font(.caption).foregroundStyle(Theme.success) }
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
                        .menuStyle(.button).buttonStyle(.menuField)
                        .fixedSize()
                        .controlSize(.small)
                        .disabled(visible.isEmpty)
                    }
                }
                .padding(10)
                dueBanner
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
                    BankEditor(item: binding, onPractice: { practice.start([id]) }, onDelete: { delete(id) }).id(id)
                } else {
                    Text(L10n.tr("bank.select")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if !store.bank.items.contains(where: { $0.id == nav.selectedBankID }) { nav.selectedBankID = visible.first?.id }
        }
        .sheet(isPresented: Binding(get: { practice.session != nil }, set: { if !$0 { practice.end() } })) {
            PracticeView(engine: practice, store: store)
        }
    }

    /// "今天待复习 5 道 [开始复习]" above the list.
    @ViewBuilder private var dueBanner: some View {
        let due = store.bank.due(at: Date())
        if !due.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.accent)
                Text(L10n.tr("practice.dueBanner", [String(due.count)])).font(.callout.weight(.medium))
                Spacer()
                Button(L10n.tr("practice.start")) { practice.start(due.map(\.id)) }
                    .buttonStyle(.brand).controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.1)))
            .padding(.horizontal, 10).padding(.bottom, 10)
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
        case .review: Theme.warning
        case .mastered: Theme.success
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.question.isEmpty ? L10n.tr("bank.untitled") : item.question).lineLimit(2).font(.callout.weight(.medium))
            HStack(spacing: 6) {
                Pill(text: item.categoryTitle, color: Theme.accent)
                Pill(text: item.mastery.title, color: masteryColor)
                if item.timesAsked > 1 { Pill(text: "×\(item.timesAsked)", color: Theme.neutral) }
                if item.isDue(at: Date()) {
                    Image(systemName: "calendar.badge.clock").font(.caption).foregroundStyle(Theme.accent)
                        .help(L10n.tr("practice.filterDue")).accessibilityLabel(L10n.tr("practice.filterDue"))
                }
                if !item.company.isEmpty { Text(item.company).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct BankEditor: View {
    @Binding var item: BankQuestion
    let onPractice: () -> Void
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
                LabeledContent(L10n.tr("bank.masteryLabel")) {
                    SegmentedControl(selection: Binding(get: { item.mastery }, set: { item.setMastery($0) }),
                                     options: BankQuestion.Mastery.allCases.map { .init(value: $0, title: $0.title) })
                        .frame(maxWidth: 320)
                }
            }

            Section {
                HStack {
                    if let due = item.dueAt {
                        Text(L10n.tr("practice.nextReview", [PracticeText.dueText(due)])).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.tr("practice.notScheduled")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.tr("practice.one"), action: onPractice)
                        .disabled(item.question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(Array(item.history.reversed().enumerated()), id: \.offset) { _, a in
                    HStack {
                        Text(a.date.formatted(date: .abbreviated, time: .omitted))
                        Text(a.kind.title).foregroundStyle(.secondary)
                        Spacer()
                        if a.corrections > 0 {
                            Text(L10n.tr("practice.corrections", [String(a.corrections)])).font(.caption).foregroundStyle(Theme.danger)
                        }
                        Text(String(format: "%.1f", a.score)).monospacedDigit()
                    }
                    .font(.callout)
                }
            } header: { Text(L10n.tr("practice.section")) }

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
                NoteEditor(text: $item.myAnswer, placeholder: L10n.tr("bank.myAnswer.placeholder"),
                           minHeight: 120, label: L10n.tr("review.myAnswer"))
            } header: { Text(L10n.tr("review.myAnswer")) }

            Section {
                NoteEditor(text: $item.betterAnswer, placeholder: L10n.tr("bank.betterAnswer.placeholder"),
                           minHeight: 140, label: L10n.tr("review.betterAnswer"))
            } header: { Text(L10n.tr("review.betterAnswer")) }

            Section {
                NoteEditor(text: $item.notes, placeholder: L10n.tr("bank.notes.placeholder"),
                           minHeight: 100, label: L10n.tr("field.notes"))
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
