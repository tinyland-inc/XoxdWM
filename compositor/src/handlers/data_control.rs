//! wlr-data-control-v1 — clipboard manager protocol (stub).
//!
//! This protocol allows external clipboard managers to persist clipboard
//! data after the source application closes.  Without it, clipboard
//! contents are lost when the copying app exits.
//!
//! Smithay 0.7 does not include a built-in data-control handler.
//! Implementation requires the `wayland-protocols-wlr` crate and manual
//! global registration.  This stub reserves the module location and
//! documents the planned approach.
//!
//! ## Implementation Plan
//!
//! 1. Add `wayland-protocols-wlr` to Cargo.toml
//! 2. Bind `zwlr_data_control_manager_v1` global
//! 3. Implement DataControlDeviceHandler:
//!    - `selection` — client sets clipboard contents
//!    - `primary_selection` — client sets primary selection
//! 4. Wire to DataDeviceState and PrimarySelectionState for forwarding
//! 5. Emit IPC events: clipboard-changed, primary-selection-changed
//!
//! See: <https://wayland.app/protocols/wlr-data-control-unstable-v1>

// TODO: Implement when wayland-protocols-wlr crate is added to dependencies.
