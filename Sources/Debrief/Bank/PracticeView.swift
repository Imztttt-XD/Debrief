import SwiftUI

/// Sheet for a practice round: question → my answer → critique → next.
struct PracticeView: View {
    @ObservedObject var engine: PracticeEngine
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = engine.session {
                if s.isDone {
                    done(s)
                } else if let item = engine.current {
                    header(s, item)
                    Text(item.question).font(.title3.weight(.semibold)).textSelection(.enabled)
                    content(s, item)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 460, idealHeight: 620)
        .buttonStyle(.soft)
        .background(Theme.windowBackground)
        .presentationBackground(Theme.windowBackground)
    }

    private func header(_ s: PracticeEngine.Session, _ item: BankQuestion) -> some View {
        HStack(spacing: 8) {
            Text(L10n.tr("practice.progress", [String(s.index + 1), String(s.queue.count)]))
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Pill(text: item.categoryTitle, color: Theme.accent)
            if !item.company.isEmpty { Text(item.company).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Button(L10n.tr("practice.end")) { engine.end() }.keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private func content(_ s: PracticeEngine.Session, _ item: BankQuestion) -> some View {
        switch s.phase {
        case .answering, .failed:
            NoteEditor(text: answer, placeholder: L10n.tr("practice.placeholder"), minHeight: 200,
                       label: L10n.tr("review.myAnswer"), boxed: true)
            if case .failed(let message) = s.phase {
                Label(message, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
            HStack {
                Button(L10n.tr("practice.skip")) { engine.next() }
                Spacer()
                Text(L10n.tr("practice.submitHint")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("practice.submit")) { engine.submit() }
                    .buttonStyle(.brand)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(s.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        case .grading:
            VStack(spacing: 10) {
                ProgressView()
                Text(L10n.tr("practice.grading")).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .graded:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    DisclosureGroup(L10n.tr("review.myAnswer")) {
                        Text(s.answer).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                    if let critique = critiqueBinding {
                        CritiqueView(critique: critique)
                    }
                    if let due = item.dueAt {
                        Label(L10n.tr("practice.nextReview", [PracticeText.dueText(due)]), systemImage: "calendar.badge.clock")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(s.index + 1 < s.queue.count ? L10n.tr("practice.next") : L10n.tr("practice.finish")) { engine.next() }
                    .buttonStyle(.brand)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func done(_ s: PracticeEngine.Session) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(Theme.success)
            Text(L10n.tr("practice.done.title")).font(.title3.bold())
            Text(L10n.tr("practice.done.detail", [String(s.finishedCount),
                                                   String(store.bank.due(at: Date()).count)]))
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(L10n.tr("practice.close")) { engine.end() }
                .buttonStyle(.brand).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var answer: Binding<String> {
        Binding(get: { engine.session?.answer ?? "" }, set: { engine.session?.answer = $0 })
    }

    /// Lets "我觉得我是对的" toggles in the critique work while the sheet is open.
    private var critiqueBinding: Binding<Critique>? {
        guard let c = engine.session?.critique else { return nil }
        return Binding(get: { engine.session?.critique ?? c }, set: { engine.session?.critique = $0 })
    }
}

enum PracticeText {
    /// "今天" / "明天" / "11月21日（3 天后）"
    static func dueText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days <= 0 { return L10n.tr("practice.due.today") }
        if days == 1 { return L10n.tr("practice.due.tomorrow") }
        let formatted = date.formatted(.dateTime.month().day().locale(L10n.locale))
        return L10n.tr("practice.due.inDays", [formatted, String(days)])
    }
}
