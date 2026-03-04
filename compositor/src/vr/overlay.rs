//! XR overlay layer management — HUD elements, notifications, and status bars.
//!
//! Overlays are 2D surfaces rendered as layers in the VR scene, either locked
//! to world space, head space (HUD), or hand space.  They have alpha blending,
//! configurable sort order, and can be linked to Wayland surfaces.
//!
//! Overlay types:
//! - `WorldLocked`: stays fixed in 3D space
//! - `HeadLocked`: follows the user's head (HUD / status bar)
//! - `HandLocked`: attached to a tracked hand

use tracing::{debug, info, warn};

use super::scene::{Quat, Transform3D, Vec3};

// ── Types ────────────────────────────────────────────────────

/// Overlay attachment type.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverlayType {
    /// World-locked overlay (stays in 3D space).
    WorldLocked,
    /// Head-locked overlay (follows head, like a HUD).
    HeadLocked,
    /// Hand-locked overlay (attached to hand).
    HandLocked,
}

impl OverlayType {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::WorldLocked => "world-locked",
            Self::HeadLocked => "head-locked",
            Self::HandLocked => "hand-locked",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "world-locked" => Some(Self::WorldLocked),
            "head-locked" => Some(Self::HeadLocked),
            "hand-locked" => Some(Self::HandLocked),
            _ => None,
        }
    }
}

/// A single overlay layer in the VR scene.
#[derive(Debug, Clone)]
pub struct OverlayLayer {
    pub id: u64,
    pub overlay_type: OverlayType,
    /// Opacity (0.0 fully transparent, 1.0 fully opaque).
    pub alpha: f32,
    /// Render order — lower values render first (behind higher values).
    pub sort_order: i32,
    /// 3D transform in the appropriate reference space.
    pub transform: Transform3D,
    /// World-space width in meters.
    pub width: f32,
    /// World-space height in meters.
    pub height: f32,
    /// Whether this overlay is currently visible.
    pub visible: bool,
    /// Linked Wayland surface (if any).
    pub surface_id: Option<u64>,
}

/// Manages the set of overlay layers.
pub struct OverlayManager {
    layers: Vec<OverlayLayer>,
    id_counter: u64,
    /// Maximum number of overlay layers.
    pub max_overlays: usize,
}

// ── Implementation ───────────────────────────────────────────

impl OverlayManager {
    pub fn new() -> Self {
        Self {
            layers: Vec::new(),
            id_counter: 0,
            max_overlays: 16,
        }
    }

    /// Create a new overlay and return its ID.
    ///
    /// Returns 0 if the maximum number of overlays has been reached.
    pub fn create_overlay(
        &mut self,
        overlay_type: OverlayType,
        width: f32,
        height: f32,
        alpha: f32,
        sort_order: i32,
    ) -> u64 {
        if self.layers.len() >= self.max_overlays {
            warn!(
                "overlay: max overlays reached ({}), rejecting create",
                self.max_overlays
            );
            return 0;
        }

        self.id_counter += 1;
        let id = self.id_counter;

        // Default transform: head-locked overlays start slightly below center,
        // world-locked start at origin, hand-locked start at hand offset.
        let transform = match overlay_type {
            OverlayType::HeadLocked => Transform3D::at(0.0, -0.3, -0.5),
            OverlayType::WorldLocked => Transform3D::default(),
            OverlayType::HandLocked => Transform3D::at(0.0, 0.1, -0.15),
        };

        self.layers.push(OverlayLayer {
            id,
            overlay_type,
            alpha: alpha.clamp(0.0, 1.0),
            sort_order,
            transform,
            width,
            height,
            visible: true,
            surface_id: None,
        });

        info!(
            "overlay: created id={} type={} size={}x{}m alpha={:.2}",
            id,
            overlay_type.as_str(),
            width,
            height,
            alpha
        );
        id
    }

