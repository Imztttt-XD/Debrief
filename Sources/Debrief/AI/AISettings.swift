import Foundation

/// What the app uses AI for. Each function gets its own provider + model so they can be
/// mixed (cheap model for question extraction, strong one for review) and switched at any time.
enum AIFunction: String, Codable, CaseIterable, Identifiable {
    case review, mockInterview, questionBank, transcription
    var id: String { rawValue }
    var title: String { L10n.tr("ai.function.\(rawValue)") }
    var detail: String { L10n.tr("ai.function.\(rawValue).desc") }
    var isTranscription: Bool { self == .transcription }
}

/// A provider account: where to send requests. The API key is in the Keychain, not here.
struct ProviderAccount: Codable, Identifiable, Hashable {
    enum Vendor: String, Codable, CaseIterable, Identifiable {
        case deepseek, dashscope, openai, custom
        var id: String { rawValue }
        var title: String { L10n.tr("vendor.\(rawValue)") }

        var defaultBaseURL: String {
            switch self {
            case .deepseek: "https://api.deepseek.com"
            case .dashscope: ""                       // derived from region / workspace
            case .openai: "https://api.openai.com/v1"
            case .custom: "http://localhost:11434/v1" // Ollama's OpenAI-compatible endpoint
            }
        }

        /// Only Qwen-ASR is wired up for transcription so far. OpenAI's audio endpoint comes later.
        var supportsTranscription: Bool { self == .dashscope }

        /// Shown as quick picks next to the model field. Only IDs confirmed from the vendors'
        /// docs are listed; any other model name can be typed in.
        func suggestedModels(for function: AIFunction) -> [String] {
            switch (self, function.isTranscription) {
            case (.deepseek, false): ["deepseek-flash", "deepseek-v4-pro"]
            case (.dashscope, true): ["qwen3-asr-flash"]
            default: []
            }
        }
    }

    enum Region: String, Codable, CaseIterable, Identifiable {
        case singapore, beijing
        var id: String { rawValue }
        var title: String { L10n.tr("ai.region.\(rawValue)") }
        var code: String { self == .singapore ? "ap-southeast-1" : "cn-beijing" }
        var legacyHost: String { self == .singapore ? "dashscope-intl.aliyuncs.com" : "dashscope.aliyuncs.com" }
    }

    var id = UUID()
    var name: String
    var vendor: Vendor
    var baseURL: String
    /// Alibaba Cloud Model Studio only.
    var region: Region = .singapore
    var workspaceID = ""
    /// Last 4 characters of the saved key, so the UI can show it without a Keychain read
    /// (which would prompt for the login password after every ad-hoc rebuild).
    var keyHint: String?

    static func preset(_ vendor: Vendor) -> ProviderAccount {
        ProviderAccount(name: vendor.title, vendor: vendor, baseURL: vendor.defaultBaseURL)
    }

    /// OpenAI-compatible base URL (".../chat/completions" is appended to it).
    var resolvedBaseURL: URL? {
        switch vendor {
        case .dashscope:
            let ws = workspaceID.trimmingCharacters(in: .whitespaces)
            // Workspace IDs are alphanumeric; refuse anything else rather than build a strange host.
            if !ws.isEmpty {
                guard ws.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
                return URL(string: "https://\(ws).\(region.code).maas.aliyuncs.com/compatible-mode/v1")
            }
            return URL(string: "https://\(region.legacyHost)/compatible-mode/v1")
        default:
            let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme) else { return nil }
            return url
        }
    }
}

struct ModelAssignment: Codable, Hashable {
    var accountID: UUID?
    var model: String
}

struct AISettings: Codable, Hashable {
    var accounts: [ProviderAccount]
    /// Keyed by AIFunction.rawValue (plain String keys keep the JSON readable).
    var assignments: [String: ModelAssignment]
    /// Transcribe on this Mac (Apple's speech recognizer, macOS 26+) instead of the cloud model.
    /// nil = never chosen: see `usesLocalTranscription`. Optional so older settings files decode.
    var localTranscription: Bool?

    /// Whether reviews transcribe on this Mac. When the user hasn't chosen, local is the default
    /// unless they already saved a key for the cloud transcription provider.
    var usesLocalTranscription: Bool {
        guard LocalTranscriber.isSupported else { return false }
        if let localTranscription { return localTranscription }
        return account(assignment(for: .transcription).accountID)?.keyHint == nil
    }

    func assignment(for function: AIFunction) -> ModelAssignment {
        assignments[function.rawValue] ?? ModelAssignment(accountID: nil, model: "")
    }

    func account(_ id: UUID?) -> ProviderAccount? {
        accounts.first { $0.id == id }
    }

    /// The budget plan chosen by the user: DeepSeek for text, Qwen-ASR for transcription.
    static var defaults: AISettings {
        let deepseek = ProviderAccount.preset(.deepseek)
        let dashscope = ProviderAccount.preset(.dashscope)
        return AISettings(
            accounts: [deepseek, dashscope],
            assignments: [
                AIFunction.review.rawValue: ModelAssignment(accountID: deepseek.id, model: "deepseek-v4-pro"),
                AIFunction.mockInterview.rawValue: ModelAssignment(accountID: deepseek.id, model: "deepseek-flash"),
                AIFunction.questionBank.rawValue: ModelAssignment(accountID: deepseek.id, model: "deepseek-flash"),
                AIFunction.transcription.rawValue: ModelAssignment(accountID: dashscope.id, model: "qwen3-asr-flash"),
            ])
    }
}
