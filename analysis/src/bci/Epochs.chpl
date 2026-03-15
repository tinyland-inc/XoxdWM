// Epochs — NUMA-parallel epoch extraction and averaging
//
// Core data structure for BCI analysis. An epoch is a time-locked
// segment of multichannel data around a stimulus event.
//
// On the T7810 with -nl 1x2s:
//   Socket 0 processes epochs 0..N/2
//   Socket 1 processes epochs N/2..N
// forall distributes work automatically across both sockets.

module Epochs {
  use CTypes;
  use IO;

  config const numChannels: int = 100;
  config const sampleRate: int = 250;
  config const epochDurationMs: int = 1000;

  type Sample = real(64);

  inline proc samplesPerEpoch(): int {
    return (sampleRate * epochDurationMs) / 1000;
  }

  // Load raw epoch data from a binary file
  // Format: [numEpochs][numChannels][samplesPerEpoch] of real(64)
  proc loadEpochs(path: string): (int, [] Sample) throws {
    var f = open(path, ioMode.r);
    var r = f.reader(locking=false);

    const fileSize = f.size;
    const bytesPerSample = 8; // real(64)
    const spe = samplesPerEpoch();
    const epochBytes = numChannels * spe * bytesPerSample;
    const nEpochs = fileSize / epochBytes;

    var data: [0..<nEpochs, 0..<numChannels, 0..<spe] Sample;

    for e in 0..<nEpochs do
      for ch in 0..<numChannels do
        for s in 0..<spe do
          data[e, ch, s] = r.read(real(64));

    r.close();
    f.close();
    return (nEpochs, data);
  }

  // NUMA-parallel epoch averaging
  // forall distributes channel×sample iterations across all available cores.
  // On dual-socket T7810, each socket handles ~half the channels.
  proc averageEpochs(ref data: [] Sample, nEpochs: int): [] Sample {
    const spe = samplesPerEpoch();
    var avg: [0..<numChannels, 0..<spe] Sample = 0.0;

    forall (ch, s) in {0..<numChannels, 0..<spe} {
      var sum: Sample = 0.0;
      for e in 0..<nEpochs do
        sum += data[e, ch, s];
      avg[ch, s] = sum / nEpochs: real;
    }
    return avg;
  }

  // Baseline correction: subtract pre-stimulus mean from each epoch
  proc baselineCorrect(ref data: [] Sample, nEpochs: int,
                       baselineStartMs: int = 0, baselineEndMs: int = 200) {
    const spe = samplesPerEpoch();
    const bStart = (baselineStartMs * sampleRate) / 1000;
    const bEnd = (baselineEndMs * sampleRate) / 1000;

    forall (e, ch) in {0..<nEpochs, 0..<numChannels} {
      var sum: Sample = 0.0;
      for s in bStart..<bEnd do
        sum += data[e, ch, s];
      const mean = sum / (bEnd - bStart): real;
      for s in 0..<spe do
        data[e, ch, s] -= mean;
    }
  }

  // Epoch rejection: flag epochs where any channel exceeds threshold
  proc rejectEpochs(ref data: [] Sample, nEpochs: int,
                    threshold: real = 150.0): [] bool {
    const spe = samplesPerEpoch();
    var rejected: [0..<nEpochs] bool = false;

    forall e in 0..<nEpochs {
      for ch in 0..<numChannels {
        for s in 0..<spe {
          if abs(data[e, ch, s]) > threshold {
            rejected[e] = true;
            break;
          }
        }
        if rejected[e] then break;
      }
    }
    return rejected;
  }
}
