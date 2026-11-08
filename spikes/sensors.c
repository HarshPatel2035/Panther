// Spike 2: everything Panther senses. No root needed.
#include "common.h"
#include <IOKit/ps/IOPowerSources.h>
#include <IOKit/ps/IOPSKeys.h>
#include <CoreGraphics/CoreGraphics.h>
#include <notify.h>
#include <libkern/OSThermalNotification.h>

static void print_cf(const char *label, CFTypeRef v) {
    char buf[128] = "n/a";
    if (v) {
        CFStringRef s = CFCopyDescription(v);
        CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8);
        CFRelease(s);
    }
    printf("%s: %s\n", label, buf);
}

int main(void) {
    printf("lid closed (AppleClamshellState): %d\n", read_bool_property("IOPMrootDomain", CFSTR("AppleClamshellState")));
    printf("lid close causes sleep (AppleClamshellCausesSleep): %d\n", read_bool_property("IOPMrootDomain", CFSTR("AppleClamshellCausesSleep")));
    printf("SleepDisabled: %d\n", read_sleep_disabled());

    uint32_t n = 0; CGDirectDisplayID ids[16];
    CGGetOnlineDisplayList(16, ids, &n);
    int external = 0;
    for (uint32_t i = 0; i < n; i++) {
        int builtin = CGDisplayIsBuiltin(ids[i]), active = CGDisplayIsActive(ids[i]);
        printf("display %u: builtin=%d active=%d asleep=%d\n", ids[i], builtin, active, CGDisplayIsAsleep(ids[i]));
        if (!builtin && active) external++;
    }
    printf("active external displays: %d\n", external);

    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFArrayRef list = info ? IOPSCopyPowerSourcesList(info) : NULL;
    for (CFIndex i = 0; list && i < CFArrayGetCount(list); i++) {
        CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
        print_cf("battery %", CFDictionaryGetValue(d, CFSTR(kIOPSCurrentCapacityKey)));
        print_cf("power source", CFDictionaryGetValue(d, CFSTR(kIOPSPowerSourceStateKey)));
    }
    if (list) CFRelease(list);
    if (info) CFRelease(info);

    // Battery temperature reads 0 on this M2 Air / macOS 27 (AverageBattSkinTemp=0), so heat comes
    // from the public thermal-pressure notification, and power draw from PowerTelemetryData.SystemLoad (mW).
    int token = 0; uint64_t pressure = 0;
    if (notify_register_check(kOSThermalNotificationPressureLevelName, &token) == NOTIFY_STATUS_OK &&
        notify_get_state(token, &pressure) == NOTIFY_STATUS_OK)
        printf("thermal pressure level: %llu (0 nominal, 1 moderate, 2 heavy, 3 trapping, 4 sleeping)\n", pressure);
    io_service_t bat = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (bat) {
        CFDictionaryRef tel = IORegistryEntryCreateCFProperty(bat, CFSTR("PowerTelemetryData"), kCFAllocatorDefault, 0);
        if (tel) {
            CFNumberRef load = CFDictionaryGetValue(tel, CFSTR("SystemLoad"));
            int mw = 0;
            if (load && CFNumberGetValue(load, kCFNumberIntType, &mw)) printf("system load: %.2f W\n", mw / 1000.0);
            CFRelease(tel);
        }
        IOObjectRelease(bat);
    }
    return 0;
}
