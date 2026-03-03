# R17.1: QtWebEngine Accessibility Tree API

## Context

EWWM needs to extract page element positions from qutebrowser for gaze-based
interaction. This document evaluates the accessibility tree approach versus the
userscript/FIFO approach for element discovery.

## QtWebEngine Accessibility Tree

Qt provides `QAccessibleInterface` for inspecting the accessibility tree of
`QWebEngineView` content. Each node exposes role, name, description, bounding
rect, and relationships (parent/child/sibling).

### API Surface

- `QWebEngineView::page()->runJavaScript(code, callback)` -- injects JS and
  returns the result asynchronously. Typical latency: 5-20ms per call on a
  loaded page.
- `QAccessible::queryAccessibleInterface(widget)` -- returns the root a11y
  interface for the widget. Traversal is O(n) in the number of nodes.
- `QWebEngineView` exposes the Chromium BrowserAccessibility tree via
  `BrowserAccessibilityManager`, but this is internal to QtWebEngine and not
  part of the public API.

### Latency

| Method | Typical Latency | Notes |
|--------|----------------|-------|
| `runJavaScript` | 5-20ms | One round-trip per call |
| `QAccessible` tree walk | 10-50ms | Depends on DOM size |
| Userscript FIFO | 1-5ms | Pre-computed, file write |

The accessibility tree approach requires Qt C++ code in the compositor or a
separate helper process. `runJavaScript` is simpler but requires a
round-trip to the renderer process per call.

## Accessibility Tree vs DOM Query

**Accessibility tree advantages:**
- Includes ARIA roles and computed names
- Handles shadow DOM and custom elements
- Screen reader semantics already computed

**Accessibility tree disadvantages:**
- QtWebEngine's BrowserAccessibility is not public API
- Tree structure lags behind DOM mutations (updates on next paint)
- Requires C++ code or Python bridge

**DOM query (userscript) advantages:**
- Pure JavaScript, no C++ needed
- Runs in the renderer process (fast)
- Direct access to `getBoundingClientRect()`
- Works with qutebrowser's existing userscript infrastructure

**DOM query disadvantages:**
- Must manually enumerate selectors for clickable elements
- Misses programmatic click handlers added via `addEventListener`
- Does not include ARIA computed names by default

## Comparison with Userscript FIFO

The userscript FIFO approach writes results to a named pipe that qutebrowser
monitors. The Emacs side reads the output asynchronously. This is the fastest
path because:

1. No IPC round-trip to the compositor
2. Runs directly in the Chromium renderer process
3. Output format is controlled by EWWM (JSON)
4. Compatible with all qutebrowser versions

The accessibility tree approach would require either:
- A Qt plugin loaded into qutebrowser (fragile, version-dependent)
- A separate helper using AT-SPI2 on Linux (extra process, Wayland a11y
  support still maturing)

## Recommendation

**Use the userscript FIFO approach.** It is simpler, faster, and does not
require C++ code. The accessibility tree approach is theoretically richer
but introduces significant complexity and fragility.

For ARIA semantics, the userscript can query `element.getAttribute('role')`
and `element.getAttribute('aria-label')` directly. This covers 95% of
real-world use cases without needing the full accessibility tree.

If future requirements demand full a11y tree access, the AT-SPI2 D-Bus
interface on Linux is the cleanest path forward, but it requires
qutebrowser to enable a11y exports (set `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`).
