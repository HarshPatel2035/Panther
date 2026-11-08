// Shared helpers for Phase 0 spikes. Written in C because the Swift toolchain on this
// Mac (Command Line Tools) can't import Foundation: SDK/compiler mismatch.
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <stdio.h>
#include <unistd.h>

// Private IOKit power APIs, found as imports of /usr/bin/pmset (not in public headers).
CFDictionaryRef IOPMCopySystemPowerSettings(void);
IOReturn IOPMSetSystemPowerSetting(CFStringRef key, CFTypeRef value);

__attribute__((unused)) static io_service_t root_domain(void) {
    return IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IOPMrootDomain"));
}

// Returns 1/0, or -1 if unreadable.
__attribute__((unused)) static int read_bool_property(const char *service_class, CFStringRef key) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(service_class));
    if (!svc) return -1;
    CFTypeRef v = IORegistryEntryCreateCFProperty(svc, key, kCFAllocatorDefault, 0);
    IOObjectRelease(svc);
    if (!v) return -1;
    int out = (CFGetTypeID(v) == CFBooleanGetTypeID()) ? CFBooleanGetValue(v) : -1;
    CFRelease(v);
    return out;
}

__attribute__((unused)) static int read_sleep_disabled(void) {
    CFDictionaryRef d = IOPMCopySystemPowerSettings();
    if (!d) return -1;
    int out = -1;
    CFTypeRef v = CFDictionaryGetValue(d, CFSTR("SleepDisabled"));
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) out = CFBooleanGetValue(v);
    else if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberIntType, &out);
    CFRelease(d);
    return out;
}
