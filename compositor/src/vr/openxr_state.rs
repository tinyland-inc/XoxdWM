//! OpenXR VR state — full session lifecycle management.
//!
//! Manages the OpenXR runtime connection including:
//! - Entry loading (dynamic via openxr-loader)
//! - Instance creation with extension negotiation
//! - System (HMD) discovery
//! - Session lifecycle: IDLE -> READY -> SYNCHRONIZED -> VISIBLE -> FOCUSED
//! - Swapchain creation and format negotiation
//! - Reference space management (LOCAL, STAGE, VIEW)
//! - Frame submission loop
//! - Session recovery from runtime/session loss

use openxrs as xr;
use std::collections::HashSet;
use std::time::{Duration, Instant};
use tracing::{debug, error, info, warn};

use super::drm_lease::HmdManager;
use super::eye_tracking::EyeTracking;
use super::frame_timing::FrameTiming;
use super::blink_wink::BlinkWinkManager;
use super::fatigue::FatigueMonitor;
use super::gaze_focus::GazeFocusManager;
use super::gaze_scroll::GazeScrollState;
use super::gaze_zone::ZoneDetector;
use super::gesture::GestureState;
use super::hand_tracking::HandTrackingState;
use super::link_hints::LinkHintState;
use super::scene::VrScene;
use super::bci_state::BciState;
use super::virtual_keyboard::VirtualKeyboardState;
use super::vr_interaction::VrInteraction;

/// Reference space type selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReferenceSpaceType {
    Local,
    Stage,
    View,
}

/// VR session state (mirrors OpenXR session states).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VrSessionState {
    Idle,
    Ready,
    Synchronized,
    Visible,
    Focused,
    Stopping,
    LossPending,
    Exiting,
}

impl VrSessionState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Ready => "ready",
            Self::Synchronized => "synchronized",
            Self::Visible => "visible",
            Self::Focused => "focused",
            Self::Stopping => "stopping",
            Self::LossPending => "loss-pending",
            Self::Exiting => "exiting",
        }
    }
}

/// HMD system information discovered via OpenXR.
#[derive(Debug, Clone)]
pub struct HmdInfo {
    pub system_name: String,
    pub vendor_id: u32,
    pub max_width: u32,
    pub max_height: u32,
    pub max_layers: u32,
    pub orientation_tracking: bool,
    pub position_tracking: bool,
    pub recommended_width: u32,
    pub recommended_height: u32,
}

impl Default for HmdInfo {
    fn default() -> Self {
        Self {
            system_name: "unknown".to_string(),
            vendor_id: 0,
            max_width: 0,
            max_height: 0,
            max_layers: 0,
            orientation_tracking: false,
            position_tracking: false,
            recommended_width: 1920,
            recommended_height: 1080,
        }
    }
}

/// Data returned from a VR frame tick for the renderer.
#[derive(Debug)]
pub struct VrFrameData {
    /// Per-eye view poses and FOVs from locate_views.
    pub views: Vec<xr::View>,
    /// Predicted display time for this frame.
    pub predicted_display_time: xr::Time,
    /// Whether we should render (false = submit empty frame).
    pub should_render: bool,
}

/// Central VR state managing the full OpenXR lifecycle.
pub struct VrState {
    pub enabled: bool,
    pub headless: bool,
    pub session_state: VrSessionState,
    pub hmd_info: HmdInfo,
    pub enabled_extensions: HashSet<String>,
    pub active_reference_space: ReferenceSpaceType,
    pub frame_timing: FrameTiming,
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

    // OpenXR objects (Option because they're created incrementally)
    entry: Option<xr::Entry>,
    instance: Option<xr::Instance>,
    system_id: Option<xr::SystemId>,

    // Session and swapchain objects
    session: Option<xr::Session<xr::OpenGL>>,
    frame_waiter: Option<xr::FrameWaiter>,
    frame_stream: Option<xr::FrameStream<xr::OpenGL>>,
    swapchains: Vec<xr::Swapchain<xr::OpenGL>>,
    swapchain_images: Vec<Vec<u32>>,
    reference_space: Option<xr::Space>,
    view_config_views: Vec<xr::ViewConfigurationView>,

