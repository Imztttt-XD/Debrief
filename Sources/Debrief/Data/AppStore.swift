import AppKit
import PDFKit
import SwiftUI

/// All user data except recordings: applications, resumes, profile, AI settings.
/// Each collection is its own JSON file, saved shortly after it changes.
@MainActor
final class AppStore: ObservableObject {
    @Published var applications: [JobApplication] { didSet { scheduleSave(.applications) } }
    @Published var resumes: [Resume] { didSet { scheduleSave(.resumes) } }
    @Published var profile: Profile { didSet { scheduleSave(.profile) } }
    @Published var ai: AISettings { didSet { scheduleSave(.ai) } }
    @Published var interviews: [Interview] { didSet { scheduleSave(.interviews); onInterviewsChanged?() } }
    @Published var recordings: [RecordingRecord] { didSet { scheduleSave(.recordings) } }
    @Published var bank: QuestionBank { didSet { scheduleSave(.bank) } }
    /// Keyed by session id; saved per session like reviews.
    @Published private(set) var mocks: [UUID: MockSession] = [:]
    private var pendingMockSaves: [UUID: Task<Void, Never>] = [:]
    /// Set by AppDelegate to resync reminders.
    var onInterviewsChanged: (() -> Void)?
    /// Keyed by recording id. Saved per review, not as one big file.
    @Published private(set) var reviews: [UUID: Review] = [:]
    private var pendingReviewSaves: [UUID: Task<Void, Never>] = [:]
    /// Shown as a banner in the main window if writing to disk fails.
    @Published var saveError: String?

    private enum Collection: CaseIterable { case applications, resumes, profile, ai, interviews, recordings, bank }

    private let applicationsFile = JSONFile<[JobApplication]>("applications.json")
    private let resumesFile = JSONFile<[Resume]>("resumes.json")
    private let profileFile = JSONFile<Profile>("profile.json")
    private let aiFile = JSONFile<AISettings>("ai-settings.json")
    private let interviewsFile = JSONFile<[Interview]>("interviews.json")
    private let recordingsFile = JSONFile<[RecordingRecord]>("recordings.json")
    private let bankFile = JSONFile<QuestionBank>("question-bank.json")
    private var pendingSaves: [Collection: Task<Void, Never>] = [:]

    init() {
        applications = applicationsFile.load() ?? []
        resumes = resumesFile.load() ?? []
        profile = profileFile.load() ?? Profile()
        ai = aiFile.load() ?? .defaults
        interviews = interviewsFile.load() ?? []
        recordings = recordingsFile.load() ?? []
        bank = bankFile.load() ?? QuestionBank()
        let mockFiles = (try? FileManager.default.contentsOfDirectory(at: AppPaths.mocks, includingPropertiesForKeys: nil)) ?? []
        for url in mockFiles where url.pathExtension == "json" {
            if let session = JSONFile<MockSession>(url: url).load() { mocks[session.id] = session }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.reviews, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" {
            let file = JSONFile<Review>(reviewsSubpath: url.lastPathComponent)
            if let review = file.load() { reviews[review.recordingID] = review }
        }
    }

    // MARK: Saving

