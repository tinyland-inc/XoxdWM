//! DPMS (Display Power Management Signaling) — output power control.
//!
//! Smithay does not have a built-in DPMS protocol.  DPMS is controlled
//! by the compositor setting the DRM output power state directly.
//! This module provides the state tracking and IPC interface;
//! actual power control is wired when the DRM backend is active.

use std::fmt;

/// Display power management state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DpmsState {
    On,
    Standby,
    Suspend,
    Off,
}

impl fmt::Display for DpmsState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DpmsState::On => write!(f, "on"),
            DpmsState::Standby => write!(f, "standby"),
            DpmsState::Suspend => write!(f, "suspend"),
            DpmsState::Off => write!(f, "off"),
        }
    }
}

impl DpmsState {
    /// Parse from an IPC string value.
    pub fn from_str_ipc(s: &str) -> Option<Self> {
        match s {
            "on" => Some(DpmsState::On),
            "standby" => Some(DpmsState::Standby),
            "suspend" => Some(DpmsState::Suspend),
            "off" => Some(DpmsState::Off),
            _ => None,
        }
    }
}

impl Default for DpmsState {
    fn default() -> Self {
        DpmsState::On
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dpms_state_roundtrip() {
        for state in [DpmsState::On, DpmsState::Standby, DpmsState::Suspend, DpmsState::Off] {
            let s = state.to_string();
            assert_eq!(DpmsState::from_str_ipc(&s), Some(state));
        }
    }

    #[test]
    fn dpms_state_default_is_on() {
        assert_eq!(DpmsState::default(), DpmsState::On);
    }

    #[test]
    fn dpms_state_unknown_returns_none() {
        assert_eq!(DpmsState::from_str_ipc("unknown"), None);
    }
}
