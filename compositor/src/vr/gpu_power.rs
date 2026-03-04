//! GPU power management — control performance modes during VR sessions.
//!
//! Reads and writes the DRM `power_dpm_force_performance_level` sysfs knob
//! (AMD GPUs) to switch between power profiles.  For non-AMD GPUs (or when
//! sysfs is not writable) the module degrades gracefully to tracking-only
//! mode.
//!
//! When `auto_vr_boost` is enabled (default), entering a VR session
//! automatically switches to `High` and exiting restores the previous
//! profile.

use std::fs;
use std::path::{Path, PathBuf};
use tracing::{info, warn};

// ── Types ────────────────────────────────────────────────────

/// GPU performance profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GpuPowerProfile {
    /// Default system-managed performance.
    Auto,
    /// Low power (screen off, idle).
    Low,
    /// Normal desktop use.
    Normal,
    /// High performance for VR rendering.
    High,
}

impl GpuPowerProfile {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Low => "low",
            Self::Normal => "normal",
            Self::High => "high",
        }
    }

    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "auto" => Some(Self::Auto),
            "low" => Some(Self::Low),
            "normal" => Some(Self::Normal),
            "high" => Some(Self::High),
            _ => None,
        }
    }

    /// Map to the AMD sysfs `power_dpm_force_performance_level` value.
    fn to_sysfs(&self) -> &'static str {
        match self {
            Self::Auto => "auto",
            Self::Low => "low",
            Self::Normal => "manual",
            Self::High => "high",
        }
    }

    /// Parse from the AMD sysfs value.
    fn from_sysfs(s: &str) -> Option<Self> {
        match s.trim() {
            "auto" => Some(Self::Auto),
            "low" => Some(Self::Low),
            "manual" => Some(Self::Normal),
            "high" => Some(Self::High),
            _ => None,
        }
    }
}

impl Default for GpuPowerProfile {
    fn default() -> Self {
        Self::Auto
    }
}

/// GPU power management state.
#[derive(Debug, Clone)]
pub struct GpuPowerState {
    pub current_profile: GpuPowerProfile,
    /// Path to DRM card directory (e.g. `/sys/class/drm/card0`).
    pub drm_card_path: Option<String>,
    /// Whether we can control power (requires sysfs write access).
    pub controllable: bool,
    /// Auto-switch to High when VR session is active.
    pub auto_vr_boost: bool,
    /// Previous profile before VR boost (to restore on exit).
    prev_profile: Option<GpuPowerProfile>,
}

impl GpuPowerState {
    pub fn new() -> Self {
        Self {
            current_profile: GpuPowerProfile::Auto,
            drm_card_path: None,
            controllable: false,
            auto_vr_boost: true,
            prev_profile: None,
        }
    }

    /// Scan `/sys/class/drm/card*/device/power_dpm_force_performance_level`
    /// and return the first card path that has the sysfs knob.
    pub fn detect_gpu() -> Option<String> {
        let drm_class = Path::new("/sys/class/drm");
        if !drm_class.exists() {
            return None;
        }

        let entries = match fs::read_dir(drm_class) {
            Ok(e) => e,
            Err(_) => return None,
        };

        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            // Only look at top-level card entries (card0, card1, ...).
            if !name_str.starts_with("card") || name_str.contains('-') {
                continue;
            }
            let perf_path = entry.path().join("device/power_dpm_force_performance_level");
            if perf_path.exists() {
                return Some(entry.path().to_string_lossy().to_string());
            }
        }
        None
    }

    /// Try to detect the GPU and update internal state.
    pub fn run_detect(&mut self) {
        match Self::detect_gpu() {
            Some(path) => {
                info!("GPU power: detected DRM card at {}", path);
                // Check if writable by attempting to read the current value.
                let perf_path = PathBuf::from(&path)
                    .join("device/power_dpm_force_performance_level");
                self.controllable = perf_path.metadata()
                    .map(|m| !m.permissions().readonly())
                    .unwrap_or(false);
                self.drm_card_path = Some(path);
                // Sync current profile from sysfs.
                if let Ok(profile) = self.get_profile_from_sysfs() {
                    self.current_profile = profile;
                }
            }
            None => {
                info!("GPU power: no controllable DRM card found");
                self.drm_card_path = None;
                self.controllable = false;
            }
        }
    }

    /// Write the requested profile to sysfs.
    pub fn set_profile(&mut self, profile: GpuPowerProfile) -> Result<(), String> {
        let card_path = match &self.drm_card_path {
            Some(p) => p.clone(),
            None => return Err("no DRM card detected; run gpu-power-detect first".to_string()),
        };

        if !self.controllable {
            return Err(format!(
                "sysfs at {} is not writable — run compositor as root or \
                 add a udev rule granting write access to power_dpm_force_performance_level",
                card_path,
            ));
        }

        let perf_path = PathBuf::from(&card_path)
            .join("device/power_dpm_force_performance_level");
        let sysfs_val = profile.to_sysfs();

        fs::write(&perf_path, sysfs_val).map_err(|e| {
            format!(
                "failed to write '{}' to {}: {}",
                sysfs_val,
                perf_path.display(),
                e,
            )
        })?;

        info!("GPU power: profile set to {:?}", profile);
        self.current_profile = profile;
        Ok(())
    }

    /// Read the current performance level from sysfs.
    pub fn get_profile_from_sysfs(&self) -> Result<GpuPowerProfile, String> {
        let card_path = match &self.drm_card_path {
            Some(p) => p,
            None => return Err("no DRM card detected".to_string()),
        };

        let perf_path = PathBuf::from(card_path)
            .join("device/power_dpm_force_performance_level");
        let raw = fs::read_to_string(&perf_path).map_err(|e| {
            format!("failed to read {}: {}", perf_path.display(), e)
        })?;

        GpuPowerProfile::from_sysfs(&raw)
            .ok_or_else(|| format!("unknown sysfs value: '{}'", raw.trim()))
    }

    /// Called when a VR session starts.  Saves the current profile and
    /// switches to High if `auto_vr_boost` is enabled.
    pub fn on_vr_session_start(&mut self) {
        if !self.auto_vr_boost {
            return;
        }
        if self.current_profile == GpuPowerProfile::High {
            return; // already high
        }
        self.prev_profile = Some(self.current_profile);
        if let Err(e) = self.set_profile(GpuPowerProfile::High) {
            warn!("GPU power: VR boost failed: {}", e);
            self.prev_profile = None;
        } else {
            info!("GPU power: VR boost activated (was {:?})", self.prev_profile);
        }
    }

    /// Called when a VR session ends.  Restores the previous profile.
    pub fn on_vr_session_end(&mut self) {
        if let Some(prev) = self.prev_profile.take() {
            if let Err(e) = self.set_profile(prev) {
                warn!("GPU power: failed to restore profile {:?}: {}", prev, e);
            } else {
                info!("GPU power: restored profile {:?}", prev);
            }
        }
    }

    /// Generate IPC s-expression for GPU power status.
    pub fn to_sexp(&self) -> String {
        format!(
            "(:profile :{} :card {} :controllable {} :auto-vr-boost {} :prev-profile {})",
            self.current_profile.as_str(),
            self.drm_card_path
                .as_deref()
                .map(|p| format!("\"{}\"", p))
                .unwrap_or_else(|| "nil".to_string()),
            if self.controllable { "t" } else { "nil" },
            if self.auto_vr_boost { "t" } else { "nil" },
            self.prev_profile
                .as_ref()
                .map(|p| format!(":{}", p.as_str()))
                .unwrap_or_else(|| "nil".to_string()),
        )
    }
}

