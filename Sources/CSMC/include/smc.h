#ifndef THERMO_SMC_H
#define THERMO_SMC_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Error codes. Negative values are thermo errors; positive values are raw kern_return_t. */
enum {
    SMC_OK = 0,
    SMC_ERR_NO_SERVICE = -1,   /* AppleSMC not found */
    SMC_ERR_OPEN = -2,         /* IOServiceOpen failed */
    SMC_ERR_KEY_NOT_FOUND = -3,
    SMC_ERR_SIZE = -4,         /* value size mismatch / too large */
    SMC_ERR_TYPE = -5,         /* type not decodable / encodable */
    SMC_ERR_NOT_PRIVILEGED = -6,
    SMC_ERR_CALL = -7,         /* SMC firmware returned an error */
    SMC_ERR_NOMEM = -8,
};

#define SMC_MAX_BYTES 32

typedef struct smc_conn smc_conn;

typedef struct {
    uint32_t key;
    uint32_t type;      /* FourCC, e.g. 'sp78' */
    uint32_t size;
    uint8_t  attributes;
} smc_key_info;

typedef struct {
    uint32_t key;
    uint32_t type;
    uint32_t size;
    uint8_t  bytes[SMC_MAX_BYTES];
} smc_value;

/* Connection lifecycle. */
int  smc_open(smc_conn **out);
void smc_close(smc_conn *conn);

/* Key enumeration. */
int smc_key_count(smc_conn *conn, uint32_t *count);
int smc_key_at_index(smc_conn *conn, uint32_t index, uint32_t *key);

/* Key info (cached after first lookup). */
int smc_key_info_get(smc_conn *conn, uint32_t key, smc_key_info *info);

/* Pre-populate the key-info cache (e.g. from an on-disk discovery cache) so the first
 * read of each key costs one SMC call instead of two. */
void smc_key_info_seed(smc_conn *conn, const smc_key_info *info);

/* Raw read / write. */
int smc_read(smc_conn *conn, uint32_t key, smc_value *out);
int smc_write(smc_conn *conn, uint32_t key, const uint8_t *bytes, uint32_t size);

/* Read and decode to double in one call (hot path). */
int smc_read_double(smc_conn *conn, uint32_t key, double *out);

/* Type codecs (pure functions, no I/O). */
bool smc_decode_double(uint32_t type, const uint8_t *bytes, uint32_t size, double *out);
bool smc_encode_double(uint32_t type, uint32_t size, double value, uint8_t *bytes);

/* FourCC helpers. */
uint32_t smc_fourcc(const char *s);              /* "TC0P" -> key; shorter strings padded with spaces */
void     smc_fourcc_str(uint32_t v, char out[5]);

/* Apple Silicon temperature sensors via IOHIDEventSystem (private API).
 * Returns number of sensors written (<= max), or 0 when unavailable (e.g. Intel). */
typedef struct smc_hid smc_hid;
typedef struct {
    char   name[64];
    double celsius;
} smc_hid_reading;

smc_hid *smc_hid_open(void);
void     smc_hid_close(smc_hid *hid);
int      smc_hid_count(smc_hid *hid);
int      smc_hid_read(smc_hid *hid, smc_hid_reading *out, int max);

#ifdef __cplusplus
}
#endif

#endif
