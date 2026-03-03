# Dry vs Gel Electrode Evaluation for EXWM-VR

## Overview

Electrode choice is a critical practical concern for daily BCI use.
Research-grade EEG uses gel (wet) electrodes for maximum signal quality,
but the setup time and cleanup make them impractical for casual use.
Dry electrodes offer rapid setup at the cost of signal quality. This
document evaluates both approaches for EXWM-VR's target use case:
daily VR window manager operation with BCI-enhanced input.

## Gel (Wet) Electrodes

### Types

**Gold-cup with Ten20 paste**: gold-plated copper disc (10mm diameter),
filled with conductive paste (Ten20 or EC2). Adhered to scalp with
collodion or paste adhesion. The reference standard for clinical EEG.

**Ag/AgCl with gel**: silver/silver-chloride pellet in plastic housing,
conductive gel injected through a hole. Used in most EEG caps (e.g.,
EasyCap, BioSemi ActiveTwo). Better for cap-based systems.

**Saline-soaked felt pads**: sponge electrodes moistened with saline
solution. Used in some consumer devices (Emotiv EPOC). Easiest wet
electrode but dries out over time (30-60 minutes).

### Impedance Characteristics

- Target impedance: <5 k-ohm (clinical standard), <10 k-ohm acceptable
- Typical achieved: 1-5 k-ohm with proper gel application
- Impedance stability: excellent over 1-4 hour sessions
- Frequency response: flat from DC to >100 Hz

### Signal Quality

- SNR: baseline reference (all comparisons relative to gel)
- Artifact susceptibility: low (gel provides mechanical coupling)
- Motion artifact: minimal (electrode does not shift against scalp)
- EMG contamination: no electrode-specific contribution

### Practical Concerns

- **Setup time**: 20-40 minutes for 8-channel cap (impedance below 10 k-ohm)
- **Cleanup time**: 10-20 minutes (wash hair, clean electrodes)
- **Consumables**: Ten20 paste (~$15/tube, ~20 sessions), prep gel, NuPrep
- **Hair**: gel must contact scalp; parting hair is time-consuming
- **Mess**: paste in hair, on clothes, on equipment
- **Skin prep**: light abrasion with NuPrep recommended (removes dead skin)

## Dry Electrodes

### Types

**Spring-loaded pins (comb electrodes)**: multiple metal pins on springs
press through hair to contact scalp. Used in OpenBCI Ultracortex Mark IV
and g.tec g.SAHARA.

- Pin count: typically 5-8 per electrode site
- Pin material: gold-plated stainless steel or silver
- Spring force: 0.5-1.5 N per pin (firm but tolerable)
- Hair penetration: good for short-medium hair, struggles with thick hair

**Flexible polymer**: conductive polymer (PEDOT:PSS or carbon-loaded
silicone) fingers that flex to part hair. Emerging technology.

- Comfort: superior to pins (no pressure points)
- Impedance: higher than pins (20-80 k-ohm)
- Durability: polymer degrades over months

**Active dry electrodes**: dry contact with integrated pre-amplifier
directly at the electrode site. The pre-amplifier has very high input
impedance (>1 G-ohm), making contact impedance less critical.

- Impedance tolerance: functions well up to 100 k-ohm contact impedance
- Signal quality: approaches gel electrodes despite high contact impedance
- Cost: significantly higher per electrode ($50-100 vs $5-10)
- Power: requires per-electrode power supply (battery or through-cap wiring)

### Impedance Characteristics

- Typical impedance: 10-50 k-ohm (pins), 20-80 k-ohm (polymer)
- Active dry: effective impedance <1 k-ohm (pre-amp dominates)
- Impedance stability: moderate (shifts with movement, sweat)
- Frequency response: reduced low-frequency fidelity below 1 Hz

### Signal Quality Comparison

| Metric                  | Gel (baseline) | Dry Pins    | Active Dry  |
|-------------------------|----------------|-------------|-------------|
| SNR reduction           | 0%             | 15-30%      | 5-15%       |
| Baseline noise (uVrms)  | 0.5-1.0        | 2.0-5.0     | 0.8-2.0     |
| Motion artifact          | Low            | High        | Moderate    |
| Impedance (k-ohm)       | 1-5            | 10-50       | 1-5 (eff.)  |
| Alpha detection          | Excellent      | Good        | Very Good   |
| P300 amplitude           | 5-15 uV        | 3-10 uV     | 4-12 uV     |
| SSVEP amplitude          | 2-8 uV         | 1.5-6 uV   | 1.8-7 uV   |
| Mu rhythm (MI)           | 1-3 uV         | 0.5-2 uV   | 0.8-2.5 uV |

