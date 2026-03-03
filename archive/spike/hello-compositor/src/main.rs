// hello-compositor: Minimal Smithay compositor spike for EXWM-VR
//
// Validates Smithay 0.7 API surface:
//   - calloop EventLoop creation
//   - Winit backend initialization (GlesRenderer)
//   - WlCompositor + XdgShell global registration
//   - Wayland socket setup with WAYLAND_DISPLAY
//   - Render loop: clear to dark gray via GLES2
//   - Event loop timing stats

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};

use smithay::{
    backend::{
        renderer::{
            Color32F, Frame, Renderer,
            gles::GlesRenderer,
        },
        winit::{self, WinitEvent},
        SwapBuffersError,
    },
    delegate_compositor, delegate_output, delegate_seat, delegate_shm, delegate_xdg_shell,
    desktop::{Space, Window},
    input::{keyboard::LedState, pointer::CursorImageStatus, Seat, SeatHandler, SeatState},
    output::{Mode, Output, PhysicalProperties, Subpixel},
    reexports::{
        calloop::EventLoop,
        wayland_server::{
            backend::{ClientData, ClientId, DisconnectReason},
            protocol::wl_surface::WlSurface,
            Display, DisplayHandle,
        },
        winit::platform::pump_events::PumpStatus,
    },
    utils::{Rectangle, Serial, Transform},
    wayland::{
        buffer::BufferHandler,
        compositor::{
            get_parent, is_sync_subsurface, CompositorClientState, CompositorHandler,
            CompositorState,
        },
        output::OutputManagerState,
        shell::xdg::{
            PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
        },
        shm::{ShmHandler, ShmState},
    },
};
use tracing::{error, info, warn};

// ---------------------------------------------------------------------------
// Compositor state
// ---------------------------------------------------------------------------

struct HelloState {
    running: Arc<AtomicBool>,
    display_handle: DisplayHandle,
    space: Space<Window>,

    // Protocol states (each registers its global on construction)
    compositor_state: CompositorState,
    xdg_shell_state: XdgShellState,
    shm_state: ShmState,
    seat_state: SeatState<Self>,
    output_manager_state: OutputManagerState,
}

// ---------------------------------------------------------------------------
// Required trait: ClientData for new client connections
// ---------------------------------------------------------------------------

struct HelloClientData;

impl ClientData for HelloClientData {
    fn initialized(&self, _client_id: ClientId) {}
    fn disconnected(&self, _client_id: ClientId, _reason: DisconnectReason) {}
}

// ---------------------------------------------------------------------------
// Smithay handler trait implementations
// ---------------------------------------------------------------------------

// -- BufferHandler (required by CompositorHandler) --
impl BufferHandler for HelloState {
    fn buffer_destroyed(&mut self, _buffer: &smithay::wayland::buffer::BufferData) {}
}

// -- CompositorHandler --
impl CompositorHandler for HelloState {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor_state
    }

    fn client_compositor_state<'a>(
        &self,
        client: &'a smithay::reexports::wayland_server::Client,
    ) -> &'a CompositorClientState {
        client
            .get_data::<CompositorClientState>()
            .unwrap_or_else(|| {
                // Safety: CompositorClientState is always initialized for clients
                // that interact with the compositor global. If missing, something
                // went seriously wrong.
                panic!("missing CompositorClientState for client");
            })
    }

    fn commit(&mut self, surface: &WlSurface) {
        // Ensure parent surfaces are committed first (subsurface sync)
        on_commit_buffer_handler::<Self>(surface);

        // Handle toplevel/popup surface commits
        if let Some(window) = self
            .space
            .elements()
            .find(|w| w.toplevel().map(|t| t.wl_surface() == surface).unwrap_or(false))
            .cloned()
        {
            window.on_commit();
        }

        // Ensure popups are handled
        ensure_initial_configure(surface, &self.space, &mut self.xdg_shell_state);
    }
}

// Helper: handle initial configure for new surfaces
fn on_commit_buffer_handler<S: CompositorHandler + 'static>(surface: &WlSurface) {
    // Walk up subsurface tree, skipping sync subsurfaces
    if !is_sync_subsurface(surface) {
        if let Some(parent) = get_parent(surface) {
            on_commit_buffer_handler::<S>(&parent);
        }
    }
}

fn ensure_initial_configure(
    _surface: &WlSurface,
    _space: &Space<Window>,
    _xdg_state: &mut XdgShellState,
) {
    // In a full compositor, this would send initial configure events
    // for newly created xdg surfaces. Kept minimal for the spike.
}

delegate_compositor!(HelloState);

// -- XdgShellHandler --
impl XdgShellHandler for HelloState {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell_state
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let window = Window::new_wayland_window(surface.clone());
        self.space.map_element(window, (0, 0), false);
        // Send initial configure
        surface.send_configure();
        info!("New toplevel surface mapped");
    }

    fn new_popup(&mut self, _surface: PopupSurface, _positioner: PositionerState) {
        info!("New popup surface (ignored in spike)");
    }

    fn grab(&mut self, _surface: PopupSurface, _seat: smithay::reexports::wayland_server::protocol::wl_seat::WlSeat, _serial: Serial) {
        // Popup grabs not implemented in spike
    }

    fn reposition(&mut self, _surface: PopupSurface, _positioner: PositionerState, _token: u32) {
        // Repositioning not implemented in spike
    }
}

