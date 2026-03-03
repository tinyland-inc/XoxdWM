# Hand Tracking Algorithms for VR Window Management

## Overview

Hand tracking in VR replaces or supplements controller input by detecting
the pose of each finger joint in real time. For a VR window manager like
EXWM-VR, hand tracking serves as the primary mechanism for gesture
recognition, virtual keyboard input, and spatial UI manipulation. This
document surveys the algorithmic landscape and records our design choices
for the Week 18 hand tracking module.

## OpenXR XR_EXT_hand_tracking

The OpenXR `XR_EXT_hand_tracking` extension defines a standardized 26-joint
skeleton per hand. The joints follow a hierarchical kinematic chain:

- **Palm** (1 joint): anchor for the hand coordinate space.
- **Wrist** (1 joint): connects to the forearm reference.
- **Thumb** (4 joints): metacarpal, proximal, distal, tip.
- **Index through Little** (5 joints each): metacarpal, proximal,
  intermediate, distal, tip.

Each joint reports an `XrHandJointLocationEXT` containing:

- `pose` (position + orientation as `XrPosef`)
- `radius` (approximate joint sphere radius in meters)
- `locationFlags` bitmask (`XR_SPACE_LOCATION_POSITION_VALID_BIT`,
  `XR_SPACE_LOCATION_ORIENTATION_VALID_BIT`, and their `_TRACKED` variants)

The runtime also provides per-joint velocity via `XrHandJointVelocityEXT`
when `XR_EXT_hand_tracking_data_source` or velocity extensions are present.
Joint data arrives at frame rate (typically 72-120 Hz) and must be
requested each frame via `xrLocateHandJoints`.

Monado (our target OpenXR runtime) implements this extension and exposes
hand tracking from a variety of drivers including camera-based and
Ultraleap backends.

## Joint Filtering and Smoothing

Raw joint data from any vision-based hand tracker exhibits jitter,
occasional frame drops, and varying latency. Smoothing is essential for
usable UI interaction. Three common approaches:

### Exponential Moving Average (EMA)

The simplest viable filter. For each joint position component:

    smoothed = alpha * raw + (1 - alpha) * prev_smoothed

where `alpha` in (0, 1) controls responsiveness. Lower alpha means more
smoothing but higher lag. EMA is trivial to implement, has O(1) memory
per joint, and introduces minimal latency at alpha >= 0.3.

Downsides: EMA cannot adapt to signal speed. Fast intentional movements
are damped, while slow jitter is insufficiently filtered.

### Kalman Filter

A Kalman filter models the joint as a state vector (position + velocity)
with a linear motion model and Gaussian noise assumptions. It provides
optimal linear estimation when the noise is truly Gaussian. Per-joint
state is a 6-element vector (3 position + 3 velocity) with a 6x6
covariance matrix.

Downsides: hand motion is highly nonlinear and non-Gaussian. An
Unscented Kalman Filter (UKF) handles nonlinearity better but at
significant computational cost (26 joints x 2 hands = 52 filter
instances per frame).

### 1-Euro Filter

The 1-Euro filter (Casiez et al., 2012) is an adaptive low-pass filter
that varies its cutoff frequency based on signal speed. At low speed
(jitter), the cutoff drops and smoothing increases. At high speed
(intentional motion), the cutoff rises and lag decreases.

Parameters: `min_cutoff` (jitter reduction), `beta` (speed response),
`d_cutoff` (derivative smoothing). The filter is lightweight (two EMA
filters internally) and well-suited to interactive pointing tasks.

Downsides: requires per-application tuning of beta and min_cutoff.
Poorly chosen parameters can cause oscillation or excessive lag.

## Confidence-Based Tracking Activation

Not all frames produce reliable joint data. Occlusion (fingers curled
behind the palm, one hand covering the other) and poor lighting cause
tracking loss. A confidence gating system prevents spurious input:

- **Per-joint confidence**: derived from `locationFlags`. A joint is
  "confident" when both `POSITION_VALID` and `POSITION_TRACKED` bits
  are set. Joints that are only `VALID` (extrapolated, not tracked) are
  marked low-confidence.
- **Hand confidence**: aggregated from per-joint scores. A simple
  approach counts the fraction of confident joints. If fewer than 60-70%
  of joints are confident, the hand is considered "lost" and input
  events are suppressed.
- **Hysteresis**: activation requires confidence above an upper threshold
  (e.g., 0.7) for N consecutive frames, while deactivation triggers when
  confidence drops below a lower threshold (e.g., 0.5). This prevents
  flickering at boundary conditions.
