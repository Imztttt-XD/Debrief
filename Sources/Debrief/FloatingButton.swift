import AppKit
import Combine
import SwiftUI

/// Desktop floating record button: a small always-on-top panel, visible on every Space and over
/// full-screen apps (e.g. a full-screen Zoom call).
/// - Click: start/stop recording. Drag: move (position is remembered). Right-click: menu.
/// - Doesn't activate the app or take focus from the meeting window when clicked.
/// - Asks to be left out of screen sharing (`sharingType = .none`). Some capture paths on
///   recent macOS ignore this, so check it with your meeting app before relying on it.
@MainActor
final class FloatingButtonController {
    static let visibleKey = "floatingButtonVisible"
    private static let originKey = "floatingButtonOrigin"
    private static let height: CGFloat = 48
    private static let idleWidth: CGFloat = 48
    private static let recordingWidth: CGFloat = 156

    static func size(for phase: Recorder.Phase) -> CGSize {
        if case .recording = phase { return CGSize(width: recordingWidth, height: height) }
        return CGSize(width: idleWidth, height: height)
    }

    private let recorder: Recorder
    private let openMainWindow: () -> Void
    private var panel: NSPanel?
    private var container: DragClickView?
    private let flash = SavedFlash()
    private var cancellables = Set<AnyCancellable>()

    init(recorder: Recorder, openMainWindow: @escaping () -> Void) {
        self.recorder = recorder
        self.openMainWindow = openMainWindow
        UserDefaults.standard.register(defaults: [Self.visibleKey: true])

        // Every toggle (main window, menu bar, right-click menu) just writes the default.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncVisibility() }
            .store(in: &cancellables)
        recorder.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in self?.update(for: phase) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.keepOnScreen() }
            .store(in: &cancellables)

        syncVisibility()
    }

    static var isVisible: Bool {
        get { UserDefaults.standard.bool(forKey: visibleKey) }
        set { UserDefaults.standard.set(newValue, forKey: visibleKey) }
    }

    // MARK: Visibility

    private func syncVisibility() {
        if Self.isVisible {
            if panel == nil { panel = makePanel() }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let width = recorder.isRecording ? Self.recordingWidth : Self.idleWidth
        let panel = NSPanel(contentRect: NSRect(origin: savedOrigin(width: width),
                                                size: NSSize(width: width, height: Self.height)),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false            // DragClickView moves the panel by hand
        panel.sharingType = .none          // ask to be excluded from screen sharing / capture
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: FloatingButtonView(recorder: recorder, flash: flash))
        let container = DragClickView(frame: NSRect(origin: .zero, size: panel.frame.size))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        container.onClick = { [weak self] in self?.recorder.toggle() }
        container.onDragEnded = { [weak self] in self?.keepOnScreen(); self?.saveOrigin() }
        container.menuProvider = { [weak self] in self?.makeContextMenu() }
        panel.contentView = container
        self.container = container
        updateLabels()
        return panel
    }

    // MARK: Phase changes

    private func update(for phase: Recorder.Phase) {
        updateLabels(phase)
        guard let panel else { return }
        let isRecording: Bool = { if case .recording = phase { return true } else { return false } }()
        let width = isRecording ? Self.recordingWidth : Self.idleWidth
        guard panel.frame.width != width else { return }
        var frame = panel.frame
        // If the button sits on the right half of the screen, grow leftwards so it doesn't run off the edge.
        if let screen = panel.screen ?? NSScreen.main, frame.midX > screen.visibleFrame.midX {
            frame.origin.x = frame.maxX - width
        }
        frame.size.width = width
        panel.setFrame(frame, display: true, animate: true)
        panel.invalidateShadow()
        keepOnScreen()
    }

    private func updateLabels(_ phase: Recorder.Phase? = nil) {
        let key: String
        switch phase ?? recorder.phase {
        case .idle: key = "float.tooltipStart"
        case .starting: key = "status.starting"
        case .recording: key = "float.tooltipStop"
        case .finalizing: key = "status.finalizing"
        }
        container?.toolTip = L10n.tr(key)
        container?.setAccessibilityLabel(L10n.tr(key))
    }

    // MARK: Position

    private func savedOrigin(width: CGFloat) -> NSPoint {
        if let s = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(s)
            let frame = NSRect(origin: p, size: NSSize(width: width, height: Self.height))
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return p }
        }
        // Default: right edge of the main screen, a bit above the middle.
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        return NSPoint(x: vf.maxX - width - 16, y: vf.midY + 80)
    }

    private func saveOrigin() {
        guard let panel else { return }
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }

    /// Clamps the panel inside a screen's visible area (also after displays are unplugged).
    private func keepOnScreen() {
        guard let panel else { return }
        var f = panel.frame
        guard let vf = (NSScreen.screens.first { $0.visibleFrame.intersects(f) } ?? NSScreen.main)?.visibleFrame
        else { return }
        f.origin.x = min(max(f.origin.x, vf.minX + 4), vf.maxX - f.width - 4)
        f.origin.y = min(max(f.origin.y, vf.minY + 4), vf.maxY - f.height - 4)
        if f.origin != panel.frame.origin { panel.setFrameOrigin(f.origin) }
    }

    // MARK: Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let toggle = ClosureMenuItem(title: L10n.tr(recorder.isRecording ? "action.stop" : "action.start")) { [weak self] in
            self?.recorder.toggle()
        }
        toggle.isEnabled = !recorder.isBusy
        menu.autoenablesItems = false
        menu.addItem(toggle)
        menu.addItem(ClosureMenuItem(title: L10n.tr("menu.showWindow")) { [weak self] in self?.openMainWindow() })
        menu.addItem(ClosureMenuItem(title: L10n.tr("menu.openFolder")) { [weak self] in self?.recorder.openOutputFolder() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L10n.tr("float.hide")) { FloatingButtonController.isVisible = false })
        return menu
    }
}

