#ifndef THERMO_AWDL_H
#define THERMO_AWDL_H
#include <stdbool.h>
#include <stdint.h>
/* Fixed awdl0 only. Returns errno, never invokes a subprocess. */
int thermo_awdl_read(uint32_t *index, bool *up);
int thermo_awdl_set_up(uint32_t expected_index, bool up);
#endif
