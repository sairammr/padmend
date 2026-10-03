import CoreGraphics
import Foundation

/// Suppresses the input the damaged trackpad would otherwise deliver, so the
/// repaired input posted in its place is the only thing the system sees.
///
/// Safety is the main design constraint here, because a program that swallows
/// pointer events can leave a machine unusable. Four things guard against that:
/// a tap dies with its process, so a crash restores the trackpad immediately;
/// macOS disables a tap whose callback stalls, which this detects and recovers
/// from; movement is only suppressed while fingers are actually on the pad, so
/// an external mouse keeps working; and a panic chord turns everything off
/// without needing a working pointer to reach a menu.
public final class EventTap {
    /// Control-Option-Command-P.
    public static let panicKeyCode: CGKeyCode = 35

    public var onPanic: (() -> Void)?
    public var onButtonState: ((_ left: Bool, _ right: Bool) -> Void)?
    /// Called when macOS disables the tap, for logging.
    public var onTapDisabled: ((String) -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let lock = NSLock()
    private var _suppressing = false
    private var _fingersDown = 0
    private var _swallowClicksUntil: TimeInterval = 0
    private var leftDown = false
    private var rightDown = false

    public init() {}

    /// Whether the trackpad's own movement and scrolling are being discarded.
    public var isSuppressing: Bool {
        lock.lock(); defer { lock.unlock() }
        return _suppressing
    }

    public func setSuppressing(_ suppressing: Bool) {
        lock.lock()
        _suppressing = suppressing
        lock.unlock()
    }

    /// How many fingers the tracker currently believes are on the glass.
    /// Written from the contact-stream thread, read from the tap callback.
    public func setFingersDown(_ count: Int) {
        lock.lock()
        _fingersDown = count
        lock.unlock()
    }

    /// Discards clicks for a moment. Called when the tracker judges a contact
    /// to have been sensor noise: macOS has already seen that contact and will
    /// synthesise a click from it, and this is the only chance to stop it.
    public func swallowClicks(for seconds: TimeInterval) {
        lock.lock()
        _swallowClicksUntil = max(_swallowClicksUntil,
                                  Date.timeIntervalSinceReferenceDate + seconds)
        lock.unlock()
    }

    public enum TapError: Error, CustomStringConvertible {
        case notPermitted

        public var description: String {
            """
            could not create an event tap — grant Accessibility permission in \
            System Settings › Privacy & Security › Accessibility
            """
        }
    }

    public func start() throws {
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<EventTap>.fromOpaque(context)
                    .takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: context)
        else {
            throw TapError.notPermitted
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        tap = nil
    }

    // MARK: - Callback

    private func handle(type: CGEventType,
                        event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        // macOS disables a tap whose callback takes too long, and a disabled
        // tap silently stops suppressing. Re-enabling here is what keeps a
        // momentary stall from turning into a half-working trackpad.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
            onTapDisabled?(reason)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }

        // Our own replacement input must never be suppressed.
        if event.getIntegerValueField(.eventSourceUserData)
            == EventPoster.signature {
            return pass
        }

        if type == .keyDown { return handleKeyDown(event, pass: pass) }

        lock.lock()
        let suppressing = _suppressing
        let fingersDown = _fingersDown
        let swallowUntil = _swallowClicksUntil
        lock.unlock()

        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            let isDown = type == .leftMouseDown || type == .rightMouseDown
            if type == .leftMouseDown || type == .leftMouseUp {
                leftDown = isDown
            } else {
                rightDown = isDown
            }
            onButtonState?(leftDown, rightDown)

            if Date.timeIntervalSinceReferenceDate < swallowUntil {
                // A click macOS built from a contact we judged to be noise.
                // Button state was already updated, so a swallowed down/up
                // pair cannot leave a phantom drag behind.
                return nil
            }
            return pass

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Only movement made while fingers are on the pad is ours to
            // replace. With no fingers down it came from a mouse.
            guard suppressing, fingersDown > 0 else { return pass }
            return nil

        case .scrollWheel:
            // A physical wheel sends discrete clicks; a trackpad sends
            // continuous pixels. That flag is a reliable way to leave a real
            // mouse alone.
            let continuous = event.getIntegerValueField(
                .scrollWheelEventIsContinuous) != 0
            guard suppressing, continuous else { return pass }
            return nil

        default:
            return pass
        }
    }

    private func handleKeyDown(_ event: CGEvent,
                               pass: Unmanaged<CGEvent>) -> Unmanaged<CGEvent>? {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard code == EventTap.panicKeyCode else { return pass }

        let required: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        guard event.flags.contains(required) else { return pass }

        onPanic?()
        return nil
    }
}
