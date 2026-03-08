//! Eye tracking integration — OpenXR XR_EXT_eye_gaze_interaction,
//! Pupil Labs ZMQ client (stub), unified gaze model, calibration,
//! visualization, health monitoring, and simulation.
//!
//! Compiled unconditionally (no openxrs dependency at struct level).
//! OpenXR-specific gaze extraction runs only when `vr` feature is active.

use std::collections::VecDeque;
use tracing::{debug, info, warn};

use super::scene::Vec3;
use super::vr_interaction::Ray;

// ── Gaze source ─────────────────────────────────────────────

/// Which hardware source is providing gaze data.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GazeSource {
    /// OpenXR XR_EXT_eye_gaze_interaction (HMD-integrated).
    OpenXR,
    /// Pupil Labs via ZMQ (external eye tracker).
    PupilLabs,
    /// Bigscreen Bigeye IR cameras with local pupil detection.
    Bigeye,
    /// Simulated gaze for development/testing.
    Simulated,
    /// No gaze source available.
    None,
}

impl GazeSource {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::OpenXR => "openxr",
            Self::PupilLabs => "pupil-labs",
            Self::Bigeye => "bigeye",
            Self::Simulated => "simulated",
            Self::None => "none",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "openxr" => Some(Self::OpenXR),
            "pupil-labs" => Some(Self::PupilLabs),
            "bigeye" => Some(Self::Bigeye),
            "simulated" => Some(Self::Simulated),
            "none" => Some(Self::None),
            "auto" => Option::None, // auto selection
            _ => Option::None,
        }
    }
}

// ── Per-eye gaze ────────────────────────────────────────────

/// Per-eye gaze data (when available from binocular trackers).
#[derive(Debug, Clone, Copy)]
pub struct PerEyeGaze {
    pub left_direction: Vec3,
    pub right_direction: Vec3,
    pub left_openness: Option<f32>,
    pub right_openness: Option<f32>,
}

// ── Unified gaze data ───────────────────────────────────────

/// Unified gaze datum abstracted over all sources.
#[derive(Debug, Clone, Copy)]
pub struct GazeData {
    /// Which source produced this sample.
    pub source: GazeSource,
    /// Gaze ray in world (compositor) coordinates.
    pub ray: Ray,
    /// Confidence [0.0, 1.0]; 0 = no tracking, 1 = high confidence.
    pub confidence: f32,
    /// Timestamp in seconds (monotonic).
    pub timestamp_s: f64,
    /// Per-eye data if available.
    pub per_eye: Option<PerEyeGaze>,
}

// ── Gaze surface hit ────────────────────────────────────────

/// Result of intersecting the gaze ray with a scene surface.
#[derive(Debug, Clone, Copy)]
pub struct GazeSurfaceHit {
    pub surface_id: u64,
    pub pixel_x: f32,
    pub pixel_y: f32,
    pub distance: f32,
    pub confidence: f32,
}

// ── Gaze visualization ──────────────────────────────────────

/// Visualization mode for the gaze indicator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GazeVisualization {
    Dot,
    Crosshair,
    Spotlight,
    None,
}

impl GazeVisualization {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Dot => "dot",
            Self::Crosshair => "crosshair",
            Self::Spotlight => "spotlight",
            Self::None => "none",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "dot" => Some(Self::Dot),
            "crosshair" => Some(Self::Crosshair),
            "spotlight" => Some(Self::Spotlight),
            "none" => Some(Self::None),
            _ => Option::None,
        }
    }
}

// ── Simulation modes ────────────────────────────────────────

/// Simulated gaze mode for development without eye tracking hardware.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SimulatedGazeMode {
    /// Use mouse position as gaze target (desktop/preview mode).
    Mouse,
    /// Replay a recorded gaze trace.
    Scripted,
    /// Gaze wanders randomly with saccade-like jumps.
    RandomWalk,
    /// Cycle through surfaces in order, dwelling 2 seconds each.
    Pattern,
}

impl SimulatedGazeMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Mouse => "mouse",
            Self::Scripted => "scripted",
            Self::RandomWalk => "random-walk",
            Self::Pattern => "pattern",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "mouse" => Some(Self::Mouse),
            "scripted" => Some(Self::Scripted),
            "random-walk" => Some(Self::RandomWalk),
            "pattern" => Some(Self::Pattern),
            _ => Option::None,
        }
    }
}

