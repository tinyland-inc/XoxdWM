//! Screen capture visibility control — per-surface screencopy inclusion/exclusion.
//!
//! Allows surfaces to be excluded from screen capture or marked as
//! sensitive (redacted in captures).  This is important for privacy:
//! credential windows, private messages, etc. should not appear in
//! screenshots or screen shares by default.

use std::collections::HashMap;
use tracing::{debug, info};

// ── Types ────────────────────────────────────────────────────

/// Visibility of a surface in screen captures.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CaptureVisibility {
    /// Surface is included in screen captures normally.
    Visible,
    /// Surface is completely excluded from screen captures.
    Hidden,
    /// Surface is included but content is redacted (solid fill).
    Sensitive,
}

impl CaptureVisibility {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Visible => "visible",
            Self::Hidden => "hidden",
            Self::Sensitive => "sensitive",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "visible" => Some(Self::Visible),
            "hidden" => Some(Self::Hidden),
            "sensitive" => Some(Self::Sensitive),
            _ => None,
        }
    }
}

impl Default for CaptureVisibility {
    fn default() -> Self {
        Self::Visible
    }
}

/// Manages per-surface capture visibility overrides.
pub struct CaptureVisibilityManager {
    /// Per-surface visibility overrides.
    overrides: HashMap<u64, CaptureVisibility>,
    /// Default visibility for surfaces not in the override map.
    pub default_visibility: CaptureVisibility,
}

// ── Implementation ───────────────────────────────────────────

impl CaptureVisibilityManager {
    pub fn new() -> Self {
        Self {
            overrides: HashMap::new(),
            default_visibility: CaptureVisibility::Visible,
        }
    }

    /// Set the capture visibility for a specific surface.
    pub fn set_visibility(&mut self, surface_id: u64, visibility: CaptureVisibility) {
        info!(
            "capture-visibility: surface {} -> {}",
            surface_id,
            visibility.as_str()
        );
        self.overrides.insert(surface_id, visibility);
    }

    /// Get the effective capture visibility for a surface.
    pub fn get_visibility(&self, surface_id: u64) -> CaptureVisibility {
        self.overrides
            .get(&surface_id)
            .copied()
            .unwrap_or(self.default_visibility)
    }

    /// Whether a surface should be included in screen captures.
    /// Returns `true` only for `Visible` surfaces.
    pub fn is_capturable(&self, surface_id: u64) -> bool {
        self.get_visibility(surface_id) == CaptureVisibility::Visible
    }

    /// Remove all per-surface overrides, reverting to the default.
    pub fn clear_overrides(&mut self) {
        let count = self.overrides.len();
        self.overrides.clear();
        debug!("capture-visibility: cleared {} overrides", count);
    }

    /// Number of active overrides.
    pub fn override_count(&self) -> usize {
        self.overrides.len()
    }

    /// Generate IPC s-expression describing the capture visibility state.
    pub fn to_sexp(&self) -> String {
        let overrides_sexp: Vec<String> = self
            .overrides
            .iter()
            .map(|(id, vis)| format!("(:surface {} :visibility :{})", id, vis.as_str()))
            .collect();

        format!(
            "(:default :{} :override-count {} :overrides ({}))",
            self.default_visibility.as_str(),
            self.overrides.len(),
            overrides_sexp.join(" "),
        )
    }
}

// ── Tests ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_visible() {
        let mgr = CaptureVisibilityManager::new();
        assert_eq!(mgr.get_visibility(1), CaptureVisibility::Visible);
        assert!(mgr.is_capturable(1));
        assert_eq!(mgr.override_count(), 0);
    }

    #[test]
    fn test_override_hidden() {
        let mut mgr = CaptureVisibilityManager::new();
        mgr.set_visibility(42, CaptureVisibility::Hidden);

        assert_eq!(mgr.get_visibility(42), CaptureVisibility::Hidden);
        assert!(!mgr.is_capturable(42));

        // Other surfaces remain at default.
        assert_eq!(mgr.get_visibility(99), CaptureVisibility::Visible);
        assert!(mgr.is_capturable(99));
    }

    #[test]
    fn test_override_sensitive() {
        let mut mgr = CaptureVisibilityManager::new();
        mgr.set_visibility(10, CaptureVisibility::Sensitive);

        assert_eq!(mgr.get_visibility(10), CaptureVisibility::Sensitive);
        assert!(!mgr.is_capturable(10));
    }

    #[test]
    fn test_clear_overrides() {
        let mut mgr = CaptureVisibilityManager::new();
        mgr.set_visibility(1, CaptureVisibility::Hidden);
        mgr.set_visibility(2, CaptureVisibility::Sensitive);
        assert_eq!(mgr.override_count(), 2);

        mgr.clear_overrides();
        assert_eq!(mgr.override_count(), 0);
        assert_eq!(mgr.get_visibility(1), CaptureVisibility::Visible);
        assert_eq!(mgr.get_visibility(2), CaptureVisibility::Visible);
    }

    #[test]
    fn test_visibility_roundtrip() {
        let variants = [
            CaptureVisibility::Visible,
            CaptureVisibility::Hidden,
            CaptureVisibility::Sensitive,
        ];
        for v in &variants {
            let s = v.as_str();
            let parsed = CaptureVisibility::from_str(s);
            assert_eq!(parsed, Some(*v), "roundtrip failed for {:?}", v);
        }
        assert_eq!(CaptureVisibility::from_str("bogus"), None);
    }

    #[test]
    fn test_to_sexp_format() {
        let mut mgr = CaptureVisibilityManager::new();
        mgr.set_visibility(5, CaptureVisibility::Hidden);
        let sexp = mgr.to_sexp();
        assert!(sexp.contains(":default :visible"));
        assert!(sexp.contains(":override-count 1"));
        assert!(sexp.contains(":surface 5"));
        assert!(sexp.contains(":visibility :hidden"));
    }
}
