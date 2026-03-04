//! 3D transient chain positioning for popup windows in VR.
//!
//! Manages parent-child relationships between Wayland surfaces (menus, tooltips,
//! dialogs) and computes 3D positions so that transient windows appear near
//! their parents in the VR scene graph.
//!
//! Placement strategies:
//! - `Front`: popup appears slightly closer to the user than its parent
//! - `Above`: popup appears above the parent surface
//! - `Below`: popup appears below the parent surface
//! - `Auto`: selects placement heuristically (Front for dialogs, etc.)

use tracing::{debug, info, warn};

use super::scene::{Quat, Transform3D, Vec3, VrScene};

// ── Types ────────────────────────────────────────────────────

/// How a transient popup should be placed relative to its parent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransientPlacement {
    /// Popup appears directly in front of parent, slightly closer to user.
    Front,
    /// Popup appears above parent.
    Above,
    /// Popup appears below parent.
    Below,
    /// Auto: use Front for dialogs, Above for tooltips, Below for menus.
    Auto,
}

impl TransientPlacement {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Front => "front",
            Self::Above => "above",
            Self::Below => "below",
            Self::Auto => "auto",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "front" => Some(Self::Front),
            "above" => Some(Self::Above),
            "below" => Some(Self::Below),
            "auto" => Some(Self::Auto),
            _ => None,
        }
    }
}

/// A parent-child relationship between two surfaces.
#[derive(Debug, Clone)]
pub struct TransientRelation {
    pub child_id: u64,
    pub parent_id: u64,
    pub placement: TransientPlacement,
    /// Depth offset toward user (meters).  Default 0.1m per depth level.
    pub z_offset: f32,
}

/// Manages a tree of transient surface relationships and computes 3D positions.
pub struct TransientChainManager {
    /// Parent-child relationships.
    relations: Vec<TransientRelation>,
    /// Default Z offset per depth level (meters).
    pub z_offset_per_level: f32,
    /// Maximum chain depth before rejecting new transients.
    pub max_depth: u32,
}

// ── Implementation ───────────────────────────────────────────

impl TransientChainManager {
    pub fn new() -> Self {
        Self {
            relations: Vec::new(),
            z_offset_per_level: 0.1,
            max_depth: 5,
        }
    }

    /// Register a transient child surface under a parent.
    /// Returns Err if the chain would exceed `max_depth`.
    pub fn add_transient(
        &mut self,
        child_id: u64,
        parent_id: u64,
        placement: TransientPlacement,
    ) -> Result<(), String> {
        // Don't allow a surface to be its own parent.
        if child_id == parent_id {
            return Err("child_id == parent_id".to_string());
        }

        // Check if child is already registered — remove old relation first.
        self.relations.retain(|r| r.child_id != child_id);

        // Compute depth: parent depth + 1.
        let parent_depth = self.chain_depth(parent_id);
        if parent_depth + 1 > self.max_depth {
            return Err(format!(
                "transient chain depth {} exceeds max {}",
                parent_depth + 1,
                self.max_depth
            ));
        }

        // Check for cycles: walk from parent_id up — if we encounter child_id,
        // inserting this edge would create a cycle.
        let mut cursor = parent_id;
        loop {
            if cursor == child_id {
                return Err("cycle detected".to_string());
            }
            match self.get_parent(cursor) {
                Some(p) => cursor = p,
                None => break,
            }
        }

        let depth = parent_depth + 1;
        let z_offset = self.z_offset_per_level * depth as f32;

        self.relations.push(TransientRelation {
            child_id,
            parent_id,
            placement,
            z_offset,
        });

        debug!(
            "transient_3d: added child {} -> parent {} (depth {}, placement {:?})",
            child_id, parent_id, depth, placement
        );
        Ok(())
    }

    /// Remove a transient and cascade-remove all its descendants.
    pub fn remove_transient(&mut self, child_id: u64) {
        // Collect the full subtree of descendants.
        let mut to_remove = vec![child_id];
        let mut i = 0;
        while i < to_remove.len() {
            let current = to_remove[i];
            let children = self.get_children(current);
            to_remove.extend(children);
            i += 1;
        }

        let before = self.relations.len();
        self.relations
            .retain(|r| !to_remove.contains(&r.child_id));
        let removed = before - self.relations.len();

        debug!(
            "transient_3d: removed {} (cascade removed {} relations)",
            child_id, removed
        );
    }

    /// Get the parent of a surface, if it is a transient.
    pub fn get_parent(&self, child_id: u64) -> Option<u64> {
        self.relations
            .iter()
            .find(|r| r.child_id == child_id)
            .map(|r| r.parent_id)
    }

