//! ext-session-lock-v1 handler — screen locking protocol.
//!
//! Implements SessionLockHandler so screen lockers (swaylock, etc.)
//! can lock the session and display lock surfaces on all outputs.

use crate::state::EwwmState;
use smithay::{
    delegate_session_lock,
    reexports::wayland_server::protocol::wl_output::WlOutput,
    wayland::session_lock::{
        LockSurface, SessionLockHandler, SessionLockManagerState, SessionLocker,
    },
};
use tracing::{debug, info};

impl SessionLockHandler for EwwmState {
    fn lock_state(&mut self) -> &mut SessionLockManagerState {
        &mut self.session_lock_state
    }

    fn lock(&mut self, confirmation: SessionLocker) {
        info!("session-lock: locking session");
        self.session_locked = true;
        // Confirm the lock immediately — the locker will then
        // create lock surfaces for each output.
        confirmation.lock();
    }

    fn unlock(&mut self) {
        info!("session-lock: unlocking session");
        self.session_locked = false;
    }

    fn new_surface(&mut self, _surface: LockSurface, _output: WlOutput) {
        debug!("session-lock: new lock surface");
    }
}

delegate_session_lock!(EwwmState);
