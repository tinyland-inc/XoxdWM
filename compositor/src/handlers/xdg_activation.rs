//! xdg-activation-v1 handler — urgency / focus-steal protocol.
//!
//! Allows applications to request activation (focus) of a surface,
//! typically after user interaction in another surface (e.g. clicking
//! a link that should open in an existing browser window).

use crate::ipc::{dispatch::format_event, server::IpcServer};
use crate::state::EwwmState;
use smithay::{
    delegate_xdg_activation,
    reexports::wayland_server::protocol::wl_surface::WlSurface,
    wayland::xdg_activation::{
        XdgActivationHandler, XdgActivationState, XdgActivationToken, XdgActivationTokenData,
    },
};
use tracing::info;

impl XdgActivationHandler for EwwmState {
    fn activation_state(&mut self) -> &mut XdgActivationState {
        &mut self.xdg_activation_state
    }

    fn request_activation(
        &mut self,
        _token: XdgActivationToken,
        _token_data: XdgActivationTokenData,
        surface: WlSurface,
    ) {
        // Look up the surface requesting activation
        let surface_id = self.surface_id_for_wl_surface(&surface);

        info!(?surface_id, "xdg-activation: activation requested");

        if let Some(sid) = surface_id {
            // Notify Emacs so it can decide whether to grant focus
            let event = format_event(
                "activation-requested",
                &[("id", &sid.to_string())],
            );
            IpcServer::broadcast_event(self, &event);
        }
    }
}

delegate_xdg_activation!(EwwmState);
