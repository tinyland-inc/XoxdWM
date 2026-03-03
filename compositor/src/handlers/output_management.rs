//! wlr-output-management-unstable-v1 stub — output configuration protocol.
//!
//! Smithay does not yet provide a built-in wlr-output-management handler.
//! This module provides the state structures and IPC interface so that
//! Emacs can query and configure outputs (position, resolution, scale, etc.)
//! via IPC.  When Smithay gains native support, this module will wrap it.

use std::fmt;

/// Transform applied to an output (rotation/flip).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputTransform {
    Normal,
    Rotate90,
    Rotate180,
    Rotate270,
    Flipped,
    Flipped90,
    Flipped180,
    Flipped270,
}

impl fmt::Display for OutputTransform {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            OutputTransform::Normal => write!(f, "normal"),
            OutputTransform::Rotate90 => write!(f, "90"),
            OutputTransform::Rotate180 => write!(f, "180"),
            OutputTransform::Rotate270 => write!(f, "270"),
            OutputTransform::Flipped => write!(f, "flipped"),
            OutputTransform::Flipped90 => write!(f, "flipped-90"),
            OutputTransform::Flipped180 => write!(f, "flipped-180"),
            OutputTransform::Flipped270 => write!(f, "flipped-270"),
        }
    }
}

impl OutputTransform {
    /// Parse from an IPC string value.
    pub fn from_str_ipc(s: &str) -> Option<Self> {
        match s {
            "normal" => Some(OutputTransform::Normal),
            "90" => Some(OutputTransform::Rotate90),
            "180" => Some(OutputTransform::Rotate180),
            "270" => Some(OutputTransform::Rotate270),
            "flipped" => Some(OutputTransform::Flipped),
            "flipped-90" => Some(OutputTransform::Flipped90),
            "flipped-180" => Some(OutputTransform::Flipped180),
            "flipped-270" => Some(OutputTransform::Flipped270),
            _ => None,
        }
    }
}

impl Default for OutputTransform {
    fn default() -> Self {
        OutputTransform::Normal
    }
}

/// Configuration for a single output.
#[derive(Debug, Clone)]
pub struct OutputConfig {
    /// Connector name (e.g. "HDMI-A-1", "DP-2").
    pub name: String,
    /// Whether this output is enabled.
    pub enabled: bool,
    /// Horizontal position in the global compositor space.
    pub x: i32,
    /// Vertical position in the global compositor space.
    pub y: i32,
    /// Width in pixels.
    pub width: i32,
    /// Height in pixels.
    pub height: i32,
    /// Refresh rate in mHz (e.g. 60000 for 60 Hz).
    pub refresh: i32,
    /// Output scale factor (e.g. 1.0, 2.0).
    pub scale: f64,
    /// Applied transform (rotation/flip).
    pub transform: OutputTransform,
}

impl OutputConfig {
    pub fn new(name: String) -> Self {
        Self {
            name,
            enabled: true,
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            refresh: 60000,
            scale: 1.0,
            transform: OutputTransform::default(),
        }
    }

    /// Format as s-expression for IPC.
    pub fn to_sexp(&self) -> String {
        let enabled = if self.enabled { "t" } else { "nil" };
        format!(
            "(:name \"{}\" :enabled {} :x {} :y {} :width {} :height {} :refresh {} :scale {:.1} :transform \"{}\")",
            self.name, enabled, self.x, self.y,
            self.width, self.height, self.refresh,
            self.scale, self.transform,
        )
    }
}

/// Compositor-side output management state.
#[derive(Debug)]
pub struct OutputManagementState {
    /// Current configurations for all known outputs.
    pub configs: Vec<OutputConfig>,
    /// Configuration serial — incremented on each apply/test.
    pub serial: u32,
}

impl Default for OutputManagementState {
    fn default() -> Self {
        Self {
            configs: Vec::new(),
            serial: 0,
        }
    }
}

