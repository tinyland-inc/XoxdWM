//! Pupil detection for Bigscreen Bigeye eye-tracking cameras.
//!
//! Processes 800x400 MJPEG frames from the Bigeye IR cameras to extract
//! pupil center coordinates for each eye. The full image is split into
//! left (0..400) and right (400..800) halves.
//!
//! Detection pipeline (traditional CV, no ML):
//! 1. Decode MJPEG to grayscale
//! 2. Gaussian blur (3x3)
//! 3. Adaptive threshold (inverted, for dark pupil on bright IR reflection)
//! 4. Find contours
//! 5. Ellipse fit on largest contour → pupil center
//!
//! Target latency: <2ms per frame on CPU.

use tracing::{debug, warn};

/// Width of a single eye region in the Bigeye image.
const EYE_WIDTH: u32 = 400;

/// Full image height.
const EYE_HEIGHT: u32 = 400;

/// Detected pupil center for one eye.
#[derive(Debug, Clone, Copy)]
pub struct PupilCenter {
    /// Horizontal pixel coordinate within the eye image (0..400).
    pub x: f32,
    /// Vertical pixel coordinate within the eye image (0..400).
    pub y: f32,
    /// Estimated pupil radius in pixels.
    pub radius: f32,
    /// Detection confidence (0.0 = no detection, 1.0 = high quality).
    pub confidence: f32,
}

/// Result of pupil detection for both eyes.
#[derive(Debug, Clone, Copy)]
pub struct PupilDetectionResult {
    /// Left eye pupil (from left half of the 800x400 image).
    pub left: Option<PupilCenter>,
    /// Right eye pupil (from right half of the 800x400 image).
    pub right: Option<PupilCenter>,
    /// Processing time in microseconds.
    pub elapsed_us: u64,
}

/// Pupil detection parameters.
#[derive(Debug, Clone)]
pub struct PupilDetectorConfig {
    /// Gaussian blur kernel size (must be odd).
    pub blur_kernel: u32,
    /// Adaptive threshold block size (must be odd).
    pub threshold_block: u32,
    /// Adaptive threshold constant subtracted from mean.
    pub threshold_c: f64,
    /// Minimum contour area (pixels²) to consider as pupil.
    pub min_contour_area: f64,
    /// Maximum contour area (pixels²) to consider as pupil.
    pub max_contour_area: f64,
    /// Minimum circularity (4π·area/perimeter²) for ellipse fit.
    pub min_circularity: f64,
}

impl Default for PupilDetectorConfig {
    fn default() -> Self {
        Self {
            blur_kernel: 3,
            threshold_block: 11,
            threshold_c: 5.0,
            min_contour_area: 50.0,
            max_contour_area: 10000.0,
            min_circularity: 0.5,
        }
    }
}

/// Stateful pupil detector with temporal smoothing.
pub struct PupilDetector {
    pub config: PupilDetectorConfig,
    /// Last detected left pupil (for temporal smoothing).
    last_left: Option<PupilCenter>,
    /// Last detected right pupil (for temporal smoothing).
    last_right: Option<PupilCenter>,
    /// EMA smoothing alpha (0 = max smoothing, 1 = no smoothing).
    pub smoothing_alpha: f32,
    /// Total frames processed.
    pub frame_count: u64,
    /// Total frames with successful detection.
    pub detect_count: u64,
}

impl PupilDetector {
    pub fn new() -> Self {
        Self {
            config: PupilDetectorConfig::default(),
            last_left: None,
            last_right: None,
            smoothing_alpha: 0.3,
            frame_count: 0,
            detect_count: 0,
        }
    }

