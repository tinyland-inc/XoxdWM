# BCI Framework Survey for EXWM-VR Integration

## Overview

This document surveys the major open-source BCI (Brain-Computer Interface)
frameworks considered for Week 19 integration into EXWM-VR. The goal is
real-time EEG signal processing embedded in a Wayland compositor workflow,
not offline scientific analysis. We need low latency, board abstraction
across consumer hardware, and a path to Rust/C FFI.

## BrainFlow

**Repository**: <https://github.com/brainflow-dev/brainflow>
**License**: MIT (core), BSD-3-Clause (bindings)
**Language**: C++ core with bindings for Python, Java, C#, R, Rust, Julia

### Architecture

BrainFlow is structured as three libraries:

- **BoardShim**: board abstraction layer; uniform API for streaming from
  any supported device. Handles USB/Bluetooth/Wi-Fi transport.
- **DataFilter**: signal processing; bandpass, notch, IIR/FIR, FFT, DWT
  (discrete wavelet transform), detrend, downsampling.
- **MLModel**: built-in classifiers for concentration/relaxation (random
  forest trained on public datasets). Extensible via ONNX.

### Supported Hardware

- OpenBCI: Cyton (8ch), Cyton+Daisy (16ch), Ganglion (4ch), WiFi Shield
- Muse: 2016, 2, S (via Bluetooth LE)
- NeuroSky: MindWave Mobile
- BrainBit, Callibri, Notion (Neurosity)
- Synthetic board: generates test data for development without hardware
- Streaming board: accepts LSL or raw TCP input

### Signal Processing Pipeline

```
Raw EEG -> Notch (50/60 Hz) -> Bandpass (1-50 Hz) -> Epoch
         -> FFT / Wavelet -> Band Power Extraction
         -> Feature Vector -> Classifier
```

Key functions:
- `perform_bandpass(data, fs, low, high, order, filter_type, ripple)`
- `perform_fft(data, window)` returns complex spectrum
- `perform_wavelet_transform(data, wavelet, level)` returns coefficients
- `get_band_power(fft_data, fs, low, high)` extracts alpha/beta/theta/etc
- `perform_ica(data, channels, components)` independent component analysis

### Real-Time Performance

- Streaming latency: <10ms (USB), <30ms (BLE)
- DataFilter operations: microsecond-range for single-channel FFT
- Ring buffer architecture: configurable depth, no-copy access
- Thread-safe: BoardShim runs acquisition on background thread

### Rust Bindings

The `brainflow` crate wraps the C++ library via C FFI. API mirrors the
Python bindings closely. Example:

```rust
use brainflow::{BoardShim, BrainFlowPresets, BoardIds};

let params = BrainFlowInputParams::default();
let board = BoardShim::new(BoardIds::CytonBoard, params)?;
board.prepare_session()?;
board.start_stream(45000, "")?;
// ... poll data ...
let data = board.get_board_data(Some(256))?; // last 256 samples
board.stop_stream()?;
board.release_session()?;
```

### Why BrainFlow for EXWM-VR

- Board abstraction means users can swap hardware without code changes
- Rust FFI path exists and is maintained
- Real-time first: ring buffer, background thread, low-latency design
- Signal processing built-in: no need for separate DSP library
- Synthetic board enables development and testing without hardware
- Active maintenance: regular releases, responsive maintainers

## OpenViBE

**Repository**: <https://gitlab.inria.fr/openvibe/openvibe>
**License**: AGPLv3 (core), various for plugins
**Language**: C++ with visual programming GUI

### Architecture

OpenViBE uses a visual dataflow model: processing is defined by connecting
"boxes" (nodes) via "links" (edges) in a GUI designer. Each box is a C++
plugin implementing an algorithm. A kernel manages scheduling, clock, and
inter-box communication.

### Paradigm Support

OpenViBE has the broadest built-in BCI paradigm support:

- **P300 Speller**: row/column flashing, xDAWN spatial filter, LDA/SVM
- **SSVEP**: frequency tagging, CCA (canonical correlation analysis)
- **Motor Imagery**: CSP (common spatial patterns), LDA, online adaptation
- **Neurofeedback**: band-power feedback loops
- **ERP**: event-related potential detection and averaging

### Limitations for EXWM-VR

- **GUI dependency**: the designer requires GTK; headless execution is
  possible but configuration still requires the GUI
- **GPL license**: AGPLv3 complicates linking with our MIT-licensed code
- **No Rust bindings**: C++ plugin API only, would need custom FFI bridge
- **Batch-oriented**: despite real-time capability, the box scheduling
  adds latency (typically 20-50ms per pipeline step)
- **Maintenance**: development has slowed; last major release was 2022

### When to Consider

OpenViBE remains valuable for rapid BCI paradigm prototyping. If we need
to evaluate a new paradigm (e.g., P300-based window selection), prototyping
in OpenViBE first, then reimplementing the pipeline in BrainFlow, is a
reasonable workflow.

## MNE-Python

**Repository**: <https://github.com/mne-tools/mne-python>
**License**: BSD-3-Clause
**Language**: Python (NumPy/SciPy core)

### Capabilities

MNE-Python is the gold standard for EEG/MEG analysis in neuroscience:

- **Preprocessing**: ICA (artifact removal), SSP (signal-space projection),
  PSD estimation, time-frequency analysis (Morlet wavelets, multitaper)
- **Source Localization**: MNE, dSPM, sLORETA, beamforming
- **Statistics**: cluster-based permutation tests, ANOVA, regression
- **Visualization**: topographic maps, source plots, time-frequency images
- **File Format Support**: EDF, BDF, GDF, FIFF, EEGLab, BrainVision

