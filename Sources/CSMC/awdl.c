#include "awdl.h"
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sockio.h>
#include <unistd.h>

static int awdl_read_on(int fd, struct ifreq *request, uint32_t *index) {
    errno = 0;
    unsigned before = if_nametoindex("awdl0");
    if (!before) return errno ? errno : ENXIO;
    memset(request, 0, sizeof(*request));
    memcpy(request->ifr_name, "awdl0", sizeof("awdl0"));
    if (ioctl(fd, SIOCGIFFLAGS, request) < 0) return errno;
    if (if_nametoindex("awdl0") != before) return ESTALE;
    *index = before;
    return 0;
}

static int awdl_socket(void) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd >= 0 && fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        int failure = errno; close(fd); errno = failure; return -1;
    }
    return fd;
}

int thermo_awdl_read(uint32_t *index, bool *up) {
    if (!index || !up) return EINVAL;
    *index = 0; *up = false;
    int fd = awdl_socket();
    if (fd < 0) return errno;
    struct ifreq request;
    uint32_t observed = 0;
    int result = awdl_read_on(fd, &request, &observed);
    if (!result) { *index = observed; *up = (request.ifr_flags & IFF_UP) != 0; }
    close(fd);
    return result;
}

int thermo_awdl_set_up(uint32_t expected_index, bool up) {
    if (geteuid() != 0) return EPERM;
    if (!expected_index) return EINVAL;
    int fd = awdl_socket();
    if (fd < 0) return errno;
    struct ifreq request;
    uint32_t observed = 0;
    int result = awdl_read_on(fd, &request, &observed);
    if (!result && observed != expected_index) result = ESTALE;
    if (!result) {
        if (up) request.ifr_flags |= IFF_UP;
        else request.ifr_flags &= ~IFF_UP;
        if (if_nametoindex("awdl0") != expected_index) result = ESTALE;
        else if (ioctl(fd, SIOCSIFFLAGS, &request) < 0) result = errno;
    }
    if (!result) {
        result = awdl_read_on(fd, &request, &observed);
        if (!result && (observed != expected_index || ((request.ifr_flags & IFF_UP) != 0) != up)) result = ESTALE;
    }
    close(fd);
    return result;
}
