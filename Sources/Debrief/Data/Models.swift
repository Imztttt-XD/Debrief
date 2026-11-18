import Foundation

/// One application = one role at one company. Interviews, recordings, reviews and real
/// questions will hang off this in later steps.
struct JobApplication: Codable, Identifiable, Hashable {
    enum Status: String, Codable, CaseIterable, Identifiable {
        case applied, interviewing, awaitingResult, offer, rejected, withdrawn
        var id: String { rawValue }
        var title: String { L10n.tr("status.app.\(rawValue)") }
    }

    var id = UUID()
    var company = ""
    var role = ""
    var jobDescription = ""
    var resumeID: UUID?
    var status: Status = .applied
    var channel = ""
    var notes = ""
    var createdAt = Date()
    var updatedAt = Date()

    var displayCompany: String { company.isEmpty ? L10n.tr("app.untitledCompany") : company }
    var displayRole: String { role.isEmpty ? L10n.tr("app.untitledRole") : role }
}

struct Resume: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Name of the file the user picked, for display.
    var originalFileName: String
    /// Copy kept under AppPaths.resumes so the app doesn't depend on the original staying put.
    var storedFileName: String
    /// Extracted text. Editable, because PDF extraction can be messy; this is what the AI reads.
    var text: String
    var importedAt = Date()

    var storedFileURL: URL { AppPaths.resumes.appendingPathComponent(storedFileName) }
}

struct Profile: Codable, Hashable {
    /// e.g. "后端开发 / 数据分析"
    var targetDirection = ""
}

/// One scheduled interview (a round) for an application.
struct Interview: Codable, Identifiable, Hashable {
    enum Format: String, Codable, CaseIterable, Identifiable {
        case online, onsite, phone
        var id: String { rawValue }
        var title: String { L10n.tr("interview.format.\(rawValue)") }
        var icon: String {
            switch self {
            case .online: "video"
            case .onsite: "building.2"
            case .phone: "phone"
            }
        }
    }

    /// Offered in the editor; minutes before the start.
    static let reminderChoices = [1440, 60, 30, 10, 5]
    static let durationChoices = [30, 45, 60, 90, 120]

    var id = UUID()
    var applicationID: UUID
    /// Free text: 一面 / 二面 / HR 面 …
    var round = ""
    var start: Date
    var durationMinutes = 60
    var format: Format = .online
    var meetingLink = ""
    /// Address (onsite) or phone number (phone).
    var location = ""
    var notes = ""
    var reminderMinutes: [Int] = [10]
    var createdAt = Date()

    var end: Date { start.addingTimeInterval(TimeInterval(durationMinutes * 60)) }
    var meetingURL: URL? {
        let t = meetingLink.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return url
    }
}

/// A saved recording, indexed so it can be linked to an interview and later transcribed.
struct RecordingRecord: Codable, Identifiable, Hashable {
    /// Which speaker a track in the `.tracks.mov` carries, in file order.
    enum Track: String, Codable { case system, microphone }

    var id = UUID()
    /// The mixed-down .m4a (for listening).
    var fileURL: URL
    /// Per-source tracks (for transcription). nil if it couldn't be kept.
    var tracksFileURL: URL?
    var startedAt: Date
    var duration: TimeInterval
    /// Empty when unknown (e.g. a single-track recording recovered after a crash).
    var tracks: [Track]
    var interviewID: UUID?
}
