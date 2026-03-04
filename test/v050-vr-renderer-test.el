;;; v050-vr-renderer-test.el --- VR renderer completion tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests verifying v0.5.0 VR renderer changes exist in source files.

;;; Code:

(require 'ert)

(defvar v050-vr--compositor-dir
  (expand-file-name "compositor" (file-name-directory
                                   (directory-file-name
                                    (file-name-directory
                                     (or load-file-name buffer-file-name))))))

(defun v050-vr--read-file (relative-path)
  "Read RELATIVE-PATH under compositor dir."
  (let ((path (expand-file-name relative-path v050-vr--compositor-dir)))
    (when (file-exists-p path)
      (with-temp-buffer
        (insert-file-contents path)
        (buffer-string)))))

;; --- Cargo.toml ---

(ert-deftest v050-vr/cargo-has-glow ()
  "Verify glow dependency in Cargo.toml."
  (let ((content (v050-vr--read-file "Cargo.toml")))
    (should content)
    (should (string-match-p "glow" content))))

(ert-deftest v050-vr/cargo-has-khronos-egl ()
  "Verify khronos-egl dependency in Cargo.toml."
  (let ((content (v050-vr--read-file "Cargo.toml")))
    (should content)
    (should (string-match-p "khronos-egl" content))))

(ert-deftest v050-vr/cargo-vr-feature-includes-glow ()
  "Verify vr feature includes glow."
  (let ((content (v050-vr--read-file "Cargo.toml")))
    (should content)
    (should (string-match-p "vr.*=.*glow" content))))

;; --- openxr_state.rs ---

(ert-deftest v050-vr/openxr-has-create-session ()
  "Verify create_session method exists."
  (let ((content (v050-vr--read-file "src/vr/openxr_state.rs")))
    (should content)
    (should (string-match-p "fn create_session" content))))

(ert-deftest v050-vr/openxr-has-real-poll-events ()
  "Verify poll_events uses poll_event (not stub)."
  (let ((content (v050-vr--read-file "src/vr/openxr_state.rs")))
    (should content)
    (should (string-match-p "poll_event" content))
    (should (string-match-p "SessionStateChanged" content))))

(ert-deftest v050-vr/openxr-has-tick-frame ()
  "Verify tick_frame has wait/begin/end calls."
  (let ((content (v050-vr--read-file "src/vr/openxr_state.rs")))
    (should content)
    (should (string-match-p "frame_waiter" content))
    (should (string-match-p "frame_stream" content))
    (should (string-match-p "locate_views" content))))

(ert-deftest v050-vr/openxr-has-session-fields ()
  "Verify session and swapchain fields."
  (let ((content (v050-vr--read-file "src/vr/openxr_state.rs")))
    (should content)
    (should (string-match-p "session:.*Option<xr::Session" content))
    (should (string-match-p "swapchains:" content))
    (should (string-match-p "swapchain_images:" content))))

(ert-deftest v050-vr/openxr-session-begin-end ()
  "Verify session.begin and session.end in state changes."
  (let ((content (v050-vr--read-file "src/vr/openxr_state.rs")))
    (should content)
    (should (string-match-p "session\\.begin" content))
    (should (string-match-p "session\\.end" content))))

(ert-deftest v050-vr/openxr-has-vr-frame-data ()
  "Verify VrFrameData struct."
  (let ((content (v050-vr--read-file "src/vr/openxr_state.rs")))
    (should content)
    (should (string-match-p "struct VrFrameData" content))
    (should (string-match-p "predicted_display_time" content))))

;; --- vr_renderer.rs ---

(ert-deftest v050-vr/renderer-has-glow ()
  "Verify renderer uses glow."
  (let ((content (v050-vr--read-file "src/vr/vr_renderer.rs")))
    (should content)
    (should (string-match-p "glow" content))
    (should (string-match-p "glow::Context" content))))

(ert-deftest v050-vr/renderer-has-shader-sources ()
  "Verify shader source constants."
  (let ((content (v050-vr--read-file "src/vr/vr_renderer.rs")))
    (should content)
    (should (string-match-p "VERTEX_SHADER" content))
    (should (string-match-p "FRAGMENT_SHADER" content))
    (should (string-match-p "u_mvp" content))
    (should (string-match-p "u_alpha" content))
    (should (string-match-p "u_tex" content))))

(ert-deftest v050-vr/renderer-has-init-gl ()
  "Verify init_gl method exists."
  (let ((content (v050-vr--read-file "src/vr/vr_renderer.rs")))
    (should content)
    (should (string-match-p "fn init_gl" content))))

(ert-deftest v050-vr/renderer-has-gl-resources ()
  "Verify GL resource fields."
  (let ((content (v050-vr--read-file "src/vr/vr_renderer.rs")))
    (should content)
    (should (string-match-p "gl:.*Option<glow::Context>" content))
    (should (string-match-p "program:.*Option<glow::Program>" content))
    (should (string-match-p "fbo:.*Option<glow::Framebuffer>" content))))

(ert-deftest v050-vr/renderer-has-render-to-swapchains ()
  "Verify render_frame_to_swapchains method."
  (let ((content (v050-vr--read-file "src/vr/vr_renderer.rs")))
    (should content)
    (should (string-match-p "fn render_frame_to_swapchains" content))))

(ert-deftest v050-vr/renderer-has-quad-geometry ()
  "Verify quad geometry constants."
  (let ((content (v050-vr--read-file "src/vr/vr_renderer.rs")))
    (should content)
    (should (string-match-p "QUAD_VERTICES" content))
    (should (string-match-p "QUAD_INDICES" content))))

;; --- texture.rs ---

(ert-deftest v050-vr/texture-has-gl-import ()
  "Verify texture.rs has GL import method."
  (let ((content (v050-vr--read-file "src/vr/texture.rs")))
    (should content)
    (should (string-match-p "fn import_pending_gl" content))))

(ert-deftest v050-vr/texture-has-create-texture ()
  "Verify texture.rs uses gl.create_texture."
  (let ((content (v050-vr--read-file "src/vr/texture.rs")))
    (should content)
    (should (string-match-p "create_texture" content))))

(ert-deftest v050-vr/texture-has-gl-cleanup ()
  "Verify texture.rs has GL cleanup method."
  (let ((content (v050-vr--read-file "src/vr/texture.rs")))
    (should content)
    (should (string-match-p "fn unregister_surface_gl" content))
    (should (string-match-p "delete_texture" content))))

(provide 'v050-vr-renderer-test)

;;; v050-vr-renderer-test.el ends here