    /// Remove an overlay by ID.  Returns true if the overlay was found and removed.
    pub fn remove_overlay(&mut self, id: u64) -> bool {
        let before = self.layers.len();
        self.layers.retain(|l| l.id != id);
        let removed = self.layers.len() < before;
        if removed {
            debug!("overlay: removed id={}", id);
        }
        removed
    }

    /// Get an immutable reference to an overlay.
    pub fn get_overlay(&self, id: u64) -> Option<&OverlayLayer> {
        self.layers.iter().find(|l| l.id == id)
    }

    /// Get a mutable reference to an overlay.
    pub fn get_overlay_mut(&mut self, id: u64) -> Option<&mut OverlayLayer> {
        self.layers.iter_mut().find(|l| l.id == id)
    }

    /// Set the transform for an overlay.  Returns true if found.
    pub fn set_transform(&mut self, id: u64, transform: Transform3D) -> bool {
        if let Some(layer) = self.get_overlay_mut(id) {
            layer.transform = transform;
            true
        } else {
            false
        }
    }

    /// Set the alpha (opacity) for an overlay.  Returns true if found.
    pub fn set_alpha(&mut self, id: u64, alpha: f32) -> bool {
        if let Some(layer) = self.get_overlay_mut(id) {
            layer.alpha = alpha.clamp(0.0, 1.0);
            true
        } else {
            false
        }
    }

    /// Set visibility for an overlay.  Returns true if found.
    pub fn set_visible(&mut self, id: u64, visible: bool) -> bool {
        if let Some(layer) = self.get_overlay_mut(id) {
            layer.visible = visible;
            true
        } else {
            false
        }
    }

    /// Link a Wayland surface to an overlay.  Returns true if found.
    pub fn link_surface(&mut self, overlay_id: u64, surface_id: u64) -> bool {
        if let Some(layer) = self.get_overlay_mut(overlay_id) {
            layer.surface_id = Some(surface_id);
            debug!(
                "overlay: linked surface {} to overlay {}",
                surface_id, overlay_id
            );
            true
        } else {
            false
        }
    }

    /// Update all head-locked overlays to follow the current head pose.
    ///
    /// Head-locked overlays maintain their offset relative to the head,
    /// so we apply the head rotation and position to the overlay's
    /// stored offset transform.
    pub fn update_head_locked(&mut self, head_pos: Vec3, head_rot: Quat) {
        for layer in self.layers.iter_mut() {
            if layer.overlay_type != OverlayType::HeadLocked {
                continue;
            }

            // The overlay's stored transform is a local offset from the head.
            // Rotate the offset by the head quaternion and add head position.
            let local = layer.transform.position;
            let rotated = quat_rotate_vec(head_rot, local);

            layer.transform.position = Vec3::new(
                head_pos.x + rotated.x,
                head_pos.y + rotated.y,
                head_pos.z + rotated.z,
            );
            layer.transform.rotation = head_rot;
        }
    }

    /// Get overlay IDs sorted by sort_order (render order, back to front).
    pub fn render_order(&self) -> Vec<u64> {
        let mut sorted: Vec<&OverlayLayer> = self
            .layers
            .iter()
            .filter(|l| l.visible)
            .collect();
        sorted.sort_by_key(|l| l.sort_order);
        sorted.iter().map(|l| l.id).collect()
    }

    /// How many overlays are currently active.
    pub fn overlay_count(&self) -> usize {
        self.layers.len()
    }

    /// Generate an IPC s-expression listing all overlays.
    pub fn to_sexp(&self) -> String {
        let mut s = String::from("(");
        for layer in &self.layers {
            let surface_str = match layer.surface_id {
                Some(id) => id.to_string(),
                None => "nil".to_string(),
            };
            s.push_str(&format!(
                "(:id {} :type :{} :alpha {:.2} :sort-order {} :position (:x {:.3} :y {:.3} :z {:.3}) :width {:.3} :height {:.3} :visible {} :surface {})",
                layer.id,
                layer.overlay_type.as_str(),
                layer.alpha,
                layer.sort_order,
                layer.transform.position.x,
                layer.transform.position.y,
                layer.transform.position.z,
                layer.width,
                layer.height,
                if layer.visible { "t" } else { "nil" },
                surface_str,
            ));
        }
        s.push(')');
        s
    }
}

