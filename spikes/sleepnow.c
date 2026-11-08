// Spike 3: put the Mac to sleep immediately, as `pmset sleepnow` does (IOPMSleepSystem).
// Panther's fix for Insomnia #94. WARNING: this really sleeps your Mac.
//   build/spike-sleepnow --yes
#include "common.h"
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "--yes")) { fprintf(stderr, "this sleeps the Mac now; pass --yes\n"); return 2; }
    io_connect_t pm = IOPMFindPowerManagement(kIOMainPortDefault);
    if (!pm) { fprintf(stderr, "IOPMFindPowerManagement failed\n"); return 1; }
    IOReturn r = IOPMSleepSystem(pm);
    printf("IOPMSleepSystem -> 0x%08x (euid %d)\n", r, geteuid());
    IOServiceClose(pm);
    return r == kIOReturnSuccess ? 0 : 1;
}
