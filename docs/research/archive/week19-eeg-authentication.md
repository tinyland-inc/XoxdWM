# EEG Biometric Authentication: Literature Survey

## Overview

Brainwave-based biometric authentication uses the unique electrical
patterns of an individual's brain as an identity credential. Unlike
fingerprints or iris scans, EEG biometrics are difficult to spoof
(you cannot replicate someone's neural activity) and are inherently
liveness-detecting (the signal only exists in a living, conscious brain).

This survey evaluates EEG authentication for integration with EXWM-VR's
existing credential management (ewwm-secrets, ewwm-vr-secure-input) and
gaze+pinch authentication explored in earlier weeks.

## EEG as a Biometric Modality

### Properties

- **Universality**: all individuals with normal brain function produce EEG
- **Uniqueness**: brain connectivity patterns, cortical folding, and neural
  dynamics differ between individuals even for identical stimuli
- **Non-volitional component**: resting-state EEG contains identity markers
  that do not require conscious effort to produce
- **Liveness**: impossible to present a recorded signal through electrodes
  on a living scalp without the brain generating its own concurrent signal
- **Cancellable**: unlike fingerprints, the template can be revoked by
  changing the stimulus protocol or feature extraction method

### Signal Characteristics

EEG biometric features typically leverage:

- **Spectral power**: relative and absolute power in standard bands
  (delta 1-4 Hz, theta 4-8 Hz, alpha 8-13 Hz, beta 13-30 Hz, gamma 30+ Hz)
- **Coherence**: phase synchronization between electrode pairs, reflecting
  structural connectivity
- **Autoregressive coefficients**: AR model parameters capture temporal
  dynamics unique to each individual
- **Connectivity matrices**: functional connectivity (PLV, coherence, mutual
  information) across all channel pairs

## Key Paradigms

### Resting State (Eyes Open / Eyes Closed)

The simplest paradigm: the user sits still for 30-120 seconds.

- **Eyes closed alpha**: strong individual differences in alpha rhythm
  (frequency, amplitude, topography)
- **Reported accuracy**: 85-95% with 8+ channels (Campisi & La Rocca 2014)
- **Advantages**: no stimulus apparatus, minimal user effort
- **Disadvantages**: mental state dependent (drowsiness, caffeine, stress
  alter the signal); lower accuracy than stimulus-driven paradigms
- **Channel requirements**: minimum 4 (Fp1/Fp2, O1/O2); 8+ preferred

### Visual Evoked Potentials (VEP)

User views a specific visual stimulus (flashing checkerboard, face images).

- **SSVEP-based**: steady-state VEP at specific frequencies; individual
  differences in harmonic content and latency
- **Face-evoked N170**: the N170 ERP component to face stimuli has
  individual amplitude and latency characteristics
- **Reported accuracy**: 90-98% (Marcel & Millan 2007, Palaniappan 2008)
- **Advantages**: stronger signal, less state-dependent, shorter trials
- **Disadvantages**: requires stimulus presentation (monitor/HMD)
- **Channel requirements**: 4-8 (occipital focus for VEP, temporal for N170)

### Motor Imagery

User imagines specific movements (left hand, right hand, feet, tongue).

- **Mu/beta desynchronization**: individual patterns of sensorimotor rhythm
  change during imagery
- **Reported accuracy**: 80-92% as biometric (lower than other paradigms)
- **Advantages**: no external stimulus needed, covert authentication
- **Disadvantages**: requires training, high inter-session variability
- **Channel requirements**: 8+ (C3, C4, Cz essential)

### Cognitive Tasks

User performs mental arithmetic, word association, or spatial navigation.

- **Multimodal features**: combines spectral, temporal, and connectivity
- **Reported accuracy**: 88-96% (Ruiz-Blondet et al. 2016 "CEREBRE")
- **Advantages**: difficult to coerce (must perform specific mental task)
- **Disadvantages**: user burden, variable effort

## Feature Extraction Methods

### Power Spectral Density (PSD)

```
Signal -> Welch's method (overlapping segments) -> PSD estimate
       -> Extract power in {delta, theta, alpha, beta, gamma}
       -> Normalize (relative power) -> Feature vector
```

Typical feature vector: 5 bands x N channels = 5N features.
For 8 channels: 40-dimensional feature vector.

### Autoregressive (AR) Coefficients

```
Signal -> Fit AR model (order 6-20, Burg method)
       -> Extract coefficients -> Feature vector
```

AR coefficients capture temporal dynamics. Order selection via AIC/BIC.
For order 10, 8 channels: 80-dimensional feature vector.

### Connectivity Features

```
Signal -> Compute pairwise coherence/PLV -> Connectivity matrix
       -> Vectorize upper triangle -> Feature vector
```

For 8 channels: 28 pairs x 5 bands = 140 features (coherence) or
28 features (broadband PLV).

### Deep Learning (EEGNet)

EEGNet (Lawhern et al. 2018) is a compact CNN for EEG classification:

- Temporal convolution -> depthwise spatial convolution -> separable conv
- Works directly on raw EEG (minimal preprocessing)
- Generalizes across paradigms with architecture changes
- Can be trained for authentication (one-class or Siamese network)
- Deployable via ONNX in BrainFlow's MLModel

## Classification Approaches

### Support Vector Machine (SVM)

- RBF kernel on PSD or AR features
- One-vs-all for multi-user; one-class SVM for single user
- Robust to small training sets (5-10 sessions)
- Reported EER (equal error rate): 3-8%

### Linear Discriminant Analysis (LDA)

- Fast, interpretable, works well with connectivity features
- Regularized LDA (shrinkage) handles high-dimensional features
- Reported EER: 5-12%

### Neural Networks

- EEGNet or custom CNN on raw epochs
- Siamese network for verification (same/different person)
- Transfer learning across sessions reduces calibration burden
- Reported EER: 1-5% (with sufficient training data)

## Accuracy Summary

| Paradigm         | Channels | Classifier | Accuracy  | EER    | Source                    |
|------------------|----------|------------|-----------|--------|---------------------------|
| Resting (EC)     | 19       | SVM        | 98.1%     | 2.4%   | Campisi & La Rocca 2014   |
| Resting (EC)     | 8        | LDA        | 91.4%     | 7.2%   | La Rocca et al. 2014      |
| Resting (EC)     | 4        | SVM        | 85.3%     | 12.1%  | Estimated from literature |
| VEP (SSVEP)      | 8        | CCA+SVM    | 96.7%     | 3.1%   | Marcel & Millan 2007      |
| Face N170        | 8        | SVM        | 93.8%     | 5.4%   | Palaniappan 2008          |
| Motor Imagery    | 16       | CSP+LDA    | 88.2%     | 9.6%   | Jayarathne et al. 2017    |
| Cognitive        | 32       | CNN        | 95.4%     | 3.8%   | Ruiz-Blondet et al. 2016  |
| Resting + VEP    | 8        | Fusion     | 97.2%     | 2.8%   | Composite estimate        |

## Security Considerations

### Replay Attacks

An attacker records the victim's EEG during authentication and replays it.

- **Mitigation**: vary the stimulus on each attempt (random SSVEP
  frequency, different face images). The brain response to a novel
  stimulus cannot be predicted from a recording of a different stimulus.
- **Liveness check**: impedance monitoring detects electrode removal/reattach

### Template Storage

- Store templates as feature vectors, not raw EEG (privacy preservation)
- Encrypt templates using ewwm-secrets infrastructure (KeePassXC backend)
- Consider cancellable biometrics: transform features with a user-specific
  random projection matrix; revoke by changing the matrix

### Temporal Stability

- EEG biometrics degrade over weeks/months (5-15% accuracy drop)
- **Adaptive templates**: update the model with each successful authentication
- **Re-enrollment triggers**: accuracy monitoring with automatic recalibration
  prompt after threshold crossings

### Multi-Factor Integration

For EXWM-VR, EEG authentication works best as one factor in a multi-modal
scheme:

```
Factor 1: EEG resting-state (passive, continuous)
Factor 2: Gaze pattern on challenge stimulus (active, per-session)
Factor 3: Pinch gesture sequence (active, per-session)
```

Any two of three factors required for authentication. Continuous EEG
monitoring can trigger re-authentication if the user changes (headset
removed and replaced by different person).

## Relevance to EXWM-VR

### Implementation Path

1. **Enrollment**: 2-minute resting-state recording + 1-minute SSVEP trial
2. **Feature extraction**: PSD + coherence from BrainFlow DataFilter
3. **Template generation**: SVM one-class model per user (scikit-learn, export ONNX)
4. **Real-time verification**: continuous resting-state monitoring via
   bci_classifier.rs, periodic SSVEP challenge via VR overlay
5. **IPC**: bci-auth-enroll, bci-auth-verify, bci-auth-status
6. **Emacs**: ewwm-bci-auth.el integrating with ewwm-secrets.el

### Estimated Performance with Our Hardware

With OpenBCI Cyton (8 channels) and dry electrodes:

- Resting state alone: ~88% accuracy, ~8% EER
- Resting + SSVEP: ~94% accuracy, ~5% EER
- With adaptive templates (1 month): ~91% accuracy, ~6% EER

Acceptable as a secondary factor, not sole authentication method.

## References

- Campisi, P., & La Rocca, D. (2014). Brain waves for automatic biometric-based user recognition. IEEE TIFS.
- Marcel, S., & Millan, J. D. R. (2007). Person authentication using brainwaves. Pattern Recognition.
- Palaniappan, R., & Mandic, D. P. (2007). Biometrics from brain electrical activity. Pattern Recognition.
- Palaniappan, R. (2008). Two-stage biometric authentication using thought activity brain waves. IJNSNS.
- Ruiz-Blondet, M. V., et al. (2016). CEREBRE: A novel method for very high accuracy event-related potential biometric identification. IEEE TIFS.
- Lawhern, V. J., et al. (2018). EEGNet: A compact convolutional neural network for EEG-based brain-computer interfaces. J. Neural Eng.
- Jayarathne, I., et al. (2017). Survey of EEG-based biometric authentication. IEEE ICAC.
