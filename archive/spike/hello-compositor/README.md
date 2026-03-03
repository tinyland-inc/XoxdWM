# hello-compositor: Smithay API Spike

Minimal Wayland compositor built with Smithay 0.7 to validate the API surface
for the EXWM-VR project. This is a throwaway spike -- production code goes in
`compositor/` starting Week 3.

## Building and Running

```bash
cargo run
# or with verbose logging:
RUST_LOG=debug cargo run
```

Connect a Wayland client in another terminal:

```bash
WAYLAND_DISPLAY=<socket printed at startup> weston-terminal
```

## Smithay API Surface Assessment

### Version Recommendation

**Smithay 0.7.0** (released 2025-06-24). This is the latest stable release and
includes significant improvements over 0.6:

- DRM syncobj support (important for VR frame timing)
- Enhanced keyboard modifier state management
- XDG toplevel tag protocol
- Improved cursor shape and X11 surface handling
- Requires Rust 1.85+, calloop 0.14, wayland-server 0.31

Pin to `smithay = "0.7"` in Cargo.toml. The project publishes infrequently
(~2 releases/year), so tracking `master` via git may be needed for bug fixes.

### Core Abstractions

| Concept | Smithay Type | Notes |
|---------|-------------|-------|
| Event loop | `calloop::EventLoop<State>` | Re-exported from calloop 0.14 |
| Wayland display | `wayland_server::Display<State>` | Generic over compositor state |
| Compositor global | `CompositorState` | Constructor registers `wl_compositor` |
| XDG Shell global | `XdgShellState` | Constructor registers `xdg_wm_base` |
| SHM buffers | `ShmState` | Constructor registers `wl_shm` |
| Seat (input) | `SeatState<State>` | Keyboard + pointer + touch |
| Output | `Output` + `OutputManagerState` | Physical display abstraction |
| Window management | `Space<Window>` | 2D element tracking, z-order, damage |
| Rendering | `GlesRenderer` | GLES2 via EGL; also Pixman software path |

### Trait Delegation Pattern

Smithay uses a "handler trait + delegate macro" pattern. For each Wayland
protocol you support, you:

1. Implement a handler trait on your state struct (e.g. `CompositorHandler`)
2. Call the corresponding delegate macro (e.g. `delegate_compositor!(State)`)

This generates the wayland-server dispatch glue. The pattern is consistent
across all protocols -- once you understand one, the rest follow the same shape.

**Minimum viable globals for a compositor:**
- `CompositorHandler` + `BufferHandler` (surface management)
- `XdgShellHandler` (window lifecycle)
- `ShmHandler` (CPU-side buffer sharing)
- `SeatHandler` (input device management)

### calloop Integration Patterns

calloop is the backbone event loop. Key patterns observed:

1. **Shared mutable state**: `EventLoop<State>` gives `&mut State` in all
   callbacks. No `Rc<RefCell<>>` needed -- calloop's design eliminates it.

2. **Source registration**: The Wayland display is inserted as a `Generic`
   calloop source with `Interest::READ`. Each dispatch drains the socket.

3. **Timer sources**: `calloop::timer::Timer` for frame scheduling. VR reprojection
   deadlines can use this.

4. **Channel sources**: `calloop::channel::Channel` for cross-thread communication
   (e.g., receiving OpenXR frame timing from a render thread).

5. **Composition**: Multiple sources compose naturally. The pattern for adding
   new event sources (DRM, libinput, timers) is always:
   ```rust
   event_loop.handle().insert_source(source, |event, _, state| { ... });
   ```

### Patterns from Anvil and Niri

#### From Anvil (Smithay's reference compositor)

- **Backend abstraction**: Anvil uses a `Backend` trait with implementations for
  Winit, X11, and udev/DRM. The state struct is generic: `AnvilState<B: Backend>`.
  We should follow this pattern for Winit-dev vs DRM-production vs VR backends.

- **Damage tracking**: `OutputDamageTracker` computes minimal repaint regions.
  Critical for VR where we must hit frame deadlines.

- **DMA-buf import**: `DmabufState` handles GPU buffer sharing. Required for
  zero-copy texture paths in VR passthrough.

- **XWayland startup**: `state.start_xwayland()` after init. Important for
  running X11 apps (which is EXWM-VR's primary use case).

#### From Niri (production Smithay compositor)

- **Module organization**: Niri splits into `backend/`, `input/`, `render/`,
  `layout/` modules. Each implements Smithay handler traits for the central
  `Niri` struct. Good model for our codebase.

- **Config crate separation**: Niri puts config parsing in a separate crate
  (`niri-config`). We should do the same for EXWM-VR settings.

- **IPC crate**: Niri defines a JSON IPC protocol in `niri-ipc`. We will need
  similar for Emacs <-> compositor communication.

- **Backend abstraction**: Niri has `winit` (development) and `tty` (production)
  backends, matching our planned Winit-dev / DRM-prod split.

- **No Rc/RefCell**: Both Niri and Anvil avoid interior mutability by leveraging
  calloop's `&mut State` callback pattern. We should maintain this discipline.

### Rendering Pipeline

The Winit backend provides a `WinitGraphicsBackend<GlesRenderer>` that combines:
- Window management (resize, close events)
- EGL context creation
- GLES2 rendering surface

The render cycle is:
```
backend.bind() -> (renderer, framebuffer)
renderer.render(size, transform, |renderer, frame| { frame.clear(...) })
backend.submit(damage_regions)
```

For VR, we will replace `backend.submit()` with texture submission to OpenXR,
but the `renderer.render()` pattern stays the same.

### Key Takeaways for Week 3

1. **Use Smithay 0.7.0** from crates.io. It is stable and well-documented
   through the anvil example.

2. **State struct design**: Single struct holding all `*State` objects. Generic
   over backend type. No Rc/RefCell.

3. **Handler traits are the API contract**: Plan which protocols to support
   early. Each protocol = one handler trait + one delegate macro.

4. **calloop is non-negotiable**: It is deeply integrated into Smithay. Our VR
   frame timing, input handling, and IPC must all be calloop sources.

5. **Space<Window> for 2D layout**: Even in VR, windows exist in a 2D logical
   space before being projected onto 3D surfaces. Use `Space` as the source of
   truth.

6. **XWayland is straightforward**: Smithay handles the X11 bridge. We just need
   to call `start_xwayland()` and implement the `XWayland*Handler` traits.

7. **DMA-buf for zero-copy VR**: Essential for performance. Smithay's
   `DmabufState` gives us the plumbing; we map those buffers as OpenXR textures.

8. **Damage tracking matters for VR**: `OutputDamageTracker` tells us which
   window regions changed, so we only re-render affected VR panels.
