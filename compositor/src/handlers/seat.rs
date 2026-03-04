//! wl_seat handler — input device management.

use crate::ipc::{dispatch::format_event, server::IpcServer};
use crate::state::{CursorImageStatus, EwwmState};
use smithay::{
    delegate_cursor_shape, delegate_data_device, delegate_output,
    delegate_primary_selection, delegate_seat,
    input::{
        pointer::CursorImageStatus as SmithayCursorImageStatus,
        Seat, SeatHandler, SeatState,
    },
    reexports::wayland_server::protocol::wl_surface::WlSurface,
    wayland::selection::{
        data_device::{
            ClientDndGrabHandler, DataDeviceHandler, DataDeviceState, ServerDndGrabHandler,
        },
        primary_selection::{PrimarySelectionHandler, PrimarySelectionState},
    },
};
use tracing::{debug, trace};

impl SeatHandler for EwwmState {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }

    fn cursor_image(
        &mut self,
        _seat: &Seat<Self>,
        image: SmithayCursorImageStatus,
    ) {
        let new_status = match image {
            SmithayCursorImageStatus::Hidden => CursorImageStatus::Hidden,
            SmithayCursorImageStatus::Named(_) => CursorImageStatus::Default,
            SmithayCursorImageStatus::Surface(_) => CursorImageStatus::Surface,
        };
        if self.cursor_status != new_status {
            trace!(?new_status, "cursor image changed");
            self.cursor_status = new_status;
        }
    }

    fn focus_changed(
        &mut self,
        _seat: &Seat<Self>,
        focused: Option<&WlSurface>,
    ) {
        let new_focus = focused.and_then(|wl| self.surface_id_for_wl_surface(wl));

        if new_focus != self.focused_surface {
            let old = self.focused_surface;
            self.focused_surface = new_focus;

            debug!(old = ?old, new = ?new_focus, "focus changed");

            // Broadcast focus-changed event to Emacs
            let old_str = old
                .map(|id| id.to_string())
                .unwrap_or_else(|| "nil".to_string());
            let new_str = new_focus
                .map(|id| id.to_string())
                .unwrap_or_else(|| "nil".to_string());

            let event = format_event(
                "focus-changed",
                &[("old", &old_str), ("new", &new_str)],
            );
            IpcServer::broadcast_event(self, &event);
        }
    }
}

impl DataDeviceHandler for EwwmState {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.data_device_state
    }
}

impl ClientDndGrabHandler for EwwmState {}
impl ServerDndGrabHandler for EwwmState {}

impl smithay::wayland::selection::SelectionHandler for EwwmState {
    type SelectionUserData = ();
}

impl smithay::wayland::output::OutputHandler for EwwmState {}

impl PrimarySelectionHandler for EwwmState {
    fn primary_selection_state(&self) -> &PrimarySelectionState {
        &self.primary_selection_state
    }
}

impl smithay::wayland::tablet_manager::TabletSeatHandler for EwwmState {}

delegate_seat!(EwwmState);
delegate_data_device!(EwwmState);
delegate_output!(EwwmState);
delegate_primary_selection!(EwwmState);
delegate_cursor_shape!(EwwmState);
