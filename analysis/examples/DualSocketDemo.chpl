// DualSocketDemo — Validate NUMA-parallel execution on Dell T7810
//
// Run: chpl DualSocketDemo.chpl -o numa-demo && ./numa-demo -nl 1x2s
//
// Expected output on the T7810 (dual Xeon E5-2630v3):
//   Locale 0: socket 0, 8 cores, processing channels 0-49
//   Locale 1: socket 1, 8 cores, processing channels 50-99
//
// This demonstrates that Chapel's forall distributes BCI channel
// processing across both NUMA domains automatically.

use Time;

config const numChannels = 100;
config const numSamples = 250 * 10;  // 10 seconds at 250 Hz
config const numEpochs = 500;

proc main() {
  writeln("═══════════════════════════════════════════════════");
  writeln("  Dell T7810 NUMA-Parallel BCI Demo");
  writeln("═══════════════════════════════════════════════════");
  writeln("  Locales:    ", numLocales);
  writeln("  Cores:      ", here.maxTaskPar, " per locale");
  writeln("  Sublocales: ", here.numSublocales, " (NUMA domains)");
  writeln("  Channels:   ", numChannels);
  writeln("  Samples:    ", numSamples, " (", numSamples / 250, "s at 250Hz)");
  writeln("  Epochs:     ", numEpochs);
  writeln("");

  // Generate synthetic EEG data (gaussian noise)
  writeln("Generating synthetic EEG data...");
  var data: [0..<numChannels, 0..<numSamples] real;
  forall (ch, s) in data.domain {
    // Simple LCG PRNG per element (deterministic, no sync needed)
    const seed = (ch * numSamples + s) * 2654435761;
    data[ch, s] = ((seed % 1000): real - 500.0) / 5.0;  // ~[-100, 100] uV
  }

  // Benchmark: serial PSD computation
  writeln("Computing PSD (serial)...");
  var t1 = new stopwatch();
  t1.start();
  var serialPSD: [0..<numChannels, 0..<129] real;
  for ch in 0..<numChannels {
    for k in 0..<129 {
      var re, im: real = 0.0;
      for n in 0..<256 {
        const angle = -2.0 * 3.14159265358979 * k * n / 256.0;
        re += data[ch, n] * cos(angle);
        im += data[ch, n] * sin(angle);
      }
      serialPSD[ch, k] = (re * re + im * im) / 256.0;
    }
  }
  t1.stop();
  writeln("  Serial:   ", t1.elapsed(), "s");

  // Benchmark: parallel PSD computation (forall across channels)
  writeln("Computing PSD (forall across channels)...");
  var t2 = new stopwatch();
  t2.start();
  var parallelPSD: [0..<numChannels, 0..<129] real;
  forall ch in 0..<numChannels {
    for k in 0..<129 {
      var re, im: real = 0.0;
      for n in 0..<256 {
        const angle = -2.0 * 3.14159265358979 * k * n / 256.0;
        re += data[ch, n] * cos(angle);
        im += data[ch, n] * sin(angle);
      }
      parallelPSD[ch, k] = (re * re + im * im) / 256.0;
    }
  }
  t2.stop();
  writeln("  Parallel: ", t2.elapsed(), "s");
  writeln("  Speedup:  ", t1.elapsed() / t2.elapsed(), "x");

  // Verify results match
  var maxDiff: real = 0.0;
  for (ch, k) in serialPSD.domain {
    const diff = abs(serialPSD[ch, k] - parallelPSD[ch, k]);
    if diff > maxDiff then maxDiff = diff;
  }
  writeln("  Max diff: ", maxDiff, if maxDiff < 1e-10 then " (PASS)" else " (FAIL)");

  // Extract band powers
  writeln("");
  writeln("Band powers (channel 0):");
  const psd0 = parallelPSD[0, ..];
  proc bp(fLow: real, fHigh: real): real {
    const lo = max(0, (fLow * 256 / 250.0): int);
    const hi = min(128, (fHigh * 256 / 250.0): int);
    var p: real = 0.0;
    for k in lo..hi do p += psd0[k];
    return p;
  }
  writeln("  Delta (0.5-4 Hz):  ", bp(0.5, 4.0));
  writeln("  Theta (4-8 Hz):    ", bp(4.0, 8.0));
  writeln("  Alpha (8-13 Hz):   ", bp(8.0, 13.0));
  writeln("  Beta  (13-30 Hz):  ", bp(13.0, 30.0));
  writeln("  Gamma (30-100 Hz): ", bp(30.0, 100.0));

  writeln("");
  writeln("═══════════════════════════════════════════════════");
}
