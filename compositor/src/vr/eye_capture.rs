//! Bigeye eye-tracking camera capture via libuvc FFI.
//!
//! The Bigscreen Beyond Bigeye camera (35bd:0202) does not work with V4L2
//! (REQBUFS returns EINVAL).  This module uses libuvc directly via manual FFI
//! bindings to capture MJPEG frames from the dual-eye 800x400 sensor.
//!
//! The camera delivers a single 800x400 MJPEG image per frame.  The left half
//! (columns 0..400) is the left eye, and the right half (columns 400..800) is
//! the right eye.  MJPEG decoding is intentionally left to the consumer --
//! this module passes through raw MJPEG bytes for maximum flexibility.
//!
//! # Platform support
//!
//! The real `UvcEyeCapture` is only compiled on Linux (`target_os = "linux"`).
//! All other platforms get `StubEyeCapture` which satisfies the same
//! `EyeCapture` trait for testing and cross-compilation.
//!
//! # Usage
//!
//! ```rust,no_run
//! # #[cfg(target_os = "linux")]
//! # {
//! use ewwm_compositor::vr::eye_capture::{UvcEyeCapture, EyeCapture};
//! let mut capture = UvcEyeCapture::open_bigeye().unwrap();
//! capture.start_streaming().unwrap();
//! while let Ok(frame) = capture.recv_frame() {
//!     println!("frame #{}: {} bytes", frame.frame_number, frame.data.len());
//! }
//! # }
//! ```

use tracing::{debug, info, warn};

// ── Constants ────────────────────────────────────────────────

/// USB vendor ID for Bigscreen devices.
pub const BIGEYE_VID: u16 = 0x35BD;

/// USB product ID for the Bigeye eye-tracking camera.
pub const BIGEYE_PID: u16 = 0x0202;

/// Full image width (both eyes side by side).
pub const WIDTH: u32 = 800;

/// Full image height.
pub const HEIGHT: u32 = 400;

/// Width of a single eye image (left or right half).
pub const EYE_WIDTH: u32 = 400;

/// Target frame rate (the sensor runs at ~82 fps, nominal 90).
pub const FPS: u32 = 90;

/// Default channel capacity for frame delivery.
const CHANNEL_CAPACITY: usize = 4;

// ── Public types ─────────────────────────────────────────────

/// A captured frame from the Bigeye camera.
///
/// Contains the raw MJPEG-compressed image data.  The consumer is responsible
/// for decoding.  The full image is 800x400 (left eye = left half, right eye
/// = right half).
#[derive(Debug, Clone)]
pub struct EyeFrame {
    /// Raw MJPEG bytes for the full 800x400 frame.
    pub data: Vec<u8>,
    /// Frame width in pixels (always 800).
    pub width: u32,
    /// Frame height in pixels (always 400).
    pub height: u32,
    /// Monotonic frame counter (starts at 0).
    pub frame_number: u64,
    /// Timestamp from the camera (microseconds, device clock).
    pub timestamp_us: u64,
}

/// Status snapshot of the capture pipeline.
#[derive(Debug, Clone)]
pub struct EyeCaptureStatus {
    /// Whether the camera device is open.
    pub device_open: bool,
    /// Whether streaming is active.
    pub streaming: bool,
    /// Total frames received since streaming started.
    pub frames_received: u64,
    /// Total frames dropped (channel full).
    pub frames_dropped: u64,
}

impl EyeCaptureStatus {
    /// Generate an IPC s-expression for Emacs.
    pub fn to_sexp(&self) -> String {
        format!(
            "(:device-open {} :streaming {} :frames-received {} :frames-dropped {})",
            if self.device_open { "t" } else { "nil" },
            if self.streaming { "t" } else { "nil" },
            self.frames_received,
            self.frames_dropped,
        )
    }
}

/// Trait abstracting eye capture backends.
///
/// Implemented by `UvcEyeCapture` on Linux and `StubEyeCapture` elsewhere.
pub trait EyeCapture: Send {
    /// Start streaming frames from the camera.
    fn start_streaming(&mut self) -> Result<(), String>;

