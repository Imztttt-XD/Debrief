import AppKit
import SwiftUI

/// 设置: 模型服务 | 个人资料 | 通用
struct SettingsView: View {
    @ObservedObject var store: AppStore
    @AppStorage("settingsTab") private var tab = "models"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(L10n.tr("settings.tab.models")).tag("models")
                Text(L10n.tr("settings.tab.profile")).tag("profile")
                Text(L10n.tr("settings.tab.general")).tag("general")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(12)
            Divider()
            switch tab {
            case "profile": ProfileSettingsView(store: store)
            case "general": GeneralSettingsView()
            default: ModelSettingsView(store: store)
            }
        }
    }
}

// MARK: - 模型服务

/// Transient UI state for the model settings page.
@MainActor
final class ModelSettingsState: ObservableObject {
    enum TestState: Equatable { case running, ok(String), failed(String) }

    @Published var tests: [AIFunction: TestState] = [:]
    /// Unsaved API key text per account.
    @Published var keyDrafts: [UUID: String] = [:]
    @Published var keyErrors: [UUID: String] = [:]

    func test(_ function: AIFunction, settings: AISettings) {
        tests[function] = .running
        Task {
            do {
                let message = try await ConnectionCheck.run(function, settings: settings)
                tests[function] = .ok(message)
            } catch {
                tests[function] = .failed(error.localizedDescription)
            }
        }
    }
}

struct ModelSettingsView: View {
    @ObservedObject var store: AppStore
    @StateObject private var state = ModelSettingsState()

