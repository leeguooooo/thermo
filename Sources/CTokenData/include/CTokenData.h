#include <stddef.h>
#include <stdint.h>
const char *thermo_token_data(int encoding);
size_t thermo_token_uncompressed_size(int encoding);
int thermo_token_inflate(const uint8_t *src, size_t count, uint8_t *out, size_t *length);