    /// Stop streaming.
    fn stop_streaming(&mut self);

    /// Try to receive the next frame (non-blocking).
    fn try_recv_frame(&self) -> Option<EyeFrame>;

    /// Receive the next frame (blocking).
    fn recv_frame(&self) -> Result<EyeFrame, String>;

    /// Get current status.
    fn status(&self) -> EyeCaptureStatus;

    /// Whether the device is open and ready.
    fn is_open(&self) -> bool;
}

// ── Linux: libuvc FFI + UvcEyeCapture ────────────────────────

#[cfg(target_os = "linux")]
mod linux_uvc {
    use super::*;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::mpsc;

    // ── libuvc FFI declarations ──────────────────────────────
    //
    // Manual bindings for the ~10 functions we need.  No bindgen required.
    // libuvc is loaded at link time from /usr/local/lib64/libuvc.so (or
    // wherever the system has it).

    /// libuvc error codes (subset).
    #[repr(i32)]
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    #[allow(non_camel_case_types, dead_code)]
    enum UvcError {
        UVC_SUCCESS = 0,
        UVC_ERROR_IO = -1,
        UVC_ERROR_INVALID_PARAM = -2,
        UVC_ERROR_ACCESS = -3,
        UVC_ERROR_NO_DEVICE = -4,
        UVC_ERROR_NOT_FOUND = -5,
        UVC_ERROR_BUSY = -6,
        UVC_ERROR_TIMEOUT = -7,
        UVC_ERROR_OVERFLOW = -8,
        UVC_ERROR_PIPE = -9,
        UVC_ERROR_INTERRUPTED = -10,
        UVC_ERROR_NO_MEM = -11,
        UVC_ERROR_NOT_SUPPORTED = -12,
        UVC_ERROR_INVALID_DEVICE = -13,
        UVC_ERROR_INVALID_MODE = -14,
        UVC_ERROR_CALLBACK_EXISTS = -15,
        UVC_ERROR_OTHER = -99,
    }

    impl UvcError {
        fn from_raw(code: i32) -> Self {
            match code {
                0 => UvcError::UVC_SUCCESS,
                -1 => UvcError::UVC_ERROR_IO,
                -2 => UvcError::UVC_ERROR_INVALID_PARAM,
                -3 => UvcError::UVC_ERROR_ACCESS,
                -4 => UvcError::UVC_ERROR_NO_DEVICE,
                -5 => UvcError::UVC_ERROR_NOT_FOUND,
                -6 => UvcError::UVC_ERROR_BUSY,
                -7 => UvcError::UVC_ERROR_TIMEOUT,
                -8 => UvcError::UVC_ERROR_OVERFLOW,
                -9 => UvcError::UVC_ERROR_PIPE,
                -10 => UvcError::UVC_ERROR_INTERRUPTED,
                -11 => UvcError::UVC_ERROR_NO_MEM,
                -12 => UvcError::UVC_ERROR_NOT_SUPPORTED,
                -13 => UvcError::UVC_ERROR_INVALID_DEVICE,
                -14 => UvcError::UVC_ERROR_INVALID_MODE,
                -15 => UvcError::UVC_ERROR_CALLBACK_EXISTS,
                _ => UvcError::UVC_ERROR_OTHER,
            }
        }

