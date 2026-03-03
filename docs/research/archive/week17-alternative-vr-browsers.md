# R17.2: Alternative VR-First Browsers

## Context

Qutebrowser is the primary browser target for EWWM-VR due to its keyboard-driven
design and IPC protocol. This document evaluates alternative browser engines and
projects for long-term VR browsing strategy.

## Nickel Browser (Servo-based)

Nickel is an experimental browser built on the Servo engine. Servo renders web
content using a parallel, GPU-accelerated pipeline written in Rust.

**Relevance to EWWM-VR:**
- Servo's WebRender compositor outputs to a texture, ideal for VR overlay
- Rust codebase integrates naturally with the EWWM compositor
- Embedding API (`libservo`) allows direct texture sharing via DMA-BUF

**Status (2025):** Servo development resumed under the Linux Foundation Europe.
Basic CSS and HTML rendering works. JavaScript support (via SpiderMonkey) is
functional but incomplete. Not production-ready for general browsing.

**Risk:** Servo may never reach full web compatibility. Long development timeline.

## Servo Engine Directly

Instead of Nickel, EWWM could embed `libservo` directly into the compositor.
This would give zero-copy texture access and eliminate IPC overhead for rendering.

**Advantages:**
- Direct DMA-BUF texture sharing (no compositor copy)
- Rust API, same language as the compositor
- WebRender is designed for GPU compositing

**Disadvantages:**
- Servo web compatibility is incomplete (no WebRTC, limited CSS Grid)
- Build system complexity (Servo pulls in SpiderMonkey)
- Maintenance burden of tracking upstream Servo

## Firefox Reality (Discontinued)

Firefox Reality was Mozilla's VR browser for standalone headsets. It was
discontinued in 2022 and succeeded by Wolvic (maintained by Igalia).

**Lessons learned:**
- VR text rendering needs at least 20px base font size for readability
- "Look and click" (gaze + controller trigger) outperformed pure gaze dwell
- Tab management in 3D space was confusing; 2D tab bar in a floating panel
  was preferred by users
- Performance: GeckoView on Qualcomm XR2 struggled to maintain 72fps during
  complex page layouts

**Applicable patterns:**
- Floating 2D panel for browser UI (not full 3D tabs)
- Adjustable text scaling per-site
- "Lean back" reading mode with enlarged text

## Chromium Embedded Framework (CEF)

CEF embeds the Chromium renderer as a library. It provides off-screen rendering
to a shared-memory buffer or texture.

**Advantages:**
- Full web compatibility (same as Chrome)
- Off-screen rendering to a texture (compatible with VR pipeline)
- Mature, widely used (Electron, Steam Overlay)

**Disadvantages:**
- Large binary (~200MB)
- C/C++ API, requires FFI bridge to Rust
- Chromium update cycle is aggressive (6-week releases)
- Memory overhead: each CEF instance uses 100-300MB

**Embedding approach:** CEF off-screen rendering -> DMA-BUF texture -> Smithay
compositor -> OpenXR swapchain. This is the same pipeline used by Steam VR
Overlay and SteamOS.

## Nyxt (Common Lisp)

Nyxt is a keyboard-driven browser written in Common Lisp. It uses WebKitGTK
for rendering.

**Relevance:**
- Lisp-based extensibility aligns with the Emacs philosophy
- Command interface is similar to Emacs M-x
- Highly programmable (full CL at runtime)

**Disadvantages:**
- WebKitGTK does not support off-screen rendering easily
- Common Lisp runtime adds complexity to packaging
- Small community, slow development pace
- No existing VR integration path

**Potential:** Nyxt could serve as a "browser within Emacs" if it exposed a
buffer API. However, the WebKitGTK dependency makes VR texture sharing difficult.

## Recommendation

**Short-term (Weeks 17-20):** Continue with qutebrowser. The IPC protocol,
userscript system, and QtWebEngine rendering are sufficient. Tab-as-buffer
integration provides the Emacs-native experience.

**Medium-term (6-12 months):** Evaluate CEF embedding for VR-native browsing.
CEF's off-screen rendering to a texture is the most practical path to zero-copy
VR browser compositing. The Chromium compatibility guarantee is essential.

**Long-term (1-2 years):** Monitor Servo/libservo progress. If Servo reaches
sufficient web compatibility, a Rust-native browser engine embedded directly
in the compositor would be the ideal architecture. This eliminates all IPC
overhead and gives full control over the rendering pipeline.

Nyxt is interesting philosophically but impractical for VR integration.
Firefox Reality's lessons (2D panels, large text, reading mode) should inform
our UX design regardless of which engine we use.
