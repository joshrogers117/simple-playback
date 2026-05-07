#ifndef SPFrameBlend_h
#define SPFrameBlend_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void SPBlendBGRA8888(
    const void *startBytes,
    const void *endBytes,
    void *outputBytes,
    size_t pixelCount,
    uint32_t alpha256
);

void SPBlendBGRA8888InPlace(
    const void *startBytes,
    void *outputBytes,
    size_t pixelCount,
    uint32_t alpha256
);

#ifdef __cplusplus
}
#endif

#endif
