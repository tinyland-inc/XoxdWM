//! pointer-constraints-unstable-v1 handler — pointer lock and confinement.
//!
//! Implements PointerConstraintsHandler so clients (games, VR overlays)
//! can lock or confine the pointer to a surface region.
//! Uses Smithay's built-in smithay::wayland::pointer_constraints support.

use crate::state::EwwmState;
use smithay::{
    delegate_pointer_constraints,
    input::pointer::PointerHandle,
    reexports::wayland_server::protocol::wl_surface::WlSurface,
    wayland::pointer_constraints::{
        with_pointer_constraint, PointerConstraintsHandler,
    },
};
use tracing::{debug, info};

use crate::ipc::dispatch::format_event;
use crate::ipc::IpcServer;

impl PointerConstraintsHandler for EwwmState {
    fn new_constraint(&mut self, surface: &WlSurface, pointer: &PointerHandle<Self>) {
        // Determine if this is a lock or confine constraint.
        let constraint_type = with_pointer_constraint(surface, pointer, |constraint| {
            constraint
                .map(|c| if c.is_active() { "active" } else { "pending" })
                .unwrap_or("unknown")
        });

        info!(
            ?surface,
            constraint_type, "pointer-constraints: new constraint"
        );

        // Notify Emacs that a pointer constraint was created.
        let event = format_event(
            "pointer-locked",
            &[("constraint-type", &format!("\"{}\"", constraint_type))],
        );
        IpcServer::broadcast_event(self, &event);
    }

    fn cursor_position_hint(
        &mut self,
        surface: &WlSurface,
        pointer: &PointerHandle<Self>,
        location: smithay::utils::Point<f64, smithay::utils::Logical>,
    ) {
        debug!(
            ?surface,
            x = location.x,
            y = location.y,
            "pointer-constraints: cursor position hint"
        );
        // In a full implementation, warp the cursor to the hinted position
        // when the constraint is deactivated.
        let _ = (surface, pointer, location);
    }
}

impl EwwmState {
    /// Emit a pointer-unlocked event.  Called when a constraint is deactivated
    /// (e.g. compositor breaks the lock via a keybind).
    pub fn notify_pointer_unlocked(&mut self) {
        info!("pointer-constraints: unlocked");
        let event = format_event("pointer-unlocked", &[]);
        IpcServer::broadcast_event(self, &event);
    }

    /// Query whether any pointer constraint is currently active.
    pub fn pointer_constraint_active(&self) -> bool {
        // The actual active-constraint tracking is per-surface in Smithay.
        // For IPC status we report whether the state object is initialized.
        // Full per-surface tracking would iterate surfaces; stub returns false.
        false
    }
}

delegate_pointer_constraints!(EwwmState);