    // Recovery
    max_retries: u32,
    retry_count: u32,
    last_retry: Option<Instant>,
}

impl VrState {
    /// Create a new VR state. Does NOT initialize OpenXR yet.
    pub fn new() -> Self {
        Self {
            enabled: false,
            headless: std::env::var("XRT_COMPOSITOR_FORCE_HEADLESS").is_ok(),
            session_state: VrSessionState::Idle,
            hmd_info: HmdInfo::default(),
            enabled_extensions: HashSet::new(),
            active_reference_space: ReferenceSpaceType::Local,
            frame_timing: FrameTiming::default(),
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
            entry: None,
            instance: None,
            system_id: None,
            session: None,
            frame_waiter: None,
            frame_stream: None,
            swapchains: Vec::new(),
            swapchain_images: Vec::new(),
            reference_space: None,
            view_config_views: Vec::new(),
            max_retries: 3,
            retry_count: 0,
            last_retry: None,
        }
    }

    /// Initialize the OpenXR runtime.
    /// Returns Ok(true) if VR is available, Ok(false) if not (graceful degradation).
    pub fn initialize(&mut self) -> anyhow::Result<bool> {
        // Step 1: Load OpenXR entry point
        info!("VR: loading OpenXR runtime...");
        let entry = match unsafe { xr::Entry::load() } {
            Ok(e) => e,
            Err(e) => {
                warn!("VR: OpenXR loader not available: {} (continuing in 2D mode)", e);
                return Ok(false);
            }
        };

        // Step 2: Enumerate available extensions
        let available_extensions = match entry.enumerate_extensions() {
            Ok(exts) => exts,
            Err(e) => {
                warn!("VR: failed to enumerate extensions: {}", e);
                return Ok(false);
            }
        };
        info!("VR: OpenXR extensions available: {:?}", available_extensions);

        // Step 3: Select extensions
        let mut required_extensions = xr::ExtensionSet::default();
        // OpenGL graphics binding (required for Smithay integration)
        required_extensions.khr_opengl_enable = available_extensions.khr_opengl_enable;

        // Optional extensions
        let mut enabled = HashSet::new();
        if available_extensions.khr_opengl_enable {
            enabled.insert("XR_KHR_opengl_enable".to_string());
        }
        if available_extensions.ext_eye_gaze_interaction {
            required_extensions.ext_eye_gaze_interaction = true;
            enabled.insert("XR_EXT_eye_gaze_interaction".to_string());
        }
        if available_extensions.ext_hand_tracking {
            required_extensions.ext_hand_tracking = true;
            enabled.insert("XR_EXT_hand_tracking".to_string());
        }

        // Step 4: Create instance
        let app_info = xr::ApplicationInfo {
            application_name: "ewwm-vr-compositor",
            application_version: 1,
            engine_name: "smithay",
            engine_version: 1,
            api_version: xr::Version::new(1, 0, 0),
        };

        let instance = match entry.create_instance(&app_info, &required_extensions, &[]) {
            Ok(inst) => inst,
            Err(e) => {
                warn!("VR: failed to create OpenXR instance: {}", e);
                return Ok(false);
            }
        };

        let instance_props = instance.properties().unwrap_or_else(|_| {
            xr::InstanceProperties {
                runtime_name: "unknown".to_string(),
                runtime_version: xr::Version::new(0, 0, 0),
            }
        });
        info!(
            "VR: OpenXR runtime: {} v{}",
            instance_props.runtime_name, instance_props.runtime_version
        );

        // Step 5: Discover HMD system
        match instance.system(xr::FormFactor::HEAD_MOUNTED_DISPLAY) {
            Ok(system_id) => {
                let system_props = instance.system_properties(system_id)?;
                self.hmd_info = HmdInfo {
                    system_name: system_props.system_name.clone(),
                    vendor_id: system_props.vendor_id,
                    max_width: system_props
                        .graphics_properties
                        .max_swapchain_image_width,
                    max_height: system_props
                        .graphics_properties
                        .max_swapchain_image_height,
                    max_layers: system_props.graphics_properties.max_layer_count,
                    orientation_tracking: system_props
                        .tracking_properties
                        .orientation_tracking,
                    position_tracking: system_props.tracking_properties.position_tracking,
                    recommended_width: 1920, // Updated after view config query
                    recommended_height: 1080,
                };

                info!(
                    "VR: HMD discovered: {} (vendor {}), max {}x{}, tracking: orient={} pos={}",
                    self.hmd_info.system_name,
                    self.hmd_info.vendor_id,
                    self.hmd_info.max_width,
                    self.hmd_info.max_height,
                    self.hmd_info.orientation_tracking,
                    self.hmd_info.position_tracking,
                );

                self.system_id = Some(system_id);
            }
            Err(xr::sys::Result::ERROR_FORM_FACTOR_UNAVAILABLE) => {
                warn!("VR: no HMD connected, falling back to headless mode");
                self.headless = true;
            }
            Err(e) => {
                warn!("VR: system discovery failed: {}", e);
                return Ok(false);
            }
        }

        self.entry = Some(entry);
        self.instance = Some(instance);
        self.enabled_extensions = enabled;
        self.enabled = true;

        info!(
            "VR: initialized (headless={}, extensions={:?})",
            self.headless, self.enabled_extensions
        );
        Ok(true)
    }

