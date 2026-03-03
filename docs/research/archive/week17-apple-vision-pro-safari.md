# R17.3: Apple Vision Pro Safari UX Patterns

## Context

Apple Vision Pro (visionOS) shipped with the most polished gaze-based browser
interaction to date. This document analyzes Safari's UX patterns on Vision Pro
and identifies patterns applicable to EWWM-VR's qutebrowser integration.

## "Look and Tap" Interaction Model

Vision Pro uses eye tracking as the primary pointing device. The interaction
model is:

1. **Look** at an interactive element (link, button, text field)
2. The element subtly **highlights** (slight scale-up + shadow change)
3. **Tap** thumb and index finger together to confirm the action

This is intentionally *not* pure gaze dwell. Apple found that dwell-based
activation caused too many accidental clicks during reading. The pinch gesture
provides explicit confirmation.

**Key design decisions:**
- Gaze is used for *targeting*, not *activation*
- No visible cursor or reticle on screen
- Highlight feedback is subtle (1.02x scale, slight glow) to avoid distraction
- 60ms latency from gaze landing to highlight appearing
- Elements must be at least 60pt (roughly 44px at arm's length) to be reliably
  targetable

## Gaze Cursor Behavior

Safari on Vision Pro has **no visible gaze cursor**. The user's gaze is tracked
but not displayed. Instead, interactive elements respond to gaze by:

- Slightly enlarging (scale transform)
- Adding a subtle shadow/glow
- Changing background opacity

Non-interactive elements show no feedback at all. This prevents the "cursor
chasing" problem where users fixate on the cursor itself.

**Applicable pattern:** EWWM should highlight qutebrowser hints without showing
a separate cursor element. The userscript should modify the target element's
style directly (outline, background) rather than rendering an overlay dot.

## Scroll Acceleration Curves

Vision Pro Safari scrolling is triggered by "look + pinch and drag" (not pure
gaze scroll). However, Apple researched gaze-initiated scrolling and rejected
it for general browsing because:

- Reading requires extended gaze near page edges (where scroll triggers live)
- Accidental scrolling during reading was the top usability complaint

For long documents, Vision Pro uses:
- Inertial scrolling with a deceleration curve (0.998 friction per frame)
- Rubber-banding at content boundaries
- Velocity proportional to drag distance, not gaze position

**Applicable pattern:** EWWM's gaze scroll should have a dead zone in the center
(at least 70% of viewport height). Only the outer 15% margins should trigger
scrolling. Speed should ramp gradually (not snap to full speed).

## Tab Management in visionOS

Safari on Vision Pro uses a **2D tab bar** floating above the browser window.
Tabs are arranged horizontally as small thumbnails.

Key behaviors:
- Tab bar appears on gaze-up gesture (looking above the window)
- Tabs show page thumbnails, not just titles
- Maximum visible tabs: ~8 before horizontal scrolling
- Tab groups (collections) are displayed as separate floating panels
- New tabs open as a new window by default in the 3D space

**Applicable pattern:** For EWWM tab-as-buffer, the Emacs buffer list / ibuffer
serves the same role as Vision Pro's tab bar. No need to replicate 3D tab
thumbnails. The buffer switching mechanism (C-x b, consult) is more efficient.

## Text Input

Text input in Safari on Vision Pro:
- A virtual keyboard appears floating in front of the user
- Gaze + pinch is used for key-by-key input (slow)
- Voice dictation is the primary text input method
- Bluetooth keyboards are supported (preferred by power users)

**Applicable pattern:** EWWM should not try to build a gaze-based keyboard.
KeePassXC auto-type via compositor key injection (already implemented in
Week 14) is the correct approach for credential entry. For general text
input, a hardware keyboard is assumed.

## Applicable Patterns for EWWM

| Vision Pro Pattern | EWWM Implementation |
|---|---|
| Look + pinch to click | Gaze + wink/blink to confirm (Week 13 wink detector) |
| No visible cursor | Highlight target element CSS, no overlay cursor |
| Subtle highlight (scale + glow) | CSS outline + slight background change via userscript |
| 60pt minimum target size | Enforce minimum hint box size in gaze-follow |
| Dead zone for scroll | 70% center dead zone, 15% top/bottom margins |
| 2D tab bar | Emacs buffer list / consult narrowing |
| Hardware keyboard for text | KeePassXC auto-type + physical keyboard |

## Summary

Apple's research confirms that pure gaze dwell is insufficient for reliable
browser interaction. An explicit confirmation gesture (pinch for Apple, wink
for EWWM) is essential. The highlight-without-cursor approach reduces visual
clutter and prevents cursor fixation. Scroll dead zones prevent accidental
scrolling during reading.
