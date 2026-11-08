// Spike 4: simulate a lid close/open without touching the lid. Reverse engineered from
// /usr/bin/pmset: its hidden "clamshell <0|1>" verb calls
// IORegistryEntrySetCFProperty(IOPMrootDomain, @"IOPMTestClamshellClose" | @"IOPMTestClamshellOpen", <number>).
// Needs root. With SleepDisabled=0 a simulated close may really sleep the Mac.
//   sudo build/spike-clamshell close ; build/spike-sensors ; sudo build/spike-clamshell open
#include "common.h"
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 2 || (strcmp(argv[1], "close") && strcmp(argv[1], "open"))) {
        fprintf(stderr, "usage: %s close|open\n", argv[0]); return 2;
    }
    int closing = !strcmp(argv[1], "close");
    io_service_t rd = root_domain();
    if (!rd) { fprintf(stderr, "IOPMrootDomain not found\n"); return 1; }
    int one = 1;
    CFNumberRef v = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &one);
    IOReturn r = IORegistryEntrySetCFProperty(rd, closing ? CFSTR("IOPMTestClamshellClose") : CFSTR("IOPMTestClamshellOpen"), v);
    CFRelease(v); IOObjectRelease(rd);
    printf("set %s -> 0x%08x (euid %d)\n", closing ? "IOPMTestClamshellClose" : "IOPMTestClamshellOpen", r, geteuid());
    usleep(300 * 1000);
    printf("AppleClamshellState now: %d\n", read_bool_property("IOPMrootDomain", CFSTR("AppleClamshellState")));
    return r == kIOReturnSuccess ? 0 : 1;
}