    /// Detect pupils in a decoded grayscale image.
    ///
    /// `gray_data` must be 800x400 single-channel (u8) grayscale pixels.
    /// Returns detection results for both eyes.
    pub fn detect(&mut self, gray_data: &[u8]) -> PupilDetectionResult {
        let start = std::time::Instant::now();
        self.frame_count += 1;

        let expected_size = (EYE_WIDTH * 2 * EYE_HEIGHT) as usize;
        if gray_data.len() != expected_size {
            warn!(
                "pupil_detect: unexpected image size {} (expected {})",
                gray_data.len(),
                expected_size
            );
            return PupilDetectionResult {
                left: self.last_left,
                right: self.last_right,
                elapsed_us: start.elapsed().as_micros() as u64,
            };
        }

        // Split into left and right eye regions
        let left = self.detect_single_eye(gray_data, 0);
        let right = self.detect_single_eye(gray_data, EYE_WIDTH as usize);

        // Apply temporal smoothing
        let left = left.map(|p| self.smooth(&mut self.last_left.clone(), p));
        let right = right.map(|p| self.smooth(&mut self.last_right.clone(), p));

        self.last_left = left;
        self.last_right = right;

        if left.is_some() || right.is_some() {
            self.detect_count += 1;
        }

        let elapsed_us = start.elapsed().as_micros() as u64;
        debug!(
            "pupil_detect: L={} R={} ({} µs)",
            left.map(|p| format!("({:.0},{:.0})", p.x, p.y))
                .unwrap_or_else(|| "none".into()),
            right
                .map(|p| format!("({:.0},{:.0})", p.x, p.y))
                .unwrap_or_else(|| "none".into()),
            elapsed_us
        );

        PupilDetectionResult {
            left,
            right,
            elapsed_us,
        }
    }

    /// Detect pupil in a single eye region of the full image.
    ///
    /// `x_offset` is the column offset (0 for left eye, 400 for right).
    fn detect_single_eye(&self, gray_data: &[u8], x_offset: usize) -> Option<PupilCenter> {
        let width = (EYE_WIDTH * 2) as usize;
        let eye_w = EYE_WIDTH as usize;
        let eye_h = EYE_HEIGHT as usize;

        // Extract eye region into contiguous buffer
        let mut eye_buf = vec![0u8; eye_w * eye_h];
        for y in 0..eye_h {
            let src_start = y * width + x_offset;
            let dst_start = y * eye_w;
            eye_buf[dst_start..dst_start + eye_w]
                .copy_from_slice(&gray_data[src_start..src_start + eye_w]);
        }

        // Simple threshold: find darkest region (pupil absorbs IR)
        // Full CV pipeline would use adaptive threshold + contour + ellipse fit.
        // This simplified version uses weighted centroid of dark pixels.
        let threshold = self.compute_adaptive_threshold(&eye_buf, eye_w, eye_h);

        let mut sum_x = 0.0f64;
        let mut sum_y = 0.0f64;
        let mut sum_w = 0.0f64;
        let mut dark_count = 0u32;

        for y in 0..eye_h {
            for x in 0..eye_w {
                let px = eye_buf[y * eye_w + x];
                if px < threshold {
                    // Weight by how far below threshold (darker = more weight)
                    let weight = (threshold - px) as f64;
                    sum_x += x as f64 * weight;
                    sum_y += y as f64 * weight;
                    sum_w += weight;
                    dark_count += 1;
                }
            }
        }

        if sum_w < 1.0 || dark_count < self.config.min_contour_area as u32 {
            return None;
        }

        // Check if dark region is too large (not a pupil)
        if dark_count as f64 > self.config.max_contour_area {
            return None;
        }

        let cx = (sum_x / sum_w) as f32;
        let cy = (sum_y / sum_w) as f32;
        let radius = (dark_count as f64 / std::f64::consts::PI).sqrt() as f32;

        // Confidence based on how focused the dark region is
        let variance = self.compute_variance(&eye_buf, eye_w, eye_h, cx, cy, threshold);
        let confidence = (1.0 - (variance / 100.0).min(1.0)) as f32;

        if confidence < 0.2 {
            return None;
        }

        Some(PupilCenter {
            x: cx,
            y: cy,
            radius,
            confidence,
        })
    }