        fn as_str(&self) -> &'static str {
            match self {
                UvcError::UVC_SUCCESS => "success",
                UvcError::UVC_ERROR_IO => "I/O error",
                UvcError::UVC_ERROR_INVALID_PARAM => "invalid parameter",
                UvcError::UVC_ERROR_ACCESS => "access denied",
                UvcError::UVC_ERROR_NO_DEVICE => "no such device",
                UvcError::UVC_ERROR_NOT_FOUND => "not found",
                UvcError::UVC_ERROR_BUSY => "device busy",
                UvcError::UVC_ERROR_TIMEOUT => "timeout",
                UvcError::UVC_ERROR_OVERFLOW => "overflow",
                UvcError::UVC_ERROR_PIPE => "pipe error",
                UvcError::UVC_ERROR_INTERRUPTED => "interrupted",
                UvcError::UVC_ERROR_NO_MEM => "out of memory",
                UvcError::UVC_ERROR_NOT_SUPPORTED => "not supported",
                UvcError::UVC_ERROR_INVALID_DEVICE => "invalid device",
                UvcError::UVC_ERROR_INVALID_MODE => "invalid mode",
                UvcError::UVC_ERROR_CALLBACK_EXISTS => "callback already registered",
                UvcError::UVC_ERROR_OTHER => "unknown error",
            }
        }
    }

    impl std::fmt::Display for UvcError {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            write!(f, "uvc error {}: {}", *self as i32, self.as_str())
        }
    }

    /// Check a libuvc return code and convert to Result.
    fn uvc_check(code: i32, context: &str) -> Result<(), String> {
        if code == 0 {
            Ok(())
        } else {
            let err = UvcError::from_raw(code);
            Err(format!("{}: {}", context, err))
        }
    }

    /// UVC frame format enum (subset).
    #[repr(u32)]
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    #[allow(non_camel_case_types, dead_code)]
    enum UvcFrameFormat {
        UVC_FRAME_FORMAT_UNKNOWN = 0,
        // UVC_FRAME_FORMAT_ANY is an alias for UNKNOWN (both 0 in C header)
        UVC_FRAME_FORMAT_UNCOMPRESSED = 1,
        UVC_FRAME_FORMAT_COMPRESSED = 2,
        UVC_FRAME_FORMAT_YUYV = 3,
        UVC_FRAME_FORMAT_UYVY = 4,
        UVC_FRAME_FORMAT_RGB = 5,
        UVC_FRAME_FORMAT_BGR = 6,
        UVC_FRAME_FORMAT_MJPEG = 7,
        UVC_FRAME_FORMAT_GRAY8 = 8,
        UVC_FRAME_FORMAT_GRAY16 = 9,
        UVC_FRAME_FORMAT_NV12 = 14,
    }

    /// Opaque libuvc types -- we only ever use pointers to these.
    #[repr(C)]
    struct UvcContext {
        _opaque: [u8; 0],
    }

    #[repr(C)]
    struct UvcDevice {
        _opaque: [u8; 0],
    }

    #[repr(C)]
    struct UvcDeviceHandle {
        _opaque: [u8; 0],
    }

    /// uvc_stream_ctrl_t -- we need to pass this by pointer to libuvc.
    /// The actual struct is ~200 bytes; we over-allocate to be safe.
    #[repr(C)]
    struct UvcStreamCtrl {
        _data: [u8; 256],
    }

    impl UvcStreamCtrl {
        fn zeroed() -> Self {
            Self { _data: [0u8; 256] }
        }
    }

    /// uvc_frame_t -- the subset of fields we actually read.
    ///
    /// The real struct has more fields after these, but we only access
    /// data, data_bytes, width, height, and frame_format via offsets.
    /// libuvc guarantees these are the first fields in the struct.
    #[repr(C)]
    struct UvcFrame {
        /// Pointer to image data.
        data: *mut libc::c_void,
        /// Number of bytes in data.
        data_bytes: libc::size_t,
        /// Image width.
        width: u32,
        /// Image height.
        height: u32,
        /// Pixel format.
        frame_format: u32,
        // step, sequence, capture_time, ... (we don't access these)
        _step: libc::size_t,
        _sequence: u32,
        _capture_time_tv_sec: libc::c_long,
        _capture_time_tv_usec: libc::c_long,
        // ... more fields we don't need
    }

    /// Frame callback type matching libuvc's signature.
    type UvcFrameCallbackT =
        unsafe extern "C" fn(frame: *mut UvcFrame, user_ptr: *mut libc::c_void);

    // ── libuvc extern declarations ───────────────────────────

    #[link(name = "uvc")]
    extern "C" {
        fn uvc_init(ctx: *mut *mut UvcContext, usb_ctx: *mut libc::c_void) -> i32;

        fn uvc_exit(ctx: *mut UvcContext);

        fn uvc_find_device(
            ctx: *mut UvcContext,
            dev: *mut *mut UvcDevice,
            vid: i32,
            pid: i32,
            serial: *const libc::c_char,
        ) -> i32;

        fn uvc_open(dev: *mut UvcDevice, devh: *mut *mut UvcDeviceHandle) -> i32;

        fn uvc_close(devh: *mut UvcDeviceHandle);

        fn uvc_unref_device(dev: *mut UvcDevice);

        fn uvc_get_stream_ctrl_format_size(
            devh: *mut UvcDeviceHandle,
            ctrl: *mut UvcStreamCtrl,
            format: u32,
            width: i32,
            height: i32,
            fps: i32,
        ) -> i32;

        fn uvc_start_streaming(
            devh: *mut UvcDeviceHandle,
            ctrl: *mut UvcStreamCtrl,
            cb: UvcFrameCallbackT,
            user_ptr: *mut libc::c_void,
            flags: u8,
        ) -> i32;

        fn uvc_stop_streaming(devh: *mut UvcDeviceHandle);
    }

    // ── Callback state ───────────────────────────────────────

    /// Shared state between the libuvc callback thread and the consumer.
    ///
    /// Allocated on the heap and passed to the callback as a raw pointer
    /// via `Box::into_raw`.  Reclaimed on stop via `Box::from_raw`.
    struct CallbackState {
        /// Channel sender for delivering frames.
        tx: mpsc::SyncSender<EyeFrame>,
        /// Monotonic frame counter.
        frame_count: AtomicU64,
        /// Number of frames dropped because the channel was full.
        frames_dropped: AtomicU64,
        /// Flag to signal the callback to stop copying data.
        active: AtomicBool,
    }

    /// The C callback invoked by libuvc on its internal USB thread.
    ///
    /// # Safety
    ///
    /// - `frame` is valid for the duration of this call (guaranteed by libuvc).
    /// - `user_ptr` is a `Box<CallbackState>` that was leaked via `Box::into_raw`.
    /// - We only read from `frame` and send a copy via the channel.
    unsafe extern "C" fn frame_callback(frame: *mut UvcFrame, user_ptr: *mut libc::c_void) {
        if frame.is_null() || user_ptr.is_null() {
            return;
        }

        let state = &*(user_ptr as *const CallbackState);

        if !state.active.load(Ordering::Relaxed) {
            return;
        }

        let frame_ref = &*frame;

        // Validate frame data.
        if frame_ref.data.is_null() || frame_ref.data_bytes == 0 {
            return;
        }

        // Copy the MJPEG data out of libuvc's buffer.
        let data_slice =
            std::slice::from_raw_parts(frame_ref.data as *const u8, frame_ref.data_bytes);
        let data = data_slice.to_vec();

        let frame_number = state.frame_count.fetch_add(1, Ordering::Relaxed);

        // Compute a microsecond timestamp from capture_time.
        let timestamp_us = (frame_ref._capture_time_tv_sec as u64)
            .wrapping_mul(1_000_000)
            .wrapping_add(frame_ref._capture_time_tv_usec as u64);

        let eye_frame = EyeFrame {
            data,
            width: frame_ref.width,
            height: frame_ref.height,
            frame_number,
            timestamp_us,
        };

        // Non-blocking send: drop frame if consumer is behind.
        match state.tx.try_send(eye_frame) {
            Ok(()) => {}
            Err(mpsc::TrySendError::Full(_)) => {
                state.frames_dropped.fetch_add(1, Ordering::Relaxed);
            }
            Err(mpsc::TrySendError::Disconnected(_)) => {
                // Consumer dropped the receiver -- stop sending.
                state.active.store(false, Ordering::Relaxed);
            }
        }
    }

    // ── UvcEyeCapture ────────────────────────────────────────

    /// Eye-tracking camera capture using libuvc.
    ///
    /// Manages the full lifecycle: uvc_init -> find_device -> open ->
    /// negotiate format -> start_streaming -> deliver frames via channel
    /// -> stop_streaming -> close -> exit.
    pub struct UvcEyeCapture {
        ctx: *mut UvcContext,
        dev: *mut UvcDevice,
        devh: *mut UvcDeviceHandle,
        /// Receiver end of the frame channel.
        rx: Option<mpsc::Receiver<EyeFrame>>,
        /// Raw pointer to the callback state (owned, reclaimed on stop).
        callback_state: *mut CallbackState,
        /// Whether streaming is currently active.
        streaming: bool,
    }

    // Safety: the raw pointers are only accessed from methods that enforce
    // proper sequencing.  The channel itself is Send-safe.
    unsafe impl Send for UvcEyeCapture {}

    impl UvcEyeCapture {
        /// Initialize libuvc and open the Bigeye camera (35bd:0202).
        ///
        /// Returns an error if libuvc cannot be initialized, the device is
        /// not found, or the device cannot be opened.
        pub fn open_bigeye() -> Result<Self, String> {
            let mut ctx: *mut UvcContext = std::ptr::null_mut();
            let mut dev: *mut UvcDevice = std::ptr::null_mut();
            let mut devh: *mut UvcDeviceHandle = std::ptr::null_mut();

            // Initialize libuvc context.
            let ret = unsafe { uvc_init(&mut ctx, std::ptr::null_mut()) };
            uvc_check(ret, "uvc_init")?;
            info!(
                "eye_capture: libuvc initialized (vid=0x{:04X} pid=0x{:04X})",
                BIGEYE_VID, BIGEYE_PID
            );

            // Find the Bigeye device.
            let ret = unsafe {
                uvc_find_device(
                    ctx,
                    &mut dev,
                    BIGEYE_VID as i32,
                    BIGEYE_PID as i32,
                    std::ptr::null(),
                )
            };
            if ret != 0 {
                unsafe { uvc_exit(ctx) };
                return Err(format!(
                    "uvc_find_device: Bigeye camera {:04X}:{:04X} not found ({})",
                    BIGEYE_VID,
                    BIGEYE_PID,
                    UvcError::from_raw(ret),
                ));
            }
            info!("eye_capture: found Bigeye camera");

            // Open the device.
            let ret = unsafe { uvc_open(dev, &mut devh) };
            if ret != 0 {
                let err = UvcError::from_raw(ret);
                unsafe {
                    uvc_unref_device(dev);
                    uvc_exit(ctx);
                }
                return Err(format!("uvc_open: {}", err));
            }
            info!("eye_capture: device opened");

            Ok(Self {
                ctx,
                dev,
                devh,
                rx: None,
                callback_state: std::ptr::null_mut(),
                streaming: false,
            })
        }

        /// Get the total number of frames received (including dropped).
        fn total_frames_received(&self) -> u64 {
            if self.callback_state.is_null() {
                return 0;
            }
            unsafe {
                let state = &*self.callback_state;
                state.frame_count.load(Ordering::Relaxed)
            }
        }

        /// Get the number of dropped frames.
        fn total_frames_dropped(&self) -> u64 {
            if self.callback_state.is_null() {
                return 0;
            }
            unsafe {
                let state = &*self.callback_state;
                state.frames_dropped.load(Ordering::Relaxed)
            }
        }
    }

    impl EyeCapture for UvcEyeCapture {
        fn start_streaming(&mut self) -> Result<(), String> {
            if self.streaming {
                warn!("eye_capture: already streaming");
                return Ok(());
            }
            if self.devh.is_null() {
                return Err("eye_capture: device not open".to_string());
            }

            // Negotiate the stream format: MJPEG, 800x400, 90fps.
            let mut ctrl = UvcStreamCtrl::zeroed();
            let ret = unsafe {
                uvc_get_stream_ctrl_format_size(
                    self.devh,
                    &mut ctrl,
                    UvcFrameFormat::UVC_FRAME_FORMAT_MJPEG as u32,
                    WIDTH as i32,
                    HEIGHT as i32,
                    FPS as i32,
                )
            };
            uvc_check(ret, "uvc_get_stream_ctrl_format_size")?;
            info!(
                "eye_capture: negotiated MJPEG {}x{} @ {}fps",
                WIDTH, HEIGHT, FPS
            );

            // Create frame delivery channel.
            let (tx, rx) = mpsc::sync_channel(CHANNEL_CAPACITY);
            self.rx = Some(rx);

            // Allocate callback state and leak it to a raw pointer.
            let cb_state = Box::new(CallbackState {
                tx,
                frame_count: AtomicU64::new(0),
                frames_dropped: AtomicU64::new(0),
                active: AtomicBool::new(true),
            });
            let cb_ptr = Box::into_raw(cb_state);
            self.callback_state = cb_ptr;

            // Start streaming with our callback.
            let ret = unsafe {
                uvc_start_streaming(
                    self.devh,
                    &mut ctrl,
                    frame_callback,
                    cb_ptr as *mut libc::c_void,
                    0, // flags: 0 = auto
                )
            };
            if ret != 0 {
                // Reclaim the callback state on failure.
                unsafe { drop(Box::from_raw(cb_ptr)) };
                self.callback_state = std::ptr::null_mut();
                self.rx = None;
                return Err(format!("uvc_start_streaming: {}", UvcError::from_raw(ret)));
            }

            self.streaming = true;
            info!("eye_capture: streaming started");
            Ok(())
        }

        fn stop_streaming(&mut self) {
            if !self.streaming {
                return;
            }

            // Signal the callback to stop.
            if !self.callback_state.is_null() {
                unsafe {
                    let state = &*self.callback_state;
                    state.active.store(false, Ordering::Relaxed);
                }
            }

            // Stop libuvc streaming (blocks until callback returns).
            if !self.devh.is_null() {
                unsafe { uvc_stop_streaming(self.devh) };
            }

            // Reclaim the callback state.
            if !self.callback_state.is_null() {
                let state = unsafe { Box::from_raw(self.callback_state) };
                let received = state.frame_count.load(Ordering::Relaxed);
                let dropped = state.frames_dropped.load(Ordering::Relaxed);
                info!(
                    "eye_capture: streaming stopped (received: {}, dropped: {})",
                    received, dropped
                );
                // state is dropped here
            }
            self.callback_state = std::ptr::null_mut();

            self.streaming = false;
            self.rx = None;
        }

        fn try_recv_frame(&self) -> Option<EyeFrame> {
            self.rx.as_ref()?.try_recv().ok()
        }

        fn recv_frame(&self) -> Result<EyeFrame, String> {
            let rx = self
                .rx
                .as_ref()
                .ok_or_else(|| "eye_capture: not streaming".to_string())?;
            rx.recv()
                .map_err(|_| "eye_capture: channel closed".to_string())
        }

        fn status(&self) -> EyeCaptureStatus {
            EyeCaptureStatus {
                device_open: !self.devh.is_null(),
                streaming: self.streaming,
                frames_received: self.total_frames_received(),
                frames_dropped: self.total_frames_dropped(),
            }
        }

        fn is_open(&self) -> bool {
            !self.devh.is_null()
        }
    }

    impl Drop for UvcEyeCapture {
        fn drop(&mut self) {
            // Stop streaming first (idempotent).
            self.stop_streaming();

            // Close device handle.
            if !self.devh.is_null() {
                unsafe { uvc_close(self.devh) };
                debug!("eye_capture: device handle closed");
                self.devh = std::ptr::null_mut();
            }

            // Release device reference.
            if !self.dev.is_null() {
                unsafe { uvc_unref_device(self.dev) };
                debug!("eye_capture: device unreferenced");
                self.dev = std::ptr::null_mut();
            }

            // Tear down libuvc context.
            if !self.ctx.is_null() {
                unsafe { uvc_exit(self.ctx) };
                info!("eye_capture: libuvc context destroyed");
                self.ctx = std::ptr::null_mut();
            }
        }
    }
}