    /// Get all direct children of a surface.
    pub fn get_children(&self, parent_id: u64) -> Vec<u64> {
        self.relations
            .iter()
            .filter(|r| r.parent_id == parent_id)
            .map(|r| r.child_id)
            .collect()
    }

    /// How deep a surface is in its transient chain (0 = root / not a transient).
    pub fn chain_depth(&self, surface_id: u64) -> u32 {
        let mut depth = 0u32;
        let mut cursor = surface_id;
        while let Some(parent) = self.get_parent(cursor) {
            depth += 1;
            cursor = parent;
            if depth > self.max_depth + 1 {
                // Safety valve against corrupted state.
                break;
            }
        }
        depth
    }

    /// Compute a child's 3D transform based on its parent transform and placement.
    ///
    /// `head_pos` is used for the `Front` placement (offset toward viewer).
    pub fn position_transient(
        &self,
        child_id: u64,
        parent_transform: &Transform3D,
        head_pos: Vec3,
    ) -> Transform3D {
        let relation = match self.relations.iter().find(|r| r.child_id == child_id) {
            Some(r) => r,
            None => return *parent_transform,
        };

        let placement = match relation.placement {
            TransientPlacement::Auto => TransientPlacement::Front,
            other => other,
        };

        let z_off = relation.z_offset;
        let offset = match placement {
            TransientPlacement::Front => {
                // Direction from parent toward the viewer.
                let dir = Vec3::new(
                    head_pos.x - parent_transform.position.x,
                    head_pos.y - parent_transform.position.y,
                    head_pos.z - parent_transform.position.z,
                )
                .normalize();
                Vec3::new(dir.x * z_off, dir.y * z_off, dir.z * z_off)
            }
            TransientPlacement::Above => Vec3::new(0.0, z_off, 0.0),
            TransientPlacement::Below => Vec3::new(0.0, -z_off, 0.0),
            TransientPlacement::Auto => unreachable!(),
        };

        Transform3D {
            position: Vec3::new(
                parent_transform.position.x + offset.x,
                parent_transform.position.y + offset.y,
                parent_transform.position.z + offset.z,
            ),
            rotation: parent_transform.rotation,
            scale: parent_transform.scale,
        }
    }

    /// Recursively position all children of `parent_id` in the scene.
    pub fn position_all_children(
        &self,
        parent_id: u64,
        scene: &mut VrScene,
        head_pos: Vec3,
    ) {
        let children = self.get_children(parent_id);
        for child_id in children {
            let parent_transform = match scene.nodes.get(&parent_id) {
                Some(n) => n.transform,
                None => continue,
            };

            let child_transform = self.position_transient(child_id, &parent_transform, head_pos);

            if let Some(node) = scene.nodes.get_mut(&child_id) {
                node.transform = child_transform;
            }

            // Recurse into grandchildren.
            self.position_all_children(child_id, scene, head_pos);
        }
    }

    /// Get the number of registered transient relations.
    pub fn relation_count(&self) -> usize {
        self.relations.len()
    }

    /// Generate an IPC s-expression listing all transient relations.
    pub fn to_sexp(&self) -> String {
        let mut s = String::from("(");
        for r in &self.relations {
            s.push_str(&format!(
                "(:child {} :parent {} :placement :{} :z-offset {:.3})",
                r.child_id,
                r.parent_id,
                r.placement.as_str(),
                r.z_offset,
            ));
        }
        s.push(')');
        s
    }
}

