import AppKit
import SwiftUI

/// The recording page (sidebar → 录音): a big record button in the middle, sources and save
/// location below (side by side when there's room), then the recording history.
struct RecordingView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var store: AppStore
    @ObservedObject var nav: NavigationModel
    @ObservedObject var engine: ReviewEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                RecordHero(recorder: recorder, store: store)

                // Two columns when wide enough, stacked otherwise.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        SourcesCard(recorder: recorder).frame(minWidth: 320)
                        SaveLocationCard(recorder: recorder).frame(minWidth: 260)
                    }
                    VStack(spacing: 16) {
                        SourcesCard(recorder: recorder)
                        SaveLocationCard(recorder: recorder)
                    }
                }

                RecordingHistory(store: store, nav: nav, engine: engine)
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Hero

private struct RecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

private struct RecordHero: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(spacing: 14) {
            Button(action: recorder.toggle) {
                ZStack {
                    if recorder.isRecording {
                        // Ring that breathes with the louder input.
                        Circle()
                            .stroke(Theme.record.opacity(0.35), lineWidth: 6)
                            .frame(width: 128, height: 128)
                            .scaleEffect(1 + CGFloat(max(recorder.systemLevel, recorder.micLevel)) * 0.18)
                            .animation(.easeOut(duration: 0.12), value: recorder.micLevel)
                    }
                    Circle()
                        .fill(recorder.isRecording ? Theme.recordGradient : Theme.brandGradient)
                        .frame(width: 104, height: 104)
                        .shadow(color: (recorder.isRecording ? Theme.record : Theme.accent).opacity(0.35), radius: 14, y: 6)
                    if recorder.isBusy {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: recorder.isRecording ? 34 : 40, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 140, height: 140)
                .contentShape(Circle())
            }
            .buttonStyle(RecordButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .disabled(recorder.isBusy)
            .accessibilityLabel(L10n.tr(recorder.isRecording ? "action.stop" : "action.start"))

            status

            linkInfo
                .font(.callout)
                .multilineTextAlignment(.center)

            if let notice = recorder.notice {
                Text(notice.text)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = recorder.lastRecordingURL, !recorder.isRecording {
                HStack(spacing: 10) {
                    Label(url.lastPathComponent, systemImage: "waveform").lineLimit(1).truncationMode(.middle)
                    Button(L10n.tr("action.play")) { NSWorkspace.shared.open(url) }
                    Button(L10n.tr("action.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .font(.callout)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .card()
    }

    @ViewBuilder private var status: some View {
        switch recorder.phase {
        case .idle:
            Text(L10n.tr("recording.hint.start")).font(.title3.weight(.semibold))
        case .starting:
            Text(L10n.tr("status.starting")).font(.title3.weight(.semibold))
        case .recording(let since):
            VStack(spacing: 2) {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Text(Duration.seconds(max(0, ctx.date.timeIntervalSince(since))).formatted(.time(pattern: .hourMinuteSecond)))
                        .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                }
                HStack(spacing: 6) {
                    Circle().fill(Theme.record).frame(width: 8, height: 8)
                    Text(L10n.tr("status.recording")).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        case .finalizing:
            Text(L10n.tr("status.finalizing")).font(.title3.weight(.semibold))
        }
    }

    @ViewBuilder private var linkInfo: some View {
        let now = Date()
        if recorder.isRecording {
            LabeledContent(L10n.tr("recording.linkedTo")) {
                MenuPicker(title: L10n.tr("recording.linkedTo"), selection: $recorder.linkedInterviewID,
                           options: InterviewText.linkOptions(near: now, store: store))
            }
            .frame(maxWidth: 460)
        } else if let iv = store.interviewCandidates(at: now).first {
            Label(L10n.tr("recording.willLink", [store.label(for: iv)]), systemImage: "link")
                .foregroundStyle(Theme.accent)
        } else {
            Text(L10n.tr("recording.noMatch")).foregroundStyle(.secondary)
                .frame(maxWidth: 460)
        }
    }
}

// MARK: - Cards

private struct SourcesCard: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: L10n.tr("section.sources"), icon: "slider.horizontal.3")
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $recorder.captureSystemAudio) {
                    Label(L10n.tr("source.system"), systemImage: "speaker.wave.2")
                }
                .toggleStyle(.brandCheckbox)
                LevelMeter(level: recorder.systemLevel)
                Divider()
                Toggle(isOn: $recorder.captureMicrophone) {
                    Label(L10n.tr("source.microphone"), systemImage: "mic")
                }
                .toggleStyle(.brandCheckbox)
                LabeledContent(L10n.tr("source.input")) {
                    MenuPicker(title: L10n.tr("source.input"), selection: $recorder.microphoneID,
                               options: [.init(value: "", title: L10n.tr("source.systemDefault"))]
                                   + recorder.microphones.map { .init(value: $0.id, title: $0.name) })
                }
                .disabled(!recorder.captureMicrophone)
                HStack {
                    Text(L10n.tr("source.micVolume")).lineLimit(1)
                    BrandSlider(value: $recorder.microphoneVolume, range: 0...2, label: L10n.tr("source.micVolume"))
                    Text("\(Int(recorder.microphoneVolume * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .disabled(!recorder.captureMicrophone)
                LevelMeter(level: recorder.micLevel)
            }
            .card()
            .disabled(recorder.isRecording || recorder.isBusy)
        }
    }
}

private struct SaveLocationCard: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: L10n.tr("section.saveTo"), icon: "folder")
            VStack(alignment: .leading, spacing: 10) {
                Text(recorder.outputDirectory.path(percentEncoded: false))
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled)
                HStack {
                    Button(L10n.tr("action.choose")) { recorder.chooseOutputFolder() }
                        .disabled(recorder.isRecording || recorder.isBusy)
                    Button(L10n.tr("action.open")) { recorder.openOutputFolder() }
                }
            }
            .card()
        }
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(level > 0.9 ? AnyShapeStyle(Theme.record) : AnyShapeStyle(Theme.brandGradient))
                    .frame(width: max(0, geo.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
        .accessibilityLabel(L10n.tr("a11y.inputLevel"))
        .accessibilityValue(L10n.tr("a11y.percent", [String(Int(level * 100))]))
    }
}

