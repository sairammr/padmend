# padmend — design

**Date:** 2026-10-03
**Status:** implemented; awaiting validation on the damaged hardware

## Problem

A MacBook trackpad has dead spots: whole rows or columns of the capacitive
sensor grid report nothing, and some areas report intermittently. The owner
cannot use the full surface, and the resulting pointer behaviour is not merely
reduced but actively broken.

The hardware facts, measured on the target machine (macOS 27.0.1, Apple
Silicon, built-in trackpad, family 110):

- Sensor grid: **26 columns × 18 rows**.
- Surface: **121.9 × 74.1 mm**, so one trace is ≈ 4.69 × 4.12 mm.
- The private `MTTouch` struct is **96 bytes** and still decodes correctly.

The grid size is the key fact. A damaged trace takes out an entire row or
column, so the defect is a *shape* aligned to the hardware, not a scatter of
bad points. A map aligned to the real sensor turns "many scattered dead cells"
into "trace 11 is gone", which is both smaller to store and far stronger to
extrapolate from.

### Symptoms, ranked by how much they hurt

1. **Phantom lift and land.** An intermittent trace drops a contact for a few
   frames. macOS sees a finger leave and return, so drags end mid-gesture,
   two-finger scrolls become stray clicks, and spurious taps fire. This is the
   worst symptom and the one least obviously connected to "dead spots".
2. **Pointer stall and jump.** Motion across a dead stripe produces no deltas,
   then a large one.
3. **Unreachable screen area.** Usable surface is narrower than the pointer
   gain assumes.

Ranking matters: fixing (1) is worth more than fixing (3), and (1) is not what
the user originally asked about.

## Constraint

A touch over a dead cell was never measured. No software can recover it. Only
two things are possible, and the design does both:

- Avoid *needing* the dead area — scale motion so the live surface covers the
  whole screen.
- Keep motion continuous *across* it — extrapolate through the gap and stitch
  on re-acquisition.

## Approaches considered

**A — Corrective layer.** Leave macOS driving; patch the cursor and swallow
phantom clicks. Small, safe, keeps gestures for free. Ceiling: cannot fix a
gesture macOS already mis-recognised.

**B — Full takeover.** Suppress the built-in trackpad's input entirely and
drive everything from the raw stream. Total control; flicker fixed at source.
Costs: must reimplement pointer acceleration, scroll inertia and gesture
recognition, and carries the risk of making a machine unusable.

**C — DriverKit virtual pointing device.** Cleanest layering in principle, but
macOS trackpad gesture recognition lives in `AppleMultitouchDriver` bound to
real multitouch hardware. A virtual HID pointer yields a mouse, not a trackpad,
losing gestures entirely. Rejected.

**Chosen: B**, at the user's direction, with A's safety posture retained — the
suppression is a switch, not a structural assumption, and the engine runs in an
observe mode during calibration that changes nothing.

## Architecture

```
MultitouchSupport (private, dlopen)
        │  raw contact frames, ~90 Hz, on its own thread
        ▼
   ContactTracker ──────────────► stable fingers + lifecycle events
        │                          (re-association, coasting, phantom taps)
        ├── 1 finger ──► PointerMapper ──► pointer delta in screen points
        ├── 2+ fingers ─► GestureRecognizer ──► scroll / pinch / swipe
        └── calibrating ─► Calibrator ──► CoverageMap ──► DeadMap
                                                            │
        EventTap (suppress the pad's own input) ◄────────────┘
        EventPoster (post the replacement)            evidence feeds back
```

`PadmendCore` holds every decision and has no system dependencies, so all of it
is testable from synthetic frames. `PadmendKit` holds the hardware, the event
tap, the posting, and the interface.

### Dead map

Per cell, two counters:

- `hits` — the sensor reported a touch here. Proves the trace is not severed.
- `transits` — a tracked finger was over this cell on a frame where the sensor
  reported nothing. Proves the cell failed.

Classification: silence with sufficient transits is `dead`; a hit rate below
0.6 with enough samples is `flaky`; no evidence is `unknown`. Unknown counts as
usable, because shrinking the working area on the strength of no evidence would
punish an incomplete sweep.

A stripe rule condemns a whole trace when ≥ 60% of its judged cells are
suspect, and fills that trace's unknown cells with whichever fault its judged
cells actually showed — a trace that flickers is reported as flickering, not
promoted to severed. "Condemned" means unusable for pointer travel, which a
thoroughly intermittent trace is just as much as a dead one.

### Evidence attribution — three attempts

This took three designs, and the two failures are the most instructive part of
the project.

1. **Credit the cells strictly between a dropout's endpoints.** Fails when a
   contact vanishes between *neighbouring* cells: there is no interior, so an
   intermittent trace — whose dropouts are short — accumulates no evidence and
   reads as healthy. Crediting both endpoints instead makes the healthy cells
   either side of a damaged trace look damaged.
2. **Credit the tracker's extrapolated positions.** Fixes that, but coasting
   velocity decays, so across a wide dead region the extrapolated positions lag
   the real finger and pile every silent frame onto the near edge. A
   four-column band was detected only two columns deep.
