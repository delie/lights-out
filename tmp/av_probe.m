#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/i2c/IOI2CInterface.h>

typedef CFTypeRef IOAVService;
extern IOAVService IOAVServiceCreate(CFAllocatorRef allocator);
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern void CGSServiceForDisplayNumber(CGDirectDisplayID display, io_service_t *service);

static NSString *serviceClassName(io_service_t service) {
    io_name_t className = {0};
    kern_return_t status = IOObjectGetClass(service, className);
    if (status != KERN_SUCCESS) {
        return @"<unknown>";
    }
    return [NSString stringWithUTF8String:className];
}

static uint64_t serviceRegistryID(io_service_t service) {
    uint64_t registryID = 0;
    IORegistryEntryGetRegistryEntryID(service, &registryID);
    return registryID;
}

static NSString *recursiveStringProperty(io_service_t service, NSString *name) {
    CFTypeRef property = IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        (__bridge CFStringRef)name,
        kCFAllocatorDefault,
        kIORegistryIterateRecursively
    );
    return CFBridgingRelease(property);
}

static BOOL shouldInspectClass(NSString *className) {
    NSArray<NSString *> *tokens = @[@"DCP", @"AV", @"Display", @"DP", @"CLCD", @"HPM"];
    for (NSString *token in tokens) {
        if ([className containsString:token]) {
            return YES;
        }
    }
    return NO;
}

static void logCreateAttempt(io_service_t service, NSString *prefix) {
    NSString *className = serviceClassName(service);
    NSString *location = recursiveStringProperty(service, @"Location");
    NSString *uuid = recursiveStringProperty(service, @"device UID") ?: recursiveStringProperty(service, @"EDID UUID");
    IOAVService avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
    NSLog(@"%@ reg=%llu class=%@ location=%@ uuid=%@ create=%@",
          prefix,
          serviceRegistryID(service),
          className ?: @"<unknown>",
          location ?: @"<nil>",
          uuid ?: @"<nil>",
          avService ? @"non-nil" : @"nil");
    if (avService) {
        CFRelease(avService);
    }
}

static void exploreSubtree(io_service_t root, NSString *label, NSMutableSet<NSNumber *> *seenIDs) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t status = IORegistryEntryCreateIterator(root, kIOServicePlane, kIORegistryIterateRecursively, &iterator);
    if (status != KERN_SUCCESS) {
        NSLog(@"%@ iterator failed => %d", label, status);
        return;
    }

    NSLog(@"%@ root reg=%llu class=%@", label, serviceRegistryID(root), serviceClassName(root));
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        uint64_t registryID = serviceRegistryID(service);
        NSNumber *boxedID = @(registryID);
        NSString *className = serviceClassName(service);
        if ([seenIDs containsObject:boxedID] || !shouldInspectClass(className ?: @"")) {
            IOObjectRelease(service);
            continue;
        }

        [seenIDs addObject:boxedID];
        logCreateAttempt(service, @"  candidate");
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);
}

static void exploreAncestors(io_service_t service, NSUInteger maxLevels) {
    NSMutableSet<NSNumber *> *seenIDs = [NSMutableSet set];
    io_registry_entry_t current = service;

    for (NSUInteger level = 0; level < maxLevels && current != IO_OBJECT_NULL; level++) {
        NSString *label = [NSString stringWithFormat:@"-- subtree level %lu", (unsigned long)level];
        exploreSubtree(current, label, seenIDs);

        io_registry_entry_t parent = IO_OBJECT_NULL;
        kern_return_t status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent);
        if (level > 0) {
            IOObjectRelease(current);
        }
        if (status != KERN_SUCCESS || parent == IO_OBJECT_NULL) {
            break;
        }
        current = parent;
    }

    if (current != service && current != IO_OBJECT_NULL) {
        IOObjectRelease(current);
    }
}

static NSString *displayName(CGDirectDisplayID displayID) {
    NSDictionary *info = CFBridgingRelease(IODisplayCreateInfoDictionary(CGDisplayIOServicePort(displayID), kIODisplayOnlyPreferredName));
    NSDictionary *names = info[@"DisplayProductName"];
    if ([names isKindOfClass:[NSDictionary class]]) {
        return names.allValues.firstObject ?: [NSString stringWithFormat:@"Display %u", displayID];
    }
    return [NSString stringWithFormat:@"Display %u", displayID];
}