### MNE-Realtime

The `mne-realtime` subpackage provides:

- LSL client for real-time streaming
- `RtEpochs`: online epoch extraction with event triggers
- `StimServer` / `StimClient`: network-based stimulus delivery
- Integration with `mne.decoding` for online classification

### Limitations for EXWM-VR

- **Python-only**: no path to Rust integration without subprocess or IPC
- **Analysis-focused**: the core library assumes batch processing; real-time
  is an add-on with higher latency than BrainFlow
- **Heavy dependencies**: NumPy, SciPy, matplotlib, Qt for visualization
- **Startup time**: importing MNE takes several seconds

### Complementary Role

MNE-Python is ideal for offline analysis tasks within EXWM-VR:

- Calibration data analysis and visualization
- Developing and validating new classifiers before porting to Rust
- Generating EEG quality reports for users
- Research and experimentation in Org-mode notebooks

We could expose MNE via an `ewwm-bci-analysis.el` module that shells out
to Python scripts for non-real-time tasks.

## Lab Streaming Layer (LSL)

**Repository**: <https://github.com/sccn/liblsl>
**License**: MIT
**Language**: C/C++ core with bindings for Python, Java, C#, MATLAB, Rust

### Architecture

LSL is a networking protocol for streaming time-series data between
applications. It provides:

- **Stream discovery**: mDNS-like resolution of available streams on LAN
- **Time synchronization**: sub-millisecond clock sync across machines
- **Data transport**: TCP (reliable) + UDP (low-latency) hybrid
- **Chunk transfer**: efficient bulk transfer with timestamps

### Relationship to BrainFlow

BrainFlow and LSL are complementary:

- BrainFlow can output to LSL (`board.start_stream(buffer, "streaming_board://225.1.1.1:6677")`)
- BrainFlow's streaming board can receive LSL input
- LSL enables multi-device synchronization (EEG + eye tracker + IMU)

### Use Cases for EXWM-VR

- **Multi-device sync**: synchronize EEG with Monado eye tracking data
  and hand tracking IMU for multimodal BCI
- **Network streaming**: stream BCI data from a dedicated acquisition
  machine to the compositor host
- **Recording**: LabRecorder captures all LSL streams to XDF files for
  offline analysis in MNE-Python
- **Inter-process**: share BCI state between compositor (Rust) and Emacs
  (Elisp) via LSL rather than our custom IPC

### Rust Support

The `lsl-rs` crate provides Rust bindings:

```rust
use lsl::{StreamInlet, resolve_stream};

let streams = resolve_stream("type", "EEG", 1, 5.0);
let inlet = StreamInlet::new(&streams[0], 360, 0, true)?;
let mut sample = vec![0.0f32; 8];
let timestamp = inlet.pull_sample(&mut sample, 1.0)?;
```

## Comparison Table

| Feature              | BrainFlow      | OpenViBE       | MNE-Python    | LSL           |
|----------------------|----------------|----------------|---------------|---------------|
| Primary language     | C++            | C++            | Python        | C/C++         |
| Rust bindings        | Yes (crate)    | No             | No            | Yes (crate)   |
| License              | MIT/BSD        | AGPLv3         | BSD-3         | MIT           |
| Real-time latency    | <10ms          | 20-50ms        | 50-200ms      | <5ms          |
| Board abstraction    | Yes (30+ boards)| Limited       | No            | No (transport)|
| Signal processing    | Built-in       | Plugin boxes   | Comprehensive | None          |
| BCI paradigms        | Concentration  | P300/SSVEP/MI  | All (offline) | None          |
| OpenBCI support      | Native         | Via LSL        | Via LSL/file  | Via BrainFlow |
| Setup complexity     | Low            | High (GUI)     | Medium        | Low           |
| Active maintenance   | Yes (2024+)    | Slow           | Yes (2024+)   | Yes (2024+)   |
| Headless operation   | Yes            | Difficult      | Yes           | Yes           |
| Embeddability        | High (library) | Low (app)      | Low (Python)  | High (library)|

## Recommended Architecture for EXWM-VR

```
 OpenBCI Cyton (USB)
       |
   BrainFlow (Rust FFI)
       |
  Signal Processing (bandpass, notch, FFT)
       |
  Feature Extraction (band power, ratios)
       |
  +----+----+
  |         |
  v         v
Compositor  LSL Stream (optional)
(attention  (for MNE-Python analysis,
 state,     multi-device sync,
 events)    LabRecorder)
  |
  IPC (s-expression)
  |
  Emacs (ewwm-bci-*.el)
```

### Integration Points

1. **bci_stream.rs**: BrainFlow Rust crate, board lifecycle, ring buffer
2. **bci_processor.rs**: signal processing pipeline, band power extraction
3. **bci_classifier.rs**: attention/relaxation classification, thresholds
4. **IPC commands**: bci-start, bci-stop, bci-calibrate, bci-status
5. **ewwm-bci.el**: Emacs interface, mode-line indicator, event dispatch

## Conclusion

BrainFlow is the right primary framework for EXWM-VR's real-time BCI
integration. Its board abstraction, low latency, built-in signal
processing, Rust bindings, and permissive license align perfectly with
our architecture. MNE-Python serves as an invaluable offline analysis
companion for calibration and research. LSL provides the multi-device
synchronization layer if we expand to multimodal input (EEG + eye
tracking + EMG). OpenViBE is useful only for paradigm prototyping.
