// BciAnalysis — NUMA-parallel electrophysiology analysis for Dell T7810
//
// This is the top-level module for offline/batch BCI signal processing.
// Designed for the T7810's dual-socket Xeon E5-2630v3 (2 NUMA domains).
//
// Run with: ./bci-analysis -nl 1x2s   (one locale per socket)
//
// Architecture:
//   Layer 1 (RT): Rust compositor acquires data from AD/DA via BrainFlow
//   Layer 2 (batch): Chapel processes recorded epochs in parallel (this)
//   Layer 3 (UI): Emacs orchestrates paradigms and displays results
//
// Data flow:
//   /dev/shm/bci-epochs-*.bin → Epochs.chpl → Spectral.chpl → Features.chpl

module BciAnalysis {
  public use Epochs;
  public use Spectral;

  config const dataDir = "/dev/shm";
  config const verbose = false;

  proc main() {
    if verbose {
      writeln("BCI Analysis v0.1.0");
      writeln("  Locales: ", numLocales);
      writeln("  Cores per locale: ", here.maxTaskPar);
      writeln("  NUMA domains: ", here.numSublocales);
    }
  }
}