int main(void) {
    @autoreleasepool {
        NSLog(@"--- Global IOAVServiceCreate ---");
        IOAVService globalService = IOAVServiceCreate(kCFAllocatorDefault);
        NSLog(@"IOAVServiceCreate => %@", globalService ? @"non-nil" : @"nil");
        if (globalService) {
            CFRelease(globalService);
        }

        NSLog(@"--- CGSServiceForDisplayNumber ---");
        uint32_t count = 0;
        CGGetOnlineDisplayList(0, NULL, &count);
        NSLog(@"CGGetOnlineDisplayList count => %u", count);
        CGDirectDisplayID displays[count];
        CGGetOnlineDisplayList(count, displays, &count);
        for (uint32_t i = 0; i < count; i++) {
            CGDirectDisplayID displayID = displays[i];
            io_service_t service = IO_OBJECT_NULL;
            CGSServiceForDisplayNumber(displayID, &service);
            NSLog(@"display %u (%@) -> service=%u class=%@", displayID, displayName(displayID), service, service ? serviceClassName(service) : @"<none>");
            if (service) {
                IOAVService avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
                NSLog(@"  IOAVServiceCreateWithService => %@", avService ? @"non-nil" : @"nil");
                if (avService) {
                    CFRelease(avService);
                }
            }

            io_service_t cgService = CGDisplayIOServicePort(displayID);
            NSLog(@"display %u (%@) -> CGDisplayIOServicePort=%u class=%@",
                  displayID,
                  displayName(displayID),
                  cgService,
                  cgService ? serviceClassName(cgService) : @"<none>");
            if (cgService) {
                IOAVService avService = IOAVServiceCreateWithService(kCFAllocatorDefault, cgService);
                NSLog(@"  IOAVServiceCreateWithService(CGDisplayIOServicePort) => %@", avService ? @"non-nil" : @"nil");
                if (avService) {
                    CFRelease(avService);
                }

                IOItemCount busCount = 0;
                kern_return_t busCountStatus = IOFBGetI2CInterfaceCount(cgService, &busCount);
                NSLog(@"  IOFBGetI2CInterfaceCount(CGDisplayIOServicePort) => %d, busCount=%u", busCountStatus, (unsigned int)busCount);
            }
        }

        NSLog(@"--- DCPAVServiceProxy enumeration ---");
        CFMutableDictionaryRef matching = IOServiceMatching("DCPAVServiceProxy");
        io_iterator_t iterator = IO_OBJECT_NULL;
        kern_return_t status = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
        NSLog(@"IOServiceGetMatchingServices(DCPAVServiceProxy) => %d", status);
        if (status == KERN_SUCCESS) {
            io_service_t service = IO_OBJECT_NULL;
            while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
                CFTypeRef location = IORegistryEntrySearchCFProperty(service, kIOServicePlane, CFSTR("Location"), kCFAllocatorDefault, kIORegistryIterateRecursively);
                NSString *locationString = CFBridgingRelease(location);
                IOAVService avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
                NSLog(@"service=%u reg=%llu class=%@ location=%@ create=%@",
                      service,
                      serviceRegistryID(service),
                      serviceClassName(service),
                      locationString ?: @"<nil>",
                      avService ? @"non-nil" : @"nil");
                if (avService) {
                    CFRelease(avService);
                }
                if ([locationString isEqualToString:@"External"]) {
                    exploreAncestors(service, 3);
                }
                IOObjectRelease(service);
            }
            IOObjectRelease(iterator);
        }

        NSLog(@"--- Targeted class sweep ---");
        NSArray<NSString *> *targetClasses = @[
            @"DCPAVControllerProxy",
            @"DCPDPControllerProxy",
            @"DCPAVDeviceProxy",
            @"DCPDPDeviceProxy",
            @"DCPAVServiceProxy",
            @"DCPDPServiceProxy",
            @"DCPAVVideoInterfaceProxy",
            @"DCPAVAudioInterfaceProxy",
            @"DCPAVAudioDriver",
            @"AppleDCPDPTXRemotePortProxy",
            @"AppleDCPDPTXRemotePortUFP",
            @"AppleDCPLinkServiceSoC"
        ];

        for (NSString *className in targetClasses) {
            NSLog(@"--- %@ ---", className);
            CFMutableDictionaryRef classMatching = IOServiceMatching(className.UTF8String);
            io_iterator_t classIterator = IO_OBJECT_NULL;
            kern_return_t classStatus = IOServiceGetMatchingServices(kIOMainPortDefault, classMatching, &classIterator);
            NSLog(@"IOServiceGetMatchingServices(%@) => %d", className, classStatus);
            if (classStatus != KERN_SUCCESS) {
                continue;
            }

            io_service_t service = IO_OBJECT_NULL;
            while ((service = IOIteratorNext(classIterator)) != IO_OBJECT_NULL) {
                logCreateAttempt(service, @"  service");
                IOObjectRelease(service);
            }

            IOObjectRelease(classIterator);
        }
    }
    return 0;
}
