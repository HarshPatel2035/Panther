// Spike 6: keyboard backlight through private CoreBrightness (KeyboardBrightnessClient).
// Method signatures recovered with tools/objcdump (docs/03-re-findings.md).
//   build/spike-keyboard get
//   build/spike-keyboard try-off 3    # backlight off (and auto off) for 3 s, then restores both
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>

@interface KeyboardBrightnessClient : NSObject
- (NSArray<NSNumber *> *)copyKeyboardBacklightIDs;
- (float)brightnessForKeyboard:(unsigned long long)kid;
- (BOOL)setBrightness:(float)level forKeyboard:(unsigned long long)kid;
- (BOOL)isAutoBrightnessEnabledForKeyboard:(unsigned long long)kid;
- (BOOL)enableAutoBrightness:(BOOL)on forKeyboard:(unsigned long long)kid;
- (BOOL)isKeyboardBuiltIn:(unsigned long long)kid;
- (BOOL)isBacklightSuppressedOnKeyboard:(unsigned long long)kid;
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)) return 1;
        Class cls = NSClassFromString(@"KeyboardBrightnessClient");
        KeyboardBrightnessClient *client = [[cls alloc] init];
        NSArray<NSNumber *> *ids = [client copyKeyboardBacklightIDs];
        for (NSNumber *n in ids) {
            unsigned long long k = n.unsignedLongLongValue;
            printf("keyboard %llu: builtIn=%d brightness=%.3f auto=%d suppressed=%d\n", k, [client isKeyboardBuiltIn:k],
                   [client brightnessForKeyboard:k], [client isAutoBrightnessEnabledForKeyboard:k],
                   [client isBacklightSuppressedOnKeyboard:k]);
        }
        if (argc == 3 && !strcmp(argv[1], "try-off")) {
            int secs = atoi(argv[2]); if (secs < 1 || secs > 10) secs = 3;
            for (NSNumber *n in ids) {
                unsigned long long k = n.unsignedLongLongValue;
                if (![client isKeyboardBuiltIn:k]) continue;
                float saved = [client brightnessForKeyboard:k];
                BOOL savedAuto = [client isAutoBrightnessEnabledForKeyboard:k];
                [client enableAutoBrightness:NO forKeyboard:k];
                BOOL ok = [client setBrightness:0 forKeyboard:k];
                printf("off: set=%d now=%.3f (saved %.3f, auto %d)\n", ok, [client brightnessForKeyboard:k], saved, savedAuto);
                sleep(secs);
                [client setBrightness:saved forKeyboard:k];
                [client enableAutoBrightness:savedAuto forKeyboard:k];
                printf("restored: now=%.3f auto=%d\n", [client brightnessForKeyboard:k], [client isAutoBrightnessEnabledForKeyboard:k]);
            }
        }
    }
    return 0;
}
