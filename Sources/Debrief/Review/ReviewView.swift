import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Plays the recording so any line or question can be heard from its timestamp.
@MainActor
final class AudioPlayerModel: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var url: URL?
    private var player: AVPlayer?
    private var observer: Any?

    func load(_ url: URL) {
        guard url != self.url else { return }
        stop()
        self.url = url
        let player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.currentTime = t.seconds
                self?.isPlaying = (self?.player?.rate ?? 0) > 0
            }
        }
        self.player = player
    }

    func play(from seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds - 0.3), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
    }

    func toggle() {
        guard let player else { return }
        if player.rate > 0 { player.pause(); isPlaying = false } else { player.play(); isPlaying = true }
    }

    func stop() {
        if let observer, let player { player.removeTimeObserver(observer) }
        player?.pause()
        player = nil
        observer = nil
        url = nil
        isPlaying = false
        currentTime = 0
    }
}

/// 复盘: recordings on the left, the selected recording's review on the right.
/// Imports audio / video files as recordings (see RecordingImporter), several at once.
@MainActor
final class ImportState: ObservableObject {
    @Published private(set) var inProgress = 0
    @Published var error: String?

    func run(_ urls: [URL], into folder: URL, store: AppStore, nav: NavigationModel) {
        for url in urls {
            inProgress += 1
            Task {
                defer { inProgress -= 1 }
                do {
                    var record = try await RecordingImporter.importFile(url, into: folder)
                    record.interviewID = store.interviewCandidates(at: record.startedAt).first?.id
                    store.add(record)
                    nav.selectedRecordingID = record.id
                    error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func pick(into folder: URL, store: AppStore, nav: NavigationModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = RecordingImporter.allowedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L10n.tr("import.panelMessage")
        guard panel.runModal() == .OK else { return }
        run(panel.urls, into: folder, store: store, nav: nav)
    }
}

struct ReviewView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var engine: ReviewEngine
    @ObservedObject var nav: NavigationModel
    /// Where imported files are copied: the recordings folder.
    let recordingsFolder: URL
    @StateObject private var player = AudioPlayerModel()
    @StateObject private var importer = ImportState()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button { importer.pick(into: recordingsFolder, store: store, nav: nav) } label: {
                            Label(L10n.tr("import.button"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                        }
                        if importer.inProgress > 0 { ProgressView().controlSize(.small) }
                    }
                    if let error = importer.error {
                        Text(error).font(.caption).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                Divider()
                recordingList
            }
            .frame(minWidth: 210, idealWidth: 260, maxWidth: 340)
            // Drop audio or video files anywhere on the list to import them.
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter { url in
                    let type = UTType(filenameExtension: url.pathExtension)
                    return RecordingImporter.allowedTypes.contains { type?.conforms(to: $0) == true }
                }
                guard !files.isEmpty else { return false }
                importer.run(files, into: recordingsFolder, store: store, nav: nav)
                return true
            }

            detailPane
        }
        .onAppear {
            // Coming back to this page: keep a recording selected.
            if !store.recordings.contains(where: { $0.id == nav.selectedRecordingID }) {
                nav.selectedRecordingID = store.recordings.max { $0.startedAt < $1.startedAt }?.id
            }
        }
        .onDisappear { player.stop() }
    }

    private var recordingList: some View {
            List {
                ForEach(store.recordings.sorted { $0.startedAt > $1.startedAt }) { rec in
                    RecordingListRow(record: rec, store: store, engine: engine)
                        .selectableRow(nav.selectedRecordingID == rec.id) { nav.selectedRecordingID = rec.id }
                        .contextMenu { deleteMenuItems(rec) }
                }
            }
            .listStyle(.inset)
            .overlay {
                if store.recordings.isEmpty {
                    Text(L10n.tr("review.noRecordings")).foregroundStyle(.secondary).padding()
                        .multilineTextAlignment(.center)
                }
            }
    }

    private var detailPane: some View {
            Group {
                if let id = nav.selectedRecordingID, let record = store.recordings.first(where: { $0.id == id }) {
                    ReviewDetail(record: record, store: store, engine: engine, player: player,
                                 deleteMenu: AnyView(deleteMenuItems(record)))
                        .id(id)
                } else {
                    Text(L10n.tr("review.select")).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shared by the list's right-click menu and the detail header's delete menu.
    @ViewBuilder private func deleteMenuItems(_ record: RecordingRecord) -> some View {
        let busy = engine.isRunning(record.id)
        Button(L10n.tr("review.delete")) {
            RecordingDeletion.deleteReview(record, store: store)
        }
        .disabled(busy || store.review(for: record.id) == nil)
        Button(L10n.tr("recording.delete"), role: .destructive) {
            if nav.selectedRecordingID == record.id { player.stop() }
            guard RecordingDeletion.deleteRecording(record, store: store) else { return }
            if nav.selectedRecordingID == record.id {
                nav.selectedRecordingID = store.recordings.max { $0.startedAt < $1.startedAt }?.id
            }
        }
        .disabled(busy)
        if busy {
            Text(L10n.tr("recording.delete.busy"))
        }
    }
}

enum ReviewText {
    @MainActor static func title(_ record: RecordingRecord, store: AppStore) -> String {
        store.interview(record.interviewID).map { store.label(for: $0) } ?? L10n.tr("review.unlinkedTitle")
    }

    static func clock(_ s: Double) -> String { ReviewAnalyzer.clock(s) }
}

private struct RecordingListRow: View {
    let record: RecordingRecord
    @ObservedObject var store: AppStore
    @ObservedObject var engine: ReviewEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ReviewText.title(record, store: store)).font(.headline).lineLimit(1)
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + ReviewText.clock(record.duration))
                .font(.caption).foregroundStyle(.secondary)
            status.font(.caption)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var status: some View {
        if let phase = engine.running[record.id] {
            Label(phase.text, systemImage: "hourglass").foregroundStyle(Theme.warning)
        } else if let review = store.review(for: record.id) {
            if review.lastError != nil {
                Label(L10n.tr("review.status.failed"), systemImage: "exclamationmark.triangle").foregroundStyle(Theme.danger)
            } else if review.isAnalyzed {
                Label(L10n.tr("review.status.done"), systemImage: "checkmark.circle").foregroundStyle(Theme.success)
            } else if review.isTranscribed {
                Label(L10n.tr("review.status.transcribed"), systemImage: "text.alignleft").foregroundStyle(.secondary)
            } else {
                Text(L10n.tr("review.status.none")).foregroundStyle(.secondary)
            }
        } else {
            Text(L10n.tr("review.status.none")).foregroundStyle(.secondary)
        }
    }
}

/// Short-lived "已复制 / 已保存" message next to the export menu.
@MainActor
final class ExportFeedback: ObservableObject {
    @Published var message: String?
    private var clear: Task<Void, Never>?

    func show(_ text: String) {
        message = text
        clear?.cancel()
        clear = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.message = nil }
        }
    }
}

