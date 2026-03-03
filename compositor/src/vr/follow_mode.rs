//! VR follow mode — keeps surfaces within the user's field of view.
//!
//! When enabled, surfaces that drift outside the FOV threshold are smoothly
//! repositioned to the edge of the visible area.  Supports multiple policies:
//! - `Disabled`: surfaces stay fixed in world space
//! - `FocusedOnly`: only the focused surface follows
//! - `GrabAll`: all surfaces maintain relative positions to the head
//! - `ThresholdOnly`: surfaces that exit the FOV+deadzone are nudged back

use std::collections::HashSet;
use std::f32::consts::PI;
use tracing::{debug, info};

use super::scene::{Quat, Vec3, VrScene};

// ── Types ────────────────────────────────────────────────────

/// Global follow policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FollowPolicy {
    /// Don't follow — surfaces stay fixed in world space.
    Disabled,
    /// Follow the focused surface only.
    FocusedOnly,
    /// Follow all visible surfaces (grab-all mode).
    GrabAll,
    /// Follow surfaces that exit the FOV threshold.
    ThresholdOnly,
}

impl FollowPolicy {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::FocusedOnly => "focused-only",
            Self::GrabAll => "grab-all",
            Self::ThresholdOnly => "threshold-only",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "disabled" => Some(Self::Disabled),
            "focused-only" => Some(Self::FocusedOnly),
            "grab-all" => Some(Self::GrabAll),
            "threshold-only" => Some(Self::ThresholdOnly),
            _ => None,
        }
    }
}

impl Default for FollowPolicy {
    fn default() -> Self {
        Self::Disabled
    }
}

/// Follow mode configuration.
#[derive(Debug, Clone)]
pub struct FollowConfig {
    /// Horizontal FOV threshold in degrees — surfaces outside this trigger follow.
    pub h_fov_threshold: f32,
    /// Vertical FOV threshold in degrees.
    pub v_fov_threshold: f32,
    /// Follow speed (0.0 = instant, 1.0 = very slow).  Lerp factor per frame.
    pub follow_speed: f32,
    /// Distance from head to place followed surfaces (meters).
    pub follow_distance: f32,
    /// Deadzone — don't follow until surface is this many degrees outside FOV.
    pub deadzone_degrees: f32,
    /// Whether to suppress follow during reading mode.
    pub suppress_during_reading: bool,
}

impl Default for FollowConfig {
    fn default() -> Self {
        Self {
            h_fov_threshold: 80.0,
            v_fov_threshold: 60.0,
            follow_speed: 0.15,
            follow_distance: 1.5,
            deadzone_degrees: 5.0,
            suppress_during_reading: true,
        }
    }
}

/// Central follow-mode state.
pub struct FollowMode {
    pub policy: FollowPolicy,
    pub config: FollowConfig,
    /// Set of surface IDs that are currently being followed (animating).
    following: HashSet<u64>,
    /// Head-space reference origin (updated on recenter).
    reference_origin: Vec3,
    reference_rotation: Quat,
}

impl FollowMode {
    pub fn new() -> Self {
        Self {
            policy: FollowPolicy::default(),
            config: FollowConfig::default(),
            following: HashSet::new(),
            reference_origin: Vec3::ZERO,
            reference_rotation: Quat::IDENTITY,
        }
    }

