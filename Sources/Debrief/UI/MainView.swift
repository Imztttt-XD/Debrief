import AppKit
import SwiftUI

/// Sidebar selection and other UI state that must survive view rebuilds (the tree is rebuilt
/// on language change). A class rather than @State: @State needs Xcode's macro plugin.
@MainActor
final class NavigationModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case applications, schedule, mock, recording, review, bank, settings
        var id: String { rawValue }
        var title: String { L10n.tr("nav.\(rawValue)") }
        var icon: String {
            switch self {
            case .applications: "briefcase"
            case .schedule: "calendar"
            case .mock: "bubble.left.and.text.bubble.right"
            case .bank: "books.vertical"
            case .recording: "waveform"
            case .review: "text.bubble"
            case .settings: "gearshape"
            }
        }
    }

    @Published var section: Section? = .applications
    @Published var selectedApplicationID: UUID?
    @Published var applicationSearch = ""
    /// Set by "安排面试" on an application; the schedule page opens the editor for it.
    @Published var scheduleForApplication: UUID?
    @Published var selectedRecordingID: UUID?
    @Published var selectedMockID: UUID?
    @Published var selectedBankID: UUID?
    let mockUI = MockUIState()
    let bankUI = BankUIState()
    let schedule = ScheduleState()
}

struct MainView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var store: AppStore
    @ObservedObject var nav: NavigationModel
    @ObservedObject var reminders: ReminderScheduler
    @ObservedObject var engine: ReviewEngine
    @ObservedObject var mockEngine: MockEngine
    @ObservedObject var practice: PracticeEngine
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.default.rawValue
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            // Selection is drawn by the app (periwinkle wash, accent label) rather than by the
            // system, whose highlight uses the user's system accent colour (usually blue).
            List {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                    Text(L10n.tr("app.name")).font(.headline)
                }
                .padding(.vertical, 6)
                .selectionDisabled()
                ForEach(NavigationModel.Section.allCases) { section in
                    let selected = (nav.section ?? .applications) == section
                    HStack {
                        // Icon styled on its own: the sidebar list tints Label icons itself.
                        Label {
                            Text(section.title)
                                .foregroundStyle(selected ? Theme.selectedText : Color.primary)
                                .fontWeight(selected ? .semibold : .regular)
                        } icon: {
                            Image(systemName: section.icon)
                                .foregroundStyle(selected ? Theme.selectedText : Color.secondary)
                        }
                        if section == .recording && recorder.isRecording {
                            Spacer()
                            Circle().fill(Theme.record).frame(width: 8, height: 8)
                                .accessibilityLabel(L10n.tr("a11y.recording"))
                        }
                    }
                    .badge(section == .bank ? store.bank.due(at: Date()).count : 0)
                    .padding(.vertical, 2)
                    .selectableRow(selected) { nav.section = section }
                }
            }
            .background(Theme.sidebarBackground)
            .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if let error = store.saveError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Theme.dangerFill)
                }
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.windowBackground)
            .navigationTitle((nav.section ?? .applications).title)
        }
        .tint(Theme.control)
        .buttonStyle(.soft)
        // Dark mode: lists and forms drop their grey system backgrounds so the violet-tinted
        // window background (Theme.windowBackground) shows through. Light mode is unchanged.
        .scrollContentBackground(colorScheme == .dark ? .hidden : .automatic)
        .containerBackground(Theme.windowBackground, for: .window)
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { MainWindow.register(openWindow) }
        // Rebuild the whole tree when the language changes so every L10n.tr call runs again.
        .id(languageRaw)
        .environment(\.locale, L10n.locale)
    }

    @ViewBuilder private var detail: some View {
        switch nav.section ?? .applications {
        case .applications: ApplicationsView(store: store, nav: nav)
        case .schedule: ScheduleView(store: store, nav: nav, reminders: reminders, recorder: recorder, state: nav.schedule)
        case .recording: RecordingView(recorder: recorder, store: store, nav: nav, engine: engine)
        case .review: ReviewView(store: store, engine: engine, nav: nav, recordingsFolder: recorder.outputDirectory)
        case .mock: MockInterviewView(store: store, engine: mockEngine, nav: nav, ui: nav.mockUI)
        case .bank: QuestionBankView(store: store, nav: nav, ui: nav.bankUI, practice: practice)
        case .settings: SettingsView(store: store)
        }
    }
}
