#include "CWebPEncoder.h"
#include <webp/encode.h>
#include <webp/mux.h>
#include <stdlib.h>
struct ThermoWebPEncoder { WebPAnimEncoder *encoder; int width, height, last_ms, finished; WebPConfig config; };
ThermoWebPEncoder *ThermoWebPEncoderCreate(int width, int height, float quality) {
    if (width <= 0 || height <= 0 || width > 16383 || height > 16383) return NULL;
    ThermoWebPEncoder *result = calloc(1, sizeof(*result));
    if (!result) return NULL;
    WebPAnimEncoderOptions options;
    if (!WebPAnimEncoderOptionsInit(&options) || !WebPConfigInit(&result->config)) { free(result); return NULL; }
    options.anim_params.loop_count = 0; result->config.quality = quality; result->config.method = 4;
    result->encoder = WebPAnimEncoderNew(width, height, &options);
    if (!result->encoder) { free(result); return NULL; }
    result->width = width; result->height = height; result->last_ms = -1; return result;
}
int ThermoWebPEncoderAdd(ThermoWebPEncoder *encoder, const uint8_t *rgba, int stride, int timestamp_ms) {
    if (!encoder || encoder->finished || !rgba || stride < encoder->width * 4 || timestamp_ms <= encoder->last_ms) return 0;
    WebPPicture picture;
    if (!WebPPictureInit(&picture)) return 0;
    picture.use_argb = 1; picture.width = encoder->width; picture.height = encoder->height;
    if (!WebPPictureImportRGBA(&picture, rgba, stride)) { WebPPictureFree(&picture); return 0; }
    int ok = WebPAnimEncoderAdd(encoder->encoder, &picture, timestamp_ms, &encoder->config);
    WebPPictureFree(&picture);
    if (ok) encoder->last_ms = timestamp_ms;
    return ok;
}
int ThermoWebPEncoderFinish(ThermoWebPEncoder *encoder, int end_ms, uint8_t **data, size_t *size) {
    if (!encoder || encoder->finished || !data || !size || end_ms <= encoder->last_ms) return 0;
    if (!WebPAnimEncoderAdd(encoder->encoder, NULL, end_ms, NULL)) return 0;
    WebPData result; WebPDataInit(&result);
    if (!WebPAnimEncoderAssemble(encoder->encoder, &result)) { WebPDataClear(&result); return 0; }
    *data = (uint8_t *)result.bytes; *size = result.size; encoder->finished = 1; return 1;
}
void ThermoWebPEncoderDelete(ThermoWebPEncoder *encoder) { if (encoder) { WebPAnimEncoderDelete(encoder->encoder); free(encoder); } }
void ThermoWebPReleaseData(uint8_t *data) { WebPFree(data); }