#[cfg(target_os = "linux")]
pub use linux_uvc::UvcEyeCapture;

// ── Stub implementation (non-Linux / tests) ──────────────────

/// Stub eye capture for platforms without libuvc (macOS, CI, tests).
///
/// Tracks method calls for test assertions but produces no real frames.
#[derive(Debug)]
pub struct StubEyeCapture {
    streaming: bool,
    frames_pushed: Vec<EyeFrame>,
    frame_cursor: usize,
}

impl Default for StubEyeCapture {
    fn default() -> Self {
        Self {
            streaming: false,
            frames_pushed: Vec::new(),
            frame_cursor: 0,
        }
    }
}

impl StubEyeCapture {
    /// Create a new stub capture.
    pub fn new() -> Self {
        Self::default()
    }

    /// Push a synthetic frame for testing.
    pub fn push_test_frame(&mut self, frame: EyeFrame) {
        self.frames_pushed.push(frame);
    }

    /// Create a synthetic test frame with the given frame number.
    pub fn make_test_frame(frame_number: u64) -> EyeFrame {
        // Minimal MJPEG: just SOI + EOI markers (0xFFD8 ... 0xFFD9).
        let data = vec![0xFF, 0xD8, 0xFF, 0xD9];
        EyeFrame {
            data,
            width: WIDTH,
            height: HEIGHT,
            frame_number,
            timestamp_us: frame_number * 11_111, // ~90fps spacing
        }
    }
}