private struct ReviewDetail: View {
    let record: RecordingRecord
    @ObservedObject var store: AppStore
    @ObservedObject var engine: ReviewEngine
    @ObservedObject var player: AudioPlayerModel
    /// 删除复盘记录 / 删除录音, from ReviewView.
    let deleteMenu: AnyView
    @AppStorage("reviewTab") private var tab = "questions"
    @StateObject private var feedback = ExportFeedback()

    private func export(_ review: Review, scope: ReviewExporter.Scope) -> String {
        ReviewExporter.markdown(review: review, title: ReviewText.title(record, store: store), scope: scope)
    }

    @ViewBuilder private func exportMenu(_ review: Review) -> some View {
        if let message = feedback.message {
            Label(message, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(Theme.success)
        }
        let projectCount = ReviewExporter.questions(in: review, scope: .projects).count
        Menu(L10n.tr("export.menu")) {
            Button(L10n.tr("export.copyProject", [String(projectCount)])) {
                ReviewExporter.copy(export(review, scope: .projects))
                feedback.show(L10n.tr("export.copied"))
            }
            .disabled(projectCount == 0)
            Button(L10n.tr("export.saveFile")) {
                do {
                    if let url = try ReviewExporter.save(export(review, scope: .projects),
                                                         suggestedName: ReviewExporter.fileName(title: ReviewText.title(record, store: store))) {
                        feedback.show(L10n.tr("export.saved", [url.lastPathComponent]))
                    }
                } catch {
                    feedback.show(error.localizedDescription)
                }
            }
            .disabled(projectCount == 0)
            Divider()
            Button(L10n.tr("export.copyAll", [String(review.questions.count)])) {
                ReviewExporter.copy(export(review, scope: .all))
                feedback.show(L10n.tr("export.copied"))
            }
        }
        .menuStyle(.button).buttonStyle(.menuField)
        .fixedSize()
        .help(L10n.tr("export.help"))
    }

    var body: some View {
        let review = store.review(for: record.id)
        VStack(spacing: 0) {
            header(review)
            Divider()
            if let review, review.isTranscribed, let binding = store.reviewBinding(record.id) {
                SegmentedControl(selection: $tab, options: [
                    .init(value: "questions", title: L10n.tr("review.tab.questions")),
                    .init(value: "transcript", title: L10n.tr("review.tab.transcript")),
                    .init(value: "summary", title: L10n.tr("review.tab.summary")),
                ])
                .frame(maxWidth: 360).padding(10)
                switch tab {
                case "transcript": TranscriptTab(review: binding, player: player)
                case "summary": SummaryTab(review: binding)
                default: QuestionsTab(review: binding, player: player)
                }
            } else {
                StartPanel(record: record, store: store, engine: engine)
            }
            Divider()
            PlayerBar(player: player, duration: record.duration)
        }
        .onAppear { player.load(record.fileURL) }
    }

    @ViewBuilder private func header(_ review: Review?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(ReviewText.title(record, store: store))
                        .font(.title3.bold())
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(record.startedAt.formatted(date: .long, time: .shortened) + " · " + ReviewText.clock(record.duration))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Menu { deleteMenu } label: { Image(systemName: "trash") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help(L10n.tr("action.delete"))
                    .accessibilityLabel(L10n.tr("action.delete"))
            }
            if let phase = engine.running[record.id] {
                HStack(spacing: 10) {
                    if let f = phase.fraction { BrandProgressBar(value: f).frame(maxWidth: 160) } else { ProgressView().controlSize(.small) }
                    Text(phase.text).font(.callout).foregroundStyle(.secondary)
                    Button(L10n.tr("action.cancel")) { engine.cancel(record.id) }
                }
            } else if let review, review.isTranscribed {
                HStack(spacing: 10) {
                    if !review.isAnalyzed {
                        Button(L10n.tr("review.continue")) { engine.start(record.id) }.buttonStyle(.brand)
                    }
                    if !review.questions.isEmpty { exportMenu(review) }
                    Menu(L10n.tr("review.redo")) {
                        Button(L10n.tr("review.reanalyze")) { engine.reanalyze(record.id) }
                        Button(L10n.tr("review.retranscribe")) { engine.retranscribe(record.id) }
                    }
                    .menuStyle(.button).buttonStyle(.menuField)
                    .fixedSize()
                }
            }
            if let review, review.isTranscribed, !review.transcript.contains(where: { $0.speaker == .interviewer }) {
                Label(L10n.tr("review.noSystemAudio"), systemImage: "speaker.slash").font(.callout).foregroundStyle(.secondary)
            }
            if let review, review.speakersEstimated == true, engine.running[record.id] == nil {
                HStack(spacing: 10) {
                    Label(L10n.tr("speakers.estimated"), systemImage: "person.2.wave.2").font(.callout).foregroundStyle(.secondary)
                    Button(L10n.tr("speakers.swap")) {
                        store.updateReview(record.id) {
                            $0.transcript = SpeakerSeparation.swapped($0.transcript)
                            $0.transcriptEdited = true
                        }
                    }
                    .controlSize(.small)
                }
            }
            if let review, review.transcriptEdited, engine.running[record.id] == nil {
                Label(L10n.tr("review.editedHint"), systemImage: "pencil").font(.callout).foregroundStyle(Theme.warning)
            }
            if let error = review?.lastError, engine.running[record.id] == nil {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
            }
            if let review, review.isTranscribed, let tm = review.transcriptModel {
                Text(L10n.tr("review.models", [tm, review.analysisModel ?? "—"])).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown before there's a transcript: what will happen, and the start button.
private struct StartPanel: View {
    let record: RecordingRecord
    @ObservedObject var store: AppStore
    @ObservedObject var engine: ReviewEngine

    var body: some View {
        let ai = store.ai
        let asr = ai.assignment(for: .transcription), llm = ai.assignment(for: .review)
        VStack(spacing: 14) {
            Image(systemName: "text.bubble").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(L10n.tr("review.start.title")).font(.title3.bold())
            Text(L10n.tr("review.start.detail", [
                ReviewText.clock(record.duration),
                ai.usesLocalTranscription ? L10n.tr("local.title") : (ai.account(asr.accountID)?.name ?? "—") + " / " + asr.model,
                (ai.account(llm.accountID)?.name ?? "—") + " / " + llm.model,
            ]))
            .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            // Imported recordings especially may need linking by hand.
            LabeledContent(L10n.tr("recording.linkedTo")) {
                MenuPicker(title: L10n.tr("recording.linkedTo"),
                           selection: Binding(get: { store.recordings.first { $0.id == record.id }?.interviewID },
                                              set: { store.link(recording: record.id, to: $0) }),
                           options: InterviewText.linkOptions(near: record.startedAt, store: store))
            }
            .frame(maxWidth: 460)
            if record.interviewID == nil {
                Label(L10n.tr("review.start.unlinked"), systemImage: "link.badge.plus").font(.callout).foregroundStyle(Theme.warning)
            }
            if record.tracksFileURL == nil || record.tracks.isEmpty {
                // Single track: say what will happen to the speakers, given the 实验功能 switch.
                let separation = UserDefaults.standard.bool(forKey: ReviewEngine.speakerSeparationKey)
                if separation && SpeakerSeparation.isReady {
                    Label(L10n.tr("review.start.willSeparate"), systemImage: "person.2.wave.2").font(.callout).foregroundStyle(Theme.accent)
                        .multilineTextAlignment(.center).frame(maxWidth: 460)
                } else {
                    Label(L10n.tr(separation ? "review.start.separationNotReady" : "review.start.noTracks"), systemImage: "person.2.slash")
                        .font(.callout).foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.center).frame(maxWidth: 460)
                }
            }
            if let saved = store.review(for: record.id)?.transcriptCache?.count, saved > 0, !engine.isRunning(record.id) {
                Label(L10n.tr("review.start.resume", [String(saved)]), systemImage: "arrow.clockwise").font(.callout)
                    .foregroundStyle(Theme.accent)
            }
            if engine.isRunning(record.id) {
                ProgressView()
            } else {
                Button(L10n.tr("review.start")) { engine.start(record.id) }
                    .buttonStyle(.brand).controlSize(.large)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Tabs

struct TimeButton: View {
    let seconds: Double?
    @ObservedObject var player: AudioPlayerModel

    var body: some View {
        if let seconds {
            Button { player.play(from: seconds) } label: {
                Label(ReviewText.clock(seconds), systemImage: "play.fill").font(.caption.monospacedDigit())
            }
            .buttonStyle(.borderless)
            .help(L10n.tr("review.playFrom"))
        }
    }
}

private struct QuestionsTab: View {
    @Binding var review: Review
    @ObservedObject var player: AudioPlayerModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if review.questions.isEmpty {
                    Text(L10n.tr("review.noQuestionsYet")).foregroundStyle(.secondary).padding()
                }
                ForEach($review.questions) { $q in
                    QuestionCard(index: (review.questions.firstIndex { $0.id == q.id } ?? 0) + 1, question: $q, player: player)
                }
            }
            .padding(18)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
    }
}

struct QuestionCard: View {
    let index: Int
    @Binding var question: ReviewQuestion
    @ObservedObject var player: AudioPlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Q\(index)")
                        .font(.system(.headline, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.brandGradient))
                    Pill(text: question.categoryTitle, color: Theme.accent)
                    if let item = question.resumeItem { Pill(text: item, color: Theme.neutral) }
                    Spacer()
                    TimeButton(seconds: question.start, player: player)
                }
                Text(question.question).font(.headline).textSelection(.enabled)
                ForEach(question.followUps) { f in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.question).font(.callout.weight(.medium))
                            if !f.answer.isEmpty { Text(f.answer).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                        }
                        Spacer()
                        TimeButton(seconds: f.start, player: player)
                    }
                }
                DisclosureGroup(L10n.tr("review.myAnswer")) {
                    Text(question.answer.isEmpty ? L10n.tr("review.noAnswer") : question.answer)
                        .font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let critique = Binding($question.critique) {
                    CritiqueView(critique: critique)
                } else {
                    Text(L10n.tr("review.noCritique")).font(.caption).foregroundStyle(.secondary)
                }
        }
        .card(padding: 16)
    }
}

struct CritiqueView: View {
    @Binding var critique: Critique

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Score(title: L10n.tr("review.score.accuracy"), value: critique.accuracy)
                Score(title: L10n.tr("review.score.structure"), value: critique.structure)
                Score(title: L10n.tr("review.score.depth"), value: critique.depth)
            }
            if !critique.corrections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(L10n.tr("review.corrections"), systemImage: "exclamationmark.bubble").font(.subheadline.bold()).foregroundStyle(Theme.danger)
                    ForEach($critique.corrections) { $c in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("“\(c.claim)”").font(.callout).strikethrough(c.disputed == false, color: Theme.danger.opacity(0.6))
                            Text(c.issue).font(.callout)
                            if !c.correct.isEmpty { Text(L10n.tr("review.correctIs", [c.correct])).font(.callout).foregroundStyle(Theme.success) }
                            Toggle(L10n.tr("review.dispute"), isOn: $c.disputed).toggleStyle(.brandCheckbox).font(.caption)
                        }
                        .opacity(c.disputed ? 0.5 : 1)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.danger.opacity(0.06)))
                    }
                    Text(L10n.tr("review.verifyNote")).font(.caption).foregroundStyle(.secondary)
                }
            }
            BulletList(title: L10n.tr("review.strengths"), icon: "hand.thumbsup", color: Theme.success, items: critique.strengths)
            BulletList(title: L10n.tr("review.improvements"), icon: "arrow.up.right", color: Theme.warning, items: critique.improvements)
            if !critique.betterAnswer.isEmpty {
                DisclosureGroup(L10n.tr("review.betterAnswer")) {
                    Text(critique.betterAnswer).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            }
        }
    }
}