// ── Calibration ─────────────────────────────────────────────

/// A recorded calibration point.
#[derive(Debug, Clone, Copy)]
pub struct CalibrationPoint {
    /// Target position the user was asked to look at.
    pub target: Vec3,
    /// Recorded gaze direction at the moment of confirmation.
    pub gaze_direction: Vec3,
    /// Timestamp of recording.
    pub timestamp_s: f64,
}

/// State of the eye tracking calibration procedure.
#[derive(Debug, Clone)]
pub enum EyeCalibrationState {
    /// Not calibrating.
    Idle,
    /// Calibration in progress; collecting points.
    Collecting {
        points: Vec<CalibrationPoint>,
        total: usize,
    },
    /// Calibration complete with computed rotation.
    Complete {
        /// Rotation matrix (3x3 flattened row-major) from tracker to world.
        rotation: [f32; 9],
        /// RMS error in degrees.
        rms_error_deg: f32,
    },
}

impl EyeCalibrationState {
    pub fn new() -> Self {
        Self::Idle
    }

    /// Start a new calibration with `n` target points.
    pub fn start(&mut self, n: usize) {
        *self = Self::Collecting {
            points: Vec::with_capacity(n),
            total: n,
        };
        info!("Eye calibration started ({} points)", n);
    }

    /// Record a calibration point. Returns true if calibration is now complete.
    pub fn record_point(&mut self, target: Vec3, gaze_direction: Vec3, timestamp_s: f64) -> bool {
        match self {
            Self::Collecting { points, total } => {
                points.push(CalibrationPoint {
                    target,
                    gaze_direction,
                    timestamp_s,
                });
                let done = points.len() >= *total;
                if done {
                    self.compute_calibration();
                }
                done
            }
            _ => false,
        }
    }

    /// Compute the calibration rotation from recorded points.
    /// Uses a simplified approach: average angular offset.
    fn compute_calibration(&mut self) {
        let points = match self {
            Self::Collecting { points, .. } => points.clone(),
            _ => return,
        };

        if points.is_empty() {
            *self = Self::Idle;
            return;
        }

        // Compute average angular error
        let mut total_error = 0.0f32;
        for p in &points {
            let target_norm = p.target.normalize();
            let gaze_norm = p.gaze_direction.normalize();
            let dot = (target_norm.x * gaze_norm.x
                + target_norm.y * gaze_norm.y
                + target_norm.z * gaze_norm.z)
                .clamp(-1.0, 1.0);
            total_error += dot.acos().to_degrees();
        }
        let rms_error = total_error / points.len() as f32;

        // Identity rotation as placeholder (full SVD would use nalgebra)
        let rotation = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0];

        info!(
            "Eye calibration complete: RMS error = {:.1} degrees ({} points)",
            rms_error,
            points.len()
        );

        *self = Self::Complete {
            rotation,
            rms_error_deg: rms_error,
        };
    }

    /// Whether calibration is currently in progress.
    pub fn is_calibrating(&self) -> bool {
        matches!(self, Self::Collecting { .. })
    }

    /// Get the current point index (0-based) during calibration.
    pub fn current_point_index(&self) -> Option<usize> {
        match self {
            Self::Collecting { points, .. } => Some(points.len()),
            _ => Option::None,
        }
    }

    /// Get total number of calibration points.
    pub fn total_points(&self) -> Option<usize> {
        match self {
            Self::Collecting { total, .. } => Some(*total),
            _ => Option::None,
        }
    }

    /// Get calibration result.
    pub fn rms_error(&self) -> Option<f32> {
        match self {
            Self::Complete { rms_error_deg, .. } => Some(*rms_error_deg),
            _ => Option::None,
        }
    }
}

// ── Gaze health ─────────────────────────────────────────────