impl EyeCapture for StubEyeCapture {
    fn start_streaming(&mut self) -> Result<(), String> {
        if self.streaming {
            warn!("StubEyeCapture: already streaming");
            return Ok(());
        }
        debug!("StubEyeCapture: streaming started");
        self.streaming = true;
        self.frame_cursor = 0;
        Ok(())
    }

    fn stop_streaming(&mut self) {
        if self.streaming {
            debug!("StubEyeCapture: streaming stopped");
        }
        self.streaming = false;
    }

    fn try_recv_frame(&self) -> Option<EyeFrame> {
        if !self.streaming {
            return None;
        }
        self.frames_pushed.get(self.frame_cursor).cloned()
    }

    fn recv_frame(&self) -> Result<EyeFrame, String> {
        if !self.streaming {
            return Err("StubEyeCapture: not streaming".to_string());
        }
        self.frames_pushed
            .get(self.frame_cursor)
            .cloned()
            .ok_or_else(|| "StubEyeCapture: no frames available".to_string())
    }

    fn status(&self) -> EyeCaptureStatus {
        EyeCaptureStatus {
            device_open: true,
            streaming: self.streaming,
            frames_received: self.frame_cursor as u64,
            frames_dropped: 0,
        }
    }

    fn is_open(&self) -> bool {
        true
    }
}