struct Score: View {
    let title: String
    let value: Int
    var body: some View {
        let color: Color = value >= 4 ? Theme.success : (value == 3 ? Theme.warning : Theme.danger)
        Text("\(title) \(value)/5")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color)
    }
}

private struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption).padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.12))).foregroundStyle(color)
    }
}

struct BulletList: View {
    let title: String
    let icon: String
    let color: Color
    let items: [String]
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon).font(.subheadline.bold()).foregroundStyle(color)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• " + item).font(.callout).textSelection(.enabled)
                }
            }
        }
    }
}

private struct TranscriptTab: View {
    @Binding var review: Review
    @ObservedObject var player: AudioPlayerModel

    var body: some View {
        List {
            ForEach($review.transcript) { $u in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TimeButton(seconds: u.start, player: player).frame(width: 70, alignment: .leading)
                    Menu(u.speaker.title) {
                        ForEach(Utterance.Speaker.allCases) { s in
                            Button(s.title) { u.speaker = s; review.transcriptEdited = true }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .foregroundStyle(u.speaker == .interviewer ? Theme.accent : (u.speaker == .me ? Theme.blue : Color.secondary))
                    TextField("", text: Binding(get: { u.text }, set: { u.text = $0; review.transcriptEdited = true }),
                              axis: .vertical)
                        .textFieldStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct SummaryTab: View {
    @Binding var review: Review

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let s = review.summary {
                    Text(s.overall).font(.body).textSelection(.enabled)
                    BulletList(title: L10n.tr("review.strengths"), icon: "hand.thumbsup", color: Theme.success, items: s.strengths)
                    BulletList(title: L10n.tr("review.improvements"), icon: "arrow.up.right", color: Theme.warning, items: s.improvements)
                    BulletList(title: L10n.tr("review.actionItems"), icon: "checklist", color: Theme.accent, items: s.actionItems)
                    if !s.interviewerStyle.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L10n.tr("review.interviewerStyle"), systemImage: "person.bubble").font(.subheadline.bold())
                            Text(s.interviewerStyle).font(.callout).textSelection(.enabled)
                        }
                    }
                } else {
                    Text(L10n.tr("review.noSummaryYet")).foregroundStyle(.secondary)
                }
                Divider()
                Text(L10n.tr("review.myNotes")).font(.subheadline.bold())
                TextEditor(text: $review.myNotes)
                    .font(.body).frame(minHeight: 120)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .accessibilityLabel(L10n.tr("review.myNotes"))
                Text(L10n.tr("review.myNotes.hint")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

private struct PlayerBar: View {
    @ObservedObject var player: AudioPlayerModel
    let duration: Double

    var body: some View {
        HStack(spacing: 10) {
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.tr(player.isPlaying ? "review.pause" : "review.play"))
            Text("\(ReviewText.clock(player.currentTime)) / \(ReviewText.clock(duration))")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            BrandProgressBar(value: duration > 0 ? min(1, player.currentTime / duration) : 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}