    /// Per-frame update.  For each visible node in the scene, check whether it
    /// has drifted outside the FOV threshold and, if so, lerp it toward the
    /// edge of the visible area.
    pub fn update(
        &mut self,
        head_pos: Vec3,
        head_rot: Quat,
        scene: &mut VrScene,
        reading_active: bool,
    ) {
        if self.policy == FollowPolicy::Disabled {
            return;
        }
        if self.config.suppress_during_reading && reading_active {
            return;
        }

        // Collect IDs that qualify for follow checking.
        let ids: Vec<u64> = scene
            .nodes
            .iter()
            .filter(|(_, node)| node.visible)
            .filter(|(_, node)| match self.policy {
                FollowPolicy::FocusedOnly => node.focused,
                FollowPolicy::GrabAll | FollowPolicy::ThresholdOnly => true,
                FollowPolicy::Disabled => false,
            })
            .map(|(id, _)| *id)
            .collect();

        let mut still_following: HashSet<u64> = HashSet::new();

        for id in ids {
            let node_pos = match scene.nodes.get(&id) {
                Some(n) => n.transform.position,
                None => continue,
            };

            let (h_angle, v_angle) = angle_from_forward(head_pos, head_rot, node_pos);

            let h_threshold = self.config.h_fov_threshold * 0.5;
            let v_threshold = self.config.v_fov_threshold * 0.5;
            let deadzone = self.config.deadzone_degrees;

            let outside_h = h_angle.abs() > h_threshold + deadzone;
            let outside_v = v_angle.abs() > v_threshold + deadzone;

            if outside_h || outside_v {
                let target = position_on_fov_edge(
                    head_pos,
                    head_rot,
                    node_pos,
                    h_threshold,
                    v_threshold,
                    self.config.follow_distance,
                );

                // Lerp: speed 0.0 => instant (t=1.0), speed 1.0 => very slow (t~0)
                let t = 1.0 - self.config.follow_speed;

                if let Some(node) = scene.nodes.get_mut(&id) {
                    node.transform.position = node.transform.position.lerp(target, t);
                }
                still_following.insert(id);
            }
        }

        self.following = still_following;
    }

    /// Snap all surfaces to head-relative positions, updating the reference
    /// origin and rotation.
    pub fn recenter(&mut self, head_pos: Vec3, head_rot: Quat, scene: &mut VrScene) {
        self.reference_origin = head_pos;
        self.reference_rotation = head_rot;

        // Reposition every node to sit at follow_distance directly in front
        // of the current head pose, preserving the existing layout offsets
        // relative to the scene center.
        let forward = quat_rotate_vec(head_rot, Vec3::new(0.0, 0.0, -1.0));
        let center = Vec3::new(
            head_pos.x + forward.x * self.config.follow_distance,
            head_pos.y + forward.y * self.config.follow_distance,
            head_pos.z + forward.z * self.config.follow_distance,
        );

        // Compute existing centroid of visible surfaces.
        let visible: Vec<u64> = scene
            .nodes
            .iter()
            .filter(|(_, n)| n.visible)
            .map(|(id, _)| *id)
            .collect();

        if visible.is_empty() {
            return;
        }

        let mut cx = 0.0f32;
        let mut cy = 0.0f32;
        let mut cz = 0.0f32;
        for id in &visible {
            if let Some(n) = scene.nodes.get(id) {
                cx += n.transform.position.x;
                cy += n.transform.position.y;
                cz += n.transform.position.z;
            }
        }
        let count = visible.len() as f32;
        cx /= count;
        cy /= count;
        cz /= count;

        // Shift each surface so the centroid lands at `center`.
        let dx = center.x - cx;
        let dy = center.y - cy;
        let dz = center.z - cz;

        for id in &visible {
            if let Some(node) = scene.nodes.get_mut(id) {
                node.transform.position.x += dx;
                node.transform.position.y += dy;
                node.transform.position.z += dz;
            }
        }

        self.following.clear();
        info!("VR follow: recentered {} surfaces", visible.len());
    }

    /// Move ALL surfaces so they maintain their relative positions to the new
    /// head pose.  This is the "grab everything" gesture.
    pub fn grab_all(&mut self, scene: &mut VrScene, head_pos: Vec3, head_rot: Quat) {
        // Compute delta from stored reference to new head pose.
        let dx = head_pos.x - self.reference_origin.x;
        let dy = head_pos.y - self.reference_origin.y;
        let dz = head_pos.z - self.reference_origin.z;

        for node in scene.nodes.values_mut() {
            node.transform.position.x += dx;
            node.transform.position.y += dy;
            node.transform.position.z += dz;
        }

        self.reference_origin = head_pos;
        self.reference_rotation = head_rot;

        debug!("VR follow: grab-all applied delta ({:.3}, {:.3}, {:.3})", dx, dy, dz);
    }

