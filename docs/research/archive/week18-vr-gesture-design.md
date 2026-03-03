# VR Gesture Recognition Design Patterns

## Overview

Gesture recognition translates hand poses and motions into discrete
semantic events that a window manager can bind to commands. This document
surveys gesture detection heuristics, debouncing strategies, and binding
systems used across major VR platforms, and records the design choices
for EXWM-VR's gesture module (`gesture.rs`).

## Static Gesture Detection

Static gestures are recognized from a single frame of hand joint data.
Detection relies on geometric relationships between joints.

### Pinch

Thumb tip touching index fingertip -- the most universal VR interaction
primitive. Compute distance between thumb tip (joint 4) and index tip
(joint 9). If distance < threshold (typically 2-3 cm), pinch is active.
Optionally require other fingers partially extended to reject fist false
positives. Pinch strength is a continuous value:
`1.0 - clamp(distance / max_distance, 0.0, 1.0)`. Variants include
middle-finger, ring-finger, and pinky pinch.

### Grab / Fist

All four fingers curled toward the palm. For each finger, compute the
angle between proximal-intermediate and intermediate-distal bone vectors.
If all curl angles exceed 90 degrees, classify as fist. Partial grab
(3 of 4 curled, index extended) indicates grab-with-point.

### Point

Index finger extended (curl < 30 degrees) while middle, ring, and pinky
are curled (> 80 degrees). Thumb position is ignored. Useful for
ray-based pointing at distant UI elements.

### Open Palm

All five fingers extended (curl < 25 degrees), palm facing a specific
direction. Optionally check palm normal (facing user = "stop", facing
away = "push"). In EXWM-VR, open palm facing the headset triggers the
command palette (analogous to M-x).

### Thumbs Up

Thumb extended upward (curl < 30 degrees), other four fingers curled
(> 80 degrees), thumb tip above metacarpal in world Y. Can serve as
a confirmation gesture.

## Dynamic Gesture Detection

### Swipe Detection

A rapid lateral or vertical hand movement detected over a sliding window
of palm positions (200-500 ms). If displacement exceeds 15 cm and
velocity exceeds 0.5 m/s, classify as swipe. Direction determined by
dominant displacement axis. A linearity check rejects curved paths.

### Flick

A short, sharp wrist rotation tracked over 100-200 ms. Angular velocity
must exceed threshold and hand must return to original orientation. Not
implemented in Week 18; noted for future work.

## Debouncing and Hold Duration

Raw gesture classification produces noisy transitions. A debouncing
system is essential:

- **Activation debounce**: gesture must be detected for N consecutive
  frames (3-5 at 90 Hz) before reporting as active.
- **Deactivation debounce**: gesture remains active for a minimum hold
  duration (50-100 ms) even if detection momentarily fails.
- **Hold events**: for sustained gestures, emit repeat events after an
  initial delay (300-500 ms) at a repeat interval (50-100 ms).
- **Cooldown**: after release, prevent re-activation for 100-150 ms to
  avoid double-triggers during release motion.

## Gesture Binding Systems

### Direct Mapping Table

A flat association between (hand, gesture, modifier-state) tuples and
command identifiers. Simple but inflexible.

### Hierarchical / Modal Bindings

Gestures have different meanings depending on context. Pinch-and-drag
in "window mode" moves a window; in "scroll mode" it scrolls content.
Modes activated by specific gestures (open palm -> command mode).

### Chord and Sequence Bindings

Simultaneous gestures on both hands form chords (left pinch + right
swipe = move window). Gestures can also compose into sequences
analogous to Emacs key sequences (C-x C-f). Powerful but challenging
for discoverability and timing.

## Platform Survey

### Meta Quest

Centers on pinch for selection and direct manipulation. System hand menu
appears on upturned palm. Pinch-to-select, pinch-and-drag, ray pointer
from pinched fingers. No exposed gesture binding API; hardcoded system
gestures. Recent updates add direct touch for close-range UI.

### Apple Vision Pro

Look-and-pinch model: gaze at target, pinch to select. Decouples
pointing (eyes) from confirmation (hand). Supports pinch-and-drag,
two-handed zoom/rotate, tap vs. long press. Custom gestures via ARKit
but system gestures are not overridable.

### Microsoft HoloLens 2

Air tap for selection, grab-and-manipulate for direct interaction, ray
plus air tap for far interaction, bloom gesture for system menu. MRTK
provides a gesture binding framework with configurable mappings.

## EXWM-VR Design Choices

For `gesture.rs`, we implement an Emacs-inspired gesture binding system:

1. **Gesture alist**: `Vec<GestureBinding>` mapping `(Hand, GestureType)`
   to IPC command strings, mirroring Emacs keymap alists.
2. **Static gestures**: pinch, grab, point, open-palm with configurable
   distance/angle thresholds.
3. **Dynamic gestures**: four-directional swipe via velocity-window.
4. **Debouncing**: 3-frame activation, 80 ms deactivation holdoff,
   120 ms cooldown. All IPC-configurable.
5. **No chord/sequence detection** this iteration. Deferred.
6. **Emacs integration**: events forwarded as `(gesture HAND TYPE STATE)`
   s-expressions. `ewwm-vr-gesture.el` dispatches through
   `ewwm-vr-gesture-alist`, a user-configurable alist.
7. **Default bindings**: right-pinch -> select, right-point -> pointer,
   left-open-palm -> M-x, left-swipe-left/right -> workspace switch.

## References

- OpenXR XR_EXT_hand_tracking specification:
  https://registry.khronos.org/OpenXR/specs/1.1/html/xrspec.html#XR_EXT_hand_tracking
- Meta Quest Hand Tracking Design Guidelines:
  https://developer.oculus.com/resources/hands-design-guidelines/
- Apple visionOS Human Interface Guidelines - Gestures:
  https://developer.apple.com/design/human-interface-guidelines/gestures
- Microsoft MRTK Gesture Documentation:
  https://learn.microsoft.com/en-us/windows/mixed-reality/mrtk-unity/features/input/gestures
- Dollar Family Gesture Recognizers:
  https://depts.washington.edu/acelab/proj/dollar/
- Wobbrock, J.O., Wilson, A.D., & Li, Y. (2007). Gestures without
  Libraries: $1 Unistroke Recognizer.
  https://dl.acm.org/doi/10.1145/1294211.1294238
