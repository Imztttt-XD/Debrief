import AppKit
import UserNotifications

/// Interview reminders as local notifications. macOS delivers them even when the app isn't
/// running. Each reminder has two buttons: 开始录音 (records, linked to that interview) and
/// 打开会议链接.
///
/// The scheduled set is always rebuilt from the interview list (`resync`) rather than patched,
/// so edits, deletions and language changes can't leave stale reminders behind.
@MainActor
final class ReminderScheduler: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum Permission { case unknown, allowed, denied }

    @Published private(set) var permission: Permission = .unknown

    var onStartRecording: ((UUID) -> Void)?
    var onOpenInterview: ((UUID) -> Void)?

    private let center = UNUserNotificationCenter.current()
    nonisolated private static let idPrefix = "debrief.interview."
    nonisolated private static let category = "debrief.interview"
    nonisolated private static let startAction = "start-recording"
    nonisolated private static let openLinkAction = "open-link"
    nonisolated private static let interviewKey = "interviewID"
    nonisolated private static let linkKey = "meetingLink"
    private var resyncTask: Task<Void, Never>?

    override init() {
        super.init()
        center.delegate = self
    }

    /// Debounced: typing in the interview editor shouldn't reschedule on every keystroke.
    func scheduleResync(_ store: AppStore) {
        resyncTask?.cancel()
        resyncTask = Task { [weak self, weak store] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self, let store else { return }
            await self.resync(store)
        }
    }

    func resync(_ store: AppStore) async {
        registerCategory()
        let now = Date()
        let requests: [UNNotificationRequest] = store.interviews.flatMap { interview in
            interview.reminderMinutes.compactMap { minutes -> UNNotificationRequest? in
                let fireDate = interview.start.addingTimeInterval(-TimeInterval(minutes * 60))
                guard fireDate > now else { return nil }
                return request(for: interview, minutesBefore: minutes, fireDate: fireDate, store: store)
            }
        }

        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard !requests.isEmpty else { await refreshPermission(); return }

        // Ask only once there's something to remind about.
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        await refreshPermission()
        for r in requests {
            try? await center.add(r)
        }
    }

    func refreshPermission() async {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional: permission = .allowed
        case .denied: permission = .denied
        default: permission = .unknown
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func request(for interview: Interview, minutesBefore: Int, fireDate: Date, store: AppStore) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = L10n.tr("reminder.title", [store.label(for: interview)])
        let time = interview.start.formatted(date: minutesBefore >= 1440 ? .abbreviated : .omitted, time: .shortened)
        var body = L10n.tr("reminder.body", [Self.leadTime(minutesBefore), time])
        switch interview.format {
        case .online: if !interview.meetingLink.isEmpty { body += "\n" + interview.meetingLink }
        case .onsite, .phone: if !interview.location.isEmpty { body += "\n" + interview.location }
        }
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.userInfo = [Self.interviewKey: interview.id.uuidString,
                            Self.linkKey: interview.meetingURL?.absoluteString ?? ""]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
        return UNNotificationRequest(identifier: "\(Self.idPrefix)\(interview.id.uuidString).\(minutesBefore)",
                                     content: content,
                                     trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
    }

    /// Re-registered on every resync so the button titles follow the current language.
    private func registerCategory() {
        let start = UNNotificationAction(identifier: Self.startAction, title: L10n.tr("reminder.action.record"), options: [.foreground])
        let open = UNNotificationAction(identifier: Self.openLinkAction, title: L10n.tr("reminder.action.openLink"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [start, open],
                                                                 intentIdentifiers: [])])
    }

    /// "10 分钟" / "1 小时" / "1 天"
    static func leadTime(_ minutes: Int) -> String {
        if minutes >= 1440 && minutes % 1440 == 0 { return L10n.tr("time.days", [String(minutes / 1440)]) }
        if minutes >= 60 && minutes % 60 == 0 { return L10n.tr("time.hours", [String(minutes / 60)]) }
        return L10n.tr("time.minutes", [String(minutes)])
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show reminders as banners even while the app is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let idString = info[Self.interviewKey] as? String, let id = UUID(uuidString: idString) else { return }
        let link = (info[Self.linkKey] as? String).flatMap(URL.init(string:))
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Self.startAction:
                onStartRecording?(id)
            case Self.openLinkAction:
                if let link { NSWorkspace.shared.open(link) } else { onOpenInterview?(id) }
            default: // clicked the notification itself
                onOpenInterview?(id)
            }
        }
    }
}
