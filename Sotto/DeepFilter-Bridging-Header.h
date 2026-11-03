#ifndef DeepFilter_Bridging_Header_h
#define DeepFilter_Bridging_Header_h

#include <stdint.h>
#include "Audio/SottoAtomics.h"

// DeepFilterNet3 noise cancellation (DeepFilter/, libdeepfilter.a). Hand-written: keep in sync with the
// #[no_mangle] exports in DeepFilter/src/lib.rs.
// Audio: 48 kHz mono float, 480-sample frames, processed in place. Output is the input delayed by 1440 samples
// (30 ms) in every mode, bypass included.
// Threading: df_process from ONE non-real-time thread (it allocates; never call it on a CoreAudio IO thread).
// df_set_attenuation from any thread. df_destroy only after the df_process thread has stopped.

typedef struct DeepFilterState DeepFilterState;

// NULL or a directory -> embedded model; otherwise a DeepFilterNet3 .tar.gz. Returns NULL on failure.
// Takes ~170 ms: call it off the main thread.
DeepFilterState* df_create(const char* model_path);
// frame_count must be 480; anything else (or a NULL pointer) leaves buffer untouched.
void df_process(DeepFilterState* state, float* buffer, int32_t frame_count);
// 0 = bypass (delayed input, model kept warm), (0,1) = 0..40 dB attenuation limit, 1 = no limit.
// Atomic; applied at the next df_process frame, with a one-frame crossfade into or out of bypass.
void df_set_attenuation(DeepFilterState* state, float attenuation);
int32_t df_get_sample_rate(const DeepFilterState* state);
int32_t df_get_frame_size(const DeepFilterState* state);
void df_destroy(DeepFilterState* state);

#endif