    /// Change the follow policy.
    pub fn set_policy(&mut self, policy: FollowPolicy) {
        info!("VR follow: policy -> {:?}", policy);
        self.policy = policy;
        if policy == FollowPolicy::Disabled {
            self.following.clear();
        }
    }

    /// Whether a given surface is currently being followed (animating).
    pub fn is_following(&self, surface_id: u64) -> bool {
        self.following.contains(&surface_id)
    }

    /// How many surfaces are actively following.
    pub fn get_following_count(&self) -> usize {
        self.following.len()
    }

    /// Generate IPC s-expression for follow status.
    pub fn status_sexp(&self) -> String {
        let following_ids: Vec<String> =
            self.following.iter().map(|id| id.to_string()).collect();
        format!(
            "(:policy :{} :h-fov-threshold {:.1} :v-fov-threshold {:.1} :follow-speed {:.2} :follow-distance {:.2} :deadzone {:.1} :suppress-reading {} :following-count {} :following-ids ({}))",
            self.policy.as_str(),
            self.config.h_fov_threshold,
            self.config.v_fov_threshold,
            self.config.follow_speed,
            self.config.follow_distance,
            self.config.deadzone_degrees,
            if self.config.suppress_during_reading { "t" } else { "nil" },
            self.following.len(),
            following_ids.join(" "),
        )
    }
}

// ── Helper functions ─────────────────────────────────────────

/// Rotate a vector by a quaternion: q * v * q⁻¹
fn quat_rotate_vec(q: Quat, v: Vec3) -> Vec3 {
    // Using the formula: v' = v + 2w(u × v) + 2(u × (u × v))
    // where q = (u, w), u = (q.x, q.y, q.z), w = q.w
    let ux = q.x;
    let uy = q.y;
    let uz = q.z;
    let w = q.w;

    // u × v
    let cx = uy * v.z - uz * v.y;
    let cy = uz * v.x - ux * v.z;
    let cz = ux * v.y - uy * v.x;

    // u × (u × v)
    let ccx = uy * cz - uz * cy;
    let ccy = uz * cx - ux * cz;
    let ccz = ux * cy - uy * cx;

    Vec3::new(
        v.x + 2.0 * (w * cx + ccx),
        v.y + 2.0 * (w * cy + ccy),
        v.z + 2.0 * (w * cz + ccz),
    )
}

/// Compute the horizontal and vertical angle (in degrees) from the head's
/// forward direction to a target position.
///
/// Returns `(h_angle, v_angle)` where positive h_angle is to the right and
/// positive v_angle is upward.
pub fn angle_from_forward(head_pos: Vec3, head_rot: Quat, target_pos: Vec3) -> (f32, f32) {
    // Direction from head to target in world space.
    let dx = target_pos.x - head_pos.x;
    let dy = target_pos.y - head_pos.y;
    let dz = target_pos.z - head_pos.z;
    let dir = Vec3::new(dx, dy, dz).normalize();

    if dir.length() < 1e-8 {
        return (0.0, 0.0);
    }

    // Head basis vectors.
    let forward = quat_rotate_vec(head_rot, Vec3::new(0.0, 0.0, -1.0));
    let right = quat_rotate_vec(head_rot, Vec3::new(1.0, 0.0, 0.0));
    let up = quat_rotate_vec(head_rot, Vec3::new(0.0, 1.0, 0.0));

    // Project direction onto the head's forward-right and forward-up planes.
    let dot_forward = dir.x * forward.x + dir.y * forward.y + dir.z * forward.z;
    let dot_right = dir.x * right.x + dir.y * right.y + dir.z * right.z;
    let dot_up = dir.x * up.x + dir.y * up.y + dir.z * up.z;

    let h_angle = dot_right.atan2(dot_forward) * (180.0 / PI);
    let v_angle = dot_up.atan2(dot_forward) * (180.0 / PI);

    (h_angle, v_angle)
}

