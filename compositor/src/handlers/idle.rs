//! Idle notification and idle inhibit handlers.
//!
//! ext-idle-notify-v1: lets clients request idle/resume callbacks.
//! zwp-idle-inhibit-v1: lets clients suppress idle (e.g. video playback).

use crate::state::EwwmState;
use smithay::{
    delegate_idle_inhibit, delegate_idle_notify,
    reexports::wayland_server::protocol::wl_surface::WlSurface,
    wayland::{
        idle_inhibit::{IdleInhibitHandler, IdleInhibitManagerState},
        idle_notify::{IdleNotifierHandler, IdleNotifierState},
    },
};
use tracing::debug;

impl IdleNotifierHandler for EwwmState {
    fn idle_notifier_state(&mut self) -> &mut IdleNotifierState<Self> {
        &mut self.idle_notifier_state
    }
}

impl IdleInhibitHandler for EwwmState {
    fn inhibit(&mut self, surface: WlSurface) {
        debug!(?surface, "idle-inhibit: surface requested idle inhibit");
        self.idle_notifier_state.set_is_inhibited(true);
    }

    fn uninhibit(&mut self, surface: WlSurface) {
        debug!(?surface, "idle-inhibit: surface released idle inhibit");
        // Only clear inhibition if no other surfaces are still inhibiting.
        // For now, simple single-surface tracking.
        self.idle_notifier_state.set_is_inhibited(false);
    }
}

delegate_idle_notify!(EwwmState);
delegate_idle_inhibit!(EwwmState);
