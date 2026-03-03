# R20.2: UX Evaluation -- Multi-Modal Input Study Design

## Overview

This document specifies the UX evaluation methodology for EWWM v0.1.0
release validation. The study measures task performance across four
input modalities to quantify the usability impact of EWWM's biometric
input systems and identify areas requiring post-release improvement.

The study is designed to be reproducible: all task scripts, metrics,
and analysis procedures are defined precisely enough that the evaluation
can be re-run for future releases.

---

## Study Design

### Participants

- **N = 3** (within-subjects design, all participants try all modalities)
- Recruitment criteria: daily Emacs users, comfortable with tiling WMs,
  no prior VR WM experience (to avoid transfer effects)
- Screening: normal or corrected-to-normal vision, no photosensitive
  epilepsy, no known EEG contraindications
- Compensation: contributor credit in CHANGELOG

### Session Structure

Each session lasts approximately 60 minutes:

| Phase           | Duration | Activity                              |
|-----------------|----------|---------------------------------------|
| Consent + setup | 5 min    | IRB consent, hardware fitting         |
| Familiarization | 20 min   | 5 min per modality (A, B, C, D)       |
| Task battery    | 30 min   | 6 tasks x 4 modalities (randomized)   |
| Debrief         | 5 min    | NASA-TLX, preference ranking, notes   |

### Modality Conditions