/// Compute where to place a surface on the FOV edge at a given distance.
///
/// The returned position is in world space, placed at `distance` from the
/// head along a direction that clamps the target's angular offset to the
/// given thresholds.
pub fn position_on_fov_edge(
    head_pos: Vec3,
    head_rot: Quat,
    target_pos: Vec3,
    h_threshold: f32,
    v_threshold: f32,
    distance: f32,
) -> Vec3 {
    let (h_angle, v_angle) = angle_from_forward(head_pos, head_rot, target_pos);

    // Clamp angles to the FOV edge.
    let clamped_h = h_angle.clamp(-h_threshold, h_threshold);
    let clamped_v = v_angle.clamp(-v_threshold, v_threshold);

    // Convert clamped angles back to radians.
    let h_rad = clamped_h * (PI / 180.0);
    let v_rad = clamped_v * (PI / 180.0);

    // Construct direction in head-local space then rotate to world.
    // Forward is -Z in head space; h_rad rotates around Y, v_rad around X.
    let local_dir = Vec3::new(h_rad.sin(), v_rad.sin(), -h_rad.cos() * v_rad.cos());
    let local_dir = local_dir.normalize();

    let world_dir = quat_rotate_vec(head_rot, local_dir);

    Vec3::new(
        head_pos.x + world_dir.x * distance,
        head_pos.y + world_dir.y * distance,
        head_pos.z + world_dir.z * distance,
    )
}