/// Health metrics for the gaze tracking pipeline.
#[derive(Debug, Clone)]
pub struct GazeHealth {
    /// Expected sample rate (Hz) for the active source.
    pub expected_rate_hz: f32,
    /// Actual sample rate over the last second (Hz).
    pub actual_rate_hz: f32,
    /// Rolling average confidence over 1 second.
    pub avg_confidence: f32,
    /// Consecutive frames with no valid tracking.
    pub consecutive_lost_frames: u32,
    /// Whether tracking is considered lost (>30 consecutive lost frames).
    pub tracking_lost: bool,
    /// Last calibration error (degrees), if calibrated.
    pub calibration_error_deg: Option<f32>,
    /// Timestamp of last valid gaze sample.
    pub last_valid_timestamp_s: f64,

    // Internal tracking
    samples_this_second: u32,
    confidence_sum: f32,
    confidence_count: u32,
    last_rate_update_s: f64,
}

impl GazeHealth {
    pub fn new() -> Self {
        Self {
            expected_rate_hz: 90.0,
            actual_rate_hz: 0.0,
            avg_confidence: 0.0,
            consecutive_lost_frames: 0,
            tracking_lost: false,
            calibration_error_deg: None,
            last_valid_timestamp_s: 0.0,
            samples_this_second: 0,
            confidence_sum: 0.0,
            confidence_count: 0,
            last_rate_update_s: 0.0,
        }
    }

    /// Update health metrics with a new gaze sample.
    pub fn update(&mut self, gaze: &GazeData) {
        if gaze.confidence > 0.1 {
            self.consecutive_lost_frames = 0;
            self.tracking_lost = false;
            self.last_valid_timestamp_s = gaze.timestamp_s;
        } else {
            self.consecutive_lost_frames += 1;
            if self.consecutive_lost_frames > 30 {
                self.tracking_lost = true;
            }
        }

        self.confidence_sum += gaze.confidence;
        self.confidence_count += 1;
        self.samples_this_second += 1;

        // Update rate every second
        if gaze.timestamp_s - self.last_rate_update_s >= 1.0 {
            self.actual_rate_hz = self.samples_this_second as f32;
            self.avg_confidence = if self.confidence_count > 0 {
                self.confidence_sum / self.confidence_count as f32
            } else {
                0.0
            };
            self.samples_this_second = 0;
            self.confidence_sum = 0.0;
            self.confidence_count = 0;
            self.last_rate_update_s = gaze.timestamp_s;
        }
    }

    /// Check if the sample rate is below 80% of expected.
    pub fn rate_low(&self) -> bool {
        self.actual_rate_hz > 0.0 && self.actual_rate_hz < self.expected_rate_hz * 0.8
    }
}

// ── EMA smoothing ───────────────────────────────────────────

/// Exponential moving average filter for gaze smoothing.
#[derive(Debug, Clone)]
pub struct GazeSmoother {
    /// Alpha parameter: 0 = maximum smoothing, 1 = no smoothing.
    pub alpha: f32,
    /// Last smoothed direction.
    last_direction: Option<Vec3>,
}

impl GazeSmoother {
    pub fn new(alpha: f32) -> Self {
        Self {
            alpha: alpha.clamp(0.0, 1.0),
            last_direction: None,
        }
    }

    /// Apply EMA smoothing to a gaze direction.
    pub fn smooth(&mut self, direction: Vec3) -> Vec3 {
        match self.last_direction {
            Some(last) => {
                let smoothed = Vec3::new(
                    last.x + self.alpha * (direction.x - last.x),
                    last.y + self.alpha * (direction.y - last.y),
                    last.z + self.alpha * (direction.z - last.z),
                )
                .normalize();
                self.last_direction = Some(smoothed);
                smoothed
            }
            None => {
                self.last_direction = Some(direction);
                direction
            }
        }
    }

    /// Reset the smoother (e.g., on source change).
    pub fn reset(&mut self) {
        self.last_direction = None;
    }
}

// ── Pupil Labs ZMQ client (stub) ────────────────────────────

/// Connection state for the Pupil Labs ZMQ client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PupilConnectionState {
    Disconnected,
    Connecting,
    Connected,
    Error(String),
}

/// Pupil Labs ZMQ client (stub — full implementation requires zmq crate).
#[derive(Debug)]
pub struct PupilLabsClient {
    pub state: PupilConnectionState,
    pub ipc_port: u16,
    pub sub_port: Option<u16>,
    pub last_reconnect_s: f64,
    pub reconnect_delay_s: f64,
}