// MARK: - History

/// Saved recordings with their interview link, which can be changed afterwards.
private struct RecordingHistory: View {
    @ObservedObject var store: AppStore
    @ObservedObject var nav: NavigationModel
    @ObservedObject var engine: ReviewEngine

    var body: some View {
        let items = Array(store.recordings.sorted { $0.startedAt > $1.startedAt }.prefix(30))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: L10n.tr("recording.history"), icon: "clock.arrow.circlepath")
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { rec in
                        RecordingRow(record: rec, store: store, isReviewing: engine.isRunning(rec.id)) {
                            nav.selectedRecordingID = rec.id
                            nav.section = .review
                        }
                        .padding(.vertical, 10)
                        if rec.id != items.last?.id { Divider() }
                    }
                }
                .card(padding: 12)
            }
        }
    }
}

private struct RecordingRow: View {
    let record: RecordingRecord
    @ObservedObject var store: AppStore
    /// Can't be deleted while its review is running.
    let isReviewing: Bool
    let onReview: () -> Void

    private var link: Binding<UUID?> {
        Binding(get: { store.recordings.first { $0.id == record.id }?.interviewID },
                set: { store.link(recording: record.id, to: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Wraps the buttons under the date when the row is narrow.
            ViewThatFits(in: .horizontal) {
                HStack { info; Spacer(minLength: 12); actions }
                VStack(alignment: .leading, spacing: 6) { info; actions }
            }
            LabeledContent(L10n.tr("recording.linkedTo")) {
                MenuPicker(title: L10n.tr("recording.linkedTo"), selection: link,
                           options: InterviewText.linkOptions(near: record.startedAt, store: store))
            }
            .controlSize(.small)
        }
    }

    private var info: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").foregroundStyle(Theme.accent)
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
            Text(Duration.seconds(record.duration).formatted(.time(pattern: .hourMinuteSecond)))
                .monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(L10n.tr("nav.review"), action: onReview).buttonStyle(.brand)
            Button(L10n.tr("action.play")) { NSWorkspace.shared.open(record.fileURL) }
            Button(L10n.tr("action.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([record.fileURL]) }
            Button { RecordingDeletion.deleteRecording(record, store: store) } label: { Image(systemName: "trash") }
                .disabled(isReviewing)
                .help(L10n.tr(isReviewing ? "recording.delete.busy" : "recording.delete"))
                .accessibilityLabel(L10n.tr("recording.delete"))
        }
        .controlSize(.small)
    }
}

enum InterviewText {
    /// "11月18日 14:00 · 字节跳动 · 后端开发 · 一面"
    /// "未关联" plus the interviews nearest to `date`, for the link pickers.
    @MainActor static func linkOptions(near date: Date, store: AppStore) -> [MenuPicker<UUID?>.Option] {
        [.init(value: nil, title: L10n.tr("recording.unlinked"))]
            + store.interviewsNear(date).map { .init(value: $0.id, title: pickerLabel($0, store: store)) }
    }

    @MainActor static func pickerLabel(_ iv: Interview, store: AppStore) -> String {
        iv.start.formatted(.dateTime.month().day().hour().minute()) + " · " + store.label(for: iv)
    }
}