// ── Tests ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add_and_get_parent() {
        let mut mgr = TransientChainManager::new();
        mgr.add_transient(10, 1, TransientPlacement::Front).unwrap();
        assert_eq!(mgr.get_parent(10), Some(1));
        assert_eq!(mgr.get_parent(1), None);
        assert_eq!(mgr.relation_count(), 1);
    }

    #[test]
    fn test_get_children() {
        let mut mgr = TransientChainManager::new();
        mgr.add_transient(10, 1, TransientPlacement::Front).unwrap();
        mgr.add_transient(11, 1, TransientPlacement::Above).unwrap();
        mgr.add_transient(12, 1, TransientPlacement::Below).unwrap();
        let children = mgr.get_children(1);
        assert_eq!(children.len(), 3);
        assert!(children.contains(&10));
        assert!(children.contains(&11));
        assert!(children.contains(&12));
    }

    #[test]
    fn test_chain_depth() {
        let mut mgr = TransientChainManager::new();
        mgr.add_transient(2, 1, TransientPlacement::Front).unwrap();
        mgr.add_transient(3, 2, TransientPlacement::Front).unwrap();
        mgr.add_transient(4, 3, TransientPlacement::Front).unwrap();
        assert_eq!(mgr.chain_depth(1), 0);
        assert_eq!(mgr.chain_depth(2), 1);
        assert_eq!(mgr.chain_depth(3), 2);
        assert_eq!(mgr.chain_depth(4), 3);
    }

    #[test]
    fn test_max_depth_rejection() {
        let mut mgr = TransientChainManager::new();
        mgr.max_depth = 3;
        mgr.add_transient(2, 1, TransientPlacement::Front).unwrap();
        mgr.add_transient(3, 2, TransientPlacement::Front).unwrap();
        mgr.add_transient(4, 3, TransientPlacement::Front).unwrap();
        // Depth 4 would exceed max_depth=3.
        let result = mgr.add_transient(5, 4, TransientPlacement::Front);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("exceeds max"));
    }

    #[test]
    fn test_cascade_remove() {
        let mut mgr = TransientChainManager::new();
        mgr.add_transient(2, 1, TransientPlacement::Front).unwrap();
        mgr.add_transient(3, 2, TransientPlacement::Front).unwrap();
        mgr.add_transient(4, 2, TransientPlacement::Above).unwrap();
        mgr.add_transient(5, 3, TransientPlacement::Below).unwrap();
        assert_eq!(mgr.relation_count(), 4);

        // Remove surface 2 — should cascade remove 3, 4, 5.
        mgr.remove_transient(2);
        assert_eq!(mgr.relation_count(), 0);
        assert_eq!(mgr.get_parent(3), None);
        assert_eq!(mgr.get_parent(4), None);
        assert_eq!(mgr.get_parent(5), None);
    }

    #[test]
    fn test_position_front() {
        let mgr = {
            let mut m = TransientChainManager::new();
            m.add_transient(10, 1, TransientPlacement::Front).unwrap();
            m
        };

        let parent = Transform3D::at(0.0, 1.0, -2.0);
        let head = Vec3::new(0.0, 1.0, 0.0);

        let child_t = mgr.position_transient(10, &parent, head);
        // Child should be closer to head (higher Z) than parent.
        assert!(
            child_t.position.z > parent.position.z,
            "child z={} should be > parent z={}",
            child_t.position.z,
            parent.position.z
        );
    }

    #[test]
    fn test_position_above() {
        let mgr = {
            let mut m = TransientChainManager::new();
            m.add_transient(10, 1, TransientPlacement::Above).unwrap();
            m
        };

        let parent = Transform3D::at(0.0, 1.0, -2.0);
        let head = Vec3::ZERO;

        let child_t = mgr.position_transient(10, &parent, head);
        assert!(
            child_t.position.y > parent.position.y,
            "child y={} should be > parent y={}",
            child_t.position.y,
            parent.position.y
        );
    }

    #[test]
    fn test_position_below() {
        let mgr = {
            let mut m = TransientChainManager::new();
            m.add_transient(10, 1, TransientPlacement::Below).unwrap();
            m
        };

        let parent = Transform3D::at(0.0, 1.0, -2.0);
        let head = Vec3::ZERO;

        let child_t = mgr.position_transient(10, &parent, head);
        assert!(
            child_t.position.y < parent.position.y,
            "child y={} should be < parent y={}",
            child_t.position.y,
            parent.position.y
        );
    }

    #[test]
    fn test_self_parent_rejected() {
        let mut mgr = TransientChainManager::new();
        let result = mgr.add_transient(1, 1, TransientPlacement::Front);
        assert!(result.is_err());
    }

    #[test]
    fn test_cycle_detection() {
        let mut mgr = TransientChainManager::new();
        mgr.add_transient(2, 1, TransientPlacement::Front).unwrap();
        mgr.add_transient(3, 2, TransientPlacement::Front).unwrap();
        // Trying to make 1 a child of 3 would create a cycle: 1->2->3->1
        let result = mgr.add_transient(1, 3, TransientPlacement::Front);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("cycle"));
    }

    #[test]
    fn test_to_sexp() {
        let mut mgr = TransientChainManager::new();
        mgr.add_transient(10, 1, TransientPlacement::Front).unwrap();
        mgr.add_transient(11, 1, TransientPlacement::Above).unwrap();
        let sexp = mgr.to_sexp();
        assert!(sexp.contains(":child 10"));
        assert!(sexp.contains(":parent 1"));
        assert!(sexp.contains(":placement :front"));
        assert!(sexp.contains(":placement :above"));
    }

    #[test]
    fn test_placement_roundtrip() {
        let placements = [
            TransientPlacement::Front,
            TransientPlacement::Above,
            TransientPlacement::Below,
            TransientPlacement::Auto,
        ];
        for p in &placements {
            let s = p.as_str();
            let parsed = TransientPlacement::from_str(s);
            assert_eq!(parsed, Some(*p), "roundtrip failed for {:?}", p);
        }
        assert_eq!(TransientPlacement::from_str("bogus"), None);
    }
}