    /// Create an OpenGL session using the provided EGL handles.
    ///
    /// # Safety
    /// The EGL display, config, and context must be valid and current on
    /// the calling thread.
    pub fn create_session(
        &mut self,
        egl_display: *mut std::ffi::c_void,
        egl_config: *mut std::ffi::c_void,
        egl_context: *mut std::ffi::c_void,
    ) -> anyhow::Result<()> {
        let instance = self.instance.as_ref()
            .ok_or_else(|| anyhow::anyhow!("OpenXR instance not initialized"))?;
        let system_id = self.system_id
            .ok_or_else(|| anyhow::anyhow!("OpenXR system not discovered"))?;

        // Query view configuration for PRIMARY_STEREO
        let view_config_views = instance.enumerate_view_configuration_views(
            system_id,
            xr::ViewConfigurationType::PRIMARY_STEREO,
        )?;
        info!(
            "VR: view config: {} views, recommended {}x{} per eye",
            view_config_views.len(),
            view_config_views.first().map(|v| v.recommended_image_rect_width).unwrap_or(0),
            view_config_views.first().map(|v| v.recommended_image_rect_height).unwrap_or(0),
        );

        // Update HMD info with actual recommended resolution
        if let Some(view) = view_config_views.first() {
            self.hmd_info.recommended_width = view.recommended_image_rect_width;
            self.hmd_info.recommended_height = view.recommended_image_rect_height;
        }

        // Create OpenGL graphics binding
        let session_create_info = xr::opengl::SessionCreateInfo::Xlib {
            x_display: std::ptr::null_mut(),
            glx_fb_config: 0,
            glx_drawable: 0,
            glx_context: egl_context as _,
        };

        // Create session
        let (session, frame_waiter, frame_stream) = unsafe {
            instance.create_session::<xr::OpenGL>(system_id, &session_create_info)?
        };
        info!("VR: OpenGL session created");

        // Create reference space
        let reference_space = session.create_reference_space(
            match self.active_reference_space {
                ReferenceSpaceType::Local => xr::ReferenceSpaceType::LOCAL,
                ReferenceSpaceType::Stage => xr::ReferenceSpaceType::STAGE,
                ReferenceSpaceType::View => xr::ReferenceSpaceType::VIEW,
            },
            xr::Posef::IDENTITY,
        )?;

        // Enumerate swapchain formats (prefer SRGB8_ALPHA8)
        let formats = session.enumerate_swapchain_formats()?;
        let format = select_swapchain_format(&formats);
        info!("VR: selected swapchain format: 0x{:X}", format);

        // Create per-eye swapchains and enumerate images
        let mut swapchains = Vec::new();
        let mut swapchain_images = Vec::new();

        for (eye_idx, view_config) in view_config_views.iter().enumerate() {
            let swapchain = session.create_swapchain(&xr::SwapchainCreateInfo {
                create_flags: xr::SwapchainCreateFlags::EMPTY,
                usage_flags: xr::SwapchainUsageFlags::COLOR_ATTACHMENT
                    | xr::SwapchainUsageFlags::SAMPLED,
                format,
                sample_count: 1,
                width: view_config.recommended_image_rect_width,
                height: view_config.recommended_image_rect_height,
                face_count: 1,
                array_size: 1,
                mip_count: 1,
            })?;

            let images: Vec<u32> = swapchain
                .enumerate_images()?
                .into_iter()
                .map(|img| img.image)
                .collect();

            info!(
                "VR: eye {} swapchain: {}x{}, {} images",
                eye_idx,
                view_config.recommended_image_rect_width,
                view_config.recommended_image_rect_height,
                images.len(),
            );

            swapchain_images.push(images);
            swapchains.push(swapchain);
        }

        self.session = Some(session);
        self.frame_waiter = Some(frame_waiter);
        self.frame_stream = Some(frame_stream);
        self.swapchains = swapchains;
        self.swapchain_images = swapchain_images;
        self.reference_space = Some(reference_space);
        self.view_config_views = view_config_views;

        Ok(())
    }

