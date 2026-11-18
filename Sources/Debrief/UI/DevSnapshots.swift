import AppKit
import SwiftUI

/// Developer tool for checking layouts without screen-recording permission.
///
///   DEBRIEF_DATA_DIR=<demo data> DEBRIEF_SNAPSHOT_DIR=<out> build/Debrief.app/Contents/MacOS/Debrief
///
/// renders every page (and the floating button) offscreen at a few window sizes, in light and
/// dark mode, to PNG files, then quits. Always use a demo DEBRIEF_DATA_DIR so real data isn't
/// rendered. Reminders are not scheduled in this mode.
@MainActor
enum DevSnapshots {
    static var outputDir: URL? {
        ProcessInfo.processInfo.environment["DEBRIEF_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// A window that may sit off-screen (normal windows get pulled back onto a display).
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    static func run(_ app: AppDelegate) async {
        guard let dir = outputDir else { return }
        // Stay out of the way: no Dock icon, no focus change, no visible windows
        // (unless DEBRIEF_SNAPSHOT_ACTIVE=1, see render).
        NSApp.setActivationPolicy(ProcessInfo.processInfo.environment["DEBRIEF_SNAPSHOT_ACTIVE"] == "1" ? .regular : .accessory)
        try? await Task.sleep(for: .milliseconds(300))
        NSApp.windows.forEach { $0.orderOut(nil) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        app.nav.selectedApplicationID = app.store.sortedApplications.first?.id
        app.nav.selectedRecordingID = app.store.recordings.first?.id
        app.store.ingestPendingReviews()
        app.nav.selectedMockID = app.store.sortedMocks.first?.id

        let sizes: [(CGSize, Bool)] = [(CGSize(width: 900, height: 600), false), (CGSize(width: 1300, height: 820), false),
                                       (CGSize(width: 1100, height: 720), true)]
        for (size, dark) in sizes {
            let suffix = "\(Int(size.width))\(dark ? "-dark" : "")"
            for section in NavigationModel.Section.allCases {
                app.nav.section = section
                switch section {
                case .settings:
                    for tab in ["models", "profile", "general", "usage"] {
                        defaults.set(tab, forKey: "settingsTab")
                        await render(mainView(app), size: size, dark: dark, to: dir.appendingPathComponent("settings-\(tab)-\(suffix).png"))
                    }
                case .review:
                    for tab in ["questions", "transcript", "summary"] {
                        defaults.set(tab, forKey: "reviewTab")
                        await render(mainView(app), size: size, dark: dark, to: dir.appendingPathComponent("review-\(tab)-\(suffix).png"))
                    }
                default:
                    await render(mainView(app), size: size, dark: dark, to: dir.appendingPathComponent("\(section.rawValue)-\(suffix).png"))
                }
            }
        }

        // Practice sheet: answering, then graded (critique filled in by hand, no API call).
        let due = app.store.bank.due(at: Date()).map(\.id)
        if !due.isEmpty {
            let size = CGSize(width: 640, height: 600)
            app.practice.start(due)
            await render(PracticeView(engine: app.practice, store: app.store), size: size, dark: false,
                         to: dir.appendingPathComponent("practice-empty.png"))
            app.practice.session?.answer = "用 Redis 的 SETNX 加用户 ID 做幂等，数据库再加唯一索引兜底。"
            await render(PracticeView(engine: app.practice, store: app.store), size: size, dark: false,
                         to: dir.appendingPathComponent("practice-answer.png"))
            app.practice.session?.critique = Critique(
                accuracy: 3, structure: 4, depth: 3,
                corrections: [.init(claim: "SETNX 加用户 ID 做幂等", issue: "SETNX 不带过期时间，进程崩溃后锁不会释放。",
                                    correct: "用 SET key value NX EX 30 原子加锁")],
                strengths: ["说出了数据库唯一索引兜底"], improvements: ["补充锁过期和误删的处理"],
                betterAnswer: "用 SET key value NX EX 30 原子加锁，并以数据库唯一索引兜底……")
            app.practice.session?.phase = .graded
            for dark in [false, true] {
                await render(PracticeView(engine: app.practice, store: app.store), size: size, dark: dark,
                             to: dir.appendingPathComponent("practice-graded\(dark ? "-dark" : "").png"))
            }
            app.practice.end()
        }

        // Interview editor sheet, editing the first scheduled interview.
        if let iv = app.store.interviews.sorted(by: { $0.start < $1.start }).last {
            app.nav.schedule.draft = InterviewDraft(interview: iv, isNew: false, createsApplication: false)
            for dark in [false, true] {
                await render(InterviewEditor(store: app.store, state: app.nav.schedule), size: CGSize(width: 560, height: 720),
                             dark: dark, to: dir.appendingPathComponent("interview-editor\(dark ? "-dark" : "").png"))
            }
            app.nav.schedule.draft = nil
        }

        // Text field states (hover and focus can't happen offscreen, so they're forced).
        for dark in [false, true] {
            let form = Form {
                ForEach([("默认", NoteEditor.Highlight.none), ("悬停", .hover), ("输入中", .focus)], id: \.0) { title, state in
                    Section {
                        NoteEditor(text: .constant(state == .none ? "" : "岗位职责：\n1. 负责即时通信与支付相关后端服务的设计与开发；\n2. 参与高并发场景下的性能优化。"),
                                   placeholder: L10n.tr("field.notes.appPlaceholder"), minHeight: 90, highlight: state)
                    } header: { Text(title) }
                }
            }
            .formStyle(.grouped)
            await render(form, size: CGSize(width: 640, height: 640), dark: dark,
                         to: dir.appendingPathComponent("editor-states\(dark ? "-dark" : "").png"))
        }

        // Floating button states, on a mid-grey backdrop so its edges are visible.
        for dark in [false, true] {
            for (name, phase) in [("idle", Recorder.Phase.idle), ("recording", .recording(since: Date().addingTimeInterval(-754)))] {
                app.recorder.setPhaseForSnapshot(phase)
                let size = FloatingButtonController.size(for: phase)
                let view = FloatingButtonView(recorder: app.recorder, flash: SavedFlash())
                    .frame(width: size.width, height: size.height)
                    .padding(20)
                    .background(Color.gray.opacity(0.35))
                await render(view, size: CGSize(width: size.width + 40, height: size.height + 40), dark: dark,
                             to: dir.appendingPathComponent("float-\(name)\(dark ? "-dark" : "").png"))
            }
        }
        app.recorder.setPhaseForSnapshot(.idle)
        NSApp.terminate(nil)
    }

    private static func mainView(_ app: AppDelegate) -> some View {
        MainView(recorder: app.recorder, store: app.store, nav: app.nav, reminders: app.reminders, engine: app.engine,
                 mockEngine: app.mockEngine, practice: app.practice)
    }

    private static func render<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) async {
        let window = OffscreenWindow(contentRect: NSRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                                     styleMask: [.titled, .closable, .resizable, .miniaturizable],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.setContentSize(size)
        window.orderFrontRegardless()
        // DEBRIEF_SNAPSHOT_ACTIVE=1: render as the key window of the active app, so controls show
        // their accent colours (inactive windows draw them grey). Briefly takes focus.
        if ProcessInfo.processInfo.environment["DEBRIEF_SNAPSHOT_ACTIVE"] == "1" {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        try? await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            // The window draws its own background; cacheDisplay leaves it transparent. Composite
            // onto the real window colour for this appearance so dark-mode shots read correctly.
            let out = NSImage(size: host.bounds.size)
            out.lockFocus()
            window.appearance?.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: host.bounds.size).fill()
            }
            // sourceOver, not the default copy: transparent pixels must let the background through.
            rep.draw(in: NSRect(origin: .zero, size: host.bounds.size), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: false, hints: nil)
            out.unlockFocus()
            if let tiff = out.tiffRepresentation, let flat = NSBitmapImageRep(data: tiff) {
                try? flat.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
        window.orderOut(nil)
        window.close()
    }
}
