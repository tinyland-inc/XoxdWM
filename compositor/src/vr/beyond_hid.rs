//! Bigscreen Beyond 2e HID control — display power, brightness, fan, LED.
//!
//! Implements the Beyond HID protocol (vendor-defined, 65-byte feature reports).
//! Based on protocol analysis from beyond_squared and Wireshark captures.
//! See docs/research/beyond-2e-bootstrap-analysis.md for protocol details.
//!
//! This module does NOT depend on hidapi.  It builds feature reports as plain
//! byte arrays that any HID transport can send.  The actual
//! `send_feature_report` call lives behind [`HidTransport`] so the module
//! compiles on every platform (including macOS where wayland is unavailable).

use tracing::{debug, info, warn};

// ── Constants ────────────────────────────────────────────────

/// Vendor and product IDs for Bigscreen Beyond headset variants.
pub const BEYOND_VENDOR_ID: u16 = 0x35BD;
pub const BEYOND_PRODUCT_ID_HMD: u16 = 0x0101;
pub const BEYOND_PRODUCT_ID_BIGEYE: u16 = 0x0202;
pub const BEYOND_PRODUCT_ID_AUDIO: u16 = 0x0105;
pub const BEYOND_PRODUCT_ID_DFU: u16 = 0x4004;

/// HID command bytes (byte[1] of 65-byte feature reports).
const CMD_LED_COLOR: u8 = 0x4C; // 'L'
const CMD_FAN_SPEED: u8 = 0x46; // 'F'
const CMD_BRIGHTNESS: u8 = 0x49; // 'I'

/// HID report size (1 byte padding + 64 bytes payload).
const REPORT_SIZE: usize = 65;

/// Minimum allowed fan speed percentage.
const FAN_SPEED_MIN: u8 = 40;

/// Maximum allowed fan speed percentage.
const FAN_SPEED_MAX: u8 = 100;

/// Display power-on report ID.
const POWER_ON_REPORT_ID: u8 = 0x06;

// ── Helper functions ─────────────────────────────────────────

/// Convert a user-facing brightness percentage (0-100) to the device's
/// internal 16-bit value.
///
/// Formula (from Wireshark analysis): `(2.15 * pct + 50.0) as u16`
/// Range: 0x0032 (50) at 0% .. 0x010A (265) at 100%.
pub fn brightness_to_device(pct: u8) -> u16 {
    let pct = pct.min(100);
    let raw = 2.15 * pct as f64 + 50.0;
    (raw as u16).clamp(0x0032, 0x010A)
}

/// Build a 65-byte HID feature report.
///
/// Layout: `[0x00, cmd, data[0], data[1], ..., 0x00, ...]`
/// - byte 0: report ID padding (always 0x00)
/// - byte 1: command byte
/// - bytes 2..: command-specific payload, zero-padded to REPORT_SIZE
pub fn build_feature_report(cmd: u8, data: &[u8]) -> [u8; REPORT_SIZE] {
    let mut report = [0u8; REPORT_SIZE];
    report[0] = 0x00; // report ID padding
    report[1] = cmd;
    let copy_len = data.len().min(REPORT_SIZE - 2);
    report[2..2 + copy_len].copy_from_slice(&data[..copy_len]);
    report
}

/// Build the 5-packet display power-on sequence (from Wireshark capture).
///
/// ```text
/// Report ID 0x06, payload: 00 22 00 00  (x3)
/// Report ID 0x06, payload: 00 22 01 00  (x1)
/// Report ID 0x06, payload: 00 22 02 00  (x1)
/// ```
///
/// These are modeled as GET feature-report requests that wake the display
/// controller.  In practice, the HID transport sends them as
/// `send_feature_report` calls.
pub fn build_power_on_sequence() -> Vec<[u8; REPORT_SIZE]> {
    let mut packets = Vec::with_capacity(5);

    // Packets 1-3: 00 22 00 00
    for _ in 0..3 {
        let mut report = [0u8; REPORT_SIZE];
        report[0] = POWER_ON_REPORT_ID;
        report[1] = 0x00;
        report[2] = 0x22;
        report[3] = 0x00;
        report[4] = 0x00;
        packets.push(report);
    }

    // Packet 4: 00 22 01 00
    {
        let mut report = [0u8; REPORT_SIZE];
        report[0] = POWER_ON_REPORT_ID;
        report[1] = 0x00;
        report[2] = 0x22;
        report[3] = 0x01;
        report[4] = 0x00;
        packets.push(report);
    }

    // Packet 5: 00 22 02 00
    {
        let mut report = [0u8; REPORT_SIZE];
        report[0] = POWER_ON_REPORT_ID;
        report[1] = 0x00;
        report[2] = 0x22;
        report[3] = 0x02;
        report[4] = 0x00;
        packets.push(report);
    }

    packets
}

