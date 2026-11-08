// Spike 5: control the built-in panel through private DisplayServices.framework.
// Reverse engineered with tools/fndump (docs/03-re-findings.md):
//   int  DisplayServicesHasPowerMode(CGDirectDisplayID)
//   int  DisplayServicesGetPowerMode(CGDirectDisplayID)               -> value of key "DisplayServicesPowerMode"
//   void*DisplayServicesSetPowerMode(CGDirectDisplayID, int mode)      -> sets that key
//   int  DisplayServicesGetBrightness(CGDirectDisplayID, float *out)  -> key "DisplayServicesBrightness"
//   int  DisplayServicesSetBrightness(CGDirectDisplayID, float value)
//
//   build/spike-display get
//   build/spike-display try-brightness-off 5   # panel to 0 for 5 s, then restores the saved value
//   build/spike-display try-powermode <mode> 5 # set power mode for 5 s, then restores
#include <CoreGraphics/CoreGraphics.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int DisplayServicesHasPowerMode(CGDirectDisplayID d);
int DisplayServicesGetPowerMode(CGDirectDisplayID d);
void *DisplayServicesSetPowerMode(CGDirectDisplayID d, int mode);
int DisplayServicesCanChangeBrightness(CGDirectDisplayID d);
int DisplayServicesGetBrightness(CGDirectDisplayID d, float *out);
int DisplayServicesSetBrightness(CGDirectDisplayID d, float value);

static CGDirectDisplayID builtin_display(void) {
    uint32_t n = 0; CGDirectDisplayID ids[16];
    CGGetOnlineDisplayList(16, ids, &n);
    for (uint32_t i = 0; i < n; i++) if (CGDisplayIsBuiltin(ids[i])) return ids[i];
    return kCGNullDirectDisplay;
}

static void report(CGDirectDisplayID d) {
    float b = -1;
    int rb = DisplayServicesGetBrightness(d, &b);
    printf("display %u: canChangeBrightness=%d brightness=%.3f (rc %d) hasPowerMode=%d powerMode=%d asleep=%d\n",
           d, DisplayServicesCanChangeBrightness(d), b, rb, DisplayServicesHasPowerMode(d),
           DisplayServicesGetPowerMode(d), CGDisplayIsAsleep(d));
}

int main(int argc, char **argv) {
    CGDirectDisplayID d = builtin_display();
    if (d == kCGNullDirectDisplay) { fprintf(stderr, "no built-in display online (lid closed?)\n"); return 1; }
    if (argc >= 2 && !strcmp(argv[1], "get")) { report(d); return 0; }

    int secs = argc >= 3 ? atoi(argv[argc - 1]) : 5;
    if (secs < 1 || secs > 30) secs = 5;
    if (argc == 3 && !strcmp(argv[1], "try-brightness-off")) {
        float saved = -1;
        if (DisplayServicesGetBrightness(d, &saved) != 0 || saved < 0) { fprintf(stderr, "cannot read brightness\n"); return 1; }
        printf("saved brightness %.3f; setting 0 for %d s\n", saved, secs);
        DisplayServicesSetBrightness(d, 0.0f);
        report(d); sleep(secs);
        DisplayServicesSetBrightness(d, saved);
        report(d); return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "try-powermode")) {
        int saved = DisplayServicesGetPowerMode(d), mode = atoi(argv[2]);
        printf("saved power mode %d; setting %d for %d s\n", saved, mode, secs);
        DisplayServicesSetPowerMode(d, mode);
        sleep(1); report(d); sleep(secs - 1 > 0 ? secs - 1 : 1);
        DisplayServicesSetPowerMode(d, saved);
        sleep(1); report(d); return 0;
    }
    fprintf(stderr, "usage: %s get | try-brightness-off <s> | try-powermode <mode> <s>\n", argv[0]);
    return 2;
}