    var body: some View {
        Form {
            Section {
                ForEach(AIFunction.allCases) { function in
                    FunctionRow(function: function, ai: $store.ai, state: state)
                }
            } header: {
                Text(L10n.tr("ai.functions.header"))
            } footer: {
                Text(L10n.tr("ai.functions.footer")).foregroundStyle(.secondary)
            }

            ForEach($store.ai.accounts) { $account in
                AccountSection(account: $account, state: state) {
                    Keychain.delete(account.id)
                    store.ai.accounts.removeAll { $0.id == account.id }
                }
            }

            Section {
                Menu(L10n.tr("ai.account.add")) {
                    ForEach(ProviderAccount.Vendor.allCases) { vendor in
                        Button(vendor.title) { store.ai.accounts.append(.preset(vendor)) }
                    }
                }
                .fixedSize()
            } footer: {
                Text(L10n.tr("ai.privacy")).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct FunctionRow: View {
    let function: AIFunction
    @Binding var ai: AISettings
    @ObservedObject var state: ModelSettingsState

    private var assignment: Binding<ModelAssignment> {
        Binding(get: { ai.assignment(for: function) },
                set: { ai.assignments[function.rawValue] = $0 })
    }

    private var providerField: some View {
        HStack(spacing: 6) {
            Text(L10n.tr("ai.provider")).foregroundStyle(.secondary)
            Picker(L10n.tr("ai.provider"), selection: assignment.accountID) {
                Text(L10n.tr("ai.notConfigured")).tag(UUID?.none)
                ForEach(eligibleAccounts) { Text($0.name).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
    }

    private var modelField: some View {
        HStack(spacing: 6) {
            Text(L10n.tr("ai.model")).foregroundStyle(.secondary)
            TextField(L10n.tr("ai.model"), text: assignment.model)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 130, idealWidth: 180, maxWidth: 220)
            let suggestions = ai.account(assignment.wrappedValue.accountID)?.vendor.suggestedModels(for: function) ?? []
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { m in Button(m) { assignment.wrappedValue.model = m } }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L10n.tr("ai.model.suggestions"))
                .accessibilityLabel(L10n.tr("ai.model.suggestions"))
            }
        }
    }

    private var testButton: some View {
        Button(L10n.tr("ai.test")) { state.test(function, settings: ai) }
            .disabled(state.tests[function] == .running)
    }

    private var eligibleAccounts: [ProviderAccount] {
        ai.accounts.filter { !function.isTranscription || $0.vendor.supportsTranscription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(function.title).font(.headline)
                Text(function.detail).font(.caption).foregroundStyle(.secondary)
            }
            // One row when there's room; provider and model on separate rows when narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { providerField; modelField; Spacer(minLength: 0); testButton }
                VStack(alignment: .leading, spacing: 8) {
                    providerField
                    HStack(spacing: 10) { modelField; Spacer(minLength: 0); testButton }
                }
            }
            if function.isTranscription && eligibleAccounts.isEmpty {
                Text(L10n.tr("ai.noTranscriptionProvider")).font(.caption).foregroundStyle(.secondary)
            }
            switch state.tests[function] {
            case .running:
                Text(L10n.tr("ai.testing")).font(.caption).foregroundStyle(.secondary)
            case .ok(let m):
                Label(m, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .failed(let m):
                Label(m, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
            case nil:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AccountSection: View {
    @Binding var account: ProviderAccount
    @ObservedObject var state: ModelSettingsState
    let onDelete: () -> Void

    private var draft: Binding<String> {
        Binding(get: { state.keyDrafts[account.id] ?? "" }, set: { state.keyDrafts[account.id] = $0 })
    }

    var body: some View {
        Section {
            TextField(L10n.tr("ai.account.name"), text: $account.name)
            LabeledContent(L10n.tr("ai.account.vendor"), value: account.vendor.title)

            if account.vendor == .dashscope {
                Picker(L10n.tr("ai.account.region"), selection: $account.region) {
                    ForEach(ProviderAccount.Region.allCases) { Text($0.title).tag($0) }
                }
                TextField(L10n.tr("ai.account.workspace"), text: $account.workspaceID,
                          prompt: Text(L10n.tr("ai.account.workspace.prompt")))
                Text(L10n.tr("ai.dashscope.keyNote")).font(.caption).foregroundStyle(.secondary)
            } else {
                TextField(L10n.tr("ai.account.baseURL"), text: $account.baseURL)
            }
            if account.resolvedBaseURL == nil {
                Text(L10n.tr("error.ai.invalidURL")).font(.caption).foregroundStyle(.red)
            }

            HStack {
                SecureField(L10n.tr("ai.account.key"), text: draft,
                            prompt: Text(account.keyHint.map { L10n.tr("ai.key.saved", [$0]) } ?? L10n.tr("ai.key.placeholder")))
                Button(L10n.tr("ai.key.save")) { saveKey() }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if account.keyHint != nil {
                    Button(L10n.tr("ai.key.remove")) {
                        Keychain.delete(account.id)
                        account.keyHint = nil
                    }
                }
            }
            if let error = state.keyErrors[account.id] {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.tr("ai.account.delete"), role: .destructive, action: onDelete)
            }
        } header: {
            Text(account.name.isEmpty ? account.vendor.title : account.name)
        }
    }

    private func saveKey() {
        let key = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Keychain.set(key, for: account.id)
            account.keyHint = String(key.suffix(4))
            state.keyDrafts[account.id] = nil
            state.keyErrors[account.id] = nil
        } catch {
            state.keyErrors[account.id] = error.localizedDescription
        }
    }
}

// MARK: - 个人资料

struct ProfileSettingsView: View {
    @ObservedObject var store: AppStore
    @StateObject private var state = ProfileState()

    var body: some View {
        Form {
            Section {
                TextField(L10n.tr("profile.direction"), text: $store.profile.targetDirection,
                          prompt: Text(L10n.tr("profile.direction.prompt")))
            }

            Section {
                ForEach($store.resumes) { $resume in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(L10n.tr("profile.resume.name"), text: $resume.name)
                            if resume.text.isEmpty {
                                Text(L10n.tr("profile.resume.empty")).font(.callout).foregroundStyle(.orange)
                            }
                            Text(L10n.tr("profile.resume.text")).font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $resume.text)
                                .font(.body)
                                .frame(minHeight: 220)
                                .accessibilityLabel(L10n.tr("profile.resume.text"))
                            HStack {
                                Button(L10n.tr("profile.resume.showFile")) {
                                    NSWorkspace.shared.activateFileViewerSelecting([resume.storedFileURL])
                                }
                                Spacer()
                                Button(L10n.tr("action.delete"), role: .destructive) { confirmDelete(resume) }
                            }
                        }
                        .padding(.vertical, 6)
                    } label: {
                        HStack {
                            Image(systemName: "doc.text")
                            Text(resume.name)
                            Spacer()
                            Text(L10n.tr("profile.resume.chars", [String(resume.text.count)]))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button(L10n.tr("profile.import")) { importResumes() }
                if let error = state.importError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text(L10n.tr("profile.resumes"))
            } footer: {
                Text(L10n.tr("profile.resumes.footer")).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func importResumes() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AppStore.resumeFileTypes.compactMap { .init(filenameExtension: $0) }
        panel.prompt = L10n.tr("profile.import")
        guard panel.runModal() == .OK else { return }
        state.importError = nil
        var failures: [String] = []
        for url in panel.urls {
            do { try store.importResume(from: url) } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            state.importError = L10n.tr("profile.resume.importFailed", [failures.joined(separator: "\n")])
        }
    }

    private func confirmDelete(_ resume: Resume) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.tr("profile.resume.delete.confirm", [resume.name])
        alert.addButton(withTitle: L10n.tr("action.delete"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { store.deleteResume(resume.id) }
    }
}

@MainActor
final class ProfileState: ObservableObject {
    @Published var importError: String?
}

// MARK: - 通用

struct GeneralSettingsView: View {
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.default.rawValue
    @AppStorage(FloatingButtonController.visibleKey) private var floatingVisible = true
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Picker(L10n.tr("section.language"), selection: $languageRaw) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .onChange(of: languageRaw) { _, new in
                (AppLanguage(rawValue: new) ?? .default).applyToSystemUI()
            }
            Picker(L10n.tr("section.appearance"), selection: $appearanceRaw) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .onChange(of: appearanceRaw) { _, new in (AppAppearance(rawValue: new) ?? .system).apply() }
            Toggle(L10n.tr("settings.floatingButton"), isOn: $floatingVisible)
        }
        .formStyle(.grouped)
    }
}