impl OutputManagementState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Apply a configuration change.  Returns `Ok(serial)` on success.
    /// In a full implementation this would program the DRM/KMS backend.
    pub fn apply_config(&mut self, config: OutputConfig) -> Result<u32, String> {
        // Validate basic constraints
        if config.width <= 0 || config.height <= 0 {
            return Err("invalid resolution: width and height must be positive".into());
        }
        if config.refresh <= 0 {
            return Err("invalid refresh rate: must be positive".into());
        }
        if config.scale <= 0.0 {
            return Err("invalid scale: must be positive".into());
        }

        self.serial += 1;

        // Update existing config or insert new one.
        if let Some(existing) = self.configs.iter_mut().find(|c| c.name == config.name) {
            *existing = config;
        } else {
            self.configs.push(config);
        }

        Ok(self.serial)
    }

    /// Test a configuration without applying it.  Returns `Ok(serial)` if valid.
    pub fn test_config(&mut self, config: &OutputConfig) -> Result<u32, String> {
        if config.width <= 0 || config.height <= 0 {
            return Err("invalid resolution: width and height must be positive".into());
        }
        if config.refresh <= 0 {
            return Err("invalid refresh rate: must be positive".into());
        }
        if config.scale <= 0.0 {
            return Err("invalid scale: must be positive".into());
        }

        self.serial += 1;
        Ok(self.serial)
    }

    /// Get all current output configurations.
    pub fn get_configurations(&self) -> &[OutputConfig] {
        &self.configs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_config_inserts_new() {
        let mut state = OutputManagementState::new();
        let cfg = OutputConfig::new("HDMI-A-1".into());
        let serial = state.apply_config(cfg).unwrap();
        assert_eq!(serial, 1);
        assert_eq!(state.configs.len(), 1);
        assert_eq!(state.configs[0].name, "HDMI-A-1");
    }

    #[test]
    fn apply_config_updates_existing() {
        let mut state = OutputManagementState::new();
        state
            .apply_config(OutputConfig::new("DP-1".into()))
            .unwrap();

        let mut updated = OutputConfig::new("DP-1".into());
        updated.width = 2560;
        updated.height = 1440;
        state.apply_config(updated).unwrap();

        assert_eq!(state.configs.len(), 1);
        assert_eq!(state.configs[0].width, 2560);
    }

    #[test]
    fn apply_config_rejects_invalid_resolution() {
        let mut state = OutputManagementState::new();
        let mut cfg = OutputConfig::new("out".into());
        cfg.width = -1;
        assert!(state.apply_config(cfg).is_err());
    }

    #[test]
    fn test_config_does_not_insert() {
        let mut state = OutputManagementState::new();
        let cfg = OutputConfig::new("DP-2".into());
        state.test_config(&cfg).unwrap();
        assert_eq!(state.configs.len(), 0);
    }

    #[test]
    fn test_config_rejects_invalid() {
        let mut state = OutputManagementState::new();
        let mut cfg = OutputConfig::new("out".into());
        cfg.scale = -1.0;
        assert!(state.test_config(&cfg).is_err());
    }

    #[test]
    fn serial_increments() {
        let mut state = OutputManagementState::new();
        let s1 = state.apply_config(OutputConfig::new("a".into())).unwrap();
        let s2 = state.apply_config(OutputConfig::new("b".into())).unwrap();
        assert_eq!(s2, s1 + 1);
    }

    #[test]
    fn output_transform_roundtrip() {
        for t in [
            OutputTransform::Normal,
            OutputTransform::Rotate90,
            OutputTransform::Rotate180,
            OutputTransform::Rotate270,
            OutputTransform::Flipped,
            OutputTransform::Flipped90,
            OutputTransform::Flipped180,
            OutputTransform::Flipped270,
        ] {
            let s = t.to_string();
            assert_eq!(OutputTransform::from_str_ipc(&s), Some(t));
        }
    }

    #[test]
    fn output_config_to_sexp() {
        let cfg = OutputConfig::new("HDMI-A-1".into());
        let sexp = cfg.to_sexp();
        assert!(sexp.contains(":name \"HDMI-A-1\""));
        assert!(sexp.contains(":enabled t"));
        assert!(sexp.contains(":width 1920"));
    }
}
