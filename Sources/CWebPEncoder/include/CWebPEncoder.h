#ifndef THERMO_WEBP_ENCODER_H
#define THERMO_WEBP_ENCODER_H
#include <stddef.h>
#include <stdint.h>
typedef struct ThermoWebPEncoder ThermoWebPEncoder;
ThermoWebPEncoder *ThermoWebPEncoderCreate(int width, int height, float quality);
int ThermoWebPEncoderAdd(ThermoWebPEncoder *encoder, const uint8_t *rgba, int stride, int timestamp_ms);
int ThermoWebPEncoderFinish(ThermoWebPEncoder *encoder, int end_ms, uint8_t **data, size_t *size);
void ThermoWebPEncoderDelete(ThermoWebPEncoder *encoder);
void ThermoWebPReleaseData(uint8_t *data);
#endif