// ── Tests ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vr::scene::VrScene;

    const EPSILON: f32 = 0.01;

    fn approx_eq(a: f32, b: f32) -> bool {
        (a - b).abs() < EPSILON
    }

    #[test]
    fn test_default_config() {
        let fm = FollowMode::new();
        assert_eq!(fm.policy, FollowPolicy::Disabled);
        assert!(approx_eq(fm.config.h_fov_threshold, 80.0));
        assert!(approx_eq(fm.config.v_fov_threshold, 60.0));
        assert!(approx_eq(fm.config.follow_speed, 0.15));
        assert!(approx_eq(fm.config.follow_distance, 1.5));
        assert!(approx_eq(fm.config.deadzone_degrees, 5.0));
        assert!(fm.config.suppress_during_reading);
        assert_eq!(fm.get_following_count(), 0);
    }

    #[test]
    fn test_angle_from_forward_straight_ahead() {
        let head = Vec3::ZERO;
        let rot = Quat::IDENTITY;
        // Directly ahead in -Z
        let target = Vec3::new(0.0, 0.0, -5.0);
        let (h, v) = angle_from_forward(head, rot, target);
        assert!(approx_eq(h, 0.0));
        assert!(approx_eq(v, 0.0));
    }

    #[test]
    fn test_angle_from_forward_to_right() {
        let head = Vec3::ZERO;
        let rot = Quat::IDENTITY;
        // 45 degrees to the right: equal x and -z
        let target = Vec3::new(1.0, 0.0, -1.0);
        let (h, v) = angle_from_forward(head, rot, target);
        assert!(approx_eq(h, 45.0));
        assert!(approx_eq(v, 0.0));
    }

    #[test]
    fn test_angle_from_forward_upward() {
        let head = Vec3::ZERO;
        let rot = Quat::IDENTITY;
        // 45 degrees up
        let target = Vec3::new(0.0, 1.0, -1.0);
        let (h, v) = angle_from_forward(head, rot, target);
        assert!(approx_eq(h, 0.0));
        assert!(approx_eq(v, 45.0));
    }

    #[test]
    fn test_position_on_fov_edge_clamps() {
        let head = Vec3::ZERO;
        let rot = Quat::IDENTITY;
        // Target far to the right (90 deg)
        let target = Vec3::new(10.0, 0.0, 0.0);
        let edge = position_on_fov_edge(head, rot, target, 40.0, 30.0, 2.0);

        // The returned position should be at distance ~2.0 from head.
        let dist = edge.length();
        assert!(approx_eq(dist, 2.0));

        // Its horizontal angle should be clamped to ~40 degrees.
        let (h, _) = angle_from_forward(head, rot, edge);
        assert!((h - 40.0).abs() < 1.0);
    }

    #[test]
    fn test_update_moves_surface_outside_fov() {
        let mut fm = FollowMode::new();
        fm.set_policy(FollowPolicy::ThresholdOnly);
        fm.config.follow_speed = 0.0; // instant

        let mut scene = VrScene::new();
        scene.add_surface(1, 100, 100);
        // Place surface far to the right (outside FOV)
        scene.nodes.get_mut(&1).unwrap().transform.position = Vec3::new(10.0, 0.0, -1.0);

        let head = Vec3::ZERO;
        let rot = Quat::IDENTITY;
        fm.update(head, rot, &mut scene, false);

        let pos = scene.nodes[&1].transform.position;
        // Surface should have moved closer to center (angle reduced)
        let (h, _) = angle_from_forward(head, rot, pos);
        assert!(
            h.abs() < 50.0,
            "Surface should have been moved into FOV edge, got h={h}"
        );
    }

    #[test]
    fn test_update_ignores_surface_inside_fov() {
        let mut fm = FollowMode::new();
        fm.set_policy(FollowPolicy::ThresholdOnly);

        let mut scene = VrScene::new();
        scene.add_surface(1, 100, 100);
        // Place directly ahead — well within FOV
        let original = Vec3::new(0.0, 0.0, -2.0);
        scene.nodes.get_mut(&1).unwrap().transform.position = original;

        let head = Vec3::ZERO;
        let rot = Quat::IDENTITY;
        fm.update(head, rot, &mut scene, false);

        let pos = scene.nodes[&1].transform.position;
        assert!(approx_eq(pos.x, original.x));
        assert!(approx_eq(pos.y, original.y));
        assert!(approx_eq(pos.z, original.z));
        assert_eq!(fm.get_following_count(), 0);
    }

    #[test]
    fn test_recenter_snaps_reference() {
        let mut fm = FollowMode::new();
        let mut scene = VrScene::new();
        scene.add_surface(1, 100, 100);
        scene.nodes.get_mut(&1).unwrap().transform.position = Vec3::new(0.0, 0.0, -2.0);

        let new_head = Vec3::new(1.0, 0.5, 0.0);
        let rot = Quat::IDENTITY;
        fm.recenter(new_head, rot, &mut scene);

        assert!(approx_eq(fm.reference_origin.x, new_head.x));
        assert!(approx_eq(fm.reference_origin.y, new_head.y));
        assert!(approx_eq(fm.reference_origin.z, new_head.z));

        // Surface should now be at follow_distance in front of head
        let pos = scene.nodes[&1].transform.position;
        let (h, v) = angle_from_forward(new_head, rot, pos);
        assert!(h.abs() < 5.0, "Surface should be roughly ahead after recenter");
    }

    #[test]
    fn test_grab_all_preserves_relative_positions() {
        let mut fm = FollowMode::new();
        fm.reference_origin = Vec3::ZERO;
        fm.reference_rotation = Quat::IDENTITY;

        let mut scene = VrScene::new();
        scene.add_surface(1, 100, 100);
        scene.add_surface(2, 100, 100);
        scene.nodes.get_mut(&1).unwrap().transform.position = Vec3::new(-1.0, 0.0, -2.0);
        scene.nodes.get_mut(&2).unwrap().transform.position = Vec3::new(1.0, 0.0, -2.0);

        // Record relative distance between surfaces before grab
        let pre_dx =
            scene.nodes[&2].transform.position.x - scene.nodes[&1].transform.position.x;

        let new_head = Vec3::new(0.0, 0.0, 1.0);
        fm.grab_all(&mut scene, new_head, Quat::IDENTITY);

        // Relative distance should be preserved
        let post_dx =
            scene.nodes[&2].transform.position.x - scene.nodes[&1].transform.position.x;
        assert!(approx_eq(pre_dx, post_dx));

        // Both surfaces should have shifted by the head delta
        assert!(approx_eq(scene.nodes[&1].transform.position.z, -1.0));
        assert!(approx_eq(scene.nodes[&2].transform.position.z, -1.0));
    }

    #[test]
    fn test_reading_mode_suppression() {
        let mut fm = FollowMode::new();
        fm.set_policy(FollowPolicy::ThresholdOnly);
        fm.config.follow_speed = 0.0;

        let mut scene = VrScene::new();
        scene.add_surface(1, 100, 100);
        scene.nodes.get_mut(&1).unwrap().transform.position = Vec3::new(10.0, 0.0, -1.0);
        let original_x = scene.nodes[&1].transform.position.x;

        let head = Vec3::ZERO;
        let rot = Quat::IDENTITY;

        // With reading_active = true, surface should NOT be moved
        fm.update(head, rot, &mut scene, true);
        assert!(approx_eq(scene.nodes[&1].transform.position.x, original_x));

        // With reading_active = false, it should move
        fm.update(head, rot, &mut scene, false);
        assert!(
            !approx_eq(scene.nodes[&1].transform.position.x, original_x),
            "Surface should have moved when reading is inactive"
        );
    }

    #[test]
    fn test_policy_from_str_roundtrip() {
        let policies = [
            FollowPolicy::Disabled,
            FollowPolicy::FocusedOnly,
            FollowPolicy::GrabAll,
            FollowPolicy::ThresholdOnly,
        ];
        for p in &policies {
            let s = p.as_str();
            let parsed = FollowPolicy::from_str(s);
            assert_eq!(parsed, Some(*p), "roundtrip failed for {:?}", p);
        }
        assert_eq!(FollowPolicy::from_str("bogus"), None);
    }

    #[test]
    fn test_focused_only_policy() {
        let mut fm = FollowMode::new();
        fm.set_policy(FollowPolicy::FocusedOnly);
        fm.config.follow_speed = 0.0; // instant

        let mut scene = VrScene::new();
        scene.add_surface(1, 100, 100);
        scene.add_surface(2, 100, 100);

        // Both far to the right
        scene.nodes.get_mut(&1).unwrap().transform.position = Vec3::new(10.0, 0.0, -1.0);
        scene.nodes.get_mut(&2).unwrap().transform.position = Vec3::new(10.0, 0.0, -1.0);
        let orig_x = 10.0;

        // Focus surface 1
        scene.set_focus(Some(1));

        let head = Vec3::ZERO;
        let rot = Quat::IDENTITY;
        fm.update(head, rot, &mut scene, false);

        // Surface 1 (focused) should have moved
        assert!(
            !approx_eq(scene.nodes[&1].transform.position.x, orig_x),
            "Focused surface should move"
        );
        // Surface 2 (unfocused) should NOT have moved
        assert!(
            approx_eq(scene.nodes[&2].transform.position.x, orig_x),
            "Unfocused surface should stay put"
        );
    }

    #[test]
    fn test_status_sexp_format() {
        let fm = FollowMode::new();
        let sexp = fm.status_sexp();
        assert!(sexp.contains(":policy :disabled"));
        assert!(sexp.contains(":h-fov-threshold 80.0"));
        assert!(sexp.contains(":following-count 0"));
    }
}