delegate_xdg_shell!(HelloState);

// -- ShmHandler --
impl ShmHandler for HelloState {
    fn shm_state(&self) -> &ShmState {
        &self.shm_state
    }
}

delegate_shm!(HelloState);

// -- SeatHandler --
impl SeatHandler for HelloState {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }

    fn cursor_image(&mut self, _seat: &Seat<Self>, _image: CursorImageStatus) {}
    fn focus_changed(&mut self, _seat: &Seat<Self>, _focused: Option<&WlSurface>) {}
    fn led_state_changed(&mut self, _seat: &Seat<Self>, _leds: LedState) {}
}

delegate_seat!(HelloState);
delegate_output!(HelloState);

// ---------------------------------------------------------------------------
// Main entry point
// ---------------------------------------------------------------------------

fn main() {
    // Logging setup: respect RUST_LOG, default to info
    if let Ok(env_filter) = tracing_subscriber::EnvFilter::try_from_default_env() {
        tracing_subscriber::fmt()
            .compact()
            .with_env_filter(env_filter)
            .init();
    } else {
        tracing_subscriber::fmt()
            .compact()
            .with_env_filter("hello_compositor=info,smithay=info")
            .init();
    }

    info!("hello-compositor spike starting");
    info!("Smithay version: 0.7.x");

    // -----------------------------------------------------------------------
    // 1. Create calloop EventLoop
    // -----------------------------------------------------------------------
    let mut event_loop: EventLoop<HelloState> = EventLoop::try_new()
        .expect("Failed to create calloop EventLoop");
    info!("calloop EventLoop created");

    // -----------------------------------------------------------------------
    // 2. Create Wayland Display
    // -----------------------------------------------------------------------
    let display: Display<HelloState> = Display::new()
        .expect("Failed to create Wayland Display");
    let display_handle = display.handle();

    // -----------------------------------------------------------------------
    // 3. Initialize Smithay Winit backend (GlesRenderer)
    // -----------------------------------------------------------------------
    let (mut backend, mut winit_event_loop) = winit::init::<GlesRenderer>()
        .expect("Failed to initialize Winit backend");

    let window_size = backend.window_size();
    info!(?window_size, "Winit backend initialized");

    // -----------------------------------------------------------------------
    // 4. Configure output
    // -----------------------------------------------------------------------
    let mode = Mode {
        size: window_size,
        refresh: 60_000, // 60 Hz in mHz
    };

    let output = Output::new(
        "hello-output".to_string(),
        PhysicalProperties {
            size: (0, 0).into(),
            subpixel: Subpixel::Unknown,
            make: "EXWM-VR".into(),
            model: "Spike".into(),
            serial_number: "0001".into(),
        },
    );
    let _output_global = output.create_global::<HelloState>(&display_handle);
    output.change_current_state(
        Some(mode),
        Some(Transform::Flipped180),
        None,
        Some((0, 0).into()),
    );
    output.set_preferred(mode);
    info!("Output configured: {}x{} @ 60Hz", mode.size.w, mode.size.h);

    // -----------------------------------------------------------------------
    // 5. Register Wayland globals via state constructors
    // -----------------------------------------------------------------------
    let compositor_state = CompositorState::new::<HelloState>(&display_handle);
    info!("wl_compositor global registered");

    let xdg_shell_state = XdgShellState::new::<HelloState>(&display_handle);
    info!("xdg_wm_base (XDG Shell) global registered");

    let shm_state = ShmState::new::<HelloState>(&display_handle, vec![]);
    info!("wl_shm global registered");

    let mut seat_state = SeatState::new();
    let _seat = seat_state.new_wl_seat(&display_handle, "hello-seat");
    info!("wl_seat global registered");

    let output_manager_state = OutputManagerState::new_with_xdg_output::<HelloState>(&display_handle);
    info!("xdg_output_manager global registered");

    // Update SHM formats from renderer
    let shm_formats = backend.renderer().shm_formats();
    // shm_state already has default formats; we could extend with renderer's

    // -----------------------------------------------------------------------
    // 6. Set up Wayland socket
    // -----------------------------------------------------------------------
    let socket_name = display
        .handle()
        .add_socket_auto()
        .expect("Failed to add Wayland socket");
    let socket_name_str = socket_name
        .to_str()
        .expect("Socket name is not valid UTF-8")
        .to_string();
    std::env::set_var("WAYLAND_DISPLAY", &socket_name_str);
    info!(socket = %socket_name_str, "Wayland socket listening");
    info!("Clients can connect via: WAYLAND_DISPLAY={}", socket_name_str);

    // -----------------------------------------------------------------------
    // 7. Build compositor state
    // -----------------------------------------------------------------------
    let mut space = Space::default();
    space.map_output(&output, (0, 0));

    let running = Arc::new(AtomicBool::new(true));

    let mut state = HelloState {
        running: running.clone(),
        display_handle: display_handle.clone(),
        space,
        compositor_state,
        xdg_shell_state,
        shm_state,
        seat_state,
        output_manager_state,
    };

    // Insert the Wayland source into calloop
    let source = smithay::reexports::calloop::generic::Generic::new(
        display,
        smithay::reexports::calloop::Interest::READ,
        smithay::reexports::calloop::Mode::Level,
    );
    event_loop
        .handle()
        .insert_source(source, |_, display, state: &mut HelloState| {
            // Safety: we keep the display alive for the lifetime of the loop
            unsafe {
                display.get_mut().dispatch_clients(state).unwrap();
            }
            Ok(smithay::reexports::calloop::PostAction::Continue)
        })
        .expect("Failed to insert Wayland source into calloop");

    info!("Initialization complete. Entering main loop.");
    info!("--- API Surface Assessment ---");
    info!("Globals registered: wl_compositor, xdg_wm_base, wl_shm, wl_seat, xdg_output_manager");
    info!("Backend: Winit + GlesRenderer");
    info!("Event loop: calloop 0.14");
    info!("------------------------------");

    // -----------------------------------------------------------------------
    // 8. Main loop: dispatch events, render, collect timing stats
    // -----------------------------------------------------------------------
    let mut frame_count: u64 = 0;
    let start_time = Instant::now();
    let mut last_stats_print = Instant::now();

    // OutputDamageTracker is available for production use:
    // let damage_tracker = OutputDamageTracker::from_output(&output);
    // For this spike we do full-frame clears instead.

    while running.load(Ordering::SeqCst) {
        let frame_start = Instant::now();

        // Dispatch winit events (input, resize, close)
        let status = winit_event_loop.dispatch_new_events(|event| match event {
            WinitEvent::Resized { size, .. } => {
                let new_mode = Mode {
                    size,
                    refresh: 60_000,
                };
                output.change_current_state(Some(new_mode), None, None, None);
                output.set_preferred(new_mode);
                info!("Window resized to {}x{}", size.w, size.h);
            }
            WinitEvent::Input(event) => {
                // Input events would be processed here in production
                // For the spike we just log them
            }
            WinitEvent::Focus(focused) => {
                info!(focused, "Window focus changed");
            }
            WinitEvent::Redraw => {}
            _ => {}
        });

        if let PumpStatus::Exit(_) = status {
            info!("Winit requested exit");
            running.store(false, Ordering::SeqCst);
            break;
        }

        // Render: clear to dark gray (#333333) via GLES2
        //
        // Smithay 0.7 render API:
        //   bind()      -> (&mut Renderer, Framebuffer)
        //   render(fb, size, transform) -> Frame
        //   frame.clear(Color32F, &[Rectangle])
        //   submit(damage)  -- called after bind borrow is released
        let output_size = output.current_mode().unwrap().size;
        let dark_gray = Color32F::new(0.2, 0.2, 0.2, 1.0); // ~#333333

        // Phase 1: bind + render (borrows backend mutably)
        let render_result = backend.bind().and_then(|(renderer, mut framebuffer)| {
            let mut frame = renderer
                .render(&mut framebuffer, output_size, Transform::Normal)
                .map_err(|e| SwapBuffersError::ContextLost(Box::new(e)))?;

            frame
                .clear(dark_gray, &[Rectangle::from_size(output_size)])
                .map_err(|e| SwapBuffersError::ContextLost(Box::new(e)))?;

            Ok(())
        });

        // Phase 2: submit (separate borrow of backend)
        let render_result = render_result.and_then(|_| backend.submit(None));

        match render_result {
            Ok(_) => {}
            Err(SwapBuffersError::ContextLost(err)) => {
                error!(%err, "Critical rendering error - context lost");
                running.store(false, Ordering::SeqCst);
                break;
            }
            Err(err) => {
                warn!(%err, "Rendering error (non-fatal)");
            }
        }

        frame_count += 1;

        // Print timing stats every 5 seconds
        if last_stats_print.elapsed() >= Duration::from_secs(5) {
            let elapsed = start_time.elapsed().as_secs_f64();
            let avg_fps = frame_count as f64 / elapsed;
            let frame_time = frame_start.elapsed();
            info!(
                frames = frame_count,
                avg_fps = format!("{:.1}", avg_fps),
                last_frame_ms = format!("{:.2}", frame_time.as_secs_f64() * 1000.0),
                "Event loop timing stats"
            );
            last_stats_print = Instant::now();
        }

        // Dispatch calloop (processes Wayland client requests)
        if event_loop
            .dispatch(Some(Duration::from_millis(1)), &mut state)
            .is_err()
        {
            error!("calloop dispatch error");
            running.store(false, Ordering::SeqCst);
        } else {
            state.space.refresh();
            state.display_handle.flush_clients().unwrap();
        }
    }

    // Final stats
    let total_elapsed = start_time.elapsed().as_secs_f64();
    info!(
        total_frames = frame_count,
        total_seconds = format!("{:.1}", total_elapsed),
        avg_fps = format!("{:.1}", frame_count as f64 / total_elapsed),
        "Compositor shut down"
    );
}
