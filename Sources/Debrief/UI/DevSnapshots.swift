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
        // Stay out of the way: no Dock icon, no focus change, no visible windows.
        NSApp.setActivationPolicy(.accessory)
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
                    for tab in ["models", "profile", "general"] {
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
                 mockEngine: app.mockEngine)
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