// ── Tests ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // -- Constants ---

    #[test]
    fn test_bigeye_vid_pid() {
        assert_eq!(BIGEYE_VID, 0x35BD);
        assert_eq!(BIGEYE_PID, 0x0202);
    }

    #[test]
    fn test_frame_dimensions() {
        assert_eq!(WIDTH, 800);
        assert_eq!(HEIGHT, 400);
        assert_eq!(EYE_WIDTH, 400);
        assert_eq!(WIDTH, EYE_WIDTH * 2);
    }

    #[test]
    fn test_fps_constant() {
        assert_eq!(FPS, 90);
    }

    // -- EyeFrame ---

    #[test]
    fn test_eye_frame_clone() {
        let frame = StubEyeCapture::make_test_frame(42);
        let cloned = frame.clone();
        assert_eq!(cloned.frame_number, 42);
        assert_eq!(cloned.width, WIDTH);
        assert_eq!(cloned.height, HEIGHT);
        assert_eq!(cloned.data, frame.data);
    }

    #[test]
    fn test_make_test_frame_is_valid_mjpeg_stub() {
        let frame = StubEyeCapture::make_test_frame(0);
        // Minimal MJPEG: starts with SOI (FFD8), ends with EOI (FFD9).
        assert!(frame.data.len() >= 4);
        assert_eq!(frame.data[0], 0xFF);
        assert_eq!(frame.data[1], 0xD8);
        assert_eq!(frame.data[frame.data.len() - 2], 0xFF);
        assert_eq!(frame.data[frame.data.len() - 1], 0xD9);
    }

    #[test]
    fn test_make_test_frame_timestamp_spacing() {
        let f0 = StubEyeCapture::make_test_frame(0);
        let f1 = StubEyeCapture::make_test_frame(1);
        let f2 = StubEyeCapture::make_test_frame(2);
        // ~11ms spacing (90fps)
        assert_eq!(f1.timestamp_us - f0.timestamp_us, 11_111);
        assert_eq!(f2.timestamp_us - f1.timestamp_us, 11_111);
    }

    // -- EyeCaptureStatus ---

    #[test]
    fn test_status_sexp_streaming() {
        let status = EyeCaptureStatus {
            device_open: true,
            streaming: true,
            frames_received: 1234,
            frames_dropped: 5,
        };
        let sexp = status.to_sexp();
        assert!(sexp.contains(":device-open t"));
        assert!(sexp.contains(":streaming t"));
        assert!(sexp.contains(":frames-received 1234"));
        assert!(sexp.contains(":frames-dropped 5"));
    }

    #[test]
    fn test_status_sexp_idle() {
        let status = EyeCaptureStatus {
            device_open: false,
            streaming: false,
            frames_received: 0,
            frames_dropped: 0,
        };
        let sexp = status.to_sexp();
        assert!(sexp.contains(":device-open nil"));
        assert!(sexp.contains(":streaming nil"));
        assert!(sexp.contains(":frames-received 0"));
        assert!(sexp.contains(":frames-dropped 0"));
    }

    // -- StubEyeCapture ---

    #[test]
    fn test_stub_default_state() {
        let stub = StubEyeCapture::new();
        assert!(!stub.streaming);
        assert!(stub.is_open());
        let status = stub.status();
        assert!(status.device_open);
        assert!(!status.streaming);
        assert_eq!(status.frames_received, 0);
    }

    #[test]
    fn test_stub_start_stop() {
        let mut stub = StubEyeCapture::new();
        stub.start_streaming().unwrap();
        assert!(stub.status().streaming);

        stub.stop_streaming();
        assert!(!stub.status().streaming);
    }

    #[test]
    fn test_stub_start_idempotent() {
        let mut stub = StubEyeCapture::new();
        stub.start_streaming().unwrap();
        // Second start should succeed (no-op).
        stub.start_streaming().unwrap();
        assert!(stub.status().streaming);
    }

    #[test]
    fn test_stub_recv_not_streaming() {
        let stub = StubEyeCapture::new();
        assert!(stub.try_recv_frame().is_none());
        assert!(stub.recv_frame().is_err());
    }

    #[test]
    fn test_stub_recv_no_frames() {
        let mut stub = StubEyeCapture::new();
        stub.start_streaming().unwrap();
        // No frames pushed yet.
        assert!(stub.try_recv_frame().is_none());
        assert!(stub.recv_frame().is_err());
    }

    #[test]
    fn test_stub_push_and_recv() {
        let mut stub = StubEyeCapture::new();
        let frame = StubEyeCapture::make_test_frame(7);
        stub.push_test_frame(frame);
        stub.start_streaming().unwrap();

        let received = stub.try_recv_frame();
        assert!(received.is_some());
        let received = received.unwrap();
        assert_eq!(received.frame_number, 7);
        assert_eq!(received.width, WIDTH);
        assert_eq!(received.height, HEIGHT);
    }

    #[test]
    fn test_stub_recv_blocking() {
        let mut stub = StubEyeCapture::new();
        stub.push_test_frame(StubEyeCapture::make_test_frame(99));
        stub.start_streaming().unwrap();

        let received = stub.recv_frame().unwrap();
        assert_eq!(received.frame_number, 99);
    }

    #[test]
    fn test_stub_stop_clears_streaming() {
        let mut stub = StubEyeCapture::new();
        stub.push_test_frame(StubEyeCapture::make_test_frame(0));
        stub.start_streaming().unwrap();

        stub.stop_streaming();
        assert!(stub.try_recv_frame().is_none());
    }
}