impl PupilLabsClient {
    pub fn new() -> Self {
        Self {
            state: PupilConnectionState::Disconnected,
            ipc_port: 50020,
            sub_port: None,
            last_reconnect_s: 0.0,
            reconnect_delay_s: 1.0,
        }
    }

    /// Attempt to connect (stub — would use zmq crate).
    pub fn connect(&mut self) {
        info!(
            "Pupil Labs: connecting to tcp://127.0.0.1:{}...",
            self.ipc_port
        );
        // In full implementation:
        // 1. REQ socket to tcp://127.0.0.1:{ipc_port}
        // 2. Send "SUB_PORT", receive sub_port
        // 3. SUB socket to tcp://127.0.0.1:{sub_port}
        // 4. Subscribe to "gaze.", "fixations", "blinks"
        self.state = PupilConnectionState::Disconnected;
    }

    /// Poll for gaze data (stub — would read from ZMQ SUB socket).
    pub fn poll(&mut self) -> Option<GazeData> {
        // In full implementation: recv_multipart from SUB, parse msgpack
        None
    }

    /// Whether the client is connected and receiving data.
    pub fn is_connected(&self) -> bool {
        self.state == PupilConnectionState::Connected
    }
}

// ── Simulated gaze state ────────────────────────────────────

/// State for simulated gaze generation.
#[derive(Debug)]
pub struct SimulatedGaze {
    pub mode: Option<SimulatedGazeMode>,
    pub current_direction: Vec3,
    pub target_direction: Vec3,
    pub dwell_timer_s: f64,
    pub saccade_interval_s: f64,
    pub last_saccade_s: f64,
    pub surface_index: usize,
}

impl SimulatedGaze {
    pub fn new() -> Self {
        Self {
            mode: None,
            current_direction: Vec3::new(0.0, 0.0, -1.0),
            target_direction: Vec3::new(0.0, 0.0, -1.0),
            dwell_timer_s: 0.0,
            saccade_interval_s: 2.5,
            last_saccade_s: 0.0,
            surface_index: 0,
        }
    }

    /// Generate a simulated gaze sample.
    pub fn generate(&mut self, timestamp_s: f64) -> Option<GazeData> {
        let mode = self.mode?;

        match mode {
            SimulatedGazeMode::Mouse => {
                // Mouse position would be injected externally
                Some(GazeData {
                    source: GazeSource::Simulated,
                    ray: Ray::new(Vec3::ZERO, self.current_direction),
                    confidence: 0.95,
                    timestamp_s,
                    per_eye: None,
                })
            }
            SimulatedGazeMode::RandomWalk => {
                // Saccade-like jumps
                if timestamp_s - self.last_saccade_s > self.saccade_interval_s {
                    // Generate new random target
                    let angle_h = ((timestamp_s * 1.7).sin() * 0.5) as f32;
                    let angle_v = ((timestamp_s * 1.3).cos() * 0.3) as f32;
                    self.target_direction = Vec3::new(angle_h, angle_v, -1.0).normalize();
                    self.last_saccade_s = timestamp_s;
                }
                // Smooth toward target (simulating fixation stability)
                self.current_direction = Vec3::new(
                    self.current_direction.x
                        + 0.1 * (self.target_direction.x - self.current_direction.x),
                    self.current_direction.y
                        + 0.1 * (self.target_direction.y - self.current_direction.y),
                    self.current_direction.z
                        + 0.1 * (self.target_direction.z - self.current_direction.z),
                )
                .normalize();

                Some(GazeData {
                    source: GazeSource::Simulated,
                    ray: Ray::new(Vec3::ZERO, self.current_direction),
                    confidence: 0.9,
                    timestamp_s,
                    per_eye: None,
                })
            }
            SimulatedGazeMode::Pattern => {
                self.dwell_timer_s += 1.0 / 90.0; // assume 90Hz
                if self.dwell_timer_s > 2.0 {
                    self.dwell_timer_s = 0.0;
                    self.surface_index += 1;
                }
                // Direction cycles around a small set of positions
                let angle = (self.surface_index as f32) * 0.5 - 1.0;
                let dir = Vec3::new(angle, 0.0, -2.0).normalize();
                Some(GazeData {
                    source: GazeSource::Simulated,
                    ray: Ray::new(Vec3::ZERO, dir),
                    confidence: 0.95,
                    timestamp_s,
                    per_eye: None,
                })
            }
            SimulatedGazeMode::Scripted => {
                // Scripted replay would load from file — stub returns forward gaze
                Some(GazeData {
                    source: GazeSource::Simulated,
                    ray: Ray::new(Vec3::ZERO, Vec3::new(0.0, 0.0, -1.0)),
                    confidence: 0.95,
                    timestamp_s,
                    per_eye: None,
                })
            }
        }
    }

