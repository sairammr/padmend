# padmend

Make a MacBook trackpad with dead spots usable again.

When a capacitive trace in a trackpad fails, the pad stops reporting touches
along a whole row or column of its sensor grid. On a 2021-era MacBook that grid
is 26 × 18 traces across 122 × 74 mm, so one dead trace is a stripe about
4.7 mm wide where the pad simply says nothing. The visible symptoms are worse
than "the cursor stops":

- **The pointer stalls** crossing the stripe, then jumps when the finger comes
  out the other side.
- **Drags break.** A contact that vanishes and returns looks to macOS like a
  finger lifting and landing, so a drag ends mid-gesture and a scroll turns
  into a stray click.
- **Phantom clicks.** An intermittent trace flickers on and off faster than a
  human can tap, and macOS dutifully synthesises a click from each flicker.
- **Part of the screen gets hard to reach**, because the surface you can
  actually use is narrower than the surface the pointer gain was tuned for.

padmend reads the raw sensor, works out which traces are bad, and replaces what
the trackpad sends with something coherent.

## What it cannot do

The dead area is dead. A touch there was never measured, so no software can
recover it. padmend does the two things that are actually possible: it avoids
*needing* the dead area, and it keeps motion continuous *across* it. It does not
resurrect the sensor, and it is not a substitute for repair.

## How it works

Four pieces, each independently testable:

**Dead map.** Calibration has one hard problem: telling a dead cell apart from
one you never swept. padmend resolves it by counting two things per cell —
*hits*, where the sensor reported a touch, and *silent frames*, where a tracked
finger provably was over the cell and the sensor said nothing. Silence with no
hits is dead; neither is unknown, and unknown is reported as unknown rather than
guessed at. A cell that answers sometimes is flaky, which is a different fault
and gets different treatment. A stripe rule then condemns an entire trace when
most of its judged cells are bad, and extends that verdict to the cells you
never reached — which is what makes calibration take fifteen seconds instead of
being a chore.

**Contact tracker.** Three repairs, all gated on map evidence so a healthy pad
is left alone:

- *Re-association.* A contact that vanishes over bad area and reappears nearby
  is the same finger, and is reported as such. No lift, no land, no broken drag.
- *Coasting.* While the sensor is silent, the finger's last velocity carries the
  pointer, decaying, with a hard cap so a fast flick into a dead stripe cannot
  fling the cursor across the screen. On re-acquisition the accumulated error is
  bled off over 50 ms rather than snapped.
- *Phantom tap suppression.* A contact that appears and disappears over
  unreliable cells faster than a human taps is noise, and the click macOS builds
  from it is swallowed.

An affirmative `breakTouch` — the hardware stating that the finger left — is
always honoured immediately and never second-guessed.

**Pointer mapping.** Motion is scaled up by the reciprocal of the surface that
still works, capped at 3×, so the whole screen stays reachable from a narrowed
pad. Ordinary acceleration sits on top, and sub-pixel movement accumulates
instead of rounding away.

**Gesture recognition.** Two fingers are ambiguous between scroll and pinch, so
one state machine watches which quantity moves first, commits, and latches.
Three- and four-finger swipes require the fingers to agree on a direction.
Scroll inertia is generated here, because macOS produces it inside the trackpad
driver, below the level this program works at.

## Install

Requires macOS 13 or later and a Swift 6 toolchain.

```sh
git clone https://github.com/sairammr/padmend
cd padmend
./Scripts/make-app.sh
cp -r dist/padmend.app /Applications/
open /Applications/padmend.app
```

Two permissions are needed, and padmend asks for both on first launch:

- **Input Monitoring**, to read the raw sensor.
- **Accessibility**, to replace what the sensor sends.

macOS grants these to a specific signed binary, so the app has to be approved
even if your terminal already was. The signature is ad-hoc, which means
rebuilding may make macOS ask again.

Then: click the menu bar icon → **Calibrate…**, sweep the whole pad in slow
overlapping strokes, and save.

## Command line

The CLI does everything the menu bar app does and is the better way to see what
is going on.

```sh
swift build -c release
.build/release/padmend doctor      # permissions, hardware, saved map
.build/release/padmend selftest    # everything checkable without a finger
.build/release/padmend probe       # raw contact stream
.build/release/padmend calibrate   # sweep the pad, live heat map in the terminal
.build/release/padmend map         # show the saved map
.build/release/padmend run         # take over and compensate
```

Sweep **slowly** when calibrating. A fast stroke gives a bad cell fewer chances
to fail, so it can look healthy.

## Safety

A program that swallows pointer events can leave a machine unusable, so:

- **Control-Option-Command-P** turns compensation off instantly, without needing
  a working pointer to reach a menu.
- An event tap dies with its process, so a crash restores the trackpad
  immediately.
- macOS disables a tap whose callback stalls; padmend detects that and
  re-enables it.
- Movement is suppressed only while fingers are actually on the pad, so an
  external mouse keeps working regardless.
- A physical mouse wheel is left alone, identified by the continuous-scroll flag
  that a real wheel never sets.

## Known compromises

Two places where the takeover is not faithful, both for the same reason — the
public API cannot express the event:

- **Pinch** is posted as Command-plus / Command-minus. `CGEvent` cannot
  construct an `NSEventTypeMagnify`, so a real pinch cannot be synthesised. This
  works in browsers, editors and terminals, and does nothing in Maps, Preview or
  Photos, where zoom is continuous.
- **Swipes** are posted as the Control-arrow shortcuts rather than real
  multi-finger gestures, which cannot be synthesised from outside WindowServer.
  Mission Control and desktop switching behave identically; an app with its own
  three-finger handling will not see them.

`MultitouchSupport.framework` is private. Its symbols are resolved with
`dlopen`/`dlsym` rather than linked, because direct calls into a private
framework fault under arm64e pointer authentication. The 96-byte touch struct
has been stable since 10.5 and is verified at runtime, but Apple owes nobody
compatibility here.

## Tests

```sh
swift run padmend-tests
```

80 tests covering the sensor geometry, map classification, the tracker's repair
behaviour, pointer mapping, gesture recognition, calibration end to end against
a simulated damaged pad, and the whole pipeline measured in screen points. The
harness is a hundred lines in `Sources/padmend-tests/Harness.swift`: this
machine has Command Line Tools without Xcode, which ships neither XCTest nor
swift-testing, and a package dependency is too much to pay for assertions.

`padmend selftest` covers what unit tests cannot — that the contact stream opens
on real hardware, that posted pointer movement actually moves the cursor, and
that the event tap can be created, suppress, and tear down.

## Layout

| Path | What it is |
| --- | --- |
| `Sources/CMultitouch` | `dlopen` shim over the private multitouch framework |
| `Sources/PadmendCore` | All the logic, no system dependencies, fully testable |
| `Sources/PadmendKit` | Hardware, event tap, event posting, engine, interface |
| `Sources/padmend` | CLI |
| `Sources/padmend-tests` | Test suite and its harness |
| `docs/specs` | Design document |

## Licence

MIT.
