#include "SPFrameBlend.h"

static inline uint32_t SPClampAlpha256(uint32_t alpha256) {
    return alpha256 > 256 ? 256 : alpha256;
}

static inline uint32_t SPBlendPixelBGRA(uint32_t startPixel, uint32_t endPixel, uint32_t alpha, uint32_t inverseAlpha) {
    const uint32_t startLow = startPixel & 0x00ff00ffu;
    const uint32_t endLow = endPixel & 0x00ff00ffu;
    const uint32_t low = ((startLow * inverseAlpha + endLow * alpha) >> 8) & 0x00ff00ffu;

    const uint32_t startHigh = (startPixel >> 8) & 0x00ff00ffu;
    const uint32_t endHigh = (endPixel >> 8) & 0x00ff00ffu;
    const uint32_t high = (((startHigh * inverseAlpha + endHigh * alpha) >> 8) & 0x00ff00ffu) << 8;

    return low | high;
}

void SPBlendBGRA8888(
    const void *startBytes,
    const void *endBytes,
    void *outputBytes,
    size_t pixelCount,
    uint32_t alpha256
) {
    const uint32_t alpha = SPClampAlpha256(alpha256);
    const uint32_t inverseAlpha = 256 - alpha;
    const uint32_t *restrict start = (const uint32_t *)startBytes;
    const uint32_t *restrict end = (const uint32_t *)endBytes;
    uint32_t *restrict output = (uint32_t *)outputBytes;

    for (size_t index = 0; index < pixelCount; index += 1) {
        output[index] = SPBlendPixelBGRA(start[index], end[index], alpha, inverseAlpha);
    }
}

void SPBlendBGRA8888InPlace(
    const void *startBytes,
    void *outputBytes,
    size_t pixelCount,
    uint32_t alpha256
) {
    const uint32_t alpha = SPClampAlpha256(alpha256);
    const uint32_t inverseAlpha = 256 - alpha;
    const uint32_t *restrict start = (const uint32_t *)startBytes;
    uint32_t *restrict output = (uint32_t *)outputBytes;

    for (size_t index = 0; index < pixelCount; index += 1) {
        output[index] = SPBlendPixelBGRA(start[index], output[index], alpha, inverseAlpha);
    }
}