// ── Helper ───────────────────────────────────────────────────

/// Rotate a vector by a quaternion: q * v * q^-1
fn quat_rotate_vec(q: Quat, v: Vec3) -> Vec3 {
    let ux = q.x;
    let uy = q.y;
    let uz = q.z;
    let w = q.w;

    // u x v
    let cx = uy * v.z - uz * v.y;
    let cy = uz * v.x - ux * v.z;
    let cz = ux * v.y - uy * v.x;

    // u x (u x v)
    let ccx = uy * cz - uz * cy;
    let ccy = uz * cx - ux * cz;
    let ccz = ux * cy - uy * cx;

    Vec3::new(
        v.x + 2.0 * (w * cx + ccx),
        v.y + 2.0 * (w * cy + ccy),
        v.z + 2.0 * (w * cz + ccz),
    )
}

// ── Tests ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_create_and_get() {
        let mut mgr = OverlayManager::new();
        let id = mgr.create_overlay(OverlayType::HeadLocked, 0.4, 0.05, 0.9, 10);
        assert!(id > 0);
        assert_eq!(mgr.overlay_count(), 1);

        let layer = mgr.get_overlay(id).unwrap();
        assert_eq!(layer.overlay_type, OverlayType::HeadLocked);
        assert!((layer.alpha - 0.9).abs() < 0.01);
        assert_eq!(layer.sort_order, 10);
        assert!((layer.width - 0.4).abs() < 0.01);
        assert!((layer.height - 0.05).abs() < 0.01);
        assert!(layer.visible);
        assert_eq!(layer.surface_id, None);
    }

    #[test]
    fn test_remove() {
        let mut mgr = OverlayManager::new();
        let id1 = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 0);
        let id2 = mgr.create_overlay(OverlayType::HeadLocked, 0.5, 0.5, 0.8, 1);
        assert_eq!(mgr.overlay_count(), 2);

        assert!(mgr.remove_overlay(id1));
        assert_eq!(mgr.overlay_count(), 1);
        assert!(mgr.get_overlay(id1).is_none());
        assert!(mgr.get_overlay(id2).is_some());

        // Removing non-existent ID returns false.
        assert!(!mgr.remove_overlay(999));
    }

    #[test]
    fn test_render_order() {
        let mut mgr = OverlayManager::new();
        let id_a = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 30);
        let id_b = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 10);
        let id_c = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 20);

        let order = mgr.render_order();
        assert_eq!(order, vec![id_b, id_c, id_a]);
    }

    #[test]
    fn test_render_order_excludes_hidden() {
        let mut mgr = OverlayManager::new();
        let id_a = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 10);
        let id_b = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 20);
        mgr.set_visible(id_a, false);

        let order = mgr.render_order();
        assert_eq!(order, vec![id_b]);
    }

    #[test]
    fn test_set_alpha_clamp() {
        let mut mgr = OverlayManager::new();
        let id = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 0.5, 0);

        mgr.set_alpha(id, 1.5);
        assert!((mgr.get_overlay(id).unwrap().alpha - 1.0).abs() < 0.01);

        mgr.set_alpha(id, -0.5);
        assert!((mgr.get_overlay(id).unwrap().alpha - 0.0).abs() < 0.01);
    }

    #[test]
    fn test_link_surface() {
        let mut mgr = OverlayManager::new();
        let id = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 0);
        assert_eq!(mgr.get_overlay(id).unwrap().surface_id, None);

        assert!(mgr.link_surface(id, 42));
        assert_eq!(mgr.get_overlay(id).unwrap().surface_id, Some(42));

        // Linking to non-existent overlay returns false.
        assert!(!mgr.link_surface(999, 42));
    }

    #[test]
    fn test_max_overlays() {
        let mut mgr = OverlayManager::new();
        mgr.max_overlays = 3;

        let id1 = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 0);
        let id2 = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 0);
        let id3 = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 0);
        assert!(id1 > 0);
        assert!(id2 > 0);
        assert!(id3 > 0);
        assert_eq!(mgr.overlay_count(), 3);

        // 4th should be rejected.
        let id4 = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 0);
        assert_eq!(id4, 0);
        assert_eq!(mgr.overlay_count(), 3);
    }

    #[test]
    fn test_head_locked_update() {
        let mut mgr = OverlayManager::new();
        let id = mgr.create_overlay(OverlayType::HeadLocked, 0.4, 0.05, 0.9, 10);

        // Store initial offset.
        let initial_pos = mgr.get_overlay(id).unwrap().transform.position;

        // Move head to new position (identity rotation so the offset is preserved).
        let head_pos = Vec3::new(1.0, 2.0, 3.0);
        let head_rot = Quat::IDENTITY;
        mgr.update_head_locked(head_pos, head_rot);

        let updated = mgr.get_overlay(id).unwrap();
        // With identity rotation, overlay should be head_pos + initial offset.
        assert!(
            (updated.transform.position.x - (head_pos.x + initial_pos.x)).abs() < 0.01,
            "x: got {} expected {}",
            updated.transform.position.x,
            head_pos.x + initial_pos.x
        );
        assert!(
            (updated.transform.position.y - (head_pos.y + initial_pos.y)).abs() < 0.01,
            "y: got {} expected {}",
            updated.transform.position.y,
            head_pos.y + initial_pos.y
        );
        assert!(
            (updated.transform.position.z - (head_pos.z + initial_pos.z)).abs() < 0.01,
            "z: got {} expected {}",
            updated.transform.position.z,
            head_pos.z + initial_pos.z
        );
    }

    #[test]
    fn test_world_locked_not_affected_by_head_update() {
        let mut mgr = OverlayManager::new();
        let id = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 0);
        let original = mgr.get_overlay(id).unwrap().transform.position;

        mgr.update_head_locked(Vec3::new(5.0, 5.0, 5.0), Quat::IDENTITY);

        let after = mgr.get_overlay(id).unwrap().transform.position;
        assert!((after.x - original.x).abs() < 0.001);
        assert!((after.y - original.y).abs() < 0.001);
        assert!((after.z - original.z).abs() < 0.001);
    }

    #[test]
    fn test_to_sexp() {
        let mut mgr = OverlayManager::new();
        mgr.create_overlay(OverlayType::HeadLocked, 0.4, 0.05, 0.9, 10);
        let sexp = mgr.to_sexp();
        assert!(sexp.contains(":type :head-locked"));
        assert!(sexp.contains(":alpha 0.90"));
        assert!(sexp.contains(":sort-order 10"));
        assert!(sexp.contains(":visible t"));
    }

    #[test]
    fn test_set_transform() {
        let mut mgr = OverlayManager::new();
        let id = mgr.create_overlay(OverlayType::WorldLocked, 1.0, 1.0, 1.0, 0);

        let new_t = Transform3D::at(1.0, 2.0, -3.0);
        assert!(mgr.set_transform(id, new_t));
        let pos = mgr.get_overlay(id).unwrap().transform.position;
        assert!((pos.x - 1.0).abs() < 0.001);
        assert!((pos.y - 2.0).abs() < 0.001);
        assert!((pos.z - (-3.0)).abs() < 0.001);

        // Non-existent ID returns false.
        assert!(!mgr.set_transform(999, new_t));
    }

    #[test]
    fn test_overlay_type_roundtrip() {
        let types = [
            OverlayType::WorldLocked,
            OverlayType::HeadLocked,
            OverlayType::HandLocked,
        ];
        for t in &types {
            let s = t.as_str();
            let parsed = OverlayType::from_str(s);
            assert_eq!(parsed, Some(*t), "roundtrip failed for {:?}", t);
        }
        assert_eq!(OverlayType::from_str("bogus"), None);
    }
}
