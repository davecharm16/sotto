#ifndef DeepFilter_Bridging_Header_h
#define DeepFilter_Bridging_Header_h

#include <stdint.h>

typedef struct DeepFilterState DeepFilterState;

DeepFilterState* df_create(const char* model_path);
void df_process(DeepFilterState* state, float* buffer, int32_t frame_count);
void df_set_attenuation(DeepFilterState* state, float attenuation);
int32_t df_get_sample_rate(const DeepFilterState* state);
int32_t df_get_frame_size(const DeepFilterState* state);
void df_destroy(DeepFilterState* state);

#endif
