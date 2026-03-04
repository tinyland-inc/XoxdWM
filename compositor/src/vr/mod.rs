//! VR subsystem — OpenXR runtime integration and 3D scene management.
//!
//! Provides:
//! - `VrState`: OpenXR lifecycle (gated behind `vr` feature)
//! - `scene`: 3D scene graph for Wayland surfaces in VR
//! - `texture`: DMA-BUF texture import pipeline (gated behind `vr` feature)
//! - `vr_renderer`: Stereo rendering to OpenXR swapchains (gated behind `vr` feature)

#[cfg(feature = "vr")]
pub mod openxr_state;

#[cfg(feature = "vr")]
pub mod frame_timing;

#[cfg(feature = "vr")]
pub mod texture;

#[cfg(feature = "vr")]
pub mod vr_renderer;

#[cfg(feature = "vr")]
pub use openxr_state::{ReferenceSpaceType, VrState};

#[cfg(not(feature = "vr"))]
pub mod stub;

#[cfg(not(feature = "vr"))]
pub use stub::{ReferenceSpaceType, VrState};

// Scene graph, DRM lease, interaction, and eye tracking are always available (no openxrs dependency).
pub mod scene;
pub mod drm_lease;
pub mod vr_interaction;
pub mod eye_tracking;
pub mod gaze_focus;
pub mod gaze_zone;
pub mod fatigue;
pub mod blink_wink;
pub mod gaze_scroll;
pub mod link_hints;
pub mod hand_tracking;
pub mod gesture;
pub mod virtual_keyboard;
pub mod attention;
pub mod ssvep;
pub mod p300;
pub mod motor_imagery;
pub mod fatigue_eeg;
pub mod bci_state;
pub mod follow_mode;
pub mod gpu_power;
pub mod transient_3d;
pub mod overlay;
pub mod radial_menu;
pub mod capture_visibility;
pub mod beyond_hid;
