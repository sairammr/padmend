import AppKit
import Foundation
import PadmendCore

/// The calibration window.
///
/// The user is the measuring instrument, so the window's main job is to show
/// them what their sweeping has established. Saving stays disabled until
/// enough of the pad has been covered to mean anything, because a map built
/// from three strokes would condemn whatever happened to be missed.
@MainActor
public final class CalibrationWindowController: NSWindowController {
    /// Enough of the pad covered for the result to be worth saving.
    private static let minimumCoverage = 0.75

    private let device: TrackpadDevice
    private let completion: (DeadMap?) -> Void

    private let stream = MultitouchStream()
    private let capture: CalibrationCapture

    private let padView = PadView()
    private let progress = NSProgressIndicator()
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save Map", target: nil, action: nil)

    private var redrawTimer: Timer?
    private var finished = false

    public init(device: TrackpadDevice, completion: @escaping (DeadMap?) -> Void) {
        self.device = device
        self.completion = completion
        self.capture = CalibrationCapture(grid: device.grid)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Calibrate Trackpad"
        super.init(window: window)

        window.delegate = self
        window.contentView = buildContent()
        window.center()
        start()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func buildContent() -> NSView {
        headline.font = .systemFont(ofSize: 13, weight: .medium)
        headline.stringValue = "Sweep your whole finger over the whole trackpad."

        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.stringValue = """
            Use slow, overlapping strokes, and go right out to the edges. Red \
            means your finger was there and the trackpad reported nothing.
            """
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1

        padView.translatesAutoresizingMaskIntoConstraints = false
        padView.heightAnchor.constraint(equalToConstant: 300).isActive = true

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.isEnabled = false

        let cancelButton = NSButton(title: "Cancel", target: self,
                                    action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"

        let restartButton = NSButton(title: "Start Over", target: self,
                                     action: #selector(restart))

        let buttons = NSStackView(views: [restartButton, NSView(),
                                          cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [headline, detail, padView,
                                        LegendView(includeFinger: true),
                                        progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -36).isActive = true
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                       constant: -36).isActive = true
        return stack
    }

    // MARK: - Capture

    private func start() {
        do {
            let capture = self.capture
            try stream.start(device: device) { frame in
                capture.ingest(frame)
            }
        } catch {
            headline.stringValue = "Cannot read the trackpad"
            detail.stringValue = "\(error)"
            return
        }

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.redraw()
        }
        RunLoop.main.add(timer, forMode: .common)
        redrawTimer = timer
    }

    private func redraw() {
        let state = capture.snapshot()
        padView.source = .coverage(state.coverage, fingers: state.fingers)
        let covered = state.progress
        let repaired = state.repairedDropouts
        progress.doubleValue = covered

        saveButton.isEnabled = covered >= CalibrationWindowController.minimumCoverage
        headline.stringValue = saveButton.isEnabled
            ? "Looks like enough. Save, or keep sweeping to be sure."
            : String(format: "Keep sweeping — %.0f%% of the pad covered",
                     covered * 100)
        if repaired > 0 {
            detail.stringValue = """
                Dropouts repaired so far: \(repaired). Red means your finger \
                was there and the trackpad reported nothing. Go right out to \
                the edges.
                """
        }
    }

    private func finish(with map: DeadMap?) {
        guard !finished else { return }
        finished = true
        redrawTimer?.invalidate()
        redrawTimer = nil
        stream.stop()
        completion(map)
        window?.close()
    }

    // MARK: - Actions

    @objc private func save() {
        let map = capture.makeDeadMap()
        finish(with: map.isCalibrated ? map : nil)
    }

    @objc private func cancel() {
        finish(with: nil)
    }

    @objc private func restart() {
        capture.reset()
        redraw()
    }
}

@MainActor
extension CalibrationWindowController: NSWindowDelegate {
    public func windowWillClose(_ notification: Notification) {
        // Closing the window is a cancel, and the contact stream must stop
        // either way or it keeps running with nothing reading it.
        finish(with: nil)
    }
}
