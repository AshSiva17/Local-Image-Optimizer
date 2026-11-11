# Reproducible native benchmarks

No real WIC benchmarks have been executed in the macOS development environment. This repository supplies the benchmark harness, not estimated performance claims.

## Procedure

1. On Windows x64, build `Release` with the documented CMake/Visual Studio toolchain.
2. Run `scripts/test-native.ps1` and the real-native API suite first. Benchmarking an unverified executable is not a release check.
3. Run `scripts/benchmark-native.ps1 -Iterations 3 -Report benchmark-results/native.json` from the repository root. Increase `Iterations` for a more stable local comparison.
4. Preserve the JSON report with its source revision and binary hash. CI's `windows-native-benchmark-<commit>` artifact supplies this report after a successful Windows job.

## Corpus and measurements

The corpus uses `System.Random(1701)` and 4000 colored rectangles on a 2400 × 1200 image. GDI+ saves a source in PNG, JPEG, BMP, and TIFF. Source hashes are recorded because encoder/runtime changes can change the encoded bytes even with identical drawing operations. The synthetic corpus contains no user photos or external licensed assets.

For every input/output format pair, quality is 1, 82, or 100, with a bounding box of 1800 × 1800 (actual output: 1800 × 900). There are 48 cases. Each case has one excluded warmup and three measured runs by default. Runs are sequential, with a fresh output file, and every output is independently decoded and checked for dimensions and actual format.

The report records:

- All measured wall-time samples and their median in milliseconds.
- Source/output dimensions, formats, quality, and encoded byte counts.
- `savings_percent = 100 × (1 − output_bytes / input_bytes)`. Negative values mean the output grew.
- Corpus version and source hashes, executable SHA-256, Git revision/dirty state, OS, CPU, PowerShell version, timestamp, warmup count, and iteration count.

Timing includes native process launch, the decode/resize/encode pipeline, and the PowerShell invocation wrapper (including diagnostic-file setup/read). It excludes fixture generation, independent output decoding, upload/network time, queue waiting, ZIP creation, and the UI. These are **CLI wall-time measurements**, not an end-to-end service latency or CPU-only encoder measurement. Warmup means results are mostly warm-cache, not cold-disk benchmarks.

## Interpretation

Use the same corpus hashes, executable build configuration, hardware, iteration count, and idle machine when comparing revisions. Hosted runner hardware varies, so compare several runs and preserve raw samples. Do not infer general photographic compression performance or quality from colored rectangles. Resizing and re-encoding both contribute to size changes; JPEG input is already lossy. TIFF's quality setting controls compression effort and need not change file size. PNG/BMP ignore quality.

Publish specific numbers only after inspecting the real report. Include the input/output format, dimensions, quality, median and sample count, and machine. Do not describe all 48 cases with one universal “compression savings” number.
