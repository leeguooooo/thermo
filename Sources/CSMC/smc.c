#include "smc.h"

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <os/lock.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <dlfcn.h>

/* ---------------------------------------------------------------------------
 * AppleSMC user client ABI
 * ------------------------------------------------------------------------- */

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_WRITE_BYTES   6
#define SMC_CMD_READ_INDEX    8
#define SMC_CMD_READ_KEYINFO  9

#define SMC_RESULT_KEY_NOT_FOUND 0x84

typedef struct {
    uint8_t  major, minor, build, reserved;
    uint16_t release;
} smc_vers;

typedef struct {
    uint16_t version, length;
    uint32_t cpu_plimit, gpu_plimit, mem_plimit;
} smc_plimit;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;
    uint8_t  data_attributes;
} smc_keyinfo_raw;

typedef struct {
    uint32_t        key;
    smc_vers        vers;
    smc_plimit      plimit;
    smc_keyinfo_raw keyinfo;
    uint8_t         result;
    uint8_t         status;
    uint8_t         data8;
    uint32_t        data32;
    uint8_t         bytes[SMC_MAX_BYTES];
} smc_param;

_Static_assert(sizeof(smc_param) == 80, "SMC param struct must be 80 bytes");

/* ---------------------------------------------------------------------------
 * Key-info cache: open addressing, linear probing, grows at 50% load.
 * ------------------------------------------------------------------------- */

typedef struct {
    uint32_t key;      /* 0 = empty slot */
    uint32_t type;
    uint32_t size;
    uint8_t  attributes;
    uint8_t  found;    /* 0 = negative cache entry */
} cache_entry;

struct smc_conn {
    io_connect_t        port;
    os_unfair_lock      lock;
    cache_entry        *table;
    uint32_t            capacity; /* power of two */
    uint32_t            used;
};

static inline uint32_t hash_key(uint32_t k) {
    k ^= k >> 16; k *= 0x7feb352dU; k ^= k >> 15; k *= 0x846ca68bU; k ^= k >> 16;
    return k;
}

static cache_entry *cache_find(smc_conn *c, uint32_t key) {
    if (!c->table) return NULL;
    uint32_t mask = c->capacity - 1;
    for (uint32_t i = hash_key(key) & mask;; i = (i + 1) & mask) {
        cache_entry *e = &c->table[i];
        if (e->key == key) return e;
        if (e->key == 0) return NULL;
    }
}

static bool cache_grow(smc_conn *c) {
    uint32_t ncap = c->capacity ? c->capacity * 2 : 2048;
    cache_entry *nt = calloc(ncap, sizeof(cache_entry));
    if (!nt) return false;
    for (uint32_t i = 0; i < c->capacity; i++) {
        cache_entry *e = &c->table[i];
        if (!e->key) continue;
        uint32_t j = hash_key(e->key) & (ncap - 1);
        while (nt[j].key) j = (j + 1) & (ncap - 1);
        nt[j] = *e;
    }
    free(c->table);
    c->table = nt;
    c->capacity = ncap;
    return true;
}

static void cache_put(smc_conn *c, const cache_entry *src) {
    if ((c->used + 1) * 2 > c->capacity && !cache_grow(c)) return;
    uint32_t mask = c->capacity - 1;
    uint32_t i = hash_key(src->key) & mask;
    while (c->table[i].key && c->table[i].key != src->key) i = (i + 1) & mask;
    if (!c->table[i].key) c->used++;
    c->table[i] = *src;
}

/* ---------------------------------------------------------------------------
 * Low-level call
 * ------------------------------------------------------------------------- */

static int smc_call(smc_conn *c, smc_param *in, smc_param *out) {
    size_t out_size = sizeof(smc_param);
    kern_return_t kr = IOConnectCallStructMethod(c->port, KERNEL_INDEX_SMC,
                                                 in, sizeof(smc_param), out, &out_size);
    if (kr == kIOReturnNotPrivileged) return SMC_ERR_NOT_PRIVILEGED;
    if (kr != kIOReturnSuccess) return (int)kr;
    if (out->result == SMC_RESULT_KEY_NOT_FOUND) return SMC_ERR_KEY_NOT_FOUND;
    if (out->result != 0) return SMC_ERR_CALL;
    return SMC_OK;
}

int smc_open(smc_conn **out) {
    *out = NULL;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return SMC_ERR_NO_SERVICE;
    smc_conn *c = calloc(1, sizeof(smc_conn));
    if (!c) { IOObjectRelease(svc); return SMC_ERR_NOMEM; }
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &c->port);
    IOObjectRelease(svc);
    if (kr != kIOReturnSuccess) { free(c); return SMC_ERR_OPEN; }
    c->lock = OS_UNFAIR_LOCK_INIT;
    *out = c;
    return SMC_OK;
}

