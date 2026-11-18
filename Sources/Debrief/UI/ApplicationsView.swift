import AppKit
import SwiftUI

/// 岗位: list of applications on the left, editor on the right.
struct ApplicationsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var nav: NavigationModel
    /// "all" or a JobApplication.Status raw value.
    @AppStorage("applicationsFilter") private var filter = "all"

    private var visible: [JobApplication] {
        let query = nav.applicationSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return store.sortedApplications.filter { app in
            (filter == "all" || app.status.rawValue == filter)
                && (query.isEmpty || app.company.lowercased().contains(query) || app.role.lowercased().contains(query))
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    HStack {
                        TextField(L10n.tr("app.search"), text: $nav.applicationSearch)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            nav.selectedApplicationID = store.newApplication()
                            filter = "all"
                            nav.applicationSearch = ""
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(L10n.tr("app.new"))
                        .accessibilityLabel(L10n.tr("app.new"))
                    }
                    Picker(L10n.tr("field.status"), selection: $filter) {
                        Text(L10n.tr("app.filter.all")).tag("all")
                        ForEach(JobApplication.Status.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                }
                .padding(10)
                Divider()

                if store.applications.isEmpty {
                    EmptyApplications { nav.selectedApplicationID = store.newApplication() }
                } else {
                    List {
                        ForEach(visible) { app in
                            ApplicationRow(app: app)
                                .selectableRow(nav.selectedApplicationID == app.id) { nav.selectedApplicationID = app.id }
                        }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)

            Group {
                if let id = nav.selectedApplicationID, let binding = store.binding(forApplication: id) {
                    ApplicationEditor(application: binding, store: store, onSchedule: {
                        nav.scheduleForApplication = id
                        nav.section = .schedule
                    }, onDelete: {
                        confirmDelete(binding.wrappedValue)
                    })
                    .id(id)
                } else {
                    Text(L10n.tr(store.applications.isEmpty ? "app.empty.message" : "app.select"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            // Coming back to this page: keep showing something instead of an empty editor.
            if nav.selectedApplicationID.flatMap(store.application) == nil {
                nav.selectedApplicationID = store.sortedApplications.first?.id
            }
        }
    }

    private func confirmDelete(_ app: JobApplication) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("app.delete.confirm", ["\(app.displayCompany) · \(app.displayRole)"])
        if !store.interviews(for: app.id).isEmpty {
            alert.informativeText = L10n.tr("app.delete.interviews")
        }
        alert.addButton(withTitle: L10n.tr("action.delete"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        nav.selectedApplicationID = nil
        store.deleteApplication(app.id)
    }
}

private struct EmptyApplications: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "briefcase").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(L10n.tr("app.empty.title")).font(.headline)
            Text(L10n.tr("app.empty.message")).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(L10n.tr("app.new"), action: onCreate).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ApplicationRow: View {
    let app: JobApplication

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(app.displayCompany).font(.headline).lineLimit(1)
            Text(app.displayRole).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                StatusBadge(status: app.status)
                Text(app.updatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct StatusBadge: View {
    let status: JobApplication.Status

    private var color: Color {
        switch status {
        case .applied: Theme.accent
        case .interviewing: Color(hex: 0xF08A24)
        case .awaitingResult: .purple
        case .offer: Color(hex: 0x23A26D)
        case .rejected: Theme.record
        case .withdrawn: .gray
        }
    }

    var body: some View {
        Pill(text: status.title, color: color)
    }
}

private struct ApplicationEditor: View {
    @Binding var application: JobApplication
    @ObservedObject var store: AppStore
    let onSchedule: () -> Void
    let onDelete: () -> Void
    private var resumes: [Resume] { store.resumes }

    var body: some View {
        Form {
            Section {
                TextField(L10n.tr("field.company"), text: $application.company)
                TextField(L10n.tr("field.role"), text: $application.role)
                Picker(L10n.tr("field.status"), selection: $application.status) {
                    ForEach(JobApplication.Status.allCases) { Text($0.title).tag($0) }
                }
                TextField(L10n.tr("field.channel"), text: $application.channel,
                          prompt: Text(L10n.tr("field.channel.prompt")))
                Picker(L10n.tr("field.resume"), selection: $application.resumeID) {
                    Text(L10n.tr("field.resume.none")).tag(UUID?.none)
                    ForEach(resumes) { Text($0.name).tag(Optional($0.id)) }
                }
            }

            Section {
                let interviews = store.interviews(for: application.id)
                if interviews.isEmpty {
                    Text(L10n.tr("app.interviews.none")).foregroundStyle(.secondary)
                }
                ForEach(interviews) { iv in
                    HStack {
                        Image(systemName: iv.format.icon).foregroundStyle(.secondary)
                        Text(iv.round.isEmpty ? L10n.tr("app.interviews.untitledRound") : iv.round)
                        Text(iv.start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        Spacer()
                        let count = store.recordings(for: iv.id).count
                        if count > 0 {
                            Label(L10n.tr("schedule.recordings", [String(count)]), systemImage: "waveform")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if iv.end <= Date() { Text(L10n.tr("schedule.ended")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button(L10n.tr("app.interviews.schedule"), action: onSchedule)
            } header: {
                Text(L10n.tr("app.interviews"))
            }

            Section {
                TextEditor(text: $application.jobDescription)
                    .font(.body)
                    .frame(minHeight: 220)
                    .accessibilityLabel(L10n.tr("field.jd"))
            } header: {
                Text(L10n.tr("field.jd"))
            } footer: {
                Text(L10n.tr("field.jd.hint")).foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $application.notes)
                    .font(.body)
                    .frame(minHeight: 90)
                    .accessibilityLabel(L10n.tr("field.notes"))
            } header: {
                Text(L10n.tr("field.notes"))
            }

            Section {
                HStack {
                    Text(L10n.tr("field.createdAt", [application.createdAt.formatted(date: .abbreviated, time: .shortened)]))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("app.delete"), role: .destructive, action: onDelete)
                }
            }
        }
        .formStyle(.grouped)
    }
}
