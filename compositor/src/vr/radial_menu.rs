//! VR radial menu — gesture-triggered circular command palette.
//!
//! A radial menu appears at a world-space position (typically anchored to a
//! hand controller) and presents a ring of selectable items.  The user moves
//! a pointer (hand ray or gaze) to highlight a slice, then confirms the
//! selection.  The menu transitions through states: Hidden -> Opening ->
//! Open -> Closing -> Hidden.

use std::f32::consts::PI;
use tracing::{debug, info};

use super::scene::Vec3;

// ── Types ────────────────────────────────────────────────────

/// Radial menu visibility/animation state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RadialMenuState {
    /// Menu is not visible.
    Hidden,
    /// Opening animation in progress.
    Opening,
    /// Menu is fully open and interactive.
    Open,
    /// Closing animation in progress.
    Closing,
}

impl RadialMenuState {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Hidden => "hidden",
            Self::Opening => "opening",
            Self::Open => "open",
            Self::Closing => "closing",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "hidden" => Some(Self::Hidden),
            "opening" => Some(Self::Opening),
            "open" => Some(Self::Open),
            "closing" => Some(Self::Closing),
            _ => None,
        }
    }
}

/// A single item (slice) in the radial menu.
#[derive(Debug, Clone)]
pub struct RadialMenuItem {
    /// Unique identifier, e.g. "workspace-1", "mute-toggle".
    pub id: String,
    /// Human-readable label.
    pub label: String,
    /// Optional icon name.
    pub icon: Option<String>,
    /// Start angle of this slice in degrees (0 = up, clockwise).
    pub angle_start: f32,
    /// End angle of this slice in degrees.
    pub angle_end: f32,
}

/// A VR radial (pie) menu.
pub struct RadialMenu {
    pub state: RadialMenuState,
    pub items: Vec<RadialMenuItem>,
    pub selected_index: Option<usize>,
    /// World-space center position of the menu.
    pub center: Vec3,
    /// Outer radius of the menu ring in meters.
    pub radius: f32,
    /// Inner dead-zone radius in meters (selections below this are ignored).
    pub inner_radius: f32,
    /// Animation progress (0.0 = start, 1.0 = complete).
    animation_progress: f32,
}

// ── Implementation ───────────────────────────────────────────

impl RadialMenu {
    pub fn new() -> Self {
        Self {
            state: RadialMenuState::Hidden,
            items: Vec::new(),
            selected_index: None,
            center: Vec3::ZERO,
            radius: 0.3,
            inner_radius: 0.05,
            animation_progress: 0.0,
        }
    }

    /// Start the opening animation at `center`.
    pub fn open(&mut self, center: Vec3) {
        self.center = center;
        self.state = RadialMenuState::Opening;
        self.animation_progress = 0.0;
        self.selected_index = None;
        info!("radial-menu: opening at ({:.2}, {:.2}, {:.2})", center.x, center.y, center.z);
    }

    /// Start the closing animation.
    pub fn close(&mut self) {
        if self.state == RadialMenuState::Hidden {
            return;
        }
        self.state = RadialMenuState::Closing;
        self.animation_progress = 1.0;
        self.selected_index = None;
        debug!("radial-menu: closing");
    }

    /// Toggle the menu open/closed at `center`.
    pub fn toggle(&mut self, center: Vec3) {
        match self.state {
            RadialMenuState::Hidden | RadialMenuState::Closing => self.open(center),
            RadialMenuState::Open | RadialMenuState::Opening => self.close(),
        }
    }

    /// Advance the animation by `dt` seconds.  Transitions Opening -> Open
    /// and Closing -> Hidden when the animation completes.
    pub fn tick(&mut self, dt: f32) {
        let speed = 4.0; // Complete in ~0.25s
        match self.state {
            RadialMenuState::Opening => {
                self.animation_progress += dt * speed;
                if self.animation_progress >= 1.0 {
                    self.animation_progress = 1.0;
                    self.state = RadialMenuState::Open;
                }
            }
            RadialMenuState::Closing => {
                self.animation_progress -= dt * speed;
                if self.animation_progress <= 0.0 {
                    self.animation_progress = 0.0;
                    self.state = RadialMenuState::Hidden;
                }
            }
            _ => {}
        }
    }