/// Build a brightness feature report.
fn build_brightness_report(pct: u8) -> [u8; REPORT_SIZE] {
    let device_val = brightness_to_device(pct);
    let hi = (device_val >> 8) as u8;
    let lo = (device_val & 0xFF) as u8;
    build_feature_report(CMD_BRIGHTNESS, &[hi, lo])
}

/// Build a fan speed feature report.
fn build_fan_speed_report(pct: u8) -> [u8; REPORT_SIZE] {
    let clamped = pct.clamp(FAN_SPEED_MIN, FAN_SPEED_MAX);
    build_feature_report(CMD_FAN_SPEED, &[clamped])
}

/// Build an LED color feature report.
fn build_led_color_report(r: u8, g: u8, b: u8) -> [u8; REPORT_SIZE] {
    build_feature_report(CMD_LED_COLOR, &[r, g, b])
}

// ── HID transport trait ──────────────────────────────────────

/// Abstraction over the actual HID send path.
///
/// On Linux with hidapi this would open `/dev/hidraw*`; on other platforms
/// (or in tests) a no-op or mock implementation is used.
pub trait HidTransport {
    /// Send a feature report and return the number of bytes written.
    fn send_feature_report(&mut self, data: &[u8; REPORT_SIZE]) -> Result<usize, String>;

    /// Receive a feature report (for firmware queries).
    fn get_feature_report(&mut self, report_id: u8, buf: &mut [u8]) -> Result<usize, String>;
}

/// Stub transport that logs commands but does not touch hardware.
/// Used on macOS and in unit tests.
#[derive(Debug, Default)]
pub struct StubHidTransport {
    /// Number of reports sent (for testing).
    pub reports_sent: usize,
}

impl HidTransport for StubHidTransport {
    fn send_feature_report(&mut self, data: &[u8; REPORT_SIZE]) -> Result<usize, String> {
        debug!(
            "StubHidTransport: send_feature_report cmd=0x{:02X} ({} bytes)",
            data[1], REPORT_SIZE
        );
        self.reports_sent += 1;
        Ok(REPORT_SIZE)
    }

    fn get_feature_report(&mut self, report_id: u8, buf: &mut [u8]) -> Result<usize, String> {
        debug!(
            "StubHidTransport: get_feature_report id=0x{:02X}",
            report_id
        );
        // Return zeroed buffer
        for b in buf.iter_mut() {
            *b = 0;
        }
        Ok(buf.len())
    }
}

// ── State and status ─────────────────────────────────────────

/// Tracked state of the Beyond headset.
#[derive(Debug, Clone)]
pub struct BeyondHidState {
    /// Whether the HID device is currently connected.
    pub connected: bool,
    /// Display brightness (0-100).
    pub brightness: u8,
    /// Fan speed (40-100).
    pub fan_speed: u8,
    /// LED color (R, G, B).
    pub led_color: (u8, u8, u8),
    /// Whether the display panel is powered on.
    pub display_powered: bool,
    /// Device serial number (if known).
    pub serial: Option<String>,
}

impl Default for BeyondHidState {
    fn default() -> Self {
        Self {
            connected: false,
            brightness: 50,
            fan_speed: 60,
            led_color: (255, 255, 255),
            display_powered: false,
            serial: None,
        }
    }
}

/// Status snapshot for IPC responses.
#[derive(Debug, Clone)]
pub struct BeyondHidStatus {
    pub connected: bool,
    pub brightness: u8,
    pub fan_speed: u8,
    pub led_color: (u8, u8, u8),
    pub display_powered: bool,
    pub serial: Option<String>,
}