    /// Set the simulated gaze direction (e.g., from mouse position).
    pub fn set_direction(&mut self, direction: Vec3) {
        self.current_direction = direction.normalize();
    }
}

// ── Eye tracking manager ────────────────────────────────────

/// Central eye tracking state manager.
pub struct EyeTracking {
    /// Source preference: None means auto-select.
    pub preferred_source: Option<GazeSource>,
    /// Currently active source.
    pub active_source: GazeSource,
    /// Latest gaze data.
    pub current_gaze: Option<GazeData>,
    /// Current gaze surface hit.
    pub gaze_target: Option<GazeSurfaceHit>,
    /// Previous gaze target surface ID (for change detection).
    pub previous_target_surface: Option<u64>,

    /// Ring buffer of recent gaze samples (last ~5.5s at 90Hz).
    pub gaze_history: VecDeque<GazeData>,
    /// Maximum history length.
    pub max_history: usize,

    /// EMA smoothing filter.
    pub smoother: GazeSmoother,
    /// Visualization mode.
    pub visualization: GazeVisualization,
    /// Minimum confidence to accept a gaze sample.
    pub confidence_min: f32,

    /// Calibration state.
    pub calibration: EyeCalibrationState,
    /// Health monitoring.
    pub health: GazeHealth,

    /// Pupil Labs ZMQ client.
    pub pupil_client: PupilLabsClient,
    /// Simulated gaze.
    pub simulated: SimulatedGaze,
}

impl EyeTracking {
    pub fn new() -> Self {
        info!("Eye tracking subsystem initialized");
        Self {
            preferred_source: None, // auto
            active_source: GazeSource::None,
            current_gaze: None,
            gaze_target: None,
            previous_target_surface: None,
            gaze_history: VecDeque::with_capacity(500),
            max_history: 500,
            smoother: GazeSmoother::new(0.3),
            visualization: GazeVisualization::Dot,
            confidence_min: 0.6,
            calibration: EyeCalibrationState::new(),
            health: GazeHealth::new(),
            pupil_client: PupilLabsClient::new(),
            simulated: SimulatedGaze::new(),
        }
    }

    /// Process a new gaze sample from any source.
    pub fn process_gaze(&mut self, mut gaze: GazeData) {
        // Apply smoothing
        let smoothed_dir = self.smoother.smooth(gaze.ray.direction);
        gaze.ray = Ray::new(gaze.ray.origin, smoothed_dir);

        // Update health
        self.health.update(&gaze);

        // Store in history
        if self.gaze_history.len() >= self.max_history {
            self.gaze_history.pop_front();
        }
        self.gaze_history.push_back(gaze);

        // Only update current gaze if confidence meets threshold
        if gaze.confidence >= self.confidence_min {
            self.current_gaze = Some(gaze);
        }
    }

    /// Update gaze target from scene intersection.
    pub fn update_target(&mut self, hit: Option<GazeSurfaceHit>) {
        let prev_sid = self.gaze_target.as_ref().map(|h| h.surface_id);
        let new_sid = hit.as_ref().map(|h| h.surface_id);

        if prev_sid != new_sid {
            self.previous_target_surface = prev_sid;
        }

        self.gaze_target = hit;
    }

    /// Get the active gaze source (auto-selects if preference is None).
    pub fn resolve_source(
        &self,
        openxr_available: bool,
        pupil_available: bool,
    ) -> GazeSource {
        self.resolve_source_full(openxr_available, pupil_available, false)
    }

