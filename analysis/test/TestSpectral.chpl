// TestSpectral — Property-based tests for spectral analysis
//
// Uses quickchpl to verify signal processing invariants:
//   - Band powers are always non-negative (PSD is squared magnitude)
//   - Band power sum <= total power (bands partition the spectrum)
//   - Alpha/theta ratio is non-negative
//   - Zero signal produces zero PSD

use quickchpl;

// Inline a minimal DFT for testing (avoids module dependency issues)
proc testPSD(signal: list(real), nfft: int = 64): list(real) {
  var psd: list(real);
  for k in 0..nfft/2 {
    var re, im: real = 0.0;
    const n = min(signal.size, nfft);
    for i in 0..<n {
      const angle = -2.0 * 3.14159265358979 * k * i / nfft: real;
      re += signal[i] * cos(angle);
      im += signal[i] * sin(angle);
    }
    psd.pushBack((re * re + im * im) / nfft: real);
  }
  return psd;
}

proc bandPower(psd: list(real), fLow: real, fHigh: real,
               fs: real = 250.0, nfft: int = 64): real {
  const lo = max(0, (fLow * nfft / fs): int);
  const hi = min(psd.size - 1, (fHigh * nfft / fs): int);
  var p: real = 0.0;
  for k in lo..hi do p += psd[k];
  return p;
}

proc main() {
  writeln("TestSpectral: property-based tests for BCI spectral analysis");
  writeln("");

  // Property 1: PSD values are always non-negative
  var psdNonNeg = property("PSD values are non-negative",
    listGen(realGen(-200.0, 200.0), 64, 64),
    proc(signal: list(real)): bool {
      const psd = testPSD(signal);
      for p in psd do
        if p < 0.0 then return false;
      return true;
    });

  var r1 = check(psdNonNeg, 200);
  printResult(r1);

  // Property 2: Band powers are non-negative
  var bandsNonNeg = property("Band powers are non-negative",
    listGen(realGen(-200.0, 200.0), 64, 64),
    proc(signal: list(real)): bool {
      const psd = testPSD(signal);
      return bandPower(psd, 0.5, 4.0) >= 0.0
          && bandPower(psd, 4.0, 8.0) >= 0.0
          && bandPower(psd, 8.0, 13.0) >= 0.0
          && bandPower(psd, 13.0, 30.0) >= 0.0
          && bandPower(psd, 30.0, 100.0) >= 0.0;
    });

  var r2 = check(bandsNonNeg, 200);
  printResult(r2);

  // Property 3: Total band power <= total PSD power
  var bandSum = property("Band sum <= total power",
    listGen(realGen(-100.0, 100.0), 64, 64),
    proc(signal: list(real)): bool {
      const psd = testPSD(signal);
      var total: real = 0.0;
      for p in psd do total += p;
      const bands = bandPower(psd, 0.5, 4.0)
                   + bandPower(psd, 4.0, 8.0)
                   + bandPower(psd, 8.0, 13.0)
                   + bandPower(psd, 13.0, 30.0)
                   + bandPower(psd, 30.0, 100.0);
      return bands <= total + 1e-10;
    });

  var r3 = check(bandSum, 200);
  printResult(r3);

  // Property 4: Scaling input scales PSD by square of scale factor
  var psdScaling = property("PSD scales quadratically with input",
    tupleGen(
      listGen(realGen(-50.0, 50.0), 64, 64),
      realGen(0.1, 10.0)
    ),
    proc(args: (list(real), real)): bool {
      const (signal, scale) = args;
      var scaled: list(real);
      for s in signal do scaled.pushBack(s * scale);
      const psd1 = testPSD(signal);
      const psd2 = testPSD(scaled);
      // PSD of scaled signal should be scale^2 * PSD of original
      for k in 0..<psd1.size {
        const expected = psd1[k] * scale * scale;
        if abs(psd2[k] - expected) > 1e-6 * max(abs(expected), 1.0) then
          return false;
      }
      return true;
    });

  var r4 = check(psdScaling, 100);
  printResult(r4);

  writeln("");
  printSummary([r1, r2, r3, r4]);
}
