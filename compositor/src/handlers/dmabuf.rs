//! linux-dmabuf-v1 handler — DMA-BUF buffer import protocol.
//!
//! Enables zero-copy buffer sharing for GPU-rendered clients.
//! The DRM backend will configure supported formats at runtime;
//! here we provide the protocol scaffolding.

use crate::state::EwwmState;
use smithay::{
    backend::allocator::dmabuf::Dmabuf,
    delegate_dmabuf,
    wayland::dmabuf::{DmabufGlobal, DmabufHandler, DmabufState, ImportNotifier},
};
use tracing::debug;

impl DmabufHandler for EwwmState {
    fn dmabuf_state(&mut self) -> &mut DmabufState {
        &mut self.dmabuf_state
    }

    fn dmabuf_imported(
        &mut self,
        _global: &DmabufGlobal,
        _dmabuf: Dmabuf,
        notifier: ImportNotifier,
    ) {
        // Without a live renderer we cannot validate the import.
        // Signal failure so the client falls back to wl_shm.
        // When the DRM backend is active, this will be replaced with
        // actual GPU import validation.
        debug!("dmabuf: import requested (no renderer — failing)");
        notifier.failed();
    }
}

delegate_dmabuf!(EwwmState);