void smc_close(smc_conn *c) {
    if (!c) return;
    IOServiceClose(c->port);
    free(c->table);
    free(c);
}

int smc_key_info_get(smc_conn *c, uint32_t key, smc_key_info *info) {
    os_unfair_lock_lock(&c->lock);
    cache_entry *e = cache_find(c, key);
    if (e) {
        cache_entry copy = *e;
        os_unfair_lock_unlock(&c->lock);
        if (!copy.found) return SMC_ERR_KEY_NOT_FOUND;
        info->key = key; info->type = copy.type; info->size = copy.size; info->attributes = copy.attributes;
        return SMC_OK;
    }
    os_unfair_lock_unlock(&c->lock);

    smc_param in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    int rc = smc_call(c, &in, &out);

    cache_entry ne = { .key = key };
    if (rc == SMC_OK) {
        ne.type = out.keyinfo.data_type;
        ne.size = out.keyinfo.data_size;
        ne.attributes = out.keyinfo.data_attributes;
        ne.found = 1;
    }
    if (rc == SMC_OK || rc == SMC_ERR_KEY_NOT_FOUND) {
        os_unfair_lock_lock(&c->lock);
        cache_put(c, &ne);
        os_unfair_lock_unlock(&c->lock);
    }
    if (rc != SMC_OK) return rc;
    info->key = key; info->type = ne.type; info->size = ne.size; info->attributes = ne.attributes;
    return SMC_OK;
}

void smc_key_info_seed(smc_conn *c, const smc_key_info *info) {
    cache_entry e = { .key = info->key, .type = info->type, .size = info->size,
                      .attributes = info->attributes, .found = 1 };
    os_unfair_lock_lock(&c->lock);
    cache_put(c, &e);
    os_unfair_lock_unlock(&c->lock);
}

int smc_key_count(smc_conn *c, uint32_t *count) {
    smc_value v;
    int rc = smc_read(c, smc_fourcc("#KEY"), &v);
    if (rc != SMC_OK) return rc;
    if (v.size != 4) return SMC_ERR_SIZE;
    *count = ((uint32_t)v.bytes[0] << 24) | ((uint32_t)v.bytes[1] << 16) |
             ((uint32_t)v.bytes[2] << 8) | v.bytes[3];
    return SMC_OK;
}

int smc_key_at_index(smc_conn *c, uint32_t index, uint32_t *key) {
    smc_param in = {0}, out = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    int rc = smc_call(c, &in, &out);
    if (rc != SMC_OK) return rc;
    *key = out.key;
    return SMC_OK;
}

int smc_read(smc_conn *c, uint32_t key, smc_value *outv) {
    smc_key_info info;
    int rc = smc_key_info_get(c, key, &info);
    if (rc != SMC_OK) return rc;
    if (info.size > SMC_MAX_BYTES) return SMC_ERR_SIZE;

    smc_param in = {0}, out = {0};
    in.key = key;
    in.keyinfo.data_size = info.size;
    in.data8 = SMC_CMD_READ_BYTES;
    rc = smc_call(c, &in, &out);
    if (rc != SMC_OK) return rc;

    outv->key = key;
    outv->type = info.type;
    outv->size = info.size;
    memcpy(outv->bytes, out.bytes, SMC_MAX_BYTES);
    return SMC_OK;
}

int smc_write(smc_conn *c, uint32_t key, const uint8_t *bytes, uint32_t size) {
    smc_key_info info;
    int rc = smc_key_info_get(c, key, &info);
    if (rc != SMC_OK) return rc;
    if (size != info.size || size > SMC_MAX_BYTES) return SMC_ERR_SIZE;

    smc_param in = {0}, out = {0};
    in.key = key;
    in.keyinfo.data_size = size;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, size);
    return smc_call(c, &in, &out);
}

int smc_read_double(smc_conn *c, uint32_t key, double *out) {
    smc_value v;
    int rc = smc_read(c, key, &v);
    if (rc != SMC_OK) return rc;
    return smc_decode_double(v.type, v.bytes, v.size, out) ? SMC_OK : SMC_ERR_TYPE;
}

/* ---------------------------------------------------------------------------
 * Type codecs
 * ------------------------------------------------------------------------- */

uint32_t smc_fourcc(const char *s) {
    uint32_t v = 0;
    bool end = false;
    for (int i = 0; i < 4; i++) {
        if (!end && !s[i]) end = true;
        v = (v << 8) | (end ? (uint8_t)' ' : (uint8_t)s[i]);
    }
    return v;
}

void smc_fourcc_str(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0;
}

static int hexval(char ch) {
    if (ch >= '0' && ch <= '9') return ch - '0';
    if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
    return -1;
}

