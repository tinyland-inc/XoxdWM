//! VR stub — used when the `vr` feature is not enabled.
//!
//! Provides a no-op VrState so the rest of the compositor compiles
//! without OpenXR dependencies (e.g., s390x headless builds).

use tracing::info;

use super::blink_wink::BlinkWinkManager;
use super::drm_lease::HmdManager;
use super::eye_tracking::EyeTracking;
use super::fatigue::FatigueMonitor;
use super::gaze_focus::GazeFocusManager;
use super::gaze_scroll::GazeScrollState;
use super::gaze_zone::ZoneDetector;
use super::gesture::GestureState;
use super::hand_tracking::HandTrackingState;
use super::link_hints::LinkHintState;
use super::scene::VrScene;
use super::bci_state::BciState;
use super::follow_mode::FollowMode;
use super::beyond_hid::BeyondHidManager;
use super::gpu_power::GpuPowerState;
use super::overlay::OverlayManager;
use super::radial_menu::RadialMenu;
use super::capture_visibility::CaptureVisibilityManager;
use super::transient_3d::TransientChainManager;
use super::virtual_keyboard::VirtualKeyboardState;
use super::vr_interaction::VrInteraction;

/// Reference space type selection (stub).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReferenceSpaceType {
    Local,
    Stage,
    View,
}

/// Stub VR state when OpenXR is not compiled in.
pub struct VrState {
    pub enabled: bool,
    pub scene: VrScene,
    pub hmd_manager: HmdManager,
    pub interaction: VrInteraction,
    pub eye_tracking: EyeTracking,
    pub gaze_focus: GazeFocusManager,
    pub blink_wink: BlinkWinkManager,
    pub zone_detector: ZoneDetector,
    pub fatigue_monitor: FatigueMonitor,
    pub gaze_scroll: GazeScrollState,
    pub link_hints: LinkHintState,
    pub hand_tracking: HandTrackingState,
    pub gesture: GestureState,
    pub virtual_keyboard: VirtualKeyboardState,
    pub bci: BciState,
    pub follow_mode: FollowMode,
    pub beyond_hid: BeyondHidManager,
    pub gpu_power: GpuPowerState,
    pub transient_chains: TransientChainManager,
    pub overlay_manager: OverlayManager,
    pub radial_menu: RadialMenu,
    pub capture_visibility: CaptureVisibilityManager,
}

impl Default for VrState {
    fn default() -> Self {
        Self {
            enabled: false,
            scene: VrScene::new(),
            hmd_manager: HmdManager::new(),
            interaction: VrInteraction::new(),
            eye_tracking: EyeTracking::new(),
            gaze_focus: GazeFocusManager::new(),
            blink_wink: BlinkWinkManager::new(),
            zone_detector: ZoneDetector::new(),
            fatigue_monitor: FatigueMonitor::new(),
            gaze_scroll: GazeScrollState::new(),
            link_hints: LinkHintState::new(),
            hand_tracking: HandTrackingState::new(),
            gesture: GestureState::new(),
            virtual_keyboard: VirtualKeyboardState::new(),
            bci: BciState::new(),
            follow_mode: FollowMode::new(),
            beyond_hid: BeyondHidManager::new(),
            gpu_power: GpuPowerState::new(),
            transient_chains: TransientChainManager::new(),
            overlay_manager: OverlayManager::new(),
            radial_menu: RadialMenu::new(),
            capture_visibility: CaptureVisibilityManager::new(),
        }
    }
}

impl VrState {
    pub fn new() -> Self {
        info!("VR subsystem disabled (compiled without 'vr' feature)");
        Self::default()
    }

    /// Returns the session state as a string for IPC.
    pub fn session_state_str(&self) -> &'static str {
        "disabled"
    }

    /// Returns HMD name for IPC.
    pub fn hmd_name(&self) -> &'static str {
        "none"
    }

    /// Returns whether VR is in headless mode.
    pub fn is_headless(&self) -> bool {
        false
    }

    /// Returns frame stats as an IPC-formatted string.
    pub fn frame_stats_sexp(&self) -> String {
        "(:fps 0 :missed 0 :frame-time-ms 0.0)".to_string()
    }

    /// Poll for VR events. No-op when VR is disabled.
    pub fn poll_events(&mut self) {}

    /// Run one VR frame. No-op when VR is disabled.
    pub fn tick_frame(&mut self) {}

    /// Set the active reference space. No-op when VR is disabled.
    pub fn set_reference_space(&mut self, _space_type: ReferenceSpaceType) {}

    /// Render VR frame. No-op when VR is disabled.
    pub fn render_vr_frame(&mut self, _views: &[()], _view_configs: &[()]) {}

    /// Shut down VR. No-op when VR is disabled.
    pub fn shutdown(&mut self) {}
}
