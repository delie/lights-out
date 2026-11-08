// Diagnostic for LightsOut: finds monitors that WindowServer knows about but
// has switched off, and can switch one back on.
//
// Build:  clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//           tmp/hidden_display_probe.m -o /tmp/hidden_display_probe
// List:   /tmp/hidden_display_probe
// Enable: /tmp/hidden_display_probe --enable <displayID>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

extern CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);

static NSArray<NSNumber *> *savedIDs(NSString *key) {
    NSMutableOrderedSet<NSNumber *> *ids = [NSMutableOrderedSet orderedSet];
    NSString *containerPlist = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Containers/Steelworks.LightsOut/Data/Library/Preferences/Steelworks.LightsOut.plist"];
    NSString *plainPlist = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Preferences/Steelworks.LightsOut.plist"];
    for (NSString *path in @[containerPlist, plainPlist]) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
        for (id value in (NSArray *)prefs[key] ?: @[]) {
            if ([value isKindOfClass:[NSNumber class]]) [ids addObject:value];
        }
    }
    return ids.array;
}

static void describe(CGDirectDisplayID d, NSString *tag) {
    printf("  id=%-10u 0x%08x vendor=%-6u model=%-6u serial=%-10u online=%d active=%d builtin=%d %s\n",
           d, d, CGDisplayVendorNumber(d), CGDisplayModelNumber(d), CGDisplaySerialNumber(d),
           CGDisplayIsOnline(d), CGDisplayIsActive(d), CGDisplayIsBuiltin(d), tag.UTF8String);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--enable") == 0) {
            CGDirectDisplayID d = (CGDirectDisplayID)strtoul(argv[2], NULL, 0);
            CGDisplayConfigRef config = NULL;
            if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) { printf("begin failed\n"); return 1; }
            CGError status = CGSConfigureDisplayEnabled(config, d, true);
            if (status != kCGErrorSuccess) { CGCancelDisplayConfiguration(config); printf("enable(%u) returned %d\n", d, status); return 1; }
            CGError complete = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
            printf("enable(%u) ok, complete=%d\n", d, complete);
            [NSThread sleepForTimeInterval:2.0];
            describe(d, @"after enable");
            return 0;
        }

        uint32_t count = 0;
        CGDirectDisplayID online[32];
        CGGetOnlineDisplayList(32, online, &count);
        NSMutableSet<NSNumber *> *onlineSet = [NSMutableSet set];
        printf("Online displays (%u):\n", count);
        for (uint32_t i = 0; i < count; i++) { [onlineSet addObject:@(online[i])]; describe(online[i], @""); }

        NSArray *disabled = savedIDs(@"DisabledDisplayIDsForRecovery");
        NSArray *pending = savedIDs(@"PendingReactivationDisplayIDs");
        printf("\nLightsOut saved hidden IDs: %s\n", [disabled componentsJoinedByString:@", "].UTF8String ?: "");
        printf("LightsOut saved pending IDs: %s\n", [pending componentsJoinedByString:@", "].UTF8String ?: "");
        for (NSNumber *n in [disabled arrayByAddingObjectsFromArray:pending]) describe(n.unsignedIntValue, @"(saved)");

        printf("\nKnown to WindowServer but not online (IDs 1-1024 scanned):\n");
        NSMutableOrderedSet<NSNumber *> *candidates = [NSMutableOrderedSet orderedSet];
        for (uint32_t d = 1; d <= 1024; d++) [candidates addObject:@(d)];
        [candidates addObjectsFromArray:disabled];
        [candidates addObjectsFromArray:pending];
        BOOL any = NO;
        for (NSNumber *n in candidates) {
            CGDirectDisplayID d = n.unsignedIntValue;
            if ([onlineSet containsObject:n]) continue;
            uint32_t model = CGDisplayModelNumber(d), vendor = CGDisplayVendorNumber(d);
            BOOL modelKnown = model != 0 && model != UINT32_MAX;
            BOOL vendorKnown = vendor != 0 && vendor != UINT32_MAX;
            if (!modelKnown && !vendorKnown) continue;
            describe(d, @"");
            any = YES;
        }
        if (!any) printf("  (none found)\n");
    }
    return 0;
}