    /// Update the highlighted item based on pointer position.
    ///
    /// The pointer position is projected onto the menu plane.  If the
    /// pointer is within the inner dead zone, no item is selected.
    /// Returns the currently highlighted item (if any).
    pub fn update_selection(&mut self, pointer_pos: Vec3) -> Option<&RadialMenuItem> {
        if self.items.is_empty() || self.state == RadialMenuState::Hidden {
            self.selected_index = None;
            return None;
        }

        // Compute offset from center in the menu plane (XY).
        let dx = pointer_pos.x - self.center.x;
        let dy = pointer_pos.y - self.center.y;
        let dist = (dx * dx + dy * dy).sqrt();

        // Inside dead zone — no selection.
        if dist < self.inner_radius {
            self.selected_index = None;
            return None;
        }

        // Compute angle in degrees (0 = up/+Y, clockwise).
        // atan2(dx, dy) gives angle from +Y toward +X.
        let angle_rad = dx.atan2(dy);
        let mut angle_deg = angle_rad * (180.0 / PI);
        if angle_deg < 0.0 {
            angle_deg += 360.0;
        }

        // Find which slice contains this angle.
        for (i, item) in self.items.iter().enumerate() {
            if angle_in_slice(angle_deg, item.angle_start, item.angle_end) {
                self.selected_index = Some(i);
                return Some(item);
            }
        }

        self.selected_index = None;
        None
    }

    /// Confirm the current selection.  Returns the selected item's ID and
    /// closes the menu.  Returns `None` if nothing is selected.
    pub fn confirm_selection(&mut self) -> Option<String> {
        let idx = self.selected_index?;
        let id = self.items.get(idx)?.id.clone();
        info!("radial-menu: confirmed item \"{}\"", id);
        self.close();
        Some(id)
    }

    /// Add an item to the menu and recompute slice angles.
    pub fn add_item(&mut self, id: &str, label: &str, icon: Option<&str>) {
        self.items.push(RadialMenuItem {
            id: id.to_string(),
            label: label.to_string(),
            icon: icon.map(|s| s.to_string()),
            angle_start: 0.0,
            angle_end: 0.0,
        });
        self.recompute_angles();
        debug!("radial-menu: added item \"{}\" (total: {})", id, self.items.len());
    }

    /// Remove an item by ID and recompute slice angles.
    /// Returns `true` if the item was found and removed.
    pub fn remove_item(&mut self, id: &str) -> bool {
        let before = self.items.len();
        self.items.retain(|item| item.id != id);
        let removed = self.items.len() < before;
        if removed {
            self.recompute_angles();
            // Clear selection if it pointed at a removed item.
            if let Some(idx) = self.selected_index {
                if idx >= self.items.len() {
                    self.selected_index = None;
                }
            }
        }
        removed
    }

    /// Bulk-set all items from `(id, label)` pairs.  Replaces existing items.
    pub fn set_items(&mut self, items: Vec<(String, String)>) {
        self.items = items
            .into_iter()
            .map(|(id, label)| RadialMenuItem {
                id,
                label,
                icon: None,
                angle_start: 0.0,
                angle_end: 0.0,
            })
            .collect();
        self.recompute_angles();
        self.selected_index = None;
        debug!("radial-menu: set {} items", self.items.len());
    }

    /// Whether the menu is visible (not `Hidden`).
    pub fn is_visible(&self) -> bool {
        self.state != RadialMenuState::Hidden
    }

    /// Generate IPC s-expression describing the menu state.
    pub fn to_sexp(&self) -> String {
        let items_sexp: Vec<String> = self
            .items
            .iter()
            .map(|item| {
                let icon_str = match &item.icon {
                    Some(name) => format!("\"{}\"", name),
                    None => "nil".to_string(),
                };
                format!(
                    "(:id \"{}\" :label \"{}\" :icon {} :angle-start {:.1} :angle-end {:.1})",
                    item.id, item.label, icon_str, item.angle_start, item.angle_end,
                )
            })
            .collect();

        format!(
            "(:state :{} :selected {} :center (:x {:.3} :y {:.3} :z {:.3}) :radius {:.3} :inner-radius {:.3} :animation {:.2} :items ({}))",
            self.state.as_str(),
            match self.selected_index {
                Some(i) => format!("{}", i),
                None => "nil".to_string(),
            },
            self.center.x,
            self.center.y,
            self.center.z,
            self.radius,
            self.inner_radius,
            self.animation_progress,
            items_sexp.join(" "),
        )
    }

