#include "CProcessRusage.h"

#include <libproc.h>
#include <sys/resource.h>

int get_process_disk_io(
    int pid,
    uint64_t *read_bytes,
    uint64_t *write_bytes
) {
    if (read_bytes == NULL || write_bytes == NULL) {
        return -1;
    }

    *read_bytes = 0;
    *write_bytes = 0;

    struct rusage_info_v4 usage = {0};

    rusage_info_t buffer = &usage;

    int result = proc_pid_rusage(
        pid,
        RUSAGE_INFO_V4,
        &buffer
    );

    if (result != 0) {
        return result;
    }

    *read_bytes = usage.ri_diskio_bytesread;
    *write_bytes = usage.ri_diskio_byteswritten;

    return 0;
}