impl BeyondHidStatus {
    /// Generate IPC s-expression for Emacs.
    pub fn to_sexp(&self) -> String {
        let serial_str = self
            .serial
            .as_deref()
            .map(|s| format!("\"{}\"", s))
            .unwrap_or_else(|| "nil".to_string());

        format!(
            "(:connected {} :brightness {} :fan-speed {} :led-color (:r {} :g {} :b {}) :display-powered {} :serial {})",
            if self.connected { "t" } else { "nil" },
            self.brightness,
            self.fan_speed,
            self.led_color.0,
            self.led_color.1,
            self.led_color.2,
            if self.display_powered { "t" } else { "nil" },
            serial_str,
        )
    }
}

// ── Command enum ─────────────────────────────────────────────

/// A pending HID command to send to the Beyond headset.
#[derive(Debug, Clone, PartialEq)]
pub enum BeyondHidCommand {
    /// Send the 5-packet display power-on sequence.
    PowerOnDisplay,
    /// Set display brightness (0-100).
    SetBrightness(u8),
    /// Set fan speed (40-100, clamped).
    SetFanSpeed(u8),
    /// Set LED color (R, G, B).
    SetLedColor(u8, u8, u8),
    /// Query firmware version via feature report GET.
    QueryFirmwareVersion,
}

// ── Manager ──────────────────────────────────────────────────

/// Manages Beyond HID state and command queue.
///
/// Commands are queued via the public API and flushed to the HID transport
/// by calling [`process_pending`].  This decouples the Emacs/IPC layer from
/// the actual USB timing.
pub struct BeyondHidManager {
    /// Current known headset state.
    pub state: BeyondHidState,
    /// Commands waiting to be sent.
    pub pending_commands: Vec<BeyondHidCommand>,
}

impl Default for BeyondHidManager {
    fn default() -> Self {
        Self {
            state: BeyondHidState::default(),
            pending_commands: Vec::new(),
        }
    }
}

impl BeyondHidManager {
    /// Create a new manager with default state.
    pub fn new() -> Self {
        info!("Beyond HID manager initialized");
        Self::default()
    }

    /// Simulate device detection (connect/disconnect).
    ///
    /// In a real implementation this would enumerate `/dev/hidraw*` looking
    /// for `BEYOND_VENDOR_ID`:`BEYOND_PRODUCT_ID_HMD`.
    pub fn detect(&mut self, connected: bool, serial: Option<String>) {
        let was_connected = self.state.connected;
        self.state.connected = connected;
        self.state.serial = serial.clone();

        if connected && !was_connected {
            info!(
                "Beyond HID: device connected (serial: {})",
                serial.as_deref().unwrap_or("unknown")
            );
        } else if !connected && was_connected {
            info!("Beyond HID: device disconnected");
            self.state.display_powered = false;
            self.pending_commands.clear();
        }
    }

    /// Queue the display power-on sequence.
    pub fn power_on_display(&mut self) -> Result<(), String> {
        if !self.state.connected {
            warn!("Beyond HID: cannot power on display — device not connected");
            return Err("device not connected".to_string());
        }
        if self.state.display_powered {
            debug!("Beyond HID: display already powered on");
            return Ok(());
        }
        self.pending_commands.push(BeyondHidCommand::PowerOnDisplay);
        info!("Beyond HID: queued display power-on sequence");
        Ok(())
    }

    /// Queue a brightness change (0-100).
    pub fn set_brightness(&mut self, pct: u8) -> Result<(), String> {
        if !self.state.connected {
            return Err("device not connected".to_string());
        }
        let pct = pct.min(100);
        self.pending_commands
            .push(BeyondHidCommand::SetBrightness(pct));
        debug!("Beyond HID: queued brightness {}%", pct);
        Ok(())
    }