**A. Keyboard-only (baseline)**
Standard keyboard input. No VR headset. Flat desktop mode with tiling
layout. Mouse disabled to force keyboard-only navigation (consistent
with EXWM's keyboard-driven philosophy). This is the control condition.

**B. Gaze + Wink**
VR headset with Pupil Labs eye tracking. Gaze moves the focus cursor.
Wink (deliberate single-eye closure) confirms actions. Dwell timeout
for passive focus (400ms). Keyboard available for text entry. This
tests the eye-tracking-only input path.

**C. Gaze + Pinch (Apple Vision Pro style)**
VR headset with eye tracking + hand tracking. Gaze targets the element.
Index finger pinch confirms actions. Middle finger pinch for secondary
actions. Keyboard available for text entry. This tests the "look and
tap" paradigm validated by Apple Vision Pro.

**D. Gaze + BCI Motor Imagery**
VR headset with eye tracking + OpenBCI Cyton (8-channel EEG). Gaze
targets the element. Left-hand motor imagery confirms actions. Right-
hand motor imagery cancels/goes back. Requires per-participant MI
calibration (included in 5-minute familiarization). Keyboard available
for text entry.

### Counterbalancing

Modality order is counterbalanced using a Latin square:

| Participant | Order           |
|-------------|-----------------|
| P1          | A, B, C, D      |
| P2          | B, D, A, C      |
| P3          | C, A, D, B      |

Task order within each modality is fixed (tasks 1-6 in sequence) to
maintain consistent cognitive load progression.

---

## Task Battery

### Task 1: Window Management

**Objective**: Open 4 applications, arrange in 2x2 grid, switch focus.

**Procedure**:
1. Launch terminal emulator (ansi-term)
2. Launch Emacs scratch buffer
3. Launch Qutebrowser (about:blank)
4. Launch second terminal emulator
5. Arrange all four in a 2x2 tiling grid
6. Switch focus to each window in sequence: top-left, top-right,
   bottom-right, bottom-left (2.5 complete cycles = 10 switches)

**Completion criteria**: All 4 windows visible in grid layout, 10 focus
switches completed correctly.

**Measurement**: Time from first app launch command to final focus switch.
Error = incorrect focus target (window that received focus was not the
intended target).

### Task 2: Text Editing

**Objective**: Navigate to specific line, rename variable, save file.

**Procedure**:
1. Open pre-prepared file `/tmp/ewwm-test/sample.py` (100 lines)
2. Navigate to line 42 (`M-g M-g 42 RET` or equivalent)
3. Find variable `old_name` on that line
4. Rename to `new_name` (via query-replace or manual edit)
5. Save file (`C-x C-s`)

**Completion criteria**: File saved with correct change on line 42.

**Measurement**: Time from file open command to save confirmation.
Error = wrong line edited, wrong variable changed, typo in new name.

### Task 3: Web Browsing

**Objective**: Navigate, follow links, bookmark a page.

**Procedure**:
1. Open Qutebrowser (or switch to existing instance)
2. Navigate to `http://localhost:8080/test-page` (local test server
   with consistent content)
3. Follow link labeled "Documentation" (requires link-hint or click)
4. Follow link labeled "API Reference"
5. Follow link labeled "Examples"
6. Bookmark current page (`:bookmark-add` or `M` in qutebrowser)

**Completion criteria**: Bookmark created for the Examples page.

**Measurement**: Time from Qutebrowser activation to bookmark creation.
Error = wrong link followed, bookmark on wrong page.

### Task 4: Password Entry

**Objective**: Auto-type credentials from KeePassXC into a web form.

**Procedure**:
1. Navigate Qutebrowser to `http://localhost:8080/login` (test form)
2. Focus the username field
3. Trigger EWWM auto-type (`M-x ewwm-secrets-autotype`)
4. KeePassXC matches URL, fills username + password
5. Verify form fields are populated (visual check)
6. Submit the form

**Completion criteria**: Login form submitted with correct credentials.

**Measurement**: Time from form page load to form submission. Error =
wrong credentials filled, auto-type failed to match, manual correction
needed.

**Note**: Secure input mode should automatically activate during this
task, pausing biometric streams. Verify this occurs.

### Task 5: Workspace Navigation

**Objective**: Create workspaces, distribute apps, cycle through all.

**Procedure**:
1. Create workspace 2 (if not existing)
2. Create workspace 3
3. Create workspace 4
4. Move Qutebrowser to workspace 2
5. Move terminal to workspace 3
6. Move second terminal to workspace 4
7. Cycle through all 4 workspaces in order: 1, 2, 3, 4, 1

**Completion criteria**: Each workspace contains the assigned application;
full cycle completed.

**Measurement**: Time from first workspace creation to return to
workspace 1. Error = app on wrong workspace, wrong workspace selected.

### Task 6: Extended Session (Fatigue Measurement)

**Objective**: 15 minutes of mixed tasks measuring fatigue over time.

**Procedure**: Repeat a randomized sequence of micro-tasks:
- Switch to a named workspace (prompted on screen)
- Open or focus a specific application (prompted)
- Type a short sentence (displayed, ~10 words)
- Navigate Qutebrowser to a prompted URL
- Switch focus between two visible windows 3 times

Tasks are prompted every 30 seconds. Total: ~30 micro-tasks.

**Completion criteria**: 15-minute session completed.

**Measurement**: Per-micro-task completion time (binned into 3 five-
minute epochs). Error rate per epoch. Subjective fatigue rating at
5-minute intervals (1-7 Likert scale). For modalities B/C/D: EWWM
fatigue monitor output (fatigue index, blink rate trend).

---

## Metrics

### Primary Metrics

| Metric                   | Unit          | Collection Method            |
|--------------------------|---------------|------------------------------|
| Task completion time     | Seconds       | Screen recording + timestamps|
| Error rate               | Errors/actions| Observer coding + log review |
| Subjective workload      | NASA-TLX (0-100)| Post-session questionnaire |
| Fatigue index over time  | Arbitrary (0-1)| EWWM fatigue monitor output |
| User preference ranking  | Ordinal (1-4) | Post-session interview       |

### Secondary Metrics

| Metric                   | Unit          | Collection Method            |
|--------------------------|---------------|------------------------------|
| Gaze accuracy            | Degrees       | Pupil Labs calibration data  |
| Wink false positive rate | Events/min    | Log review                   |
| Pinch false positive rate| Events/min    | Log review                   |
| BCI classification acc.  | Percent       | BrainFlow log                |
| Secure input activation  | Boolean/task  | IPC log                      |
| Simulator sickness (SSQ) | Score (0-235) | Post-session questionnaire   |

### NASA-TLX Dimensions

Each rated 0-100 (21-point scale):
1. Mental Demand
2. Physical Demand
3. Temporal Demand
4. Performance (self-assessed)
5. Effort
6. Frustration

---

## Expected Results

### Predicted Task Completion Times (seconds)

| Task                  | A (Keyboard) | B (Gaze+Wink) | C (Gaze+Pinch) | D (Gaze+BCI) |
|-----------------------|-------------|---------------|----------------|--------------|
| 1. Window management  | 25          | 45            | 35             | 60           |
| 2. Text editing       | 20          | 50            | 40             | 55           |
| 3. Web browsing       | 15          | 30            | 20             | 40           |
| 4. Password entry     | 10          | 15            | 12             | 18           |
| 5. Workspace nav      | 20          | 40            | 30             | 50           |
| 6. Extended (per task)| 8           | 15            | 12             | 20           |

**Rationale**: Keyboard-only is fastest for experienced Emacs users due
to muscle memory. Gaze+Pinch is predicted second-fastest due to natural
"look and tap" interaction (validated by Apple Vision Pro usability
studies). Gaze+Wink is slower due to deliberate wink requiring conscious
effort. Gaze+BCI is slowest due to MI classification latency (~1-2s)
and lower classification accuracy (~70-80%).

### Predicted Error Rates (errors per total actions)

| Task                  | A (Keyboard) | B (Gaze+Wink) | C (Gaze+Pinch) | D (Gaze+BCI) |
|-----------------------|-------------|---------------|----------------|--------------|
| 1. Window management  | 0.02        | 0.10          | 0.06           | 0.15         |
| 2. Text editing       | 0.01        | 0.08          | 0.05           | 0.12         |
| 3. Web browsing       | 0.02        | 0.12          | 0.08           | 0.18         |
| 4. Password entry     | 0.01        | 0.03          | 0.02           | 0.05         |
| 5. Workspace nav      | 0.02        | 0.08          | 0.05           | 0.12         |
| 6. Extended (epoch 3) | 0.03        | 0.15          | 0.10           | 0.20         |

**Rationale**: Keyboard errors are primarily typos. Gaze errors are
primarily focus targeting (Midas touch). BCI errors reflect ~70-80%
MI classification accuracy. Error rates increase in Task 6 epoch 3
due to fatigue.

### Predicted NASA-TLX Scores (overall workload, 0-100)

| Modality         | Mental | Physical | Temporal | Effort | Frustration | Overall |
|------------------|--------|----------|----------|--------|-------------|---------|
| A. Keyboard      | 30     | 20       | 25       | 25     | 15          | 23      |
| B. Gaze+Wink     | 55     | 40       | 45       | 50     | 40          | 46      |
| C. Gaze+Pinch    | 40     | 30       | 35       | 35     | 25          | 33      |
| D. Gaze+BCI      | 65     | 25       | 55       | 60     | 55          | 52      |

**Rationale**: BCI has highest mental demand (motor imagery requires
concentration). Wink has moderate physical demand (deliberate eye
closure is fatiguing). Pinch is most natural (lowest frustration among
VR modalities). Keyboard is lowest overall (familiar, well-practiced).

---

## Analysis Plan

### Statistical Tests

**Primary analysis**: Repeated-measures one-way ANOVA for each metric
across the four modality conditions. Within-subjects factor: Modality
(4 levels: A, B, C, D). Dependent variables: task completion time,
error rate, NASA-TLX overall score.

**Post-hoc comparisons**: Pairwise t-tests with Bonferroni correction
(6 comparisons, adjusted alpha = 0.05/6 = 0.0083). Key comparisons:
- A vs C (keyboard vs best VR modality -- does VR reach keyboard parity?)
- B vs C (wink vs pinch -- which confirmation mechanism is better?)
- C vs D (pinch vs BCI -- is BCI viable for daily use?)

**Effect size**: Partial eta-squared for ANOVA, Cohen's d for pairwise.

**Fatigue analysis**: Linear mixed model with time (epoch) as fixed
effect and participant as random effect. Test whether error rate
increases significantly across epochs for each modality.

### Qualitative Analysis

Post-session interview (5 minutes) with open-ended questions:
1. Which modality felt most natural? Why?
2. Which modality was most frustrating? What went wrong?
3. Would you use any VR modality daily? Under what conditions?
4. What would need to change for VR input to match keyboard speed?

Responses coded into themes by two independent raters. Inter-rater
reliability assessed via Cohen's kappa (target > 0.7).

### Limitations

- **N = 3** is insufficient for statistical power. This evaluation is
  exploratory, not confirmatory. Results identify trends and usability
  issues, not statistically significant differences.
- **Learning effects**: Despite counterbalancing, 5 minutes of
  familiarization may be insufficient for BCI (which typically requires
  hours of training). BCI results likely underestimate trained performance.
- **Ecological validity**: Lab tasks with predetermined steps do not
  capture real-world exploratory workflows. Extended session (Task 6)
  partially addresses this.
- **Hardware variability**: Eye tracking accuracy varies with calibration
  quality and individual physiology. BCI classification accuracy varies
  with electrode impedance and individual cortical activation patterns.

### Reporting

Results will be reported in `docs/ux-evaluation-results-v0.1.0.md` with:
- Per-task, per-modality completion time tables (mean, SD, range)
- Error rate tables with breakdown by error type
- NASA-TLX radar charts per modality
- Fatigue trend line graphs (error rate vs epoch)
- Participant preference rankings with justification quotes
- Identified usability issues prioritized for v0.2.0

---

## Equipment List

| Item                        | Purpose                      | Qty |
|-----------------------------|------------------------------|-----|
| Linux workstation (RTX 3070)| Compositor + rendering       | 1   |
| VR HMD (Valve Index or similar)| Display + tracking        | 1   |
| Pupil Labs Core             | Eye tracking (120Hz binocular)| 1  |
| OpenBCI Cyton (8ch)         | EEG acquisition              | 1   |
| Electrode cap (10-20 system)| EEG electrode placement      | 1   |
| Conductive gel               | Electrode impedance          | 1   |
| USB keyboard                | Text input (all conditions)  | 1   |
| Screen recording software   | Task timing capture          | 1   |
| Local HTTP server            | Test pages for Tasks 3, 4   | 1   |
| NASA-TLX paper forms         | Subjective workload          | 12  |
| SSQ paper forms              | Simulator sickness           | 3   |

---

## Ethical Considerations

- Informed consent obtained before any data collection
- EEG data stored locally, deleted after analysis (no cloud upload)
- Gaze data stored locally, deleted after analysis
- Participants may withdraw at any time
- VR sessions capped at 30 minutes continuous to limit simulator sickness
- Fatigue alerts from EWWM fatigue monitor respected (session paused
  if fatigue level reaches "high")
- No deception; participants fully informed of all recording
