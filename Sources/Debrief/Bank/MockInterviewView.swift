import AppKit
import SwiftUI

/// UI state for the mock interview page.
@MainActor
final class MockUIState: ObservableObject {
    /// Answer being typed, per session.
    @Published var drafts: [UUID: String] = [:]
    /// New-session form.
    @Published var newApplicationID: UUID?
    @Published var newFocus: MockSession.Focus = .mixed
    @Published var newCount = 5
    @Published var showingSetup = false
}

/// 模拟面试: sessions on the left; on the right either the setup form, the chat, or the
/// critique once it's finished.
struct MockInterviewView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var engine: MockEngine
    @ObservedObject var nav: NavigationModel
    @ObservedObject var ui: MockUIState

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Button {
                    ui.showingSetup = true
                    nav.selectedMockID = nil
                } label: {
                    Label(L10n.tr("mock.new"), systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand)
                .controlSize(.large)
                .padding(10)
                Divider()
                List {
                    ForEach(store.sortedMocks) { s in
                        MockRow(session: s, store: store, busy: engine.isBusy(s.id))
                            .selectableRow(nav.selectedMockID == s.id) { nav.selectedMockID = s.id }
                    }
                }
                .listStyle(.inset)
                .overlay {
                    if store.mocks.isEmpty {
                        Text(L10n.tr("mock.empty")).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
            }
            .frame(minWidth: 210, idealWidth: 250, maxWidth: 320)

            Group {
                if let id = nav.selectedMockID, let session = store.mocks[id] {
                    MockSessionView(session: session, store: store, engine: engine, ui: ui).id(id)
                } else {
                    MockSetupView(store: store, engine: engine, nav: nav, ui: ui)
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: nav.selectedMockID) { _, id in if id != nil { ui.showingSetup = false } }
        .onAppear {
            if nav.selectedMockID.flatMap({ store.mocks[$0] }) == nil && !ui.showingSetup {
                nav.selectedMockID = store.sortedMocks.first?.id
            }
        }
    }
}

private struct MockRow: View {
    let session: MockSession
    @ObservedObject var store: AppStore
    let busy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.title(for: session)).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Pill(text: session.focus.title, color: Theme.accent)
                Text(L10n.tr("mock.progress", [String(session.mainQuestionsAsked), String(session.questionCount)]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if busy {
                    Label(L10n.tr("mock.thinking"), systemImage: "ellipsis.bubble").foregroundStyle(Theme.accent)
                } else if session.summary != nil {
                    Label(L10n.tr("review.status.done"), systemImage: "checkmark.circle").foregroundStyle(Theme.success)
                } else if session.finished {
                    Label(L10n.tr("mock.status.ended"), systemImage: "flag.checkered").foregroundStyle(.secondary)
                } else {
                    Label(L10n.tr("mock.status.inProgress"), systemImage: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            Text(session.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Setup

private struct MockSetupView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var engine: MockEngine
    @ObservedObject var nav: NavigationModel
    @ObservedObject var ui: MockUIState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("mock.setup.title")).font(.title2.bold())
                        Text(L10n.tr("mock.setup.subtitle")).foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent(L10n.tr("schedule.field.application")) {
                        MenuPicker(title: L10n.tr("schedule.field.application"), selection: $ui.newApplicationID,
                                   options: [.init(value: UUID?.none, title: L10n.tr("mock.setup.noApplication"))]
                                       + store.sortedApplications.map { .init(value: Optional($0.id), title: "\($0.displayCompany) · \($0.displayRole)") })
                    }
                    LabeledContent(L10n.tr("mock.setup.focus")) {
                        MenuPicker(title: L10n.tr("mock.setup.focus"), selection: $ui.newFocus,
                                   options: MockSession.Focus.allCases.map { .init(value: $0, title: $0.title) })
                    }
                    LabeledContent(L10n.tr("mock.setup.count")) {
                        SegmentedControl(selection: $ui.newCount, options: MockSession.questionCountChoices.map {
                            .init(value: $0, title: L10n.tr("mock.setup.countValue", [String($0)]))
                        })
                    }
                }
                .card()

                let seeds = store.seedQuestions(for: ui.newApplicationID, resumeText: store.resumes.first?.text ?? "", limit: 25)
                Label(seeds.isEmpty ? L10n.tr("mock.setup.noSeeds") : L10n.tr("mock.setup.seeds", [String(seeds.count)]),
                      systemImage: "books.vertical")
                    .font(.callout).foregroundStyle(.secondary)
                if store.resumes.isEmpty {
                    Label(L10n.tr("mock.setup.noResume"), systemImage: "doc.badge.plus").font(.callout).foregroundStyle(Theme.warning)
                }

                Button {
                    let id = engine.start(applicationID: ui.newApplicationID, focus: ui.newFocus, questionCount: ui.newCount)
                    nav.selectedMockID = id
                } label: {
                    Label(L10n.tr("mock.setup.start"), systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand)
                .controlSize(.large)
            }
            .padding(28)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Session

private struct MockSessionView: View {
    let session: MockSession
    @ObservedObject var store: AppStore
    @ObservedObject var engine: MockEngine
    @ObservedObject var ui: MockUIState
    @AppStorage("mockTab") private var tab = "chat"
    @StateObject private var feedback = ExportFeedback()
    @StateObject private var player = AudioPlayerModel()   // unused; QuestionCard expects one

    private var title: String { store.title(for: session) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.summary != nil || !session.questions.isEmpty {
                SegmentedControl(selection: $tab, options: [.init(value: "chat", title: L10n.tr("mock.tab.chat")),
                                                            .init(value: "feedback", title: L10n.tr("mock.tab.feedback"))])
                    .frame(maxWidth: 260).padding(10)
            }
            if tab == "feedback" && (session.summary != nil || !session.questions.isEmpty) {
                feedbackView
            } else {
                chat
                if !session.finished { composer }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.title3.bold()).lineLimit(2)
            HStack(spacing: 8) {
                Pill(text: session.focus.title, color: Theme.accent)
                Text(L10n.tr("mock.progress", [String(session.mainQuestionsAsked), String(session.questionCount)]))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if let a = engine.activity[session.id], a != .thinking {
                    ProgressView().controlSize(.small)
                    Text(activityText(a)).font(.callout).foregroundStyle(.secondary)
                } else if !session.finished {
                    Button(L10n.tr("mock.finish")) { engine.finish(session.id) }
                        .disabled(session.mainQuestionsAsked == 0 || engine.isBusy(session.id))
                } else if session.summary == nil {
                    Button(L10n.tr("mock.critique")) { engine.finish(session.id) }.buttonStyle(.brand)
                }
                exportMenu
                if let message = feedback.message {
                    Label(message, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(Theme.success)
                }
                Spacer()
                Button(role: .destructive) { confirmDelete() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L10n.tr("mock.delete"))
                    .accessibilityLabel(L10n.tr("mock.delete"))
            }
            if let error = session.lastError, !engine.isBusy(session.id) {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger).textSelection(.enabled)
                    if !session.finished && !session.awaitingAnswer {
                        Button(L10n.tr("mock.retry")) { engine.retry(session.id) }
                    }
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityText(_ a: MockEngine.Activity) -> String {
        switch a {
        case .thinking: L10n.tr("mock.thinking")
        case .critiquing(let d, let t): L10n.tr("review.phase.critiquing", [String(d), String(t)])
        case .summarizing: L10n.tr("review.phase.summarizing")
        }
    }

    private var exportMenu: some View {
        let questions = session.asReviewQuestions
        return Menu(L10n.tr("export.menu")) {
            Button(L10n.tr("export.copyAll", [String(questions.count)])) {
                ReviewExporter.copy(ReviewExporter.markdown(title: L10n.tr("mock.exportTitle", [title]), questions: questions))
                feedback.show(L10n.tr("export.copied"))
            }
            Button(L10n.tr("mock.export.save")) {
                let text = ReviewExporter.markdown(title: L10n.tr("mock.exportTitle", [title]), questions: questions)
                do {
                    if let url = try ReviewExporter.save(text, suggestedName: ReviewExporter.fileName(title: L10n.tr("mock.exportTitle", [title]))) {
                        feedback.show(L10n.tr("export.saved", [url.lastPathComponent]))
                    }
                } catch { feedback.show(error.localizedDescription) }
            }
        }
        .menuStyle(.button).buttonStyle(.menuField)
        .fixedSize()
        .disabled(questions.isEmpty)
        .help(L10n.tr("mock.export.help"))
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.messages) { m in
                        Bubble(message: m).id(m.id)
                    }
                    if engine.activity[session.id] == .thinking {
                        HStack(spacing: 8) {
                            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                            ProgressView().controlSize(.small)
                            Text(L10n.tr("mock.thinking")).foregroundStyle(.secondary)
                        }
                        .id("thinking")
                    }
                }
                .padding(18)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: session.messages.count) { _, _ in
                withAnimation { proxy.scrollTo(session.messages.last?.id, anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo(session.messages.last?.id, anchor: .bottom) }
        }
    }

    private var draft: Binding<String> {
        Binding(get: { ui.drafts[session.id] ?? "" }, set: { ui.drafts[session.id] = $0 })
    }

    private var composer: some View {
        VStack(spacing: 6) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField(L10n.tr("mock.answerPlaceholder"), text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...8)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                    .disabled(!session.awaitingAnswer)
                Button {
                    engine.submit(draft.wrappedValue, to: session.id)
                    ui.drafts[session.id] = nil
                } label: {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.brandGradient))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!session.awaitingAnswer || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(L10n.tr("mock.send"))
                .accessibilityLabel(L10n.tr("mock.send"))
            }
            Text(L10n.tr("mock.sendHint")).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18).padding(.bottom, 12)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }

    private var feedbackView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let s = session.summary {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(s.overall).textSelection(.enabled)
                        BulletList(title: L10n.tr("review.strengths"), icon: "hand.thumbsup", color: Theme.success, items: s.strengths)
                        BulletList(title: L10n.tr("review.improvements"), icon: "arrow.up.right", color: Theme.warning, items: s.improvements)
                        BulletList(title: L10n.tr("review.actionItems"), icon: "checklist", color: Theme.accent, items: s.actionItems)
                    }
                    .card(padding: 16)
                }
                ForEach(Array(session.questions.enumerated()), id: \.element.id) { i, q in
                    QuestionCard(index: i + 1, question: .constant(q), player: player)
                }
            }
            .padding(18)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("mock.delete.confirm")
        alert.addButton(withTitle: L10n.tr("action.delete"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        engine.cancel(session.id)
        store.deleteMock(session.id)
    }
}

/// Chat bubble: interviewer on the left with the app's buddy, my answers on the right.
private struct Bubble: View {
    let message: MockMessage

    var body: some View {
        if message.isInterviewer {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    if message.kind == .followUp {
                        Text(L10n.tr("mock.followUpLabel")).font(.caption).foregroundStyle(Theme.accent)
                    }
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                }
                Spacer(minLength: 60)
            }
        } else {
            HStack {
                Spacer(minLength: 60)
                Text(message.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.brandGradient))
            }
        }
    }
}
