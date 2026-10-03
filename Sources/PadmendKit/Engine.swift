import Foundation
import PadmendCore

/// Wires the contact stream to the repaired output.
///
/// Frames are processed on the thread MultitouchSupport delivers them on,
/// because the pointer is being driven from them and a hop onto another queue
/// is latency the user can feel. Everything mutable is therefore behind one
/// lock, taken by the frame handler and by any setting changed from a menu.
public final class Engine {
    public enum Mode: Sendable {
        /// Watch the stream, change nothing. Used while calibrating.
        case observe
        /// Suppress the trackpad's own input and post the repaired input.
        case takeover
    }

    public let device: TrackpadDevice

    /// Raw frame alongside the tracker's view of it, for calibration and the
    /// live heat map. Called on the contact-stream thread.
    public var onFrame: ((TouchFrame, TrackerOutput) -> Void)?
    public var onPanic: (() -> Void)?
    public var onNotice: ((String) -> Void)?

    private let stream = MultitouchStream()
    private let poster = EventPoster()
    private let tap = EventTap()

    private let lock = NSLock()
    private var tracker: ContactTracker
    private var pointer: PointerMapper
    private var gestures: GestureRecognizer
    private var settings: Settings
    private var mode: Mode = .observe
    private var lastFrameTime: Double?

    private var momentumTimer: DispatchSourceTimer?
    private let momentumQueue = DispatchQueue(label: "padmend.momentum")

    public init(device: TrackpadDevice,
                deadMap: DeadMap,
                settings: Settings = .default,
                trackerConfig: TrackerConfig? = nil) {
        self.device = device
        self.settings = settings
        self.tracker = ContactTracker(deadMap: deadMap,
                                      config: trackerConfig ?? settings.tracker)
        self.pointer = PointerMapper(deadMap: deadMap, config: settings.pointer)
        self.gestures = GestureRecognizer(grid: device.grid,
                                          config: settings.gesture)
    }

    // MARK: - Lifecycle

    public func start(mode: Mode) throws {
        self.mode = mode

        if mode == .takeover {
            try tap.start()
            tap.onPanic = { [weak self] in self?.handlePanic() }
            tap.onButtonState = { [weak self] left, right in
                self?.poster.isLeftButtonDown = left
                self?.poster.isRightButtonDown = right
            }
            tap.onTapDisabled = { [weak self] reason in
                self?.onNotice?("event tap was disabled (\(reason)); re-enabled")
            }
            tap.setSuppressing(true)
        }

        try stream.start(device: device) { [weak self] frame in
            self?.process(frame)
        }
    }

    public func stop() {
        stopMomentum()
        stream.stop()
        tap.setSuppressing(false)
        tap.stop()
    }

    public var isSuppressing: Bool { tap.isSuppressing }

    /// Turns suppression off without tearing anything down, so it can be
    /// turned straight back on.
    public func setEnabled(_ enabled: Bool) {
        tap.setSuppressing(enabled && mode == .takeover)
        if !enabled {
            stopMomentum()
            lock.lock()
            gestures.reset()
            pointer.flushResidual()
            lock.unlock()
        }
    }

    private func handlePanic() {
        setEnabled(false)
        onNotice?("panic chord pressed — compensation off, trackpad is raw again")
        onPanic?()
    }

    // MARK: - Settings

    public func update(deadMap: DeadMap) {
        lock.lock()
        tracker.deadMap = deadMap
        pointer.deadMap = deadMap
        lock.unlock()
    }

    public func update(settings: Settings) {
        lock.lock()
        self.settings = settings
        tracker.config = settings.tracker
        pointer.config = settings.pointer
        gestures.config = settings.gesture
        lock.unlock()
    }

    public var currentSettings: Settings {
        lock.lock(); defer { lock.unlock() }
        return settings
    }

    // MARK: - Frame handling

    private func process(_ frame: TouchFrame) {
        lock.lock()

        let dt = lastFrameTime.map { min(max(frame.timestamp - $0, 0), 0.1) } ?? 0
        lastFrameTime = frame.timestamp

        let output = tracker.process(frame)
        let active = mode == .takeover && tap.isSuppressing

        var pointerStep: (dx: Int, dy: Int) = (0, 0)
        var gestureEvents: [GestureEvent] = []
        var swallowClicks = false

        if active {
            // A single finger is the pointer. Anything else is a gesture, and
            // macOS does not move the pointer under multiple fingers either.
            if output.fingers.count == 1 {
                pointerStep = pointer.step(delta: output.fingers[0].delta, dt: dt)
            } else if output.fingers.isEmpty {
                pointer.flushResidual()
            }
            gestureEvents = gestures.update(fingers: output.fingers, dt: dt)

            swallowClicks = output.events.contains { event in
                if case .phantomTapSuppressed = event { return true }
                return false
            } && settings.suppressPhantomClicks

            let allowThree = settings.threeFingerSwipes
            let allowFour = settings.fourFingerSwipes
            gestureEvents = gestureEvents.filter { event in
                guard case .swipe(let fingers, _) = event else { return true }
                return fingers == 3 ? allowThree : allowFour
            }
        }

        let momentumWanted = gestures.isMomentumActive
        lock.unlock()

        tap.setFingersDown(output.fingers.count)

        if active {
            if pointerStep.dx != 0 || pointerStep.dy != 0 {
                poster.moveCursor(dx: pointerStep.dx, dy: pointerStep.dy)
            }
            for event in gestureEvents { emit(event) }
            if swallowClicks {
                // Long enough to cover the click macOS builds from the contact
                // we rejected, short enough not to eat a real one after it.
                tap.swallowClicks(for: 0.16)
            }
            if momentumWanted { startMomentum() } else { stopMomentum() }
        }

        onFrame?(frame, output)
    }

    private func emit(_ event: GestureEvent) {
        switch event {
        case .scroll(let phase, let dx, let dy):
            poster.scroll(phase: phase, dx: dx, dy: dy)
        case .pinch(let phase, let magnification):
            if phase == .began || phase == .ended {
                poster.resetPinch()
            } else {
                poster.pinch(magnification: magnification)
            }
        case .swipe(_, let direction):
            poster.swipe(direction)
        }
    }

    // MARK: - Scroll inertia

    /// Inertia has to be driven by a clock, because the hardware stops
    /// reporting the moment the fingers leave the glass.
    private func startMomentum() {
        guard momentumTimer == nil else { return }
        let interval = 1.0 / 90
        let timer = DispatchSource.makeTimerSource(queue: momentumQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let events = self.gestures.tick(dt: interval)
            let stillActive = self.gestures.isMomentumActive
            self.lock.unlock()

            for event in events { self.emit(event) }
            if !stillActive { self.stopMomentum() }
        }
        momentumTimer = timer
        timer.resume()
    }

    private func stopMomentum() {
        momentumTimer?.cancel()
        momentumTimer = nil
    }
}
