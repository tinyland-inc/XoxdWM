//! EWWM Compositor library — VR-first Wayland compositor built on Smithay.
//!
//! This library crate exposes the compositor's core modules for integration
//! testing. The binary entry point lives in `main.rs`.

pub mod autotype;
pub mod clock;
pub mod config;
pub mod input_source;
pub mod backend;
pub(crate) mod handlers;
pub(crate) mod input;
pub mod ipc;
pub(crate) mod render;
pub mod secure_input;
pub(crate) mod state;
pub mod vr;
