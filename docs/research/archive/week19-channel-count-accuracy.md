# EEG Channel Count vs BCI Accuracy Benchmarks

## Overview

The number of EEG channels fundamentally constrains which BCI paradigms
are viable and at what accuracy. More channels provide better spatial
resolution, enable spatial filtering algorithms (CSP, CCA, beamforming),
and improve artifact rejection. However, more channels also increase
setup time, cost, and discomfort.

This document benchmarks expected accuracy across paradigms for the
channel counts relevant to EXWM-VR: 4, 8, 16, and 32+ channels.

## Channel Configurations

### 4-Channel Minimal (OpenBCI Ganglion)

**Electrodes**: Fp1, Fp2, O1, O2
**Reference**: A1 or A2 (earlobe)
**Cost**: ~$250 (Ganglion board)

Coverage: frontal (prefrontal) and occipital only. No central, parietal,
or temporal coverage. This is the absolute minimum for any useful BCI.

**What works**:
- Attention monitoring (frontal alpha/beta ratio) -- adequate
- SSVEP (occipital) -- feasible but limited spatial filtering
- Blink/eye movement detection (frontal EOG) -- reliable

**What degrades**:
- P300 (needs Pz, Cz, Fz) -- severely degraded, likely unusable
- Motor imagery (needs C3, C4) -- impossible without central electrodes

**What fails**:
- Spatial filtering (CSP, CCA with >2 channels) -- insufficient channels
- Source localization -- impossible
- EEG biometrics -- poor accuracy (<80%)

### 8-Channel Standard (OpenBCI Cyton)

**Electrodes**: Fp1, Fp2, C3, C4, P3, P4, O1, O2
**Reference**: A1 or A2, ground at Fpz
**Cost**: ~$500 (Cyton board + electrodes)

Coverage: frontal, central, parietal, and occipital. This is the standard
10-20 subset for consumer BCI and our recommended starting configuration.

**What works well**:
- Attention monitoring -- reliable (frontal + occipital cross-validation)
- SSVEP -- good (O1/O2 + P3/P4 for CCA with 4 occipito-parietal channels)
- Motor imagery -- basic (C3/C4 for left/right hand, no feet/tongue)
- P300 -- adequate (P3/P4 capture parietal P300, miss Cz/Fz components)
- EEG biometrics -- adequate (~90% accuracy)

**What degrades**:
- 4-class MI (needs Cz, FC3, FC4) -- limited to 2-class (left/right)
- Complex P300 spellers -- reduced SNR without frontal/central coverage
- Connectivity analysis -- limited to 28 channel pairs

### 16-Channel Extended (OpenBCI Cyton + Daisy)

**Electrodes**: Fp1, Fp2, F3, F4, F7, F8, C3, C4, T3, T4, P3, P4, T5,
T6, O1, O2
**Reference**: A1+A2 linked, ground at Fpz
**Cost**: ~$950 (Cyton + Daisy boards)

Coverage: full 10-20 system. All major cortical areas represented with
adequate spatial sampling for standard BCI paradigms.

**What works well**:
- All paradigms at good-to-excellent accuracy
- Spatial filtering (CSP) -- effective with 16 channels
- CCA for SSVEP -- strong harmonic estimation
- P300 -- full coverage of target sites (Fz, Cz, Pz, Oz)
- 4-class MI -- feasible (motor cortex + supplementary areas)
- EEG biometrics -- strong (~95% accuracy)
- Artifact rejection via ICA -- 16 components, good decomposition

**What degrades**:
- Source localization -- still too sparse for accurate inverse solutions
- High-density spatial patterns -- not captured

### 32+ Channel Research Grade

**Electrodes**: full 10-20 + 10-10 intermediates
**Reference**: average reference (computed)
**Cost**: $2,000-20,000+ (research-grade amplifiers)

**Accuracy**: marginal improvement over 16 channels for online BCI.
The additional channels primarily benefit:

- Source localization (inverse problem better conditioned)
- Fine-grained spatial patterns (e.g., lateralized readiness potential)
- ICA artifact rejection (more components = cleaner decomposition)
- Research applications requiring high spatial resolution

For real-time BCI in a consumer/prosumer context, 32+ channels have
diminishing returns versus the cost and setup burden.

## Accuracy Benchmarks by Paradigm

### Attention Monitoring (Alpha/Beta Ratio)

Classification: focused vs relaxed (2-class)

| Channels | Accuracy | Cohen's Kappa | Notes                              |
|----------|----------|---------------|------------------------------------|
| 4        | 78-85%   | 0.56-0.70     | Frontal pair sufficient, noisy     |
| 8        | 85-92%   | 0.70-0.84     | Cross-validation with occipital    |
| 16       | 88-94%   | 0.76-0.88     | Marginal gain, temporal adds info  |
| 32       | 89-95%   | 0.78-0.90     | Minimal additional benefit         |

**Recommendation**: 4 channels adequate; 8 channels reliable.

### SSVEP (Steady-State Visual Evoked Potential)

Classification: which frequency target is the user attending (4-8 class)