    /// Get the active gaze source with Bigeye availability.
    pub fn resolve_source_full(
        &self,
        openxr_available: bool,
        pupil_available: bool,
        bigeye_available: bool,
    ) -> GazeSource {
        if let Some(preferred) = self.preferred_source {
            return preferred;
        }
        // Auto: OpenXR > Bigeye > Pupil Labs > Simulated
        if openxr_available {
            GazeSource::OpenXR
        } else if bigeye_available {
            GazeSource::Bigeye
        } else if pupil_available {
            GazeSource::PupilLabs
        } else if self.simulated.mode.is_some() {
            GazeSource::Simulated
        } else {
            GazeSource::None
        }
    }

    /// Set the preferred gaze source.
    pub fn set_source(&mut self, source: Option<GazeSource>) {
        self.preferred_source = source;
        self.smoother.reset();
        info!("Eye tracking source set to {:?}", source);
    }

    /// Set the visualization mode.
    pub fn set_visualization(&mut self, vis: GazeVisualization) {
        self.visualization = vis;
        info!("Gaze visualization set to {}", vis.as_str());
    }

    /// Set EMA smoothing alpha.
    pub fn set_smoothing(&mut self, alpha: f32) {
        self.smoother = GazeSmoother::new(alpha);
        info!("Gaze smoothing alpha set to {:.2}", alpha);
    }

    /// Set simulation mode.
    pub fn set_simulate(&mut self, mode: Option<SimulatedGazeMode>) {
        self.simulated.mode = mode;
        if mode.is_some() {
            self.active_source = GazeSource::Simulated;
        }
        info!("Gaze simulation set to {:?}", mode);
    }

    /// Start calibration with n points.
    pub fn start_calibration(&mut self, n_points: usize) {
        self.calibration.start(n_points);
    }

    /// Record a calibration point. Returns true if calibration is complete.
    pub fn record_calibration_point(
        &mut self,
        target: Vec3,
        gaze_direction: Vec3,
        timestamp_s: f64,
    ) -> bool {
        let complete = self
            .calibration
            .record_point(target, gaze_direction, timestamp_s);
        if complete {
            if let Some(err) = self.calibration.rms_error() {
                self.health.calibration_error_deg = Some(err);
            }
        }
        complete
    }

    /// Clean up eye tracking state.
    pub fn teardown(&mut self) {
        self.current_gaze = None;
        self.gaze_target = None;
        self.previous_target_surface = None;
        self.gaze_history.clear();
        self.active_source = GazeSource::None;
        self.calibration = EyeCalibrationState::new();
        self.smoother.reset();
        self.simulated.mode = None;
        info!("Eye tracking torn down");
    }

    /// Generate IPC status response.
    pub fn status_sexp(&self) -> String {
        format!(
            "(:source :{} :active {} :confidence {:.2} :visualization :{} :smoothing {:.2} :calibrated {} :tracking-lost {} :rate {:.0})",
            self.active_source.as_str(),
            if self.current_gaze.is_some() { "t" } else { "nil" },
            self.health.avg_confidence,
            self.visualization.as_str(),
            self.smoother.alpha,
            if self.calibration.rms_error().is_some() { "t" } else { "nil" },
            if self.health.tracking_lost { "t" } else { "nil" },
            self.health.actual_rate_hz,
        )
    }
}

