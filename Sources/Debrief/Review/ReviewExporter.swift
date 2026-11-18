import AppKit
import UniformTypeIdentifiers

/// Exports a review's interviewer questions as Markdown, meant to be handed to a coding
/// assistant (Codex, Claude Code…) that has the project's source, so it can explain each
/// question against the real code.
enum ReviewExporter {
    enum Scope {
        /// Project deep-dive questions plus technical questions about an item on the resume.
        case projects
        case all
    }

    /// Questions about the candidate's projects: what a coding assistant with the project's
    /// code can actually explain. Internship questions are left out (often logistics such as
    /// "where was it?", and not in the repository anyway).
    static func isProjectQuestion(_ q: ReviewQuestion) -> Bool {
        q.category == "project"
            || (q.resumeItem != nil && ["fundamentals", "algorithm"].contains(q.category))
    }

    static func questions(in review: Review, scope: Scope) -> [ReviewQuestion] {
        scope == .all ? review.questions : review.questions.filter(isProjectQuestion)
    }

    /// Title, instructions for the assistant, then the questions as a numbered list with
    /// follow-ups as sub-items. Nothing else: no times, tags or answers.
    static func markdown(review: Review, title: String, scope: Scope) -> String {
        markdown(title: title, questions: questions(in: review, scope: scope))
    }

    /// Shared by reviews, mock interviews and the question bank.
    static func markdown(title: String, questions: [ReviewQuestion]) -> String {
        var out = ["# " + L10n.tr("export.heading", [title])]
        out.append(L10n.tr("export.instructions").split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }.joined(separator: "\n"))
        let list = questions.enumerated().map { i, q in
            ([ "\(i + 1). \(q.question)" ] + q.followUps.map { "   - \($0.question)" }).joined(separator: "\n")
        }
        out.append(list.joined(separator: "\n"))
        return out.joined(separator: "\n\n") + "\n"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Returns the saved file, or nil if cancelled.
    @MainActor
    static func save(_ text: String, suggestedName: String) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// "字节跳动-一面-面试问题.md" (characters that are awkward in file names replaced).
    static func fileName(title: String) -> String {
        let cleaned = title.replacingOccurrences(of: " · ", with: "-")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        return cleaned + "-" + L10n.tr("export.fileSuffix") + ".md"
    }
}
