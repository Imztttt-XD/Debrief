import AppKit
import SwiftUI

/// UI state for the schedule page (kept in NavigationModel so it survives rebuilds).
@MainActor
final class ScheduleState: ObservableObject {
    @Published var displayedMonth = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    /// nil = show the upcoming list instead of one day.
    @Published var selectedDay: Date?
    @Published var draft: InterviewDraft?
    /// Month shown in the editor's calendar; nil = the draft's own month.
    @Published var editorMonth: Date?
}

/// What the editor sheet edits: a copy of the interview plus fields for creating a new
/// application inline.
struct InterviewDraft: Identifiable {
    var interview: Interview
    let isNew: Bool
    var createsApplication: Bool
    var newCompany = ""
    var newRole = ""
    var id: UUID { interview.id }

    static func new(on day: Date?, applicationID: UUID?) -> InterviewDraft {
        // Default: the selected day (or today) at the next full hour.
        let cal = Calendar.current
        let base = day.map { cal.date(bySettingHour: 10, minute: 0, second: 0, of: $0) ?? $0 }
            ?? cal.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
        return InterviewDraft(interview: Interview(applicationID: applicationID ?? UUID(), start: base),
                              isNew: true, createsApplication: applicationID == nil)
    }
}

struct ScheduleView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var nav: NavigationModel
    @ObservedObject var reminders: ReminderScheduler
    @ObservedObject var recorder: Recorder
    @ObservedObject var state: ScheduleState

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                MonthCalendar(store: store, state: state)
                Button {
                    state.draft = .new(on: state.selectedDay, applicationID: store.sortedApplications.first?.id)
                } label: {
                    Label(L10n.tr("schedule.new"), systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.brand)
                .controlSize(.large)
                if reminders.permission == .denied {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L10n.tr("schedule.notificationsOff"), systemImage: "bell.slash")
                            .font(.callout).foregroundStyle(Theme.warning)
                        Button(L10n.tr("schedule.openNotificationSettings")) { reminders.openSystemSettings() }
                    }
                }
                Spacer()
            }
            .padding(16)
            .frame(minWidth: 300, idealWidth: 320, maxWidth: 380)

            InterviewList(store: store, recorder: recorder, state: state)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: $state.draft) { _ in
            InterviewEditor(store: store, state: state)
        }
        .onAppear {
            // "安排面试" on an application page lands here with the application preselected.
            if let appID = nav.scheduleForApplication {
                nav.scheduleForApplication = nil
                state.draft = .new(on: nil, applicationID: appID)
            }
            Task { await reminders.refreshPermission() }
        }
    }
}

// MARK: - Month grid

private struct MonthCalendar: View {
    @ObservedObject var store: AppStore
    @ObservedObject var state: ScheduleState
    private let cal = Calendar.current

    var body: some View {
        VStack(spacing: 8) {
            MonthGrid(month: $state.displayedMonth, selected: state.selectedDay,
                      marks: { store.interviewMarks(on: $0) }) { day in
                let isSelected = state.selectedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false
                state.selectedDay = isSelected ? nil : cal.startOfDay(for: day)
            }

            HStack {
                Button(L10n.tr("schedule.today")) {
                    state.displayedMonth = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
                    state.selectedDay = cal.startOfDay(for: Date())
                }
                Spacer()
                if state.selectedDay != nil {
                    Button(L10n.tr("schedule.showUpcoming")) { state.selectedDay = nil }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .font(.callout)
        }
    }
}

/// A month of day buttons with a dot per interview on that day (up to 3): brand-coloured for
/// interviews still to come, very light grey for ended ones; a day whose interviews have all
/// ended also gets a light grey background. Used by the schedule page and the interview editor.
struct MonthGrid: View {
    /// First day of the displayed month.
    @Binding var month: Date
    let selected: Date?
    let marks: (Date) -> Interview.DayMarks
    let onSelect: (Date) -> Void
    var cellHeight: CGFloat = 34
    private let cal = Calendar.current

    private var days: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let firstWeekday = cal.component(.weekday, from: month)
        let leading = (firstWeekday - cal.firstWeekday + 7) % 7
        let dates = range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }
        let cells: [Date?] = Array(repeating: nil, count: leading) + dates
        return cells + Array(repeating: nil, count: (7 - cells.count % 7) % 7)
    }