static uint64_t be_uint(const uint8_t *b, uint32_t n) {
    uint64_t v = 0;
    for (uint32_t i = 0; i < n; i++) v = (v << 8) | b[i];
    return v;
}

static void put_be(uint8_t *b, uint32_t n, uint64_t v) {
    for (uint32_t i = 0; i < n; i++) b[n - 1 - i] = (uint8_t)(v >> (8 * i));
}

#define T(a,b,c,d) (((uint32_t)(a)<<24)|((uint32_t)(b)<<16)|((uint32_t)(c)<<8)|(uint32_t)(d))

bool smc_decode_double(uint32_t type, const uint8_t *b, uint32_t size, double *out) {
    char t0 = (char)(type >> 24), t1 = (char)(type >> 16), t2 = (char)(type >> 8), t3 = (char)type;

    switch (type) {
    case T('f','l','t',' '):
        if (size != 4) return false;
        { float f; memcpy(&f, b, 4); *out = f; }  /* little-endian, native */
        return true;
    case T('f','l','a','g'):
        if (size < 1) return false;
        *out = b[0] ? 1 : 0;
        return true;
    case T('i','o','f','t'):
        if (size != 8) return false;
        { uint64_t v; memcpy(&v, b, 8); *out = (double)v / 65536.0; }
        return true;
    case T('u','i','8',' '): if (size != 1) return false; *out = b[0]; return true;
    case T('u','i','1','6'): if (size != 2) return false; *out = (double)be_uint(b, 2); return true;
    case T('u','i','3','2'): if (size != 4) return false; *out = (double)be_uint(b, 4); return true;
    case T('u','i','6','4'): if (size != 8) return false; *out = (double)be_uint(b, 8); return true;
    case T('s','i','8',' '): if (size != 1) return false; *out = (int8_t)b[0]; return true;
    case T('s','i','1','6'): if (size != 2) return false; *out = (int16_t)be_uint(b, 2); return true;
    case T('s','i','3','2'): if (size != 4) return false; *out = (int32_t)be_uint(b, 4); return true;
    case T('s','i','6','4'): if (size != 8) return false; *out = (double)(int64_t)be_uint(b, 8); return true;
    case T('h','e','x','_'):
        if (size == 0 || size > 8) return false;
        *out = (double)be_uint(b, size);
        return true;
    case T('p','w','m',' '):
        if (size != 2) return false;
        *out = (double)be_uint(b, 2) * 100.0 / 65536.0;
        return true;
    }

    /* fpXY (unsigned) / spXY (signed) fixed point, 16-bit big-endian; Y = fraction bits (hex). */
    if ((t0 == 'f' || t0 == 's') && t1 == 'p' && size == 2) {
        int ib = hexval(t2), fb = hexval(t3);
        if (ib < 0 || fb < 0) return false;
        uint16_t raw = (uint16_t)be_uint(b, 2);
        *out = (t0 == 's') ? (double)(int16_t)raw / (double)(1 << fb)
                           : (double)raw / (double)(1 << fb);
        return true;
    }
    return false;
}

bool smc_encode_double(uint32_t type, uint32_t size, double v, uint8_t *b) {
    char t0 = (char)(type >> 24), t1 = (char)(type >> 16), t2 = (char)(type >> 8), t3 = (char)type;
    memset(b, 0, size);

    switch (type) {
    case T('f','l','t',' '):
        if (size != 4) return false;
        { float f = (float)v; memcpy(b, &f, 4); }
        return true;
    case T('f','l','a','g'):
        if (size < 1) return false;
        b[0] = v != 0;
        return true;
    case T('u','i','8',' '):
    case T('u','i','1','6'):
    case T('u','i','3','2'):
    case T('u','i','6','4'):
    case T('h','e','x','_'):
        if (size == 0 || size > 8 || v < 0) return false;
        put_be(b, size, (uint64_t)(v + 0.5));
        return true;
    case T('s','i','8',' '):
    case T('s','i','1','6'):
    case T('s','i','3','2'):
    case T('s','i','6','4'):
        if (size == 0 || size > 8) return false;
        put_be(b, size, (uint64_t)(int64_t)(v < 0 ? v - 0.5 : v + 0.5));
        return true;
    }

    if ((t0 == 'f' || t0 == 's') && t1 == 'p' && size == 2) {
        int ib = hexval(t2), fb = hexval(t3);
        if (ib < 0 || fb < 0) return false;
        double scaled = v * (double)(1 << fb);
        if (t0 == 'f') {
            if (scaled < 0 || scaled > 65535) return false;
            put_be(b, 2, (uint16_t)(scaled + 0.5));
        } else {
            if (scaled < -32768 || scaled > 32767) return false;
            put_be(b, 2, (uint16_t)(int16_t)(scaled < 0 ? scaled - 0.5 : scaled + 0.5));
        }
        return true;
    }
    return false;
}