- **Grace period**: after tracking loss, a short grace window (100-200 ms)
  holds the last known pose before declaring the hand inactive. This
  handles momentary occlusions during normal interaction.

## Prediction and Latency Compensation

End-to-end latency from camera capture to rendered frame can be 20-40 ms.
For direct manipulation (grabbing, typing), this lag degrades usability.
Prediction extrapolates joint positions forward in time:

- **Linear extrapolation**: extend each joint along its velocity vector
  by the predicted display time offset. Simple but diverges quickly for
  non-linear motion (e.g., finger curling).
- **Quadratic extrapolation**: uses position, velocity, and acceleration.
  More accurate for short horizons (< 20 ms) but amplifies noise.
- **OpenXR predicted display time**: `xrLocateHandJoints` accepts a
  `time` parameter. Passing the predicted display time from
  `XrFrameState::predictedDisplayTime` lets the runtime perform its own
  internal prediction, which is generally superior to application-side
  extrapolation.

For EXWM-VR, we rely on the runtime's predicted display time and do not
perform additional application-level prediction. This keeps the code
simple and avoids double-prediction artifacts.

## Platform Comparison

### Meta Quest Hand Tracking

Meta's hand tracking (v2.2) uses onboard cameras and a neural network
running on the Snapdragon XR2 DSP. It achieves sub-centimeter accuracy
for most joints in good conditions. Latency is approximately 25-35 ms.
The system handles self-occlusion reasonably well but struggles with
hand-hand interaction and very fast motion. Meta exposes data through
both the OpenXR extension and their proprietary OVR API.

### Ultraleap (formerly Leap Motion)

Ultraleap uses dedicated infrared cameras and stereo vision. The Gemini
(v5) tracking engine achieves higher accuracy than camera-passthrough
systems, particularly for fine finger movements. Latency is 10-20 ms.
Monado includes an Ultraleap driver that maps to the OpenXR hand
tracking extension. The main drawback is the requirement for additional
hardware and a limited tracking volume.

### MediaPipe Hands

Google's MediaPipe Hands runs on CPU/GPU using a two-stage ML pipeline
(palm detection + hand landmark regression). It tracks 21 landmarks
(not the full 26 OpenXR joints; missing some metacarpals). Accuracy is
lower than dedicated VR systems but sufficient for coarse gestures.
Latency depends on hardware; 30-60 ms on desktop GPU. Not directly
usable in OpenXR but relevant as a fallback for webcam-based desktop
usage.

## EXWM-VR Design Choices

For our hand tracking module (`hand_tracking.rs`), we adopt:

1. **EMA smoothing** with configurable alpha (default 0.4). We chose EMA
   over the 1-Euro filter for simplicity and predictability. The alpha
   value is exposed as an IPC-configurable parameter so users can tune
   responsiveness vs. stability.

2. **Confidence gating** with hysteresis. Upper threshold 0.7, lower 0.5,
   with a 150 ms grace period. These values are also IPC-configurable.

3. **Runtime-side prediction** only (via `predictedDisplayTime`). No
   application-level extrapolation.

4. **Per-hand state machine**: Inactive -> Tracking -> Active -> Lost.
   The Active state requires sustained confidence above threshold.
   Gesture recognition only operates on Active hands.

5. **Joint data structure**: a flat `[JointPose; 26]` array per hand,
   indexed by the OpenXR joint enum. This avoids hierarchical tree
   traversal overhead for the common case of reading individual joint
   positions (e.g., fingertip for hit testing).

These choices prioritize implementation simplicity and debuggability
over optimal filtering. The EMA filter can be replaced with a 1-Euro
filter in a future iteration if jitter proves problematic in practice.

## References

- OpenXR XR_EXT_hand_tracking specification:
  https://registry.khronos.org/OpenXR/specs/1.1/html/xrspec.html#XR_EXT_hand_tracking
- Casiez, G., Roussel, N., & Vogel, D. (2012). 1-Euro Filter:
  https://gery.casiez.net/1euro/
- Monado hand tracking documentation:
  https://monado.freedesktop.org/
- Meta Quest Hand Tracking SDK:
  https://developer.oculus.com/documentation/native/android/move-hand-tracking/
- Ultraleap Gemini tracking:
  https://docs.ultraleap.com/tracking-api/
- MediaPipe Hands:
  https://developers.google.com/mediapipe/solutions/vision/hand_landmarker
- Welch, G. & Bishop, G. (2006). An Introduction to the Kalman Filter:
  https://www.cs.unc.edu/~welch/media/pdf/kalman_intro.pdf