| Channels | 4-class Accuracy | 8-class Accuracy | ITR (bits/min) |
|----------|------------------|------------------|----------------|
| 4        | 82-90%           | 70-82%           | 20-35          |
| 8        | 90-96%           | 82-92%           | 35-55          |
| 16       | 94-98%           | 88-96%           | 45-70          |
| 32       | 95-99%           | 90-97%           | 50-75          |

SSVEP benefits significantly from spatial filtering (CCA), which
improves with channel count. The jump from 4 to 8 channels is the
most impactful.

**Recommendation**: 8 channels for practical SSVEP BCI.

### P300 (Oddball Paradigm)

Classification: target vs non-target stimulus (with row/column decoding)

| Channels | Char Accuracy (15 avg) | Char Accuracy (5 avg) | Speed       |
|----------|------------------------|-----------------------|-------------|
| 4        | 70-80%                 | 50-65%                | Very slow   |
| 8        | 82-90%                 | 68-80%                | Moderate    |
| 16       | 90-96%                 | 80-90%                | Good        |
| 32       | 92-97%                 | 82-92%                | Good        |

P300 requires parietal and central coverage. 4 channels without Pz/Cz
severely limits performance. The xDAWN spatial filter needs 8+ channels
to effectively extract the P300 component from background EEG.

**Recommendation**: 8 channels minimum; 16 for reliable P300 speller.

### Motor Imagery (MI)

Classification: imagined left hand vs right hand (2-class) or 4-class

| Channels | 2-class Accuracy | 4-class Accuracy | Notes                     |
|----------|------------------|------------------|---------------------------|
| 4        | N/A              | N/A              | Cannot capture C3/C4      |
| 8        | 72-85%           | N/A              | C3/C4 only, no 4-class    |
| 16       | 80-92%           | 60-78%           | CSP effective, all classes |
| 32       | 82-94%           | 65-82%           | Best CSP performance      |

Motor imagery is the most channel-hungry paradigm. CSP (Common Spatial
Patterns) is the standard spatial filter and requires channels covering
the sensorimotor cortex (C3, Cz, C4, FC3, FC4, CP3, CP4 at minimum).

**Recommendation**: 16 channels for practical MI BCI.

### EEG Biometric Authentication

Classification: identity verification (genuine vs impostor)

| Channels | Accuracy | EER    | FAR at 1% FRR | Notes                     |
|----------|----------|--------|----------------|---------------------------|
| 4        | 78-85%   | 12-18% | 25-35%         | Insufficient for security |
| 8        | 88-93%   | 5-9%   | 10-18%         | Acceptable secondary      |
| 16       | 93-97%   | 2-5%   | 4-8%           | Good standalone           |
| 32       | 95-99%   | 1-3%   | 2-5%           | Research-grade performance|

**Recommendation**: 8 channels as secondary factor; 16 for standalone.

## Setup Time and Comfort

| Channels | Gel Setup  | Dry Setup | Comfort (1hr) | Daily Feasibility |
|----------|------------|-----------|---------------|-------------------|
| 4        | 5-10 min   | 1-2 min   | Good          | Excellent         |
| 8        | 10-20 min  | 2-5 min   | Good          | Good              |
| 16       | 20-35 min  | 5-10 min  | Moderate      | Moderate          |
| 32       | 30-60 min  | 10-20 min | Poor          | Poor              |

Setup time includes electrode placement, gel application (if wet),
impedance checking, and signal quality verification.

## Cost Comparison

| Configuration        | Board         | Electrodes    | Total    |
|----------------------|---------------|---------------|----------|
| 4ch Ganglion         | $250          | $50-100       | $300-350 |
| 8ch Cyton            | $500          | $50-100       | $550-600 |
| 16ch Cyton+Daisy     | $950          | $100-200      | $1,050+  |
| 32ch (g.tec, ANT)    | $5,000-15,000 | Included      | $5,000+  |

## Recommendation for EXWM-VR

### Primary Configuration: 8-Channel (Cyton)

The OpenBCI Cyton (8 channels) is the sweet spot for EXWM-VR:

- **Attention monitoring**: our primary use case, works well at 8ch
- **SSVEP**: viable for VR overlay selection (4-8 targets)
- **Biometrics**: acceptable as secondary authentication factor
- **Cost**: $550 is accessible for enthusiast users
- **Setup**: 5 minutes with dry electrodes, reasonable for daily use
- **BrainFlow support**: native, well-tested

### Stretch Configuration: 16-Channel (Cyton+Daisy)

For users wanting full paradigm support:

- **Motor imagery**: enables thought-based window switching
- **P300**: enables BCI keyboard/speller in VR
- **Biometrics**: strong enough for standalone authentication
- **Trade-off**: more setup time, higher cost, less comfortable

### Software Design Implication

The BCI modules should be channel-count-agnostic:

- Detect available channels at session start
- Enable/disable paradigms based on available coverage
- Degrade gracefully (attention always available, MI only with C3/C4)
- Report expected accuracy for current configuration
- Recommend upgrades when user attempts unavailable paradigms