3. **Retrospective interpolation** (chosen). Once a dropout is repaired, both
   endpoints are known, so the silent frames are spread evenly along the line
   between them. Silent frames are held until the dropout's outcome is known
   and discarded if the contact never returns — otherwise calibration paints a
   dead spot wherever the user happens to lift their finger.

### Contact tracker

State per track: hardware id, last real position, reported position, velocity,
path length, stitch offset, coasting flag, and whether it has been over suspect
area.

- **Affirmative lift wins.** `breakTouch` ends a track immediately and is never
  second-guessed. A contact that *vanishes* without it is the dropout signature.
- **Hold and re-associate**, gated on map evidence, within a 120 ms window and
  a 0.12-normalised radius of the predicted position.
- **Coast** on decaying velocity (τ = 90 ms), capped at 0.30 normalised, and
  bleed the re-acquisition error off over 50 ms.
- **Suppress** taps under 80 ms that began and ended over suspect cells.

The gates are **asymmetric in the number of fingers down**, which is the one
behavioural rule that had to be corrected after a test caught it. For a lone
finger, holding a vanished contact open costs lag on every lift and click, so
it is only done over known-bad area. With two or more fingers down the trade
reverses: fingers rarely leave one at a time mid-scroll, so a wrong hold costs
milliseconds at the end of a gesture while a wrong lift tears the gesture in
half. Both the hold and the re-association gate therefore relax while a
multi-finger gesture is in progress.

### Pointer mapping

Compensation = `1 / usableFraction` per axis, capped at 3× — past roughly that
the pointer is unusable however much surface was lost. A smoothstep
acceleration curve sits on top (0.55× below 12 mm/s, 2.6× above 220 mm/s).
Sub-pixel movement accumulates, because at low gain a slow finger produces less
than one point per frame and per-frame rounding would discard it.

### Gesture recognition

Two fingers are ambiguous. The recognizer stays undecided until the fingers
have moved 1.2 mm, then compares accumulated translation against accumulated
separation (with a 1.2× bias toward scroll) and **latches** — switching mode
mid-gesture would make both feel unreliable. Movement spent deciding is carried
into the first event rather than discarded.

Swipes need 9 mm of centroid travel and all fingers agreeing on a direction, so
a pinch with a drifting centroid cannot register as one. They are reported once
per gesture.

Scroll inertia is generated here, driven by a timer rather than the contact
stream, because the hardware stops reporting the moment the fingers leave.

### Suppression and safety

`CGEventTap` at the HID level, head-inserted. Movement is dropped only while
the tracker reports fingers on the pad, so an external mouse is untouched.
Trackpad scroll is identified by the continuous-scroll flag, which a physical
wheel never sets. Clicks pass through normally and are swallowed only inside a
160 ms window opened by a phantom-tap verdict; physical force clicks therefore
keep working, which matters because the click mechanism is a separate sensor
and stays reliable when the digitizer does not.

Four safety properties: the panic chord (⌃⌥⌘P) works without a pointer; a tap
dies with its process, so a crash restores the pad; a stalled tap is disabled
by macOS and re-enabled here; and suppression is gated on fingers being present.

## Known compromises

- **Pinch** is posted as ⌘+ / ⌘−. `CGEvent` cannot construct an
  `NSEventTypeMagnify`, so a real pinch is not synthesisable. Works in
  browsers, editors and terminals; does nothing in Maps, Preview or Photos.
- **Swipes** are posted as ⌃arrow shortcuts. Real multi-finger gestures cannot
  be synthesised from outside WindowServer. Mission Control and desktop
  switching behave identically; an app with its own three-finger handling will
  not see them.
- **No assist mode.** Repairing while macOS still drives would double-count
  motion. Observe and takeover are the two modes.
- **One device.** The private callback carries no context pointer, so the shim
  holds a single active device. A second trackpad would need a device-keyed map.

## Testing

80 tests over the geometry, classification, tracker repairs, pointer mapping,
gesture recognition, calibration end to end against a simulated damaged pad,
and the whole pipeline measured in screen points. A `PadSimulator` generates
contact streams for a pad with chosen defects, including the hardware's habit
of issuing a fresh contact identifier after a dropout — which is what makes a
flicker look like a lift and a land.

Hardware-dependent behaviour is covered by `padmend selftest`: both
permissions, that the contact stream opens, that posted pointer movement moves
the cursor and can be put back, and that the tap can be created, suppress and
tear down. All of it passes on the target machine.

What no automated test can cover is whether the result *feels* right, and
whether the real damage matches what calibration finds. That needs the damaged
pad and its owner.

## Open questions

- Where the damage actually is. The design assumes stripes because that is what
  was reported; calibration will say.
- Whether the tracker's defaults suit this pad. Grace window, coast cap and
  phantom-tap threshold are the knobs most likely to need tuning, and all are
  in `TrackerConfig`.
- Whether the compensation cap of 3× is enough, or too much to live with.