### Impact on BCI Accuracy

Expected accuracy degradation from gel to dry (passive pins):

| Paradigm        | Gel Accuracy | Dry Accuracy | Degradation |
|-----------------|-------------|--------------|-------------|
| Attention       | 88%         | 80-85%       | 3-8%        |
| SSVEP (4-class) | 93%         | 85-90%       | 3-8%        |
| P300            | 88%         | 75-82%       | 6-13%       |
| Motor Imagery   | 82%         | 68-75%       | 7-14%       |
| Biometrics      | 91%         | 82-87%       | 4-9%        |

P300 and MI suffer most because they rely on lower-amplitude components
that are masked by the higher noise floor of dry electrodes.

## Commercial Options

### OpenBCI Ultracortex Mark IV

- Type: 3D-printed frame, spring-loaded dry pins (comfort cups)
- Channels: 8 (Cyton) or 16 (Cyton+Daisy)
- Comfort cups: dry spikey electrode with spring suspension
- Optional: flat electrodes for forehead/behind ear, comfort pads
- Cost: $350 (frame + dry electrodes, board separate)
- Comfort: moderate; pins can cause discomfort after 30+ minutes
- Setup: 2-5 minutes
- Hair compatibility: good for short-medium, poor for thick/long

### g.tec g.SAHARA

- Type: active dry electrodes with integrated pre-amplifier
- Channels: up to 64 (modular)
- Signal quality: approaches gel (active amplification)
- Cost: ~$100 per electrode; full system $3,000+
- Comfort: better than passive pins (lower required contact pressure)
- Setup: 3-5 minutes
- Research-grade active dry; expensive but excellent quality

### Emotiv EPOC X

- Type: saline-soaked felt pads (semi-dry)
- Channels: 14 fixed locations
- Impedance: 10-30 k-ohm (when fresh)
- Cost: $849 (complete system)
- Comfort: good (lightweight, no pressure points)
- Limitation: saline dries in 30-60 minutes, closed ecosystem
- BrainFlow support: yes (via USB dongle or BLE)

### Muse 2 / Muse S

- Type: conductive rubber (forehead), conductive fabric (behind ear)
- Channels: 4 (Fp1, Fp2, TP9, TP10)
- Cost: $250-400
- Comfort: excellent (headband form factor)
- Limitation: 4 channels, only frontal + temporal, not suitable for MI/P300
- BrainFlow support: yes (Bluetooth LE)

## Recommendations for EXWM-VR

### Daily Use: Dry Electrodes

For everyday EXWM-VR sessions where BCI provides attention monitoring,
SSVEP selection, and passive biometric monitoring:

- **OpenBCI Ultracortex Mark IV** with dry comfort cups is the primary
  recommendation. 2-5 minute setup, adequate signal for attention and
  SSVEP, compatible with our BrainFlow integration.
- Accept the 3-8% accuracy degradation as a trade-off for usability.
- The dry electrode noise floor is manageable for high-amplitude signals
  (attention alpha, SSVEP harmonics).

### Calibration and Validation: Gel Electrodes

For initial enrollment, biometric template creation, and periodic
recalibration:

- Use gel electrodes (Ag/AgCl with EasyCap or equivalent) for maximum
  signal quality during template creation.
- Calibration sessions happen infrequently (monthly), so setup time is
  acceptable.
- Better signal quality means better templates, which improves subsequent
  dry-electrode sessions.

### Hybrid Approach: Gel on Critical Channels

A practical compromise for users who need MI or P300:

- **Gel on O1, O2, C3, C4**: the four channels where signal quality
  matters most (occipital for SSVEP, central for MI)
- **Dry on Fp1, Fp2, P3, P4**: frontal and parietal channels where
  higher impedance is more tolerable (attention monitoring uses ratio
  not amplitude, P300 parietal is higher amplitude)
- Reduces gel setup to 4 channels (~10 minutes) while maintaining
  accuracy on critical paradigms

### Software Compensation

The BCI processing pipeline should account for electrode type:

- **Impedance-aware thresholds**: adjust artifact rejection thresholds
  based on measured impedance at session start
- **Noise-adaptive filtering**: increase notch filter order and apply
  additional spatial filtering when impedance is high
- **Confidence weighting**: weight channel contributions by inverse
  impedance in classifier features
- **User notification**: alert when signal quality degrades below
  usable threshold for a given paradigm