    /// Queue a fan speed change (clamped to 40-100).
    pub fn set_fan_speed(&mut self, pct: u8) -> Result<(), String> {
        if !self.state.connected {
            return Err("device not connected".to_string());
        }
        let clamped = pct.clamp(FAN_SPEED_MIN, FAN_SPEED_MAX);
        if clamped != pct {
            warn!(
                "Beyond HID: fan speed {}% clamped to {}% (min {}%)",
                pct, clamped, FAN_SPEED_MIN
            );
        }
        self.pending_commands
            .push(BeyondHidCommand::SetFanSpeed(clamped));
        debug!("Beyond HID: queued fan speed {}%", clamped);
        Ok(())
    }

    /// Queue an LED color change.
    pub fn set_led_color(&mut self, r: u8, g: u8, b: u8) -> Result<(), String> {
        if !self.state.connected {
            return Err("device not connected".to_string());
        }
        self.pending_commands
            .push(BeyondHidCommand::SetLedColor(r, g, b));
        debug!("Beyond HID: queued LED color ({}, {}, {})", r, g, b);
        Ok(())
    }

    /// Queue a firmware version query.
    pub fn query_firmware_version(&mut self) -> Result<(), String> {
        if !self.state.connected {
            return Err("device not connected".to_string());
        }
        self.pending_commands
            .push(BeyondHidCommand::QueryFirmwareVersion);
        debug!("Beyond HID: queued firmware version query");
        Ok(())
    }

    /// Return a snapshot of the current state for IPC.
    pub fn status(&self) -> BeyondHidStatus {
        BeyondHidStatus {
            connected: self.state.connected,
            brightness: self.state.brightness,
            fan_speed: self.state.fan_speed,
            led_color: self.state.led_color,
            display_powered: self.state.display_powered,
            serial: self.state.serial.clone(),
        }
    }

    /// Flush all pending commands through the given HID transport.
    ///
    /// Returns the number of commands successfully sent.
    pub fn process_pending(
        &mut self,
        transport: &mut dyn HidTransport,
    ) -> Result<usize, String> {
        if self.pending_commands.is_empty() {
            return Ok(0);
        }

        if !self.state.connected {
            let count = self.pending_commands.len();
            self.pending_commands.clear();
            warn!(
                "Beyond HID: discarding {} commands — device not connected",
                count
            );
            return Err("device not connected".to_string());
        }

        let commands: Vec<BeyondHidCommand> = self.pending_commands.drain(..).collect();
        let mut sent = 0usize;

        for cmd in &commands {
            match cmd {
                BeyondHidCommand::PowerOnDisplay => {
                    let packets = build_power_on_sequence();
                    for (i, pkt) in packets.iter().enumerate() {
                        transport.send_feature_report(pkt).map_err(|e| {
                            format!(
                                "power-on packet {}/{} failed: {}",
                                i + 1,
                                packets.len(),
                                e
                            )
                        })?;
                    }
                    self.state.display_powered = true;
                    info!("Beyond HID: display powered on ({} packets)", packets.len());
                }
                BeyondHidCommand::SetBrightness(pct) => {
                    let report = build_brightness_report(*pct);
                    transport
                        .send_feature_report(&report)
                        .map_err(|e| format!("brightness command failed: {}", e))?;
                    self.state.brightness = *pct;
                    info!("Beyond HID: brightness set to {}%", pct);
                }
                BeyondHidCommand::SetFanSpeed(pct) => {
                    let report = build_fan_speed_report(*pct);
                    transport
                        .send_feature_report(&report)
                        .map_err(|e| format!("fan speed command failed: {}", e))?;
                    self.state.fan_speed = *pct;
                    info!("Beyond HID: fan speed set to {}%", pct);
                }
                BeyondHidCommand::SetLedColor(r, g, b) => {
                    let report = build_led_color_report(*r, *g, *b);
                    transport
                        .send_feature_report(&report)
                        .map_err(|e| format!("LED color command failed: {}", e))?;
                    self.state.led_color = (*r, *g, *b);
                    info!("Beyond HID: LED color set to ({}, {}, {})", r, g, b);
                }
                BeyondHidCommand::QueryFirmwareVersion => {
                    let mut buf = [0u8; REPORT_SIZE];
                    transport
                        .get_feature_report(0x01, &mut buf)
                        .map_err(|e| format!("firmware query failed: {}", e))?;
                    debug!("Beyond HID: firmware response {:02X?}", &buf[..8]);
                }
            }
            sent += 1;
        }

        debug!("Beyond HID: processed {} commands", sent);
        Ok(sent)
    }

