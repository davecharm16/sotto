# Test fixtures

Clean speech for `tests/nc_offline.rs`. Both files are **unmodified** copies from the CMU ARCTIC databases
(Carnegie Mellon University, 2003), licensed "free for use for any purpose" under the terms in
[`CMU_ARCTIC_COPYING`](CMU_ARCTIC_COPYING). Only the file names were changed, to add the voice.

| File | Source (downloaded 2026-10-04) | Voice | SHA-1 |
|---|---|---|---|
| `cmu_us_slt_arctic_a0003.wav` | http://festvox.org/cmu_arctic/cmu_arctic/cmu_us_slt_arctic/wav/arctic_a0003.wav | US female | `edd4cbaedfe1a13b35750e2e875929de4994dd38` |
| `cmu_us_bdl_arctic_a0003.wav` | http://festvox.org/cmu_arctic/cmu_arctic/cmu_us_bdl_arctic/wav/arctic_a0003.wav | US male | `8592e136542b544c9cbf97332747cb6a45f067c1` |

Utterance: "For the twentieth time that evening the two men shook hands." 16 kHz, 16-bit PCM mono. The test upsamples
them to 48 kHz in memory. Noise is generated in the test from fixed seeds, so nothing else is stored here.