    /// Debounced so typing in a long text field doesn't rewrite the file on every keystroke.
    private func scheduleSave(_ c: Collection) {
        pendingSaves[c]?.cancel()
        pendingSaves[c] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save(c)
        }
    }

    /// Writes everything that's pending. Called on quit.
    func flush() {
        for c in Collection.allCases where pendingSaves[c] != nil {
            pendingSaves[c]?.cancel()
            save(c)
        }
        for id in pendingReviewSaves.keys {
            pendingReviewSaves[id]?.cancel()
            saveReview(id)
        }
        for id in pendingMockSaves.keys {
            pendingMockSaves[id]?.cancel()
            saveMock(id)
        }
    }

    // MARK: Mock interviews

    var sortedMocks: [MockSession] { mocks.values.sorted { $0.createdAt > $1.createdAt } }

    func updateMock(_ id: UUID, _ change: (inout MockSession) -> Void) {
        guard var session = mocks[id] else { return }
        change(&session)
        session.updatedAt = Date()
        mocks[id] = session
        pendingMockSaves[id]?.cancel()
        pendingMockSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveMock(id)
        }
    }

    func addMock(_ session: MockSession) {
        mocks[session.id] = session
        saveMock(session.id)
    }

    /// Also takes its questions back out of the question bank (see QuestionBank.removeContributions).
    func deleteMock(_ id: UUID) {
        if bank.ingestedMocks.contains(id), let session = mocks[id] {
            bank.removeContributions(of: id, questions: session.questions, kind: .mock, date: session.createdAt)
            bank.ingestedMocks.removeAll { $0 == id }
        }
        pendingMockSaves[id]?.cancel()
        mocks[id] = nil
        try? FileManager.default.removeItem(at: AppPaths.mocks.appendingPathComponent("\(id.uuidString).json"))
    }

    /// "字节跳动 · 后端开发" or "模拟面试" when it isn't tied to an application.
    func title(for session: MockSession) -> String {
        guard let app = application(session.applicationID) else { return L10n.tr("mock.generalTitle") }
        return "\(app.displayCompany) · \(app.displayRole)"
    }

    private func saveMock(_ id: UUID) {
        pendingMockSaves[id] = nil
        guard let session = mocks[id] else { return }
        do {
            try JSONFile<MockSession>(url: AppPaths.mocks.appendingPathComponent("\(id.uuidString).json")).save(session)
        } catch {
            saveError = L10n.tr("error.save", [error.localizedDescription])
        }
    }

    // MARK: Question bank

    /// Adds critiqued questions to the bank (merge rules: QuestionBank.merge in Bank/BankMerge.swift).
    func ingest(_ questions: [ReviewQuestion], source: BankQuestion.Source, applicationID: UUID?, at date: Date,
                sourceID: UUID? = nil) {
        let app = application(applicationID)
        bank.merge(questions, source: source, applicationID: applicationID,
                   company: app?.company ?? "", role: app?.role ?? "", at: date, sourceID: sourceID)
    }

    /// Adds a finished review's questions once.
    func ingestReview(_ recordingID: UUID) {
        guard !bank.ingestedReviews.contains(recordingID), let review = reviews[recordingID], review.isAnalyzed,
              let record = recordings.first(where: { $0.id == recordingID }) else { return }
        ingest(review.questions, source: .interview, applicationID: interview(record.interviewID)?.applicationID,
               at: record.startedAt, sourceID: recordingID)
        bank.ingestedReviews.append(recordingID)
    }

    func ingestMock(_ id: UUID) {
        guard !bank.ingestedMocks.contains(id), let session = mocks[id], session.summary != nil else { return }
        ingest(session.questions, source: .mock, applicationID: session.applicationID, at: session.createdAt,
               sourceID: id)
        bank.ingestedMocks.append(id)
    }

    /// At launch: pick up reviews finished before the bank existed (or while it failed to save).
    func ingestPendingReviews() {
        for id in reviews.keys { ingestReview(id) }
    }

    /// Real questions to seed a mock interview: same application first, then same company,
    /// then ones about items on the chosen resume, then ones I still need to review.
    func seedQuestions(for applicationID: UUID?, resumeText: String, limit: Int = 25) -> [BankQuestion] {
        let app = application(applicationID)
        func rank(_ q: BankQuestion) -> Int {
            if applicationID != nil && q.applicationID == applicationID { return 0 }
            if let c = app?.company, !c.isEmpty, q.company == c { return 1 }
            if let item = q.resumeItem, !item.isEmpty, resumeText.contains(item) { return 2 }
            if q.mastery != .mastered { return 3 }
            return 4
        }
        return Array(bank.items.sorted { (rank($0), -$0.timesAsked) < (rank($1), -$1.timesAsked) }.prefix(limit))
    }

    // MARK: Reviews

    func review(for recordingID: UUID) -> Review? { reviews[recordingID] }

    func ensureReview(for recordingID: UUID) {
        if reviews[recordingID] == nil {
            reviews[recordingID] = Review(recordingID: recordingID)
            scheduleReviewSave(recordingID)
        }
    }

    func updateReview(_ recordingID: UUID, _ change: (inout Review) -> Void) {
        var review = reviews[recordingID] ?? Review(recordingID: recordingID)
        change(&review)
        review.updatedAt = Date()
        reviews[recordingID] = review
        scheduleReviewSave(recordingID)
    }

    func reviewBinding(_ recordingID: UUID) -> Binding<Review>? {
        guard reviews[recordingID] != nil else { return nil }
        return Binding(get: { [weak self] in self?.reviews[recordingID] ?? Review(recordingID: recordingID) },
                       set: { [weak self] new in self?.updateReview(recordingID) { $0 = new } })
    }

    /// Removes the transcript and analysis of a recording; the recording itself stays and can
    /// be reviewed again. The questions this review added to the bank are taken back out
    /// (QuestionBank.removeContributions), and it leaves `ingestedReviews`, so reviewing it again
    /// adds them again.
    func deleteReview(_ recordingID: UUID) {
        if bank.ingestedReviews.contains(recordingID), let review = reviews[recordingID] {
            let date = recordings.first { $0.id == recordingID }?.startedAt ?? review.createdAt
            bank.removeContributions(of: recordingID, questions: review.questions, kind: .interview, date: date)
            bank.ingestedReviews.removeAll { $0 == recordingID }
        }
        pendingReviewSaves[recordingID]?.cancel()
        pendingReviewSaves[recordingID] = nil
        reviews[recordingID] = nil
        try? FileManager.default.removeItem(at: AppPaths.reviews.appendingPathComponent("\(recordingID.uuidString).json"))
    }

    /// Moves the recording's audio files to the Trash (so a mistake can be undone in Finder)
    /// and removes it and its review from the app. Files already gone are skipped; if one
    /// can't be moved, the recording stays in the app and the error is thrown.
    /// Returns where the files went in the Trash.
    @discardableResult
    func deleteRecording(_ id: UUID) throws -> [URL] {
        guard let record = recordings.first(where: { $0.id == id }) else { return [] }
        let files = [record.fileURL, record.tracksFileURL].compactMap { $0 }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        var trashed: [URL] = []
        for url in files {
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            if let result { trashed.append(result as URL) }
        }
        deleteReview(id)
        recordings.removeAll { $0.id == id }
        return trashed
    }

    private func scheduleReviewSave(_ id: UUID) {
        pendingReviewSaves[id]?.cancel()
        pendingReviewSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveReview(id)
        }
    }

    private func saveReview(_ id: UUID) {
        pendingReviewSaves[id] = nil
        guard let review = reviews[id] else { return }
        do {
            try JSONFile<Review>(reviewsSubpath: "\(id.uuidString).json").save(review)
        } catch {
            saveError = L10n.tr("error.save", [error.localizedDescription])
        }
    }

    private func save(_ c: Collection) {
        pendingSaves[c] = nil
        do {
            switch c {
            case .applications: try applicationsFile.save(applications)
            case .resumes: try resumesFile.save(resumes)
            case .profile: try profileFile.save(profile)
            case .ai: try aiFile.save(ai)
            case .interviews: try interviewsFile.save(interviews)
            case .recordings: try recordingsFile.save(recordings)
            case .bank: try bankFile.save(bank)
            }
            saveError = nil
        } catch {
            saveError = L10n.tr("error.save", [error.localizedDescription])
        }
    }

    // MARK: Applications

    /// Newest first by creation date (not by last edit, so the list doesn't jump while typing).
    var sortedApplications: [JobApplication] {
        applications.sorted { $0.createdAt > $1.createdAt }
    }

    func newApplication() -> UUID {
        let app = JobApplication()
        applications.append(app)
        return app.id
    }

    /// Also deletes its interviews; recordings stay but lose the link.
    func deleteApplication(_ id: UUID) {
        let interviewIDs = Set(interviews.filter { $0.applicationID == id }.map(\.id))
        interviews.removeAll { interviewIDs.contains($0.id) }
        unlinkRecordings(from: interviewIDs)
        applications.removeAll { $0.id == id }
    }

    func application(_ id: UUID?) -> JobApplication? {
        applications.first { $0.id == id }
    }

    // MARK: Interviews

    func interview(_ id: UUID?) -> Interview? {
        interviews.first { $0.id == id }
    }

    /// Adds or replaces. Scheduling an interview moves an application from 已投递 to 面试中.
    func save(_ interview: Interview) {
        if let i = interviews.firstIndex(where: { $0.id == interview.id }) {
            interviews[i] = interview
        } else {
            interviews.append(interview)
        }
        if let i = applications.firstIndex(where: { $0.id == interview.applicationID }),
           applications[i].status == .applied {
            applications[i].status = .interviewing
            applications[i].updatedAt = Date()
        }
    }

    func deleteInterview(_ id: UUID) {
        interviews.removeAll { $0.id == id }
        unlinkRecordings(from: [id])
    }

    func interviewMarks(on day: Date) -> Interview.DayMarks {
        Interview.marks(interviews, on: day, now: Date())
    }

    func interviews(for applicationID: UUID) -> [Interview] {
        interviews.filter { $0.applicationID == applicationID }.sorted { $0.start < $1.start }
    }

    /// "字节跳动 · 后端开发 · 一面"
    func label(for interview: Interview) -> String {
        let app = application(interview.applicationID)
        return [app?.displayCompany, app?.displayRole, interview.round.isEmpty ? nil : interview.round]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Interviews a recording starting at `date` could belong to (rule: Interview.candidates).
    func interviewCandidates(at date: Date) -> [Interview] {
        Interview.candidates(in: interviews, forRecordingAt: date)
    }

    /// For link pickers: the interviews nearest to `date` (before or after), at most `limit`.
    func interviewsNear(_ date: Date, limit: Int = 12) -> [Interview] {
        Array(interviews.sorted { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }.prefix(limit))
    }

    var upcomingInterviews: [Interview] {
        let now = Date()
        return interviews.filter { $0.end > now }.sorted { $0.start < $1.start }
    }

    // MARK: Recordings

    func add(_ record: RecordingRecord) {
        recordings.append(record)
    }

    func link(recording id: UUID, to interviewID: UUID?) {
        guard let i = recordings.firstIndex(where: { $0.id == id }) else { return }
        recordings[i].interviewID = interviewID
    }

    func recordings(for interviewID: UUID) -> [RecordingRecord] {
        recordings.filter { $0.interviewID == interviewID }.sorted { $0.startedAt < $1.startedAt }
    }

    /// Drops index entries whose .m4a was deleted outside the app.
    func pruneMissingRecordings() {
        let existing = recordings.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        if existing.count != recordings.count { recordings = existing }
    }

    private func unlinkRecordings(from interviewIDs: Set<UUID>) {
        for i in recordings.indices where recordings[i].interviewID.map(interviewIDs.contains) == true {
            recordings[i].interviewID = nil
        }
    }

    /// A binding into the array by id (not by index), so deleting another item can't make it
    /// point at the wrong element. Edits also bump `updatedAt`.
    func binding(forApplication id: UUID) -> Binding<JobApplication>? {
        guard applications.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.applications.first { $0.id == id } ?? JobApplication(id: id) },
            set: { [weak self] new in
                guard let self, let i = self.applications.firstIndex(where: { $0.id == id }) else { return }
                var updated = new
                updated.updatedAt = Date()
                self.applications[i] = updated
            })
    }

    // MARK: Resumes

    enum ImportError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            if case .unsupported(let ext) = self { return L10n.tr("profile.resume.unsupported", [ext]) }
            return nil
        }
    }

    static let resumeFileTypes = ["pdf", "docx", "doc", "rtf", "txt", "md"]

    /// Copies the file into app storage and extracts its text. An empty `text` means extraction
    /// found nothing (e.g. a scanned PDF); the UI then asks the user to paste the text in.
    @discardableResult
    func importResume(from url: URL) throws -> Resume {
        let ext = url.pathExtension.lowercased()
        guard Self.resumeFileTypes.contains(ext) else { throw ImportError.unsupported(ext) }
        let text = try Self.extractText(from: url, ext: ext)

        let id = UUID()
        let stored = "\(id.uuidString).\(ext)"
        try FileManager.default.copyItem(at: url, to: AppPaths.resumes.appendingPathComponent(stored))
        let resume = Resume(id: id, name: url.deletingPathExtension().lastPathComponent,
                            originalFileName: url.lastPathComponent, storedFileName: stored,
                            text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        resumes.append(resume)
        return resume
    }

    func deleteResume(_ id: UUID) {
        guard let resume = resumes.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: resume.storedFileURL)
        resumes.removeAll { $0.id == id }
        for i in applications.indices where applications[i].resumeID == id {
            applications[i].resumeID = nil
        }
    }

    private static func extractText(from url: URL, ext: String) throws -> String {
        switch ext {
        case "pdf":
            return PDFDocument(url: url)?.string ?? ""
        case "txt", "md":
            return try String(contentsOf: url, encoding: .utf8)
        default: // docx, doc, rtf: AppKit's text importers
            let type: NSAttributedString.DocumentType = switch ext {
            case "docx": .officeOpenXML
            case "doc": .docFormat
            default: .rtf
            }
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
        }
    }
}
