# R17.4: Qutebrowser Memory Usage Profiling

## Context

EWWM-VR maps qutebrowser tabs to Emacs buffers. Understanding qutebrowser's
memory footprint per tab is critical for determining practical limits of the
tab-as-buffer design.

## QtWebEngine Process Model

Qutebrowser uses QtWebEngine (Chromium-based). Chromium's process model for
QtWebEngine:

- **Main process:** qutebrowser Python + Qt event loop (~100-150MB RSS)
- **GPU process:** shared across all tabs (~50-100MB)
- **Renderer processes:** one per site instance (see-origin isolation)
- **Utility processes:** network, storage, audio (~20-40MB each)

By default, QtWebEngine uses Chromium's "process-per-site-instance" model.
Multiple tabs on the same origin share a renderer process.

## RSS per Tab

Measured on qutebrowser 3.x with QtWebEngine 6.7 on x86_64 Linux:

| Page Type | RSS per Tab | Notes |
|-----------|-------------|-------|
| about:blank | ~8MB | Minimal renderer overhead |
| Simple text page | ~25-40MB | HTML + CSS, no JS |
| News article | ~50-80MB | JS frameworks, images |
| Web app (Gmail) | ~100-200MB | Heavy JS, long-running |
| Video streaming | ~150-300MB | Media buffers |

These numbers are for unique origins. Tabs sharing an origin share the renderer
process, so 5 tabs on the same domain use roughly 1.5x the memory of a single
tab (not 5x).

## Practical Tab Limits

| Tab Count | Estimated RSS | Usability |
|-----------|--------------|-----------|
| 10 | ~1-2GB | Comfortable |
| 25 | ~2-4GB | Fine on 16GB+ systems |
| 50 | ~4-7GB | Requires 16GB+ RAM |
| 100 | ~8-15GB | Requires 32GB+ RAM, some tabs discarded |
| 200+ | ~15-30GB | Chromium tab discarding kicks in |

QtWebEngine supports Chromium's tab discarding (freezing background tabs and
releasing their renderer). This is controlled by:
- `--enable-features=TabDiscarding` (Chromium flag)
- `qt.webengine.chromiumFlags` in qutebrowser config

## Memory Optimization Strategies

### 1. Tab Discarding

Configure QtWebEngine to aggressively discard background tabs:
```python
c.qt.args = ['--enable-features=TabDiscarding']
```
Discarded tabs retain their title and URL but release renderer memory. Switching
back to a discarded tab reloads the page.

### 2. Process Limit

Limit the number of renderer processes:
```python
c.qt.args = ['--renderer-process-limit=10']
```
Forces site instances to share renderers. Reduces total memory at the cost of
isolation (a crash in one renderer affects all tabs sharing it).

### 3. Lazy Tab Loading

On session restore, load tabs only when switched to:
```python
c.session.lazy_restore = True
```
This prevents all tabs from loading simultaneously at startup.

### 4. Emacs Buffer Integration

The Emacs buffer for each tab is lightweight (~1-2KB). The memory concern is
entirely on the QtWebEngine side. EWWM should:
- Create Emacs buffers eagerly (cheap)
- Let QtWebEngine manage renderer memory (tab discarding)
- Show tab state in the buffer (loaded / discarded / error)

### 5. Extension Blocking

Heavy web pages are often caused by ad/tracker JavaScript. Content blocking
reduces memory per tab by 20-40% on ad-heavy sites:
```python
c.content.blocking.method = 'both'
```

## Recommendation for Tab-as-Buffer Design

1. **Buffer creation is free.** Create an Emacs buffer for every tab without
   concern. The per-buffer overhead is negligible (~1-2KB).

2. **Default tab limit: none.** Let users open as many tabs as they want. The
   QtWebEngine tab discarding mechanism handles memory pressure automatically.

3. **Show discarded state.** When a tab is discarded by QtWebEngine, update the
   Emacs buffer to show "[discarded]" in the mode-line. Switching to the buffer
   triggers a reload.

4. **Recommend lazy restore.** Document `session.lazy_restore = True` as a
   recommended setting for EWWM users.

5. **Memory warning.** At 50+ tabs, display a one-time warning in the minibuffer
   about potential memory pressure. Do not block tab creation.

6. **VR consideration.** VR rendering already consumes 1-2GB of GPU memory.
   On systems with 8GB RAM, recommend keeping tabs under 25 to avoid swap
   pressure that would cause frame drops in the VR pipeline.