// ── Tests ───────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gaze_source_roundtrip() {
        assert_eq!(GazeSource::from_str("openxr"), Some(GazeSource::OpenXR));
        assert_eq!(
            GazeSource::from_str("pupil-labs"),
            Some(GazeSource::PupilLabs)
        );
        assert_eq!(
            GazeSource::from_str("simulated"),
            Some(GazeSource::Simulated)
        );
        assert_eq!(GazeSource::from_str("none"), Some(GazeSource::None));
        assert_eq!(GazeSource::from_str("invalid"), None);
    }

    #[test]
    fn test_visualization_roundtrip() {
        assert_eq!(
            GazeVisualization::from_str("dot"),
            Some(GazeVisualization::Dot)
        );
        assert_eq!(
            GazeVisualization::from_str("crosshair"),
            Some(GazeVisualization::Crosshair)
        );
        assert_eq!(
            GazeVisualization::from_str("spotlight"),
            Some(GazeVisualization::Spotlight)
        );
        assert_eq!(
            GazeVisualization::from_str("none"),
            Some(GazeVisualization::None)
        );
    }

    #[test]
    fn test_simulated_mode_roundtrip() {
        assert_eq!(
            SimulatedGazeMode::from_str("mouse"),
            Some(SimulatedGazeMode::Mouse)
        );
        assert_eq!(
            SimulatedGazeMode::from_str("random-walk"),
            Some(SimulatedGazeMode::RandomWalk)
        );
        assert_eq!(
            SimulatedGazeMode::from_str("pattern"),
            Some(SimulatedGazeMode::Pattern)
        );
    }

    #[test]
    fn test_ema_smoothing_first_sample() {
        let mut s = GazeSmoother::new(0.3);
        let dir = Vec3::new(0.0, 0.0, -1.0);
        let result = s.smooth(dir);
        // First sample should pass through unchanged
        assert!((result.z - (-1.0)).abs() < 0.01);
    }

    #[test]
    fn test_ema_smoothing_converges() {
        let mut s = GazeSmoother::new(0.3);
        let dir1 = Vec3::new(0.0, 0.0, -1.0);
        let dir2 = Vec3::new(1.0, 0.0, -1.0).normalize();
        s.smooth(dir1);
        // Apply same direction many times
        let mut result = dir1;
        for _ in 0..50 {
            result = s.smooth(dir2);
        }
        // Should converge close to dir2
        assert!((result.x - dir2.x).abs() < 0.05);
    }

    #[test]
    fn test_gaze_health_tracking_lost() {
        let mut health = GazeHealth::new();
        let ray = Ray::new(Vec3::ZERO, Vec3::new(0.0, 0.0, -1.0));

        // Send 35 low-confidence samples
        for i in 0..35 {
            health.update(&GazeData {
                source: GazeSource::Simulated,
                ray,
                confidence: 0.05,
                timestamp_s: i as f64 * 0.011,
                per_eye: None,
            });
        }
        assert!(health.tracking_lost);
        assert!(health.consecutive_lost_frames >= 30);
    }

    #[test]
    fn test_gaze_health_tracking_recovered() {
        let mut health = GazeHealth::new();
        let ray = Ray::new(Vec3::ZERO, Vec3::new(0.0, 0.0, -1.0));

        // Lose tracking
        for i in 0..35 {
            health.update(&GazeData {
                source: GazeSource::Simulated,
                ray,
                confidence: 0.05,
                timestamp_s: i as f64 * 0.011,
                per_eye: None,
            });
        }
        assert!(health.tracking_lost);

        // Recover
        health.update(&GazeData {
            source: GazeSource::Simulated,
            ray,
            confidence: 0.9,
            timestamp_s: 1.0,
            per_eye: None,
        });
        assert!(!health.tracking_lost);
        assert_eq!(health.consecutive_lost_frames, 0);
    }

    #[test]
    fn test_calibration_lifecycle() {
        let mut cal = EyeCalibrationState::new();
        assert!(!cal.is_calibrating());

        cal.start(3);
        assert!(cal.is_calibrating());
        assert_eq!(cal.current_point_index(), Some(0));

        let target = Vec3::new(0.0, 0.0, -2.0);
        let gaze = Vec3::new(0.0, 0.0, -1.0);

        assert!(!cal.record_point(target, gaze, 0.0));
        assert_eq!(cal.current_point_index(), Some(1));

        assert!(!cal.record_point(target, gaze, 1.0));
        assert!(cal.record_point(target, gaze, 2.0));

        // Calibration complete
        assert!(!cal.is_calibrating());
        assert!(cal.rms_error().is_some());
    }

    #[test]
    fn test_confidence_filter() {
        let mut et = EyeTracking::new();
        et.confidence_min = 0.6;

        let low_conf = GazeData {
            source: GazeSource::Simulated,
            ray: Ray::new(Vec3::ZERO, Vec3::new(0.0, 0.0, -1.0)),
            confidence: 0.3,
            timestamp_s: 0.0,
            per_eye: None,
        };
        et.process_gaze(low_conf);
        assert!(et.current_gaze.is_none());

        let high_conf = GazeData {
            source: GazeSource::Simulated,
            ray: Ray::new(Vec3::ZERO, Vec3::new(0.0, 0.0, -1.0)),
            confidence: 0.9,
            timestamp_s: 0.1,
            per_eye: None,
        };
        et.process_gaze(high_conf);
        assert!(et.current_gaze.is_some());
    }

    #[test]
    fn test_source_auto_selection() {
        let et = EyeTracking::new();
        assert_eq!(et.resolve_source(true, true), GazeSource::OpenXR);
        assert_eq!(et.resolve_source(false, true), GazeSource::PupilLabs);
        assert_eq!(et.resolve_source(false, false), GazeSource::None);
    }

    #[test]
    fn test_source_preferred_override() {
        let mut et = EyeTracking::new();
        et.set_source(Some(GazeSource::PupilLabs));
        assert_eq!(et.resolve_source(true, true), GazeSource::PupilLabs);
    }

    #[test]
    fn test_target_change_detection() {
        let mut et = EyeTracking::new();

        et.update_target(Some(GazeSurfaceHit {
            surface_id: 42,
            pixel_x: 100.0,
            pixel_y: 200.0,
            distance: 1.5,
            confidence: 0.9,
        }));
        assert!(et.previous_target_surface.is_none());

        et.update_target(Some(GazeSurfaceHit {
            surface_id: 43,
            pixel_x: 300.0,
            pixel_y: 400.0,
            distance: 2.0,
            confidence: 0.85,
        }));
        assert_eq!(et.previous_target_surface, Some(42));
    }

    #[test]
    fn test_simulated_random_walk() {
        let mut sim = SimulatedGaze::new();
        sim.mode = Some(SimulatedGazeMode::RandomWalk);

        let mut last_dir = Vec3::ZERO;
        for i in 0..10 {
            if let Some(gaze) = sim.generate(i as f64 * 0.1) {
                assert!(gaze.confidence > 0.5);
                assert_eq!(gaze.source, GazeSource::Simulated);
                last_dir = gaze.ray.direction;
            }
        }
        // Direction should have moved from initial
        assert!(last_dir.z < 0.0); // still pointing forward-ish
    }

    #[test]
    fn test_simulated_pattern() {
        let mut sim = SimulatedGaze::new();
        sim.mode = Some(SimulatedGazeMode::Pattern);

        let gaze1 = sim.generate(0.0).unwrap();
        // Run enough to trigger surface index change
        for _ in 0..200 {
            sim.generate(3.0);
        }
        let gaze2 = sim.generate(4.0).unwrap();
        // Surface index should have advanced
        assert!(sim.surface_index > 0);
        assert_eq!(gaze1.source, GazeSource::Simulated);
        assert_eq!(gaze2.source, GazeSource::Simulated);
    }

    #[test]
    fn test_history_ring_buffer() {
        let mut et = EyeTracking::new();
        et.max_history = 5;
        et.confidence_min = 0.0; // accept all

        let ray = Ray::new(Vec3::ZERO, Vec3::new(0.0, 0.0, -1.0));
        for i in 0..10 {
            et.process_gaze(GazeData {
                source: GazeSource::Simulated,
                ray,
                confidence: 0.9,
                timestamp_s: i as f64 * 0.1,
                per_eye: None,
            });
        }
        assert_eq!(et.gaze_history.len(), 5);
        // Oldest should be timestamp 0.5 (samples 5-9)
        assert!((et.gaze_history.front().unwrap().timestamp_s - 0.5).abs() < 0.001);
    }

    #[test]
    fn test_teardown_clears_state() {
        let mut et = EyeTracking::new();
        et.active_source = GazeSource::OpenXR;
        let ray = Ray::new(Vec3::ZERO, Vec3::new(0.0, 0.0, -1.0));
        et.process_gaze(GazeData {
            source: GazeSource::OpenXR,
            ray,
            confidence: 0.9,
            timestamp_s: 0.0,
            per_eye: None,
        });

        et.teardown();
        assert!(et.current_gaze.is_none());
        assert!(et.gaze_target.is_none());
        assert_eq!(et.active_source, GazeSource::None);
        assert!(et.gaze_history.is_empty());
    }
}