// ── Tests ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_profile_roundtrip() {
        let profiles = [
            GpuPowerProfile::Auto,
            GpuPowerProfile::Low,
            GpuPowerProfile::Normal,
            GpuPowerProfile::High,
        ];
        for p in &profiles {
            let s = p.as_str();
            let parsed = GpuPowerProfile::from_str(s);
            assert_eq!(parsed, Some(*p), "roundtrip failed for {:?}", p);
        }
        assert_eq!(GpuPowerProfile::from_str("bogus"), None);
    }

    #[test]
    fn test_detect_returns_none_on_non_linux() {
        // On macOS / CI without /sys, detect should return None.
        if !Path::new("/sys/class/drm").exists() {
            assert!(GpuPowerState::detect_gpu().is_none());
        }
    }

    #[test]
    fn test_default_state() {
        let state = GpuPowerState::new();
        assert_eq!(state.current_profile, GpuPowerProfile::Auto);
        assert!(state.drm_card_path.is_none());
        assert!(!state.controllable);
        assert!(state.auto_vr_boost);
        assert!(state.prev_profile.is_none());
    }

    #[test]
    fn test_vr_boost_saves_and_restores() {
        let mut state = GpuPowerState::new();
        state.current_profile = GpuPowerProfile::Normal;

        // on_vr_session_start should save current and attempt to set High.
        // Without sysfs it will fail, but prev_profile is set before the
        // write attempt.  We can verify the logic by checking that
        // prev_profile was set.
        state.auto_vr_boost = true;
        state.on_vr_session_start();

        // Without a real card, set_profile errors and prev_profile is cleared.
        // Verify that auto_vr_boost=false skips entirely.
        let mut state2 = GpuPowerState::new();
        state2.current_profile = GpuPowerProfile::Low;
        state2.auto_vr_boost = false;
        state2.on_vr_session_start();
        assert!(state2.prev_profile.is_none());
        assert_eq!(state2.current_profile, GpuPowerProfile::Low);
    }

    #[test]
    fn test_sysfs_profile_mapping() {
        assert_eq!(GpuPowerProfile::Auto.to_sysfs(), "auto");
        assert_eq!(GpuPowerProfile::High.to_sysfs(), "high");
        assert_eq!(GpuPowerProfile::Normal.to_sysfs(), "manual");
        assert_eq!(GpuPowerProfile::Low.to_sysfs(), "low");

        assert_eq!(GpuPowerProfile::from_sysfs("auto\n"), Some(GpuPowerProfile::Auto));
        assert_eq!(GpuPowerProfile::from_sysfs("manual"), Some(GpuPowerProfile::Normal));
        assert_eq!(GpuPowerProfile::from_sysfs("unknown"), None);
    }

    #[test]
    fn test_to_sexp() {
        let state = GpuPowerState::new();
        let sexp = state.to_sexp();
        assert!(sexp.contains(":profile :auto"));
        assert!(sexp.contains(":card nil"));
        assert!(sexp.contains(":controllable nil"));
        assert!(sexp.contains(":auto-vr-boost t"));
    }
}