    private var weekdaySymbols: [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let start = cal.firstWeekday - 1
        return Array(symbols[start...] + symbols[..<start])
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(L10n.tr("schedule.prevMonth"))
                Spacer()
                Text(month.formatted(.dateTime.year().month(.wide)))
                    .font(.headline)
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel(L10n.tr("schedule.nextMonth"))
            }
            .buttonStyle(.borderless)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        DayCell(day: day, marks: marks(day), height: cellHeight,
                                selected: selected.map { cal.isDate($0, inSameDayAs: day) } ?? false) { onSelect(day) }
                    } else {
                        Color.clear.frame(height: cellHeight)
                    }
                }
            }
        }
    }

    private func shift(_ months: Int) {
        month = cal.date(byAdding: .month, value: months, to: month) ?? month
    }
}

private struct DayCell: View {
    let day: Date
    let marks: Interview.DayMarks
    let height: CGFloat
    let selected: Bool
    let action: () -> Void
    private let cal = Calendar.current

    var body: some View {
        let today = cal.isDateInToday(day)
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day))")
                    .font(.callout.weight(today ? .bold : .regular))
                    .foregroundStyle(selected ? Color.white : (today ? Theme.accent : Color.primary))
                HStack(spacing: 2) {
                    // Upcoming first, then ended, at most 3 dots in all.
                    let upcoming = min(marks.upcoming, 3), ended = min(marks.ended, 3 - upcoming)
                    ForEach(0..<upcoming, id: \.self) { _ in
                        Circle().fill(selected ? Color.white : Theme.periwinkle).frame(width: 5, height: 5)
                    }
                    ForEach(0..<ended, id: \.self) { _ in
                        Circle().fill(selected ? Color.white.opacity(0.55) : Theme.endedMark).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background(today: today)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue(marks.total > 0 ? L10n.tr("schedule.a11y.count", [String(marks.total)]) : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func background(today: Bool) -> Color {
        if selected { return Theme.control }
        if today { return Theme.selection }
        if marks.upcoming == 0 && marks.ended > 0 { return Theme.endedDay }
        return .clear
    }
}

// MARK: - List

private struct InterviewList: View {
    @ObservedObject var store: AppStore
    @ObservedObject var recorder: Recorder
    @ObservedObject var state: ScheduleState

    var body: some View {
        let cal = Calendar.current
        List {
            if let day = state.selectedDay {
                let items = store.interviews.filter { cal.isDate($0.start, inSameDayAs: day) }.sorted { $0.start < $1.start }
                Section(day.formatted(date: .complete, time: .omitted)) {
                    if items.isEmpty {
                        Text(L10n.tr("schedule.noneOnDay")).foregroundStyle(.secondary)
                    }
                    ForEach(items) { InterviewRow(interview: $0, store: store, recorder: recorder, state: state) }
                }
            } else {
                let upcoming = store.upcomingInterviews
                Section(L10n.tr("schedule.upcoming")) {
                    if upcoming.isEmpty {
                        Text(L10n.tr("schedule.noneUpcoming")).foregroundStyle(.secondary)
                    }
                    ForEach(upcoming) { InterviewRow(interview: $0, store: store, recorder: recorder, state: state) }
                }
                let past = store.interviews.filter { $0.end <= Date() }.sorted { $0.start > $1.start }.prefix(20)
                if !past.isEmpty {
                    Section(L10n.tr("schedule.past")) {
                        ForEach(Array(past)) { InterviewRow(interview: $0, store: store, recorder: recorder, state: state) }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct InterviewRow: View {
    let interview: Interview
    @ObservedObject var store: AppStore
    @ObservedObject var recorder: Recorder
    @ObservedObject var state: ScheduleState

    var body: some View {
        let app = store.application(interview.applicationID)
        let recordings = store.recordings(for: interview.id)
        let now = Date()
        let isPast = interview.end <= now
        // Recording is offered from 30 min before until the end.
        let canRecord = !isPast && interview.start.addingTimeInterval(-Interview.matchMargin) <= now

        HStack(alignment: .top, spacing: 12) {
            // Ended interviews: time and details faded; the buttons stay normal so they don't look disabled.
            VStack(alignment: .trailing, spacing: 2) {
                Text(interview.start.formatted(date: .omitted, time: .shortened)).font(.headline.monospacedDigit())
                Text(interview.end.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if state.selectedDay == nil {
                    Text(interview.start.formatted(.dateTime.month().day().weekday(.abbreviated)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, alignment: .trailing)
            .opacity(isPast ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(app?.displayCompany ?? L10n.tr("app.untitledCompany")).font(.headline)
                    if !interview.round.isEmpty {
                        Pill(text: interview.round, color: isPast ? Theme.neutral : Theme.accent)
                    }
                    if isPast { Pill(text: L10n.tr("schedule.ended"), color: Theme.neutral) }
                }
                Text(app?.displayRole ?? "").foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label(interview.format.title, systemImage: interview.format.icon)
                    if !interview.reminderMinutes.isEmpty {
                        Label(interview.reminderMinutes.sorted(by: >).map(ReminderScheduler.leadTime).joined(separator: "、"),
                              systemImage: "bell")
                    }
                    if !recordings.isEmpty {
                        Label(L10n.tr("schedule.recordings", [String(recordings.count)]), systemImage: "waveform")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !interview.notes.isEmpty {
                    Text(interview.notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .opacity(isPast ? 0.5 : 1)
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button(L10n.tr("schedule.edit")) {
                    state.draft = InterviewDraft(interview: interview, isNew: false, createsApplication: false)
                }
                if let url = interview.meetingURL, !isPast {
                    Button(L10n.tr("reminder.action.openLink")) { NSWorkspace.shared.open(url) }
                }
                if canRecord && !recorder.isRecording {
                    Button(L10n.tr("action.start")) { recorder.requestStart(linkTo: interview.id) }
                        .tint(Theme.dangerFill)
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Editor

struct InterviewEditor: View {
    @ObservedObject var store: AppStore
    @ObservedObject var state: ScheduleState
    @Environment(\.colorScheme) private var colorScheme
    private static let roundSuggestions = ["schedule.round.1", "schedule.round.2", "schedule.round.3", "schedule.round.hr", "schedule.round.final"]

    private var draft: Binding<InterviewDraft> {
        Binding(get: { state.draft ?? .new(on: nil, applicationID: nil) }, set: { state.draft = $0 })
    }

    private var canSave: Bool {
        guard let d = state.draft else { return false }
        if d.createsApplication {
            return !d.newCompany.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return store.application(d.interview.applicationID) != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker(L10n.tr("schedule.field.application"), selection: applicationSelection) {
                        ForEach(store.sortedApplications) { app in
                            Text("\(app.displayCompany) · \(app.displayRole)").tag(Optional(app.id))
                        }
                        Divider()
                        Text(L10n.tr("schedule.field.newApplication")).tag(UUID?.none)
                    }
                    if draft.wrappedValue.createsApplication {
                        TextField(L10n.tr("field.company"), text: draft.newCompany)
                        TextField(L10n.tr("field.role"), text: draft.newRole)
                    }
                    HStack {
                        TextField(L10n.tr("schedule.field.round"), text: draft.interview.round,
                                  prompt: Text(L10n.tr("schedule.round.1")))
                        Menu {
                            ForEach(Self.roundSuggestions, id: \.self) { key in
                                Button(L10n.tr(key)) { draft.wrappedValue.interview.round = L10n.tr(key) }
                            }
                        } label: { Image(systemName: "chevron.down.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(L10n.tr("schedule.field.round"))
                    }
                }

                Section {
                    timeSummary
                    MonthGrid(month: editorMonth, selected: draft.wrappedValue.interview.start,
                              marks: { store.interviewMarks(on: $0) }, onSelect: setDay, cellHeight: 38)
                        .padding(.vertical, 4)
                    LabeledContent(L10n.tr("schedule.field.timeOfDay")) { timePickers }
                    quickTimes
                    LabeledContent(L10n.tr("schedule.field.duration")) {
                        SegmentedControl(selection: draft.interview.durationMinutes, options: Interview.durationChoices.map {
                            .init(value: $0, title: L10n.tr("time.minutes", [String($0)]))
                        })
                    }
                } header: {
                    Text(L10n.tr("schedule.field.start"))
                }

                Section {
                    LabeledContent(L10n.tr("schedule.field.format")) {
                        SegmentedControl(selection: draft.interview.format, options: Interview.Format.allCases.map {
                            .init(value: $0, title: $0.title, icon: $0.icon)
                        })
                        .frame(maxWidth: 300)
                    }
                    switch draft.wrappedValue.interview.format {
                    case .online:
                        TextField(L10n.tr("schedule.field.link"), text: draft.interview.meetingLink,
                                  prompt: Text("https://…"))
                    case .onsite:
                        TextField(L10n.tr("schedule.field.address"), text: draft.interview.location)
                    case .phone:
                        TextField(L10n.tr("schedule.field.phone"), text: draft.interview.location)
                    }
                }

                Section {
                    ForEach(Interview.reminderChoices, id: \.self) { minutes in
                        Toggle(L10n.tr("schedule.reminderBefore", [ReminderScheduler.leadTime(minutes)]),
                               isOn: reminderBinding(minutes))
                            .toggleStyle(.brandSwitch)
                    }
                } header: {
                    Text(L10n.tr("schedule.field.reminders"))
                }

                Section {
                    TextEditor(text: draft.interview.notes)
                        .frame(minHeight: 70)
                        .accessibilityLabel(L10n.tr("field.notes"))
                } header: {
                    Text(L10n.tr("field.notes"))
                } footer: {
                    Text(L10n.tr("schedule.notes.hint")).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            // A sheet is its own window: hide the grey form background here too (dark mode).
            .scrollContentBackground(colorScheme == .dark ? .hidden : .automatic)

            Divider()
            HStack {
                if !draft.wrappedValue.isNew {
                    Button(L10n.tr("schedule.delete"), role: .destructive) { delete() }
                }
                Spacer()
                Button(L10n.tr("action.cancel")) { state.draft = nil }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("ai.key.save")) { save() }
                    .buttonStyle(.brand)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
        }
        .frame(width: 560, height: 720)
        .buttonStyle(.soft)
        .background(Theme.windowBackground)
        .presentationBackground(Theme.windowBackground)
        .onAppear { state.editorMonth = nil }
    }

    // MARK: Start time

    private let cal = Calendar.current
    private static let quickTimeChoices = [(9, 0), (10, 0), (11, 0), (14, 0), (15, 0), (16, 0), (19, 0)]

    private var start: Date { draft.wrappedValue.interview.start }

    /// "11月20日 星期四" and "14:00 – 15:00", large, so the choice is obvious at a glance.
    private var timeSummary: some View {
        let end = draft.wrappedValue.interview.end
        return VStack(alignment: .leading, spacing: 2) {
            Text(start.formatted(.dateTime.month(.wide).day().weekday(.wide).locale(L10n.locale)))
                .font(.title3.weight(.semibold))
            // 24-hour, matching the hour / minute pickers below.
            Text("\(Self.clock(start, cal)) – \(Self.clock(end, cal))")
                .font(.title3.monospacedDigit())
                .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// The calendar follows the chosen date unless the user pages to another month.
    private var editorMonth: Binding<Date> {
        Binding(get: { state.editorMonth ?? cal.dateInterval(of: .month, for: start)?.start ?? start },
                set: { state.editorMonth = $0 })
    }

    private var hour: Int { cal.component(.hour, from: start) }
    private var minute: Int { cal.component(.minute, from: start) }

    private var timePickers: some View {
        // Every 5 minutes, plus the current minute if it's in between (e.g. from an older entry).
        let minutes = Array(Set(Array(stride(from: 0, to: 60, by: 5)) + [minute])).sorted()
        return HStack(spacing: 4) {
            Picker(L10n.tr("schedule.field.hour"), selection: Binding(get: { hour }, set: { setTime($0, minute) })) {
                ForEach(0..<24, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden().fixedSize()
            Text(":").font(.title3.monospacedDigit())
            Picker(L10n.tr("schedule.field.minute"), selection: Binding(get: { minute }, set: { setTime(hour, $0) })) {
                ForEach(minutes, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    /// One click for the usual interview slots.
    private var quickTimes: some View {
        LabeledContent(L10n.tr("schedule.field.quickTimes")) {
            HStack(spacing: 6) {
                ForEach(Self.quickTimeChoices, id: \.0) { h, m in
                    let chosen = hour == h && minute == m
                    Button(String(format: "%02d:%02d", h, m)) { setTime(h, m) }
                        .buttonStyle(.plain)
                        .font(.callout.monospacedDigit().weight(chosen ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(chosen ? Theme.control : Theme.selection))
                        .foregroundStyle(chosen ? Color.white : Theme.accent)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
    }

    static func clock(_ date: Date, _ cal: Calendar) -> String {
        String(format: "%02d:%02d", cal.component(.hour, from: date), cal.component(.minute, from: date))
    }

    private func setDay(_ day: Date) {
        guard let new = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { return }
        state.draft?.interview.start = new
    }

    private func setTime(_ h: Int, _ m: Int) {
        guard let new = cal.date(bySettingHour: h, minute: m, second: 0, of: start) else { return }
        state.draft?.interview.start = new
    }

    /// nil = "新建岗位…"
    private var applicationSelection: Binding<UUID?> {
        Binding(
            get: { state.draft?.createsApplication == true ? nil : state.draft?.interview.applicationID },
            set: { id in
                if let id {
                    state.draft?.interview.applicationID = id
                    state.draft?.createsApplication = false
                } else {
                    state.draft?.createsApplication = true
                }
            })
    }

    private func reminderBinding(_ minutes: Int) -> Binding<Bool> {
        Binding(
            get: { state.draft?.interview.reminderMinutes.contains(minutes) ?? false },
            set: { on in
                guard var list = state.draft?.interview.reminderMinutes else { return }
                list.removeAll { $0 == minutes }
                if on { list.append(minutes) }
                state.draft?.interview.reminderMinutes = list.sorted(by: >)
            })
    }

    private func save() {
        guard var d = state.draft else { return }
        if d.createsApplication {
            var app = JobApplication()
            app.company = d.newCompany.trimmingCharacters(in: .whitespaces)
            app.role = d.newRole.trimmingCharacters(in: .whitespaces)
            store.applications.append(app)
            d.interview.applicationID = app.id
        }
        store.save(d.interview)
        state.selectedDay = Calendar.current.startOfDay(for: d.interview.start)
        state.displayedMonth = Calendar.current.dateInterval(of: .month, for: d.interview.start)?.start ?? state.displayedMonth
        state.draft = nil
    }

    private func delete() {
        guard let d = state.draft else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("schedule.delete.confirm", [store.label(for: d.interview)])
        alert.addButton(withTitle: L10n.tr("action.delete"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteInterview(d.interview.id)
        state.draft = nil
    }
}