    // ── Internal ─────────────────────────────────────────────

    /// Recompute slice angles so all items span equal portions of 360 degrees.
    fn recompute_angles(&mut self) {
        let n = self.items.len();
        if n == 0 {
            return;
        }
        let slice = 360.0 / n as f32;
        for (i, item) in self.items.iter_mut().enumerate() {
            item.angle_start = i as f32 * slice;
            item.angle_end = (i + 1) as f32 * slice;
        }
    }
}

// ── Helpers ──────────────────────────────────────────────────

/// Check whether `angle` falls within the slice `[start, end)`.
/// All values in degrees, wrapping at 360.
fn angle_in_slice(angle: f32, start: f32, end: f32) -> bool {
    if start < end {
        angle >= start && angle < end
    } else {
        // Wraps around 0/360 boundary.
        angle >= start || angle < end
    }
}

// ── Tests ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add_items_recomputes_angles() {
        let mut menu = RadialMenu::new();
        menu.add_item("a", "Alpha", None);
        menu.add_item("b", "Beta", None);
        menu.add_item("c", "Charlie", None);

        assert_eq!(menu.items.len(), 3);
        let eps = 0.1;
        // Each should span 120 degrees.
        assert!((menu.items[0].angle_start - 0.0).abs() < eps);
        assert!((menu.items[0].angle_end - 120.0).abs() < eps);
        assert!((menu.items[1].angle_start - 120.0).abs() < eps);
        assert!((menu.items[1].angle_end - 240.0).abs() < eps);
        assert!((menu.items[2].angle_start - 240.0).abs() < eps);
        assert!((menu.items[2].angle_end - 360.0).abs() < eps);
    }

    #[test]
    fn test_remove_recomputes_angles() {
        let mut menu = RadialMenu::new();
        menu.add_item("a", "A", None);
        menu.add_item("b", "B", None);
        menu.add_item("c", "C", None);
        menu.add_item("d", "D", None);

        assert!(menu.remove_item("b"));
        assert_eq!(menu.items.len(), 3);
        // After removal, each slice should be 120 degrees.
        let eps = 0.1;
        assert!((menu.items[0].angle_end - 120.0).abs() < eps);
        assert!((menu.items[1].angle_end - 240.0).abs() < eps);
        assert!((menu.items[2].angle_end - 360.0).abs() < eps);

        // Removing nonexistent returns false.
        assert!(!menu.remove_item("nonexistent"));
    }

    #[test]
    fn test_selection_by_angle() {
        let mut menu = RadialMenu::new();
        menu.add_item("up", "Up", None);
        menu.add_item("right", "Right", None);
        menu.add_item("down", "Down", None);
        menu.add_item("left", "Left", None);
        // Slices: up=[0,90), right=[90,180), down=[180,270), left=[270,360)

        menu.open(Vec3::ZERO);
        menu.state = RadialMenuState::Open;

        // Pointer straight up (+Y direction): angle = 0 degrees => "up"
        let result = menu.update_selection(Vec3::new(0.0, 0.2, 0.0));
        assert_eq!(result.unwrap().id, "up");

        // Pointer to the right (+X direction): angle = 90 degrees => "right"
        let result = menu.update_selection(Vec3::new(0.2, 0.0, 0.0));
        assert_eq!(result.unwrap().id, "right");

        // Pointer straight down (-Y direction): angle = 180 degrees => "down"
        let result = menu.update_selection(Vec3::new(0.0, -0.2, 0.0));
        assert_eq!(result.unwrap().id, "down");

        // Pointer to the left (-X direction): angle = 270 degrees => "left"
        let result = menu.update_selection(Vec3::new(-0.2, 0.0, 0.0));
        assert_eq!(result.unwrap().id, "left");
    }

    #[test]
    fn test_dead_zone() {
        let mut menu = RadialMenu::new();
        menu.add_item("a", "A", None);
        menu.open(Vec3::ZERO);
        menu.state = RadialMenuState::Open;

        // Pointer within the inner dead zone — should select nothing.
        let result = menu.update_selection(Vec3::new(0.01, 0.01, 0.0));
        assert!(result.is_none());
        assert!(menu.selected_index.is_none());
    }

    #[test]
    fn test_toggle_state() {
        let mut menu = RadialMenu::new();
        assert_eq!(menu.state, RadialMenuState::Hidden);

        menu.toggle(Vec3::ZERO);
        assert_eq!(menu.state, RadialMenuState::Opening);

        // Force to Open to test toggle back.
        menu.state = RadialMenuState::Open;
        menu.toggle(Vec3::ZERO);
        assert_eq!(menu.state, RadialMenuState::Closing);
    }

    #[test]
    fn test_confirm_returns_id_and_closes() {
        let mut menu = RadialMenu::new();
        menu.add_item("action-1", "Action 1", None);
        menu.add_item("action-2", "Action 2", None);
        menu.open(Vec3::ZERO);
        menu.state = RadialMenuState::Open;

        // Select item 1 (angle ~90 = right of center, [180,360) = item 1).
        menu.selected_index = Some(1);
        let result = menu.confirm_selection();
        assert_eq!(result, Some("action-2".to_string()));
        // Menu should be closing after confirmation.
        assert_eq!(menu.state, RadialMenuState::Closing);
    }

    #[test]
    fn test_confirm_none_when_nothing_selected() {
        let mut menu = RadialMenu::new();
        menu.add_item("x", "X", None);
        menu.open(Vec3::ZERO);
        menu.state = RadialMenuState::Open;

        let result = menu.confirm_selection();
        assert!(result.is_none());
        // State should remain Open since nothing was confirmed.
        assert_eq!(menu.state, RadialMenuState::Open);
    }

    #[test]
    fn test_empty_menu_selection() {
        let mut menu = RadialMenu::new();
        menu.open(Vec3::ZERO);
        menu.state = RadialMenuState::Open;

        let result = menu.update_selection(Vec3::new(0.2, 0.0, 0.0));
        assert!(result.is_none());
    }

    #[test]
    fn test_set_items_bulk() {
        let mut menu = RadialMenu::new();
        menu.set_items(vec![
            ("ws-1".into(), "Workspace 1".into()),
            ("ws-2".into(), "Workspace 2".into()),
        ]);

        assert_eq!(menu.items.len(), 2);
        assert_eq!(menu.items[0].id, "ws-1");
        assert_eq!(menu.items[1].id, "ws-2");
        let eps = 0.1;
        assert!((menu.items[0].angle_end - 180.0).abs() < eps);
        assert!((menu.items[1].angle_end - 360.0).abs() < eps);
    }

    #[test]
    fn test_tick_animation() {
        let mut menu = RadialMenu::new();
        menu.open(Vec3::ZERO);
        assert_eq!(menu.state, RadialMenuState::Opening);

        // Tick enough to complete the animation (speed=4.0, so 0.25s total).
        menu.tick(0.3);
        assert_eq!(menu.state, RadialMenuState::Open);

        menu.close();
        assert_eq!(menu.state, RadialMenuState::Closing);

        menu.tick(0.3);
        assert_eq!(menu.state, RadialMenuState::Hidden);
    }

    #[test]
    fn test_to_sexp_format() {
        let mut menu = RadialMenu::new();
        menu.add_item("test", "Test Item", Some("icon-test"));
        let sexp = menu.to_sexp();
        assert!(sexp.contains(":state :hidden"));
        assert!(sexp.contains(":id \"test\""));
        assert!(sexp.contains(":label \"Test Item\""));
        assert!(sexp.contains(":icon \"icon-test\""));
        assert!(sexp.contains(":radius 0.300"));
    }
}