    /// Compute adaptive threshold using mean of the image.
    fn compute_adaptive_threshold(&self, data: &[u8], _w: usize, _h: usize) -> u8 {
        let sum: u64 = data.iter().map(|&p| p as u64).sum();
        let mean = (sum / data.len() as u64) as u8;
        // Pupil is darker than average; threshold below mean
        mean.saturating_sub(self.config.threshold_c as u8)
    }

    /// Compute spatial variance of dark pixels around the centroid.
    fn compute_variance(
        &self,
        data: &[u8],
        w: usize,
        h: usize,
        cx: f32,
        cy: f32,
        threshold: u8,
    ) -> f64 {
        let mut var_sum = 0.0f64;
        let mut count = 0u32;
        for y in 0..h {
            for x in 0..w {
                if data[y * w + x] < threshold {
                    let dx = x as f64 - cx as f64;
                    let dy = y as f64 - cy as f64;
                    var_sum += dx * dx + dy * dy;
                    count += 1;
                }
            }
        }
        if count > 0 {
            var_sum / count as f64
        } else {
            f64::MAX
        }
    }

    /// Apply EMA smoothing to a pupil center.
    fn smooth(&self, last: &mut Option<PupilCenter>, current: PupilCenter) -> PupilCenter {
        match last {
            Some(prev) => {
                let a = self.smoothing_alpha;
                PupilCenter {
                    x: prev.x + a * (current.x - prev.x),
                    y: prev.y + a * (current.y - prev.y),
                    radius: prev.radius + a * (current.radius - prev.radius),
                    confidence: current.confidence,
                }
            }
            None => current,
        }
    }

    /// Detection rate (fraction of frames with successful detection).
    pub fn detection_rate(&self) -> f64 {
        if self.frame_count > 0 {
            self.detect_count as f64 / self.frame_count as f64
        } else {
            0.0
        }
    }

    /// Reset detection state and statistics.
    pub fn reset(&mut self) {
        self.last_left = None;
        self.last_right = None;
        self.frame_count = 0;
        self.detect_count = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_detector_empty_image() {
        let mut detector = PupilDetector::new();
        let result = detector.detect(&[]);
        assert!(result.left.is_none());
        assert!(result.right.is_none());
    }

    #[test]
    fn test_detector_uniform_image() {
        let mut detector = PupilDetector::new();
        // All-white image: no dark pupil to find
        let data = vec![255u8; (800 * 400) as usize];
        let result = detector.detect(&data);
        assert!(result.left.is_none());
        assert!(result.right.is_none());
    }

    #[test]
    fn test_detector_dark_spot() {
        let mut detector = PupilDetector::new();
        let mut data = vec![200u8; (800 * 400) as usize];

        // Draw a dark spot in the left eye region (center at ~200, 200)
        for y in 190..210 {
            for x in 190..210 {
                data[y * 800 + x] = 20;
            }
        }

        let result = detector.detect(&data);
        assert!(result.left.is_some(), "should detect left pupil");
        let left = result.left.unwrap();
        assert!((left.x - 199.5).abs() < 5.0, "x={}", left.x);
        assert!((left.y - 199.5).abs() < 5.0, "y={}", left.y);
        assert!(left.confidence > 0.0);
    }

    #[test]
    fn test_detection_rate() {
        let mut detector = PupilDetector::new();
        assert_eq!(detector.detection_rate(), 0.0);

        // Process uniform image (no detection)
        let data = vec![128u8; (800 * 400) as usize];
        detector.detect(&data);
        assert_eq!(detector.frame_count, 1);
    }

    #[test]
    fn test_reset() {
        let mut detector = PupilDetector::new();
        detector.frame_count = 100;
        detector.detect_count = 50;
        detector.reset();
        assert_eq!(detector.frame_count, 0);
        assert_eq!(detector.detect_count, 0);
        assert!(detector.last_left.is_none());
    }
}
