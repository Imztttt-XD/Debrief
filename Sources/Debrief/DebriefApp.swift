import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder = Recorder()
    let store = AppStore()
    let nav = NavigationModel()
    let reminders = ReminderScheduler()
    lazy var engine = ReviewEngine(store: store)
    lazy var mockEngine = MockEngine(store: store)
    lazy var practice = PracticeEngine(store: store)
    private var floatingButton: FloatingButtonController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if DevSnapshots.outputDir != nil {
            // Render-only mode: no floating panel, reminders or crash recovery.
            Task { await DevSnapshots.run(self) }
            return
        }
        AppAppearance.current.apply()
        recorder.onNeedsAttention = { [weak self] in self?.showMainWindow() }

        // Recording ↔ interview linking.
        recorder.interviewMatcher = { [weak self] date in self?.store.interviewCandidates(at: date).first?.id }
        recorder.interviewLabel = { [weak self] id in
            guard let self, let iv = self.store.interview(id) else { return nil }
            return self.store.label(for: iv)
        }
        recorder.onRecordingSaved = { [weak self] record in self?.store.add(record) }
        store.pruneMissingRecordings()
        store.ingestPendingReviews()
        Task { await recorder.recoverInterruptedRecordings() }

        // Reminders: rebuilt whenever interviews change, and once at launch.
        store.onInterviewsChanged = { [weak self] in
            guard let self else { return }
            self.reminders.scheduleResync(self.store)
        }
        reminders.onStartRecording = { [weak self] id in
            guard let self else { return }
            if self.recorder.isRecording {
                self.recorder.linkedInterviewID = id
            } else {
                self.recorder.requestStart(linkTo: id)
            }
        }
        reminders.onOpenInterview = { [weak self] id in
            guard let self, let iv = self.store.interview(id) else { return }
            self.nav.section = .schedule
            self.nav.schedule.selectedDay = Calendar.current.startOfDay(for: iv.start)
            self.nav.schedule.displayedMonth = Calendar.current.dateInterval(of: .month, for: iv.start)?.start ?? iv.start
            self.showMainWindow()
        }
        // Reminder texts are in the UI language, so reschedule when it changes.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, AppLanguage.current != self.lastLanguage else { return }
                self.lastLanguage = AppLanguage.current
                self.reminders.scheduleResync(self.store)
            }
        }
        reminders.scheduleResync(store)

        floatingButton = FloatingButtonController(recorder: recorder) { [weak self] in self?.showMainWindow() }
    }

    private var lastLanguage = AppLanguage.current

    func showMainWindow() {
        if let open = MainWindow.open {
            open()
        } else {
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    /// Quitting mid-recording still produces a finished .m4a.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store.flush()
        UsageLedger.shared.save()
        guard recorder.isRecording else { return .terminateNow }
        Task {
            await recorder.stop(reason: .quitting)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Lets AppKit code (floating button, error handling) open the SwiftUI main window.
/// Any SwiftUI view that has the `openWindow` environment value registers it on appear.
@MainActor
enum MainWindow {
    static let id = "main"
    static var open: (() -> Void)?

    static func register(_ action: OpenWindowAction) {
        open = { action(id: id) }
    }
}

@main
struct DebriefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.default.rawValue

    init() {
        // Runs before AppKit loads its localized resources, so system UI matches from the first launch.
        AppLanguage.current.applyToSystemUI()
    }

    var body: some Scene {
        Window(Text(L10n.tr("app.name")), id: "main") {
            MainView(recorder: appDelegate.recorder, store: appDelegate.store, nav: appDelegate.nav,
                     reminders: appDelegate.reminders, engine: appDelegate.engine, mockEngine: appDelegate.mockEngine,
                     practice: appDelegate.practice)
        }
        .defaultSize(width: 1100, height: 720)

        MenuBarExtra {
            MenuContent(recorder: appDelegate.recorder, store: appDelegate.store)
                .id(languageRaw)
        } label: {
            MenuBarIcon(recording: appDelegate.recorder.isRecording)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(FloatingButtonController.visibleKey) private var floatingVisible = true

    var body: some View {
        if let next = store.upcomingInterviews.first {
            Text(L10n.tr("menu.nextInterview", [next.start.formatted(.dateTime.month().day().hour().minute()), store.label(for: next)]))
            Divider()
        }
        Button(L10n.tr(recorder.isRecording ? "action.stop" : "action.start")) { recorder.toggle() }
            .disabled(recorder.isBusy)
        Button(L10n.tr(floatingVisible ? "float.hide" : "float.show")) { floatingVisible.toggle() }
        Button(L10n.tr("menu.showWindow")) {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button(L10n.tr("menu.openFolder")) { recorder.openOutputFolder() }
        Divider()
        Button(L10n.tr("menu.quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
            .onAppear { MainWindow.register(openWindow) }
    }
}

/// Template icon when idle, red non-template icon while recording.
/// SwiftUI tints get dropped in the menu bar, so build the NSImage directly.
private struct MenuBarIcon: View {
    let recording: Bool

    var body: some View {
        Image(nsImage: Self.image(recording: recording))
    }

    static func image(recording: Bool) -> NSImage {
        let name = recording ? "record.circle.fill" : "waveform"
        let label = L10n.tr(recording ? "a11y.recording" : "app.name")
        let base = NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        guard recording,
              let red = base.withSymbolConfiguration(.init(paletteColors: [.systemRed])) else {
            base.isTemplate = true
            return base
        }
        red.isTemplate = false
        return red
    }
}
