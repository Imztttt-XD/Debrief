import Charts
import SwiftUI

/// 设置 → 用量: token usage per model, from UsageLedger.
struct UsageView: View {
    @ObservedObject var ledger = UsageLedger.shared
    @AppStorage("usagePeriod") private var periodRaw = UsagePeriod.week.rawValue
    @StateObject private var hover = HoverDay()

    /// The day under the pointer in the daily chart (a class rather than @State, see NavigationModel).
    final class HoverDay: ObservableObject { @Published var day: Date? }

    private var period: UsagePeriod { UsagePeriod(rawValue: periodRaw) ?? .week }
    private var summary: UsageSummary { UsageSummary.make(ledger.entries, period: period) }

    var body: some View {
        let s = summary
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SegmentedControl(selection: $periodRaw, options: UsagePeriod.allCases.map { .init(value: $0.rawValue, title: $0.title) })
                    .frame(maxWidth: 420)
                if s.total.requests == 0 {
                    Text(L10n.tr(ledger.entries.isEmpty ? "usage.empty" : "usage.emptyPeriod"))
                        .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
                        .card()
                } else {
                    kpis(s)
                    byModel(s)
                    if period != .today { daily(s) }
                    details(s)
                }
                Text(L10n.tr("usage.note")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Headline numbers

    private func kpis(_ s: UsageSummary) -> some View {
        let tiles: [(String, String, String?)] = [
            (L10n.tr("usage.total"), Self.compact(s.total.total), nil),
            (L10n.tr("usage.input"), Self.compact(s.total.input), nil),
            (L10n.tr("usage.output"), Self.compact(s.total.output),
             s.total.reasoning > 0 ? L10n.tr("usage.reasoningPart", [Self.compact(s.total.reasoning)]) : nil),
            (L10n.tr("usage.requests"), s.total.requests.formatted(), s.total.audioSeconds > 0
                ? L10n.tr("usage.audio", [Self.minutes(s.total.audioSeconds)]) : nil),
        ]
        return HStack(spacing: 12) {
            ForEach(tiles.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text(tiles[i].0).font(.callout).foregroundStyle(.secondary)
                    Text(tiles[i].1).font(.title.weight(.semibold)).monospacedDigit()
                    Text(tiles[i].2 ?? " ").font(.caption).foregroundStyle(.secondary)
                }
                .card(padding: 14)
            }
        }
    }

    // MARK: Per model (ranked bars)

    private func byModel(_ s: UsageSummary) -> some View {
        let maxTotal = max(1, s.byModel.map(\.total).max() ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: L10n.tr("usage.byModel"), icon: "cpu")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(s.byModel) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.model).font(.callout.weight(.medium))
                            Text(row.provider).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Self.compact(row.total)).font(.callout.weight(.semibold)).monospacedDigit()
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.chartTrack)
                                Capsule().fill(Theme.chartBar)
                                    .frame(width: max(6, geo.size.width * CGFloat(row.total) / CGFloat(maxTotal)))
                            }
                        }
                        .frame(height: 8)
                        Text(Self.breakdown(row)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .help(Self.exact(row))
                    .accessibilityElement(children: .combine)
                }
            }
            .card(padding: 16)
        }
    }

    // MARK: Per day (column chart with hover)

    private func daily(_ s: UsageSummary) -> some View {
        let points = s.byDay.compactMap { d in UsageSummary.day(d.day, .current).map { (date: $0, total: d.total) } }
        let selected = hover.day.flatMap { h in points.first { Calendar.current.isDate($0.date, inSameDayAs: h) } }
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: L10n.tr("usage.daily"), icon: "chart.bar")
            Chart {
                ForEach(points, id: \.date) { p in
                    BarMark(x: .value(L10n.tr("usage.day"), p.date, unit: .day), y: .value(L10n.tr("usage.total"), p.total))
                        .foregroundStyle(Theme.chartBar.opacity(selected == nil || selected?.date == p.date ? 1 : 0.45))
                        .cornerRadius(3)
                }
                if let selected {
                    RuleMark(x: .value(L10n.tr("usage.day"), selected.date, unit: .day))
                        .foregroundStyle(Color.secondary.opacity(0.25))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selected.date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(L10n.locale)))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(selected.total.formatted() + " tokens").font(.callout.weight(.semibold)).monospacedDigit()
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                        }
                }
            }
            .chartXSelection(value: $hover.day)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Theme.chartTrack)
                    AxisValueLabel { if let v = value.as(Int.self) { Text(Self.compact(v)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 7)) { _ in
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: true)
                }
            }
            .frame(height: 200)
            .padding(.top, 34)   // room for the hover label above the tallest bar
            .card(padding: 16)
        }
    }

    // MARK: Table

    private func details(_ s: UsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: L10n.tr("usage.details"), icon: "tablecells")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    ForEach(["usage.col.model", "usage.col.function", "usage.requests", "usage.input", "usage.output", "usage.total"], id: \.self) { key in
                        Text(L10n.tr(key)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .gridColumnAlignment(["usage.col.model", "usage.col.function"].contains(key) ? .leading : .trailing)
                    }
                }
                Divider()
                ForEach(s.rows) { r in
                    GridRow {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.model).font(.callout)
                            Text(r.provider).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(r.function.flatMap(AIFunction.init(rawValue:))?.title ?? "—").font(.callout)
                        Text(r.requests.formatted()).monospacedDigit()
                        Text(r.input.formatted()).monospacedDigit()
                        Text(r.output.formatted()).monospacedDigit()
                        Text(r.total.formatted()).monospacedDigit().fontWeight(.semibold)
                    }
                    .font(.callout)
                }
            }
            .card(padding: 16)
        }
    }

    // MARK: Formatting

    /// "1.2万" / "12K": the app's language, compact.
    static func compact(_ n: Int) -> String {
        n.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(L10n.locale))
    }

    static func minutes(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)
            .locale(L10n.locale))
    }

    static func breakdown(_ r: UsageSummary.Row) -> String {
        var parts = [L10n.tr("usage.inputValue", [compact(r.input)]), L10n.tr("usage.outputValue", [compact(r.output)])]
        if r.reasoning > 0 { parts.append(L10n.tr("usage.reasoningPart", [compact(r.reasoning)])) }
        parts.append(L10n.tr("usage.requestsValue", [r.requests.formatted()]))
        return parts.joined(separator: " · ")
    }

    static func exact(_ r: UsageSummary.Row) -> String {
        "\(r.model) — \(r.total.formatted()) tokens (\(r.input.formatted()) + \(r.output.formatted()))"
    }
}