/* ---------------------------------------------------------------------------
 * IOHIDEventSystem temperature sensors (Apple Silicon). Resolved via dlsym so
 * missing private symbols never break linking or loading.
 * ------------------------------------------------------------------------- */

typedef CFTypeRef (*fn_client_create)(CFAllocatorRef);
typedef int       (*fn_set_matching)(CFTypeRef, CFDictionaryRef);
typedef CFArrayRef(*fn_copy_services)(CFTypeRef);
typedef CFTypeRef (*fn_copy_event)(CFTypeRef, int64_t, int32_t, int64_t);
typedef CFTypeRef (*fn_copy_property)(CFTypeRef, CFStringRef);
typedef double    (*fn_get_float)(CFTypeRef, int32_t);

#define HID_EVENT_TYPE_TEMPERATURE 15
#define HID_FIELD_TEMPERATURE (HID_EVENT_TYPE_TEMPERATURE << 16)

struct smc_hid {
    CFTypeRef       client;
    CFArrayRef      services;
    int             count;
    char          (*names)[64];
    fn_copy_event   copy_event;
    fn_get_float    get_float;
};

smc_hid *smc_hid_open(void) {
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!h) return NULL;
    fn_client_create create   = (fn_client_create)dlsym(h, "IOHIDEventSystemClientCreate");
    fn_set_matching  matching = (fn_set_matching)dlsym(h, "IOHIDEventSystemClientSetMatching");
    fn_copy_services services = (fn_copy_services)dlsym(h, "IOHIDEventSystemClientCopyServices");
    fn_copy_event    event    = (fn_copy_event)dlsym(h, "IOHIDServiceClientCopyEvent");
    fn_copy_property property = (fn_copy_property)dlsym(h, "IOHIDServiceClientCopyProperty");
    fn_get_float     getf     = (fn_get_float)dlsym(h, "IOHIDEventGetFloatValue");
    if (!create || !matching || !services || !event || !property || !getf) return NULL;

    CFTypeRef client = create(kCFAllocatorDefault);
    if (!client) return NULL;

    int page = 0xff00, usage = 5;
    CFNumberRef npage = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef nusage = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { npage, nusage };
    CFDictionaryRef dict = CFDictionaryCreate(NULL, keys, vals, 2,
                                              &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    matching(client, dict);
    CFRelease(dict); CFRelease(npage); CFRelease(nusage);

    CFArrayRef svcs = services(client);
    int n = svcs ? (int)CFArrayGetCount(svcs) : 0;
    if (n == 0) {
        if (svcs) CFRelease(svcs);
        CFRelease(client);
        return NULL;
    }

    smc_hid *hid = calloc(1, sizeof(smc_hid));
    if (hid) hid->names = calloc((size_t)n, 64);
    if (!hid || !hid->names) { free(hid); CFRelease(svcs); CFRelease(client); return NULL; }
    hid->client = client;
    hid->services = svcs;
    hid->count = n;
    hid->copy_event = event;
    hid->get_float = getf;
    for (int i = 0; i < n; i++) {
        CFTypeRef svc = CFArrayGetValueAtIndex(svcs, i);
        CFTypeRef name = property(svc, CFSTR("Product"));
        if (name && CFGetTypeID(name) == CFStringGetTypeID())
            CFStringGetCString((CFStringRef)name, hid->names[i], 64, kCFStringEncodingUTF8);
        else
            snprintf(hid->names[i], 64, "HID sensor %d", i);
        if (name) CFRelease(name);
    }
    return hid;
}

void smc_hid_close(smc_hid *hid) {
    if (!hid) return;
    CFRelease(hid->services);
    CFRelease(hid->client);
    free(hid->names);
    free(hid);
}

int smc_hid_count(smc_hid *hid) { return hid ? hid->count : 0; }

int smc_hid_read(smc_hid *hid, smc_hid_reading *out, int max) {
    if (!hid) return 0;
    int w = 0;
    for (int i = 0; i < hid->count && w < max; i++) {
        CFTypeRef svc = CFArrayGetValueAtIndex(hid->services, i);
        CFTypeRef ev = hid->copy_event(svc, HID_EVENT_TYPE_TEMPERATURE, 0, 0);
        if (!ev) continue;
        double t = hid->get_float(ev, HID_FIELD_TEMPERATURE);
        CFRelease(ev);
        if (t <= 0 || t > 150) continue;
        memcpy(out[w].name, hid->names[i], 64);
        out[w].celsius = t;
        w++;
    }
    return w;
}
