// Spike 1: read/set SleepDisabled through IOKit directly, as pmset does. No shell, no sudoers.
//   build/spike-sleepguard get
//   sudo build/spike-sleepguard set 1 ; pmset -g | grep SleepDisabled ; sudo build/spike-sleepguard set 0
#include "common.h"
#include <string.h>

int main(int argc, char **argv) {
    if (argc >= 2 && strcmp(argv[1], "get") == 0) {
        printf("SleepDisabled = %d (euid %d)\n", read_sleep_disabled(), geteuid());
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "set") == 0 && (argv[2][0] == '0' || argv[2][0] == '1') && !argv[2][1]) {
        CFBooleanRef value = argv[2][0] == '1' ? kCFBooleanTrue : kCFBooleanFalse;
        IOReturn r = IOPMSetSystemPowerSetting(CFSTR("SleepDisabled"), value);
        printf("IOPMSetSystemPowerSetting(SleepDisabled, %s) -> 0x%08x %s\n", argv[2], r,
               r == kIOReturnSuccess ? "success" : (r == kIOReturnNotPrivileged ? "NOT PRIVILEGED (run as root)" : "FAILED"));
        usleep(500 * 1000);
        printf("read back: SleepDisabled = %d\n", read_sleep_disabled());
        return r == kIOReturnSuccess ? 0 : 1;
    }
    fprintf(stderr, "usage: %s get | set 0|1\n", argv[0]);
    return 2;
}