    /// Returns the session state as a string for IPC.
    pub fn session_state_str(&self) -> &'static str {
        if !self.enabled {
            "disabled"
        } else if self.headless {
            "headless"
        } else {
            self.session_state.as_str()
        }
    }

    /// Returns HMD name for IPC.
    pub fn hmd_name(&self) -> &str {
        &self.hmd_info.system_name
    }

    /// Returns whether VR is in headless mode.
    pub fn is_headless(&self) -> bool {
        self.headless
    }

    /// Returns frame stats as an IPC-formatted string.
    pub fn frame_stats_sexp(&self) -> String {
        self.frame_timing.stats_sexp()
    }

    /// Returns a reference to swapchains for the renderer.
    pub fn swapchains_mut(&mut self) -> &mut Vec<xr::Swapchain<xr::OpenGL>> {
        &mut self.swapchains
    }

    /// Returns swapchain image texture IDs.
    pub fn swapchain_images(&self) -> &[Vec<u32>] {
        &self.swapchain_images
    }

    /// Returns view configuration views.
    pub fn view_config_views(&self) -> &[xr::ViewConfigurationView] {
        &self.view_config_views
    }

    /// Handle a session state transition.
    pub fn handle_state_change(&mut self, new_state: VrSessionState) {
        let old = self.session_state;
        self.session_state = new_state;
        info!("VR: session state: {:?} -> {:?}", old, new_state);

        match new_state {
            VrSessionState::Ready => {
                if let Some(session) = &self.session {
                    match session.begin(xr::ViewConfigurationType::PRIMARY_STEREO) {
                        Ok(()) => info!("VR: session begun (PRIMARY_STEREO)"),
                        Err(e) => error!("VR: failed to begin session: {}", e),
                    }
                } else {
                    info!("VR: session ready but no session object (create_session not called)");
                }
            }
            VrSessionState::Stopping => {
                if let Some(session) = &self.session {
                    match session.end() {
                        Ok(()) => info!("VR: session ended"),
                        Err(e) => error!("VR: failed to end session: {}", e),
                    }
                }
            }
            VrSessionState::Exiting => {
                info!("VR: session exiting, cleanup");
                self.enabled = false;
            }
            VrSessionState::LossPending => {
                warn!("VR: runtime loss pending, will attempt recovery");
                self.attempt_recovery();
            }
            _ => {}
        }
    }

    /// Attempt to recover from runtime/session loss.
    fn attempt_recovery(&mut self) {
        if self.retry_count >= self.max_retries {
            error!(
                "VR: max retries ({}) reached, disabling VR",
                self.max_retries
            );
            self.enabled = false;
            return;
        }

        if let Some(last) = self.last_retry {
            if last.elapsed() < Duration::from_secs(1) {
                return; // Too soon
            }
        }

        self.retry_count += 1;
        self.last_retry = Some(Instant::now());
        info!(
            "VR: recovery attempt {}/{}",
            self.retry_count, self.max_retries
        );

        // Destroy current state
        self.destroy_session();
        self.instance = None;
        self.system_id = None;
        self.session_state = VrSessionState::Idle;

        // Try to reinitialize
        match self.initialize() {
            Ok(true) => {
                info!("VR: recovery successful");
                self.retry_count = 0;
            }
            Ok(false) => {
                warn!("VR: recovery failed (VR not available)");
            }
            Err(e) => {
                warn!("VR: recovery error: {}", e);
            }
        }
    }

    /// Clean up session-related resources.
    fn destroy_session(&mut self) {
        self.swapchains.clear();
        self.swapchain_images.clear();
        self.reference_space = None;
        self.frame_stream = None;
        self.frame_waiter = None;
        self.session = None;
        self.view_config_views.clear();
    }

    /// Set the active reference space.
    pub fn set_reference_space(&mut self, space_type: ReferenceSpaceType) {
        self.active_reference_space = space_type;
        info!("VR: reference space set to {:?}", space_type);

        // Recreate reference space if session is active
        if let Some(session) = &self.session {
            let xr_type = match space_type {
                ReferenceSpaceType::Local => xr::ReferenceSpaceType::LOCAL,
                ReferenceSpaceType::Stage => xr::ReferenceSpaceType::STAGE,
                ReferenceSpaceType::View => xr::ReferenceSpaceType::VIEW,
            };
            match session.create_reference_space(xr_type, xr::Posef::IDENTITY) {
                Ok(space) => {
                    self.reference_space = Some(space);
                    info!("VR: reference space recreated");
                }
                Err(e) => error!("VR: failed to recreate reference space: {}", e),
            }
        }
    }

    /// Poll for VR events from the OpenXR runtime.
    pub fn poll_events(&mut self) {
        let instance = match &self.instance {
            Some(inst) => inst,
            None => return,
        };

        let mut event_buffer = xr::EventDataBuffer::new();
        while let Ok(Some(event)) = instance.poll_event(&mut event_buffer) {
            match event {
                xr::Event::SessionStateChanged(state_event) => {
                    let new_state = match state_event.state() {
                        xr::SessionState::IDLE => VrSessionState::Idle,
                        xr::SessionState::READY => VrSessionState::Ready,
                        xr::SessionState::SYNCHRONIZED => VrSessionState::Synchronized,
                        xr::SessionState::VISIBLE => VrSessionState::Visible,
                        xr::SessionState::FOCUSED => VrSessionState::Focused,
                        xr::SessionState::STOPPING => VrSessionState::Stopping,
                        xr::SessionState::LOSS_PENDING => VrSessionState::LossPending,
                        xr::SessionState::EXITING => VrSessionState::Exiting,
                        _ => {
                            debug!("VR: unknown session state, ignoring");
                            continue;
                        }
                    };
                    self.handle_state_change(new_state);
                }
                xr::Event::InstanceLossPending(_) => {
                    warn!("VR: instance loss pending");
                    self.handle_state_change(VrSessionState::LossPending);
                }
                xr::Event::EventsLost(lost) => {
                    warn!("VR: {} events lost", lost.lost_event_count());
                }
                _ => {
                    debug!("VR: unhandled event");
                }
            }
        }
    }

    /// Run one VR frame tick. Returns frame data for the renderer.
    pub fn tick_frame(&mut self) -> Option<VrFrameData> {
        if !self.enabled {
            return None;
        }

        // Only produce frames in renderable states
        let renderable = matches!(
            self.session_state,
            VrSessionState::Synchronized | VrSessionState::Visible | VrSessionState::Focused
        );
        if !renderable {
            return None;
        }

        let frame_waiter = self.frame_waiter.as_mut()?;
        let frame_stream = self.frame_stream.as_mut()?;
        let session = self.session.as_ref()?;
        let space = self.reference_space.as_ref()?;

        // Wait for frame timing
        let frame_state = match frame_waiter.wait() {
            Ok(state) => state,
            Err(e) => {
                error!("VR: wait_frame failed: {}", e);
                return None;
            }
        };

        // Begin frame
        if let Err(e) = frame_stream.begin() {
            error!("VR: begin_frame failed: {}", e);
            return None;
        }

        let should_render = frame_state.should_render;
        if !should_render {
            // Submit empty frame
            if let Err(e) = frame_stream.end(
                frame_state.predicted_display_time,
                xr::EnvironmentBlendMode::OPAQUE,
                &[],
            ) {
                error!("VR: end_frame (empty) failed: {}", e);
            }
            return Some(VrFrameData {
                views: Vec::new(),
                predicted_display_time: frame_state.predicted_display_time,
                should_render: false,
            });
        }

        // Locate eye views
        let (_, views) = match session.locate_views(
            xr::ViewConfigurationType::PRIMARY_STEREO,
            frame_state.predicted_display_time,
            space,
        ) {
            Ok(result) => result,
            Err(e) => {
                error!("VR: locate_views failed: {}", e);
                // End frame with empty layers on error
                let _ = frame_stream.end(
                    frame_state.predicted_display_time,
                    xr::EnvironmentBlendMode::OPAQUE,
                    &[],
                );
                return None;
            }
        };

        // Record frame timing
        self.frame_timing.record_frame();

        Some(VrFrameData {
            views,
            predicted_display_time: frame_state.predicted_display_time,
            should_render: true,
        })
    }

    /// End a frame with the given composition layers.
    pub fn end_frame(
        &mut self,
        predicted_time: xr::Time,
        layers: &[xr::CompositionLayerProjection<xr::OpenGL>],
    ) {
        let frame_stream = match self.frame_stream.as_mut() {
            Some(fs) => fs,
            None => return,
        };

        let layer_refs: Vec<&xr::CompositionLayerBase<xr::OpenGL>> =
            layers.iter().map(|l| l as &xr::CompositionLayerBase<xr::OpenGL>).collect();

        if let Err(e) = frame_stream.end(
            predicted_time,
            xr::EnvironmentBlendMode::OPAQUE,
            &layer_refs,
        ) {
            error!("VR: end_frame failed: {}", e);
        }
    }

    /// Shut down VR.
    pub fn shutdown(&mut self) {
        info!("VR: shutting down");
        if self.session_state != VrSessionState::Idle
            && self.session_state != VrSessionState::Exiting
        {
            self.handle_state_change(VrSessionState::Stopping);
        }
        self.destroy_session();
        self.instance = None;
        self.system_id = None;
        self.entry = None;
        self.enabled = false;
        self.session_state = VrSessionState::Idle;
    }

    /// Generate IPC event for session state change.
    pub fn session_state_event(&self) -> String {
        format!(
            "(:type :event :event :vr-session-state :state :{} :headless {})",
            self.session_state.as_str(),
            if self.headless { "t" } else { "nil" },
        )
    }

    /// Generate IPC event for system discovery.
    pub fn system_discovered_event(&self) -> String {
        format!(
            "(:type :event :event :vr-system-discovered :system-name \"{}\" :max-resolution (:w {} :h {}) :orientation-tracking {} :position-tracking {})",
            self.hmd_info.system_name,
            self.hmd_info.max_width,
            self.hmd_info.max_height,
            if self.hmd_info.orientation_tracking { "t" } else { "nil" },
            if self.hmd_info.position_tracking { "t" } else { "nil" },
        )
    }

    /// Generate IPC response for vr-status query.
    pub fn status_response(&self, msg_id: i64) -> String {
        format!(
            "(:type :response :id {} :status :ok :session :{} :runtime \"{}\" :hmd \"{}\" :headless {} :extensions {:?} :frame-stats {})",
            msg_id,
            self.session_state.as_str(),
            self.instance.as_ref().map(|i| {
                i.properties().map(|p| p.runtime_name).unwrap_or_default()
            }).unwrap_or_default(),
            self.hmd_info.system_name,
            if self.headless { "t" } else { "nil" },
            self.enabled_extensions,
            self.frame_stats_sexp(),
        )
    }
}

/// Select the best swapchain format from available formats.
/// Prefers SRGB8_ALPHA8, falls back to RGBA8, then first available.
fn select_swapchain_format(formats: &[i64]) -> i64 {
    const GL_SRGB8_ALPHA8: i64 = 0x8C43;
    const GL_RGBA8: i64 = 0x8058;
    const GL_RGBA16F: i64 = 0x881A;

    if formats.contains(&GL_SRGB8_ALPHA8) {
        GL_SRGB8_ALPHA8
    } else if formats.contains(&GL_RGBA8) {
        GL_RGBA8
    } else if formats.contains(&GL_RGBA16F) {
        GL_RGBA16F
    } else {
        formats.first().copied().unwrap_or(GL_RGBA8)
    }
}
