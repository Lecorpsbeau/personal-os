#ifndef CProcessRusage_h
#define CProcessRusage_h

#include <stdint.h>

int get_process_disk_io(
    int pid,
    uint64_t *read_bytes,
    uint64_t *write_bytes
);

#endif
