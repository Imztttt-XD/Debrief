import Foundation

/// Token counts a provider reports for one request. Field names differ between providers
/// (OpenAI / DeepSeek: prompt_tokens / completion_tokens; DashScope ASR: input_tokens /
/// output_tokens, plus seconds of audio), so `parse` accepts both.
struct TokenUsage: Equatable, Sendable {
    var input = 0
    var output = 0
    /// Thinking tokens of reasoning models, already included in `output`.
    var reasoning = 0
    /// Input tokens served from the provider's cache, already included in `input`.
    var cached = 0
    var audioSeconds: Double = 0

    var total: Int { input + output }

    static func parse(_ json: Any?) -> TokenUsage? {
        guard let u = json as? [String: Any] else { return nil }
        func int(_ keys: String...) -> Int { keys.lazy.compactMap { (u[$0] as? NSNumber)?.intValue }.first ?? 0 }
        var t = TokenUsage(input: int("prompt_tokens", "input_tokens"), output: int("completion_tokens", "output_tokens"))
        t.reasoning = ((u["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? NSNumber)?.intValue ?? 0
        t.cached = int("prompt_cache_hit_tokens")
        if t.cached == 0 { t.cached = ((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? NSNumber)?.intValue ?? 0 }
        t.audioSeconds = (u["seconds"] as? NSNumber)?.doubleValue ?? 0
        if t.total == 0 && t.audioSeconds == 0, let total = (u["total_tokens"] as? NSNumber)?.intValue { t.input = total }
        return t.total > 0 || t.audioSeconds > 0 ? t : nil
    }
}

/// Usage summed per day, function, provider and model: small enough to keep forever.
struct UsageEntry: Codable, Hashable, Identifiable {
    /// yyyy-MM-dd in local time.
    var day: String
    /// AIFunction raw value.
    var function: String
    var provider: String
    var model: String
    var requests = 0
    var input = 0
    var output = 0
    var reasoning = 0
    var cached = 0
    var audioSeconds: Double = 0

    var id: String { "\(day)|\(function)|\(provider)|\(model)" }
    var total: Int { input + output }

    mutating func add(_ u: TokenUsage) {
        requests += 1
        input += u.input; output += u.output; reasoning += u.reasoning; cached += u.cached
        audioSeconds += u.audioSeconds
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// The token usage log behind 设置 → 用量, in usage.json. Started with this feature: requests
/// before it aren't known.
@MainActor
final class UsageLedger: ObservableObject {
    static let shared = UsageLedger()

    @Published private(set) var entries: [UsageEntry]
    private let file = JSONFile<[UsageEntry]>("usage.json")
    private var pendingSave: Task<Void, Never>?

    init() {
        entries = file.load() ?? []
    }

    func record(_ usage: TokenUsage, function: AIFunction, provider: String, model: String, at date: Date = Date()) {
        let day = UsageEntry.dayKey(date)
        if let i = entries.firstIndex(where: { $0.day == day && $0.function == function.rawValue && $0.provider == provider && $0.model == model }) {
            entries[i].add(usage)
        } else {
            var e = UsageEntry(day: day, function: function.rawValue, provider: provider, model: model)
            e.add(usage)
            entries.append(e)
        }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        pendingSave = nil
        try? file.save(entries)
    }
}

enum UsagePeriod: String, CaseIterable, Identifiable {
    case today, week, month, all
    var id: String { rawValue }
    var title: String { L10n.tr("usage.period.\(rawValue)") }
    /// Days covered, counting today; nil = everything recorded.
    var days: Int? {
        switch self {
        case .today: 1
        case .week: 7
        case .month: 30
        case .all: nil
        }
    }
}

/// What the usage page shows for a period (pure, so it can be tested).
struct UsageSummary: Equatable {
    struct Row: Equatable, Identifiable {
        var model: String
        var provider: String
        /// nil when rows are per model only.
        var function: String?
        var requests = 0, input = 0, output = 0, reasoning = 0
        var audioSeconds: Double = 0
        var total: Int { input + output }
        var id: String { "\(provider)|\(model)|\(function ?? "")" }
    }

    var total = Row(model: "", provider: "")
    /// Per model, most tokens first (ties: most requests, then name).
    var byModel: [Row] = []
    /// Per model and function, most tokens first.
    var rows: [Row] = []
    /// Total tokens per day, every day of the period (zero where nothing ran), oldest first.
    var byDay: [(day: String, total: Int)] = []

    static func == (a: UsageSummary, b: UsageSummary) -> Bool {
        a.total == b.total && a.byModel == b.byModel && a.rows == b.rows && a.byDay.map(\.day) == b.byDay.map(\.day)
            && a.byDay.map(\.total) == b.byDay.map(\.total)
    }

    static func make(_ entries: [UsageEntry], period: UsagePeriod, now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let today = calendar.startOfDay(for: now)
        let firstDay: Date = {
            if let n = period.days { return calendar.date(byAdding: .day, value: -(n - 1), to: today) ?? today }
            let earliest = entries.compactMap { day($0.day, calendar) }.min() ?? today
            return min(earliest, today)
        }()
        let firstKey = UsageEntry.dayKey(firstDay, calendar: calendar)
        let picked = entries.filter { $0.day >= firstKey }

        var s = UsageSummary()
        func add(_ e: UsageEntry, to r: inout Row) {
            r.requests += e.requests; r.input += e.input; r.output += e.output; r.reasoning += e.reasoning
            r.audioSeconds += e.audioSeconds
        }
        var models: [String: Row] = [:], detail: [String: Row] = [:]
        for e in picked {
            add(e, to: &s.total)
            add(e, to: &models["\(e.provider)|\(e.model)", default: Row(model: e.model, provider: e.provider)])
            add(e, to: &detail["\(e.provider)|\(e.model)|\(e.function)", default: Row(model: e.model, provider: e.provider, function: e.function)])
        }
        func ranked(_ rows: [Row]) -> [Row] {
            rows.sorted { ($0.total, $0.requests, $1.model) > ($1.total, $1.requests, $0.model) }
        }
        s.byModel = ranked(Array(models.values))
        s.rows = ranked(Array(detail.values))

        var perDay: [String: Int] = [:]
        for e in picked { perDay[e.day, default: 0] += e.total }
        var d = firstDay
        while d <= today {
            let key = UsageEntry.dayKey(d, calendar: calendar)
            s.byDay.append((key, perDay[key] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: d) else { break }
            d = next
        }
        return s
    }

    static func day(_ key: String, _ calendar: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}
