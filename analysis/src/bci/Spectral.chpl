// Spectral — NUMA-parallel spectral analysis for BCI channels
//
// Provides FFT-based power spectral density and standard EEG band
// extraction. All channel-level operations use forall for automatic
// distribution across both sockets of the Dell T7810.
//
// EEG frequency bands:
//   Delta: 0.5-4 Hz   (sleep, deep meditation)
//   Theta: 4-8 Hz     (drowsiness, memory encoding)
//   Alpha: 8-13 Hz    (relaxed attention, BCI idle)
//   Beta:  13-30 Hz   (active thinking, motor imagery)
//   Gamma: 30-100 Hz  (high-level processing, feature binding)

module Spectral {
  use Math;

  config const defaultNfft: int = 256;
  config const defaultFs: real = 250.0;

  record BandPowers {
    var delta, theta, alpha, beta, gamma: real;
  }

  // Compute power spectral density for a single channel via DFT
  // (pure Chapel implementation — replace with FFTW extern for production)
  proc computePSD(signal: [] real, nfft: int = defaultNfft): [] real {
    var psd: [0..<nfft/2+1] real;

    for k in 0..<nfft/2+1 {
      var re, im: real = 0.0;
      for n in signal.domain {
        const angle = -2.0 * pi * k * n / nfft: real;
        re += signal[n] * cos(angle);
        im += signal[n] * sin(angle);
      }
      psd[k] = (re * re + im * im) / nfft: real;
    }
    return psd;
  }

  // Band power: integrate PSD over frequency range
  proc bandPower(psd: [] real, fLow: real, fHigh: real,
                 fs: real = defaultFs, nfft: int = defaultNfft): real {
    const binLow = max(0, (fLow * nfft / fs): int);
    const binHigh = min(psd.size - 1, (fHigh * nfft / fs): int);
    var power: real = 0.0;
    for k in binLow..binHigh do
      power += psd[k];
    return power;
  }

  // Extract standard EEG bands from a PSD
  proc extractBands(psd: [] real, fs: real = defaultFs,
                    nfft: int = defaultNfft): BandPowers {
    return new BandPowers(
      delta = bandPower(psd, 0.5, 4.0, fs, nfft),
      theta = bandPower(psd, 4.0, 8.0, fs, nfft),
      alpha = bandPower(psd, 8.0, 13.0, fs, nfft),
      beta  = bandPower(psd, 13.0, 30.0, fs, nfft),
      gamma = bandPower(psd, 30.0, 100.0, fs, nfft)
    );
  }

  // NUMA-parallel PSD across all channels
  // On T7810: channels 0-49 on socket 0, channels 50-99 on socket 1
  proc channelPSD(data: [?D] real, nfft: int = defaultNfft): [] real {
    const nChannels = D.dim(0).size;
    var psd: [0..<nChannels, 0..<nfft/2+1] real;

    forall ch in 0..<nChannels {
      psd[ch, ..] = computePSD(data[ch, ..], nfft);
    }
    return psd;
  }

  // NUMA-parallel band extraction across all channels
  proc channelBands(data: [?D] real, fs: real = defaultFs,
                    nfft: int = defaultNfft): [] BandPowers {
    const nChannels = D.dim(0).size;
    var bands: [0..<nChannels] BandPowers;

    forall ch in 0..<nChannels {
      const psd = computePSD(data[ch, ..], nfft);
      bands[ch] = extractBands(psd, fs, nfft);
    }
    return bands;
  }

  // Alpha/theta ratio — commonly used BCI metric for attention
  proc alphaThetaRatio(bp: BandPowers): real {
    if bp.theta <= 0.0 then return 0.0;
    return bp.alpha / bp.theta;
  }

  // Beta/alpha ratio — arousal/engagement metric
  proc betaAlphaRatio(bp: BandPowers): real {
    if bp.alpha <= 0.0 then return 0.0;
    return bp.beta / bp.alpha;
  }
}