    /// Get the number of pending commands.
    pub fn pending_count(&self) -> usize {
        self.pending_commands.len()
    }

    /// Get state as IPC s-expression.
    pub fn status_sexp(&self) -> String {
        self.status().to_sexp()
    }
}

// ── Tests ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // -- brightness_to_device conversion ---

    #[test]
    fn test_brightness_to_device_zero() {
        // 2.15 * 0 + 50.0 = 50 = 0x0032
        let val = brightness_to_device(0);
        assert_eq!(val, 0x0032);
    }

    #[test]
    fn test_brightness_to_device_fifty() {
        // 2.15 * 50 + 50.0 = 157.5 -> 157 = 0x009D
        let val = brightness_to_device(50);
        assert_eq!(val, 157);
    }

    #[test]
    fn test_brightness_to_device_hundred() {
        // 2.15 * 100 + 50.0 = 265 = 0x0109
        let val = brightness_to_device(100);
        assert_eq!(val, 265);
        assert!(val <= 0x010A);
    }

    #[test]
    fn test_brightness_to_device_clamp_above_100() {
        // Values above 100 should be clamped to 100 first.
        let val = brightness_to_device(255);
        assert_eq!(val, brightness_to_device(100));
    }

    // -- build_feature_report ---

    #[test]
    fn test_build_feature_report_structure() {
        let data = [0xAA, 0xBB, 0xCC];
        let report = build_feature_report(CMD_LED_COLOR, &data);

        assert_eq!(report.len(), REPORT_SIZE);
        assert_eq!(report[0], 0x00); // padding
        assert_eq!(report[1], CMD_LED_COLOR);
        assert_eq!(report[2], 0xAA);
        assert_eq!(report[3], 0xBB);
        assert_eq!(report[4], 0xCC);
        // Rest should be zeroed
        for &b in &report[5..] {
            assert_eq!(b, 0x00);
        }
    }

    #[test]
    fn test_build_feature_report_empty_data() {
        let report = build_feature_report(CMD_FAN_SPEED, &[]);
        assert_eq!(report[0], 0x00);
        assert_eq!(report[1], CMD_FAN_SPEED);
        for &b in &report[2..] {
            assert_eq!(b, 0x00);
        }
    }

    #[test]
    fn test_build_feature_report_overflow_data() {
        // Data larger than available space should be truncated, not panic.
        let big_data = [0xFF; 128];
        let report = build_feature_report(0x01, &big_data);
        assert_eq!(report.len(), REPORT_SIZE);
        assert_eq!(report[0], 0x00);
        assert_eq!(report[1], 0x01);
        // Bytes 2..65 should all be 0xFF (63 bytes copied)
        for &b in &report[2..] {
            assert_eq!(b, 0xFF);
        }
    }

    // -- power-on sequence ---

    #[test]
    fn test_power_on_sequence_length() {
        let seq = build_power_on_sequence();
        assert_eq!(seq.len(), 5);
    }

    #[test]
    fn test_power_on_sequence_content() {
        let seq = build_power_on_sequence();

        // Packets 0-2: report_id=0x06, 00 22 00 00
        for i in 0..3 {
            assert_eq!(seq[i][0], POWER_ON_REPORT_ID);
            assert_eq!(seq[i][1], 0x00);
            assert_eq!(seq[i][2], 0x22);
            assert_eq!(seq[i][3], 0x00);
            assert_eq!(seq[i][4], 0x00);
        }

        // Packet 3: report_id=0x06, 00 22 01 00
        assert_eq!(seq[3][0], POWER_ON_REPORT_ID);
        assert_eq!(seq[3][2], 0x22);
        assert_eq!(seq[3][3], 0x01);
        assert_eq!(seq[3][4], 0x00);

        // Packet 4: report_id=0x06, 00 22 02 00
        assert_eq!(seq[4][0], POWER_ON_REPORT_ID);
        assert_eq!(seq[4][2], 0x22);
        assert_eq!(seq[4][3], 0x02);
        assert_eq!(seq[4][4], 0x00);
    }

    // -- fan speed clamping ---

    #[test]
    fn test_fan_speed_clamp_below_minimum() {
        let report = build_fan_speed_report(10);
        // byte[2] should be clamped to FAN_SPEED_MIN (40)
        assert_eq!(report[2], FAN_SPEED_MIN);
    }

    #[test]
    fn test_fan_speed_at_minimum() {
        let report = build_fan_speed_report(40);
        assert_eq!(report[2], 40);
    }

    #[test]
    fn test_fan_speed_at_maximum() {
        let report = build_fan_speed_report(100);
        assert_eq!(report[2], 100);
    }

    // -- LED color report ---

    #[test]
    fn test_led_color_report() {
        let report = build_led_color_report(0xFF, 0x00, 0x80);
        assert_eq!(report[0], 0x00);
        assert_eq!(report[1], CMD_LED_COLOR);
        assert_eq!(report[2], 0xFF);
        assert_eq!(report[3], 0x00);
        assert_eq!(report[4], 0x80);
    }

    // -- BeyondHidManager state transitions ---

    #[test]
    fn test_manager_new_defaults() {
        let mgr = BeyondHidManager::new();
        assert!(!mgr.state.connected);
        assert_eq!(mgr.state.brightness, 50);
        assert_eq!(mgr.state.fan_speed, 60);
        assert!(!mgr.state.display_powered);
        assert_eq!(mgr.pending_count(), 0);
    }

    #[test]
    fn test_detect_connect_disconnect() {
        let mut mgr = BeyondHidManager::new();

        mgr.detect(true, Some("BSB2E-00123".to_string()));
        assert!(mgr.state.connected);
        assert_eq!(mgr.state.serial.as_deref(), Some("BSB2E-00123"));

        mgr.detect(false, None);
        assert!(!mgr.state.connected);
        assert!(!mgr.state.display_powered);
    }

    #[test]
    fn test_commands_fail_when_disconnected() {
        let mut mgr = BeyondHidManager::new();
        // Not connected — all commands should return Err.
        assert!(mgr.power_on_display().is_err());
        assert!(mgr.set_brightness(80).is_err());
        assert!(mgr.set_fan_speed(70).is_err());
        assert!(mgr.set_led_color(255, 0, 0).is_err());
        assert!(mgr.query_firmware_version().is_err());
        assert_eq!(mgr.pending_count(), 0);
    }

    #[test]
    fn test_commands_queue_when_connected() {
        let mut mgr = BeyondHidManager::new();
        mgr.detect(true, None);

        mgr.power_on_display().unwrap();
        mgr.set_brightness(80).unwrap();
        mgr.set_fan_speed(70).unwrap();
        mgr.set_led_color(0, 255, 128).unwrap();
        assert_eq!(mgr.pending_count(), 4);
    }

    #[test]
    fn test_process_pending_updates_state() {
        let mut mgr = BeyondHidManager::new();
        let mut transport = StubHidTransport::default();

        mgr.detect(true, Some("TEST-001".to_string()));
        mgr.power_on_display().unwrap();
        mgr.set_brightness(75).unwrap();
        mgr.set_fan_speed(80).unwrap();
        mgr.set_led_color(10, 20, 30).unwrap();

        let sent = mgr.process_pending(&mut transport).unwrap();
        // 4 commands: power-on (5 packets, 1 command), brightness, fan, LED
        assert_eq!(sent, 4);
        assert!(mgr.state.display_powered);
        assert_eq!(mgr.state.brightness, 75);
        assert_eq!(mgr.state.fan_speed, 80);
        assert_eq!(mgr.state.led_color, (10, 20, 30));
        assert_eq!(mgr.pending_count(), 0);
        // 5 power-on packets + 1 brightness + 1 fan + 1 LED = 8 reports
        assert_eq!(transport.reports_sent, 8);
    }

    #[test]
    fn test_process_pending_empty() {
        let mut mgr = BeyondHidManager::new();
        let mut transport = StubHidTransport::default();
        mgr.detect(true, None);

        let sent = mgr.process_pending(&mut transport).unwrap();
        assert_eq!(sent, 0);
        assert_eq!(transport.reports_sent, 0);
    }

    #[test]
    fn test_process_pending_disconnected_discards() {
        let mut mgr = BeyondHidManager::new();
        let mut transport = StubHidTransport::default();

        mgr.detect(true, None);
        mgr.set_brightness(50).unwrap();
        mgr.detect(false, None); // disconnect clears pending

        // Queue is already empty after disconnect
        assert_eq!(mgr.pending_count(), 0);
    }

    #[test]
    fn test_fan_speed_clamping_via_manager() {
        let mut mgr = BeyondHidManager::new();
        mgr.detect(true, None);

        // Below minimum — should be clamped
        mgr.set_fan_speed(10).unwrap();
        assert_eq!(
            mgr.pending_commands.last(),
            Some(&BeyondHidCommand::SetFanSpeed(FAN_SPEED_MIN))
        );
    }

    #[test]
    fn test_power_on_idempotent() {
        let mut mgr = BeyondHidManager::new();
        let mut transport = StubHidTransport::default();

        mgr.detect(true, None);
        mgr.power_on_display().unwrap();
        mgr.process_pending(&mut transport).unwrap();

        // Display now powered — second power_on should be a no-op.
        mgr.power_on_display().unwrap();
        assert_eq!(mgr.pending_count(), 0);
    }

    // -- status / sexp ---

    #[test]
    fn test_status_snapshot() {
        let mut mgr = BeyondHidManager::new();
        mgr.detect(true, Some("SN-42".to_string()));

        let status = mgr.status();
        assert!(status.connected);
        assert_eq!(status.serial.as_deref(), Some("SN-42"));
        assert_eq!(status.brightness, 50);
    }

    #[test]
    fn test_status_sexp_format() {
        let mut mgr = BeyondHidManager::new();
        mgr.detect(true, Some("SN-42".to_string()));

        let sexp = mgr.status_sexp();
        assert!(sexp.contains(":connected t"));
        assert!(sexp.contains(":brightness 50"));
        assert!(sexp.contains(":fan-speed 60"));
        assert!(sexp.contains(":display-powered nil"));
        assert!(sexp.contains(":serial \"SN-42\""));
        assert!(sexp.contains(":led-color (:r 255 :g 255 :b 255)"));
    }

    #[test]
    fn test_status_sexp_disconnected() {
        let mgr = BeyondHidManager::new();
        let sexp = mgr.status_sexp();
        assert!(sexp.contains(":connected nil"));
        assert!(sexp.contains(":serial nil"));
    }

    // -- brightness report encoding ---

    #[test]
    fn test_brightness_report_encoding() {
        let report = build_brightness_report(100);
        assert_eq!(report[1], CMD_BRIGHTNESS);
        // 265 = 0x0109 -> hi=0x01, lo=0x09
        assert_eq!(report[2], 0x01);
        assert_eq!(report[3], 0x09);
    }

    #[test]
    fn test_brightness_report_zero() {
        let report = build_brightness_report(0);
        assert_eq!(report[1], CMD_BRIGHTNESS);
        // 50 = 0x0032 -> hi=0x00, lo=0x32
        assert_eq!(report[2], 0x00);
        assert_eq!(report[3], 0x32);
    }

    // -- firmware query ---

    #[test]
    fn test_firmware_query_queues() {
        let mut mgr = BeyondHidManager::new();
        mgr.detect(true, None);
        mgr.query_firmware_version().unwrap();
        assert_eq!(mgr.pending_count(), 1);
        assert_eq!(
            mgr.pending_commands[0],
            BeyondHidCommand::QueryFirmwareVersion
        );
    }

    #[test]
    fn test_firmware_query_processes() {
        let mut mgr = BeyondHidManager::new();
        let mut transport = StubHidTransport::default();

        mgr.detect(true, None);
        mgr.query_firmware_version().unwrap();
        let sent = mgr.process_pending(&mut transport).unwrap();
        assert_eq!(sent, 1);
    }
}
