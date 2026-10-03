import CoreGraphics
import Foundation
import PadmendCore

/// Posts the synthetic input that replaces what the trackpad would have sent.
///
/// Every event carries a marker in its source's user data so the event tap can
/// recognise its own output and let it through. Without that, suppressing
/// trackpad movement would also suppress the movement posted to replace it.
public final class EventPoster {
    /// Arbitrary, just has to be ours.
    public static let signature: Int64 = 0x7061_646d_656e_64

    private let source: CGEventSource?
    private var boundsCache: CGRect = .zero
    private var boundsCachedAt: TimeInterval = 0

    /// Tracked from the events that pass through the tap, because a drag has
    /// to be posted as a drag: posting plain movement while a button is held
    /// makes text selection and window dragging come apart.
    public var isLeftButtonDown = false
    public var isRightButtonDown = false

    public init() {
        source = CGEventSource(stateID: .privateState)
        source?.userData = EventPoster.signature
    }

    // MARK: - Pointer

    public func moveCursor(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        let current = currentLocation()
        let target = clampToDisplays(CGPoint(x: current.x + CGFloat(dx),
                                             y: current.y + CGFloat(dy)))

        let type: CGEventType
        let button: CGMouseButton
        if isLeftButtonDown {
            type = .leftMouseDragged
            button = .left
        } else if isRightButtonDown {
            type = .rightMouseDragged
            button = .right
        } else {
            type = .mouseMoved
            button = .left
        }

        guard let event = CGEvent(mouseEventSource: source,
                                  mouseType: type,
                                  mouseCursorPosition: target,
                                  mouseButton: button) else { return }
        // Applications that read deltas rather than absolute position — games,
        // drawing tools — see nothing without these.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)
    }

    public func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Keeps the pointer on a display. Posting a location outside every screen
    /// is not reliably clamped for us, and the pointer can be lost offscreen.
    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        let bounds = displayBounds()
        guard !bounds.isNull, bounds.width > 0 else { return point }
        return CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                       y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }

    private func displayBounds() -> CGRect {
        let now = Date.timeIntervalSinceReferenceDate
        // Recomputed occasionally rather than watching for reconfiguration:
        // plugging in a display is not a fast path.
        if now - boundsCachedAt < 2, boundsCache.width > 0 { return boundsCache }

        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        var union = CGRect.null
        for id in ids.prefix(Int(count)) {
            union = union.union(CGDisplayBounds(id))
        }
        boundsCache = union
        boundsCachedAt = now
        return union
    }

    // MARK: - Scroll

    public func scroll(phase: GesturePhase, dx: Int, dy: Int) {
        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(dy),
                                  wheel2: Int32(dx),
                                  wheel3: 0) else { return }

        // Continuous scrolling plus explicit phases is what makes rubber-band
        // bouncing and inertia work in AppKit and WebKit scroll views.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        switch phase {
        case .began:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        case .changed:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        case .ended:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        case .momentumBegan:
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        case .momentumChanged:
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        case .momentumEnded:
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 3)
        }
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Gestures

    /// Pinch, as a keyboard zoom.
    ///
    /// This is a deliberate compromise and the one place the takeover is not
    /// faithful. A real pinch is an `NSEventTypeMagnify`, and there is no
    /// public way to construct one: `CGEvent` cannot express gesture types, so
    /// a pinch cannot be synthesised the way movement and scrolling can.
    /// Command-plus and command-minus work in browsers, editors, terminals and
    /// most document apps, and do nothing at all in Maps, Preview or Photos,
    /// where zoom is continuous. Accumulating to a threshold keeps it from
    /// firing on every frame of a slow pinch.
    public func pinch(magnification: Double) {
        pinchAccumulator += magnification
        let step = 0.18
        while abs(pinchAccumulator) >= step {
            let zoomIn = pinchAccumulator > 0
            pinchAccumulator -= zoomIn ? step : -step
            // 24 is '=' and 27 is '-'; with command these are zoom in and out.
            postKey(code: zoomIn ? 24 : 27, flags: .maskCommand)
        }
    }

    private var pinchAccumulator: Double = 0

    public func resetPinch() { pinchAccumulator = 0 }

    /// Swipes are posted as the keyboard shortcuts that already drive these
    /// features. Synthesising the real multi-finger gesture is not possible
    /// from outside WindowServer, but Mission Control and desktop switching
    /// both have reliable key equivalents, so the outcome is the same.
    public func swipe(_ direction: SwipeDirection) {
        let arrow: CGKeyCode
        switch direction {
        case .left: arrow = 123
        case .right: arrow = 124
        case .down: arrow = 125
        case .up: arrow = 126
        }
        postKey(code: arrow, flags: .maskControl)
    }

    private func postKey(code: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
