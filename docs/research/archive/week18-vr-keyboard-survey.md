# VR Virtual Keyboard Survey

## Overview

Virtual keyboards in VR must contend with the absence of physical key
surfaces, imprecise hand tracking, and the need for sustained text entry
without fatigue. This document surveys layout approaches, hit testing
strategies, haptic feedback, and modifier handling across major VR
platforms. It records design decisions for EXWM-VR's virtual keyboard
module (`virtual_keyboard.rs`).

## Layout Approaches

**QWERTY** remains the default due to user familiarity. VR requires
increased key spacing (hand tracking has 5-10 mm fingertip error),
curved or angled layouts to avoid looking down, and optionally split
left/right halves for natural arm position.

**Dvorak and Colemak** reduce finger travel. In VR, travel distance
matters less but reduced hand movement amplitude may lower fatigue.
Supporting multiple layouts is straightforward since layout is data.

**Specialized VR layouts** include radial/circular (keys in concentric
rings), T9-style reduced key sets with predictive disambiguation, and
drum-style (keys on the inside of a virtual cylinder). These trade
familiarity for potentially faster input for trained users.

For EXWM-VR, we support QWERTY, Dvorak, and Colemak via a configurable
layout table. Custom layouts can be defined in Elisp and sent via IPC.

## Key Sizing and Spacing

Physical keys are approximately 15 mm wide with 4 mm gaps. In VR, hand
tracking error requires larger targets:

- Minimum recommended key width: 20-24 mm.
- Recommended gap: 4-6 mm.
- Total keyboard width: ~500-550 mm for a 10-key QWERTY row.
- Key height: 20-24 mm (vertical precision is worse than horizontal).
- Position: 40-60 cm from chest, angled 15-30 degrees from horizontal.

All spatial parameters are IPC-configurable in EXWM-VR.

## Hit Testing Approaches

### Ray Casting

A ray from the fingertip intersects the keyboard plane; nearest key is
selected. Activation by pinch gesture or pushing past the surface.
Works at any distance but amplifies jitter; requires confirmation.

### Proximity / Direct Touch

Each fingertip compared against key spatial bounds. A two-zone model
mitigates accidental activation: an outer hover zone (5-15 mm) for
highlights and an inner press zone (0-5 mm) for activation. Optionally
require minimum downward velocity. Most natural for typing but requires
keyboard within arm's reach.

### Dwell

Hold pointer over a key for 300-800 ms to activate. Accessibility
fallback; too slow for sustained typing (20-30 WPM ceiling).

### EXWM-VR Approach

Primary: proximity-based direct touch with two-zone model. Fallback:
ray casting for distant placement. Dwell available as accessibility
option. Hit test mode and zone distances are IPC-configurable.

## Haptic Feedback

- **Controller haptics**: vibration pulse on keypress (controller only).
- **Audio feedback**: click sound on activation, widely effective. We
  emit a `keyboard-keypress` IPC event for Emacs to trigger audio.
- **Visual feedback**: key depression animation, color flash. Handled
  in the compositor's keyboard renderer.
- **Ultrasonic arrays**: experimental finger resistance; not on consumer
  hardware.

## Modifier Key Handling

Simultaneous multi-key input is difficult with hand tracking. Approaches:

**One-shot (sticky) modifiers**: pressing a modifier activates it for
the next keypress only, then deactivates. Double-tap locks it on.
Matches Emacs's sticky-keys concept and is the standard VR approach.

**Gesture-based modifiers**: a hand gesture held during a keypress
applies a modifier (e.g., left fist + right typing = Ctrl). Keeps both
hands productive but requires simultaneous gesture + hit test tracking.

EXWM-VR uses one-shot modifiers by default with double-tap lock.
Gesture-based Ctrl (left fist) is available as an opt-in feature.
Modifier state is tracked in `virtual_keyboard.rs` and included in
IPC keypress payloads. Elisp maps to standard Emacs key representation.

## Platform Survey

### Meta Quest Virtual Keyboard

Flat QWERTY layout, supports controller pointer and direct hand tracking.
Two-zone proximity model. Predictive text bar with swipe-to-type
(controller only). Voice input primary alternative. GBoard integration
for multilingual support. Keys approximately 22 mm wide.

### Apple Vision Pro Keyboard

Look-and-tap model: gaze at key to highlight, pinch to activate.
Leverages eye tracking precision for targeting. Physical keyboard
passthrough with tracked highlights when Bluetooth keyboard nearby.
Dictation prominently featured.

### Immersed Virtual Keyboard

Physical keyboard passthrough with overlay as primary mode. Floating
virtual keyboard with hand tracking as fallback. Custom layouts and
sizes. Designed for developer-grade text entry speed.

## Text Prediction in VR

Predictive text improves speed where raw input is 15-25 WPM (vs. 40-80
on physical keyboards). Approaches: autocomplete bar (Meta Quest model),
inline ghost text (accepted by swipe gesture), sentence prediction.

For EXWM-VR, prediction is handled on the Emacs side. The compositor
sends raw keypress events via IPC; Emacs packages like `company-mode`
or `corfu` provide completion. The virtual keyboard sends a
`keyboard-text-input` event with key symbol and modifier state.

## EXWM-VR Configuration Summary

IPC-configurable parameters:

- `keyboard-layout`: qwerty, dvorak, colemak, or custom definition.
- `keyboard-key-size`: width and height in meters.
- `keyboard-gap`: inter-key gap in meters.
- `keyboard-position`: 3D position relative to user.
- `keyboard-angle`: tilt angle in degrees.
- `keyboard-hit-mode`: proximity, raycast, or dwell.
- `keyboard-hover-distance` / `keyboard-press-distance`: zone thresholds.
- `keyboard-modifier-mode`: one-shot, locked, or gesture-based.
- `keyboard-visible`: show/hide toggle.

All mirrored as `defcustom` variables in `ewwm-vr-keyboard.el`.

## References

- Meta Quest Virtual Keyboard Design Guidelines:
  https://developer.oculus.com/resources/hands-design-virtual-keyboard/
- Apple visionOS Text Input Guidelines:
  https://developer.apple.com/design/human-interface-guidelines/text-fields
- Markussen, A., Jakobsen, M.R., & Hornbaek, K. (2014). Vulture: A
  Mid-Air Word-Gesture Keyboard.
  https://dl.acm.org/doi/10.1145/2556288.2556964
- Kim, Y.R. & Kim, G.J. (2020). HoVR-Type: Smartphone-based 3D Virtual
  Keyboard for VR Head-Mounted Displays.
  https://doi.org/10.1016/j.ijhcs.2019.102364
- Speicher, M., Feit, A.M., Ziegler, P., & Kruger, A. (2018). Selection-
  Based Text Entry in Virtual Reality.
  https://dl.acm.org/doi/10.1145/3173574.3174221
- Fitts, P.M. (1954). The Information Capacity of the Human Motor System
  in Controlling the Amplitude of Movement. Journal of Experimental
  Psychology, 47(6), 381-391.
