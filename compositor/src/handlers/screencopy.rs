//! wlr-screencopy-unstable-v1 stub — output capture protocol.
//!
//! Provides the state structures and IPC interface for screencopy.
//! Full implementation requires the `wayland-protocols-wlr` crate
//! and wiring into the renderer's output damage tracking.
//! This module provides the compositor-side bookkeeping so that
//! IPC clients (Emacs) can query and cancel screencopy operations.

use std::fmt;

/// A single in-flight screencopy frame capture.
#[derive(Debug, Clone)]
pub struct ScreencopyFrame {
    /// Which output is being captured.
    pub output_name: String,
    /// Whether the client requested damage-tracking (incremental) mode.
    pub damage_tracking: bool,
    /// Monotonic frame ID (assigned by ScreencopyState).
    pub frame_id: u64,
}

impl fmt::Display for ScreencopyFrame {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "(frame-id {} output \"{}\" damage-tracking {})",
            self.frame_id,
            self.output_name,
            if self.damage_tracking { "t" } else { "nil" },
        )
    }
}

/// Compositor-side screencopy state.
#[derive(Debug)]
pub struct ScreencopyState {
    /// Currently active (in-flight) frame captures.
    pub active_frames: Vec<ScreencopyFrame>,
    /// Monotonically increasing frame counter for ID assignment.
    pub frame_counter: u64,
}

impl Default for ScreencopyState {
    fn default() -> Self {
        Self {
            active_frames: Vec::new(),
            frame_counter: 0,
        }
    }
}

impl ScreencopyState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Start a new screencopy frame capture.  Returns the assigned frame ID.
    pub fn start_copy(&mut self, output_name: String, damage_tracking: bool) -> u64 {
        self.frame_counter += 1;
        let frame = ScreencopyFrame {
            output_name,
            damage_tracking,
            frame_id: self.frame_counter,
        };
        self.active_frames.push(frame);
        self.frame_counter
    }

    /// Cancel (or mark completed) an in-flight frame by ID.
    /// Returns `true` if the frame was found and removed.
    pub fn cancel_copy(&mut self, frame_id: u64) -> bool {
        let before = self.active_frames.len();
        self.active_frames.retain(|f| f.frame_id != frame_id);
        self.active_frames.len() < before
    }

    /// Number of currently active frame captures.
    pub fn get_active_count(&self) -> usize {
        self.active_frames.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn start_and_cancel_copy() {
        let mut state = ScreencopyState::new();
        let id1 = state.start_copy("HDMI-A-1".into(), false);
        let id2 = state.start_copy("DP-1".into(), true);
        assert_eq!(state.get_active_count(), 2);

        assert!(state.cancel_copy(id1));
        assert_eq!(state.get_active_count(), 1);
        assert_eq!(state.active_frames[0].frame_id, id2);
    }

    #[test]
    fn cancel_nonexistent_returns_false() {
        let mut state = ScreencopyState::new();
        assert!(!state.cancel_copy(999));
    }

    #[test]
    fn frame_counter_monotonic() {
        let mut state = ScreencopyState::new();
        let id1 = state.start_copy("out".into(), false);
        let id2 = state.start_copy("out".into(), false);
        assert!(id2 > id1);
    }

    #[test]
    fn frame_display() {
        let frame = ScreencopyFrame {
            output_name: "HDMI-A-1".into(),
            damage_tracking: true,
            frame_id: 42,
        };
        let s = frame.to_string();
        assert!(s.contains("frame-id 42"));
        assert!(s.contains("HDMI-A-1"));
        assert!(s.contains("damage-tracking t"));
    }
}