// MARK: - Click vs. drag

/// Takes all mouse events for the panel. A press that moves more than 3 pt is a drag; otherwise it's a click.
/// The SwiftUI content underneath only draws.
final class DragClickView: NSView {
    var onClick: () -> Void = {}
    var onDragEnded: () -> Void = {}
    var menuProvider: () -> NSMenu? = { nil }

    private var mouseDownScreen: NSPoint = .zero
    private var originAtMouseDown: NSPoint = .zero
    private var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreen = NSEvent.mouseLocation
        originAtMouseDown = window?.frame.origin ?? .zero
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = NSEvent.mouseLocation
        let dx = p.x - mouseDownScreen.x, dy = p.y - mouseDownScreen.y
        if !isDragging && hypot(dx, dy) > 3 { isDragging = true }
        if isDragging {
            window?.setFrameOrigin(NSPoint(x: originAtMouseDown.x + dx, y: originAtMouseDown.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging { onDragEnded() } else { onClick() }
        isDragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

// MARK: - Visuals

/// Briefly shows a green check after a recording is saved. A class rather than @State because
/// the SwiftUI macro plugin isn't available with Command Line Tools alone.
@MainActor
final class SavedFlash: ObservableObject {
    @Published private(set) var isOn = false
    private var task: Task<Void, Never>?

    func trigger() {
        isOn = true
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.isOn = false
        }
    }
}

/// Idle: a small brand-gradient circle with a mic. Recording: a light capsule with a blinking
/// red dot, the elapsed time and a round stop button. Saved: turns green with a check for 2 s.
struct FloatingButtonView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var flash: SavedFlash
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if case .recording(let since) = recorder.phase {
                recording(since: since)
            } else {
                idle
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: recorder.lastRecordingURL) { _, url in
            if url != nil { flash.trigger() }
        }
    }

    private var idle: some View {
        ZStack {
            Circle().fill(flash.isOn ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x6EE7B7), Color(hex: 0x34C38F)],
                                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                                     : AnyShapeStyle(Theme.brandGradient))
            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
            switch recorder.phase {
            case .starting, .finalizing:
                ProgressView().controlSize(.small).tint(.white)
            default:
                Image(systemName: flash.isOn ? "checkmark" : "mic.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .padding(2)
    }

    private func recording(since: Date) -> some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: since, by: 1)) { ctx in
                let elapsed = max(0, ctx.date.timeIntervalSince(since))
                HStack(spacing: 8) {
                    // Blinks once a second (driven by the same 1 s tick as the clock).
                    Circle()
                        .fill(Theme.record)
                        .frame(width: 9, height: 9)
                        .opacity(Int(elapsed) % 2 == 0 ? 1 : 0.35)
                        .animation(.easeInOut(duration: 0.6), value: Int(elapsed))
                    Text(Duration.seconds(elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .fixedSize()
                }
            }
            .padding(.leading, 14)
            Spacer(minLength: 0)
            ZStack {
                Circle().fill(Theme.recordGradient)
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white)
                    .frame(width: 11, height: 11)
            }
            .frame(width: 34, height: 34)
            .padding(.trailing, 7)
        }
        .background(Capsule().fill(scheme == .dark ? Color(white: 0.17) : Color.white))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(scheme == .dark ? 0.18 : 0.08)))
    }
}
