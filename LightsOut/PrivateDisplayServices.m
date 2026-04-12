#import "PrivateDisplayServices.h"

#import <IOKit/i2c/IOI2CInterface.h>
#import <IOKit/graphics/IOGraphicsLib.h>

typedef CFTypeRef IOAVService;

extern IOAVService IOAVServiceCreate(CFAllocatorRef allocator);
extern IOAVService IOAVServiceCreateWithService(CFAllocatorRef allocator, io_service_t service);
extern IOReturn IOAVServiceReadI2C(IOAVService service, uint32_t chipAddress, uint32_t offset, void *outputBuffer, uint32_t outputBufferSize);
extern IOReturn IOAVServiceWriteI2C(IOAVService service, uint32_t chipAddress, uint32_t dataAddress, void *inputBuffer, uint32_t inputBufferSize);
extern void CGSServiceForDisplayNumber(CGDirectDisplayID display, io_service_t *service);

static const uint8_t kLODDCInputSourceControlID = 0x60;
static const uint8_t kLODDCGetVCPReplyOpcode = 0x02;
static const uint8_t kLODDCHostAddress = 0x51;
static const uint8_t kLODDCDisplayWriteAddress = 0x6E;
static const uint8_t kLODDCDisplayReadAddress = 0x6F;
static const uint32_t kLODDCChipAddress = 0x37;
static const uint32_t kLODDCDataAddress = 0x51;

static uint8_t LOChecksum(const uint8_t *bytes, size_t length, uint8_t initial) {
    uint8_t checksum = initial;
    for (size_t index = 0; index < length; index++) {
        checksum ^= bytes[index];
    }
    return checksum;
}

static BOOL LOParseDDCReply(const uint8_t *bytes, size_t length, uint8_t controlID, uint16_t *currentValue, uint16_t *maximumValue) {
    if (length < 8) {
        return NO;
    }

    size_t opcodeIndex = SIZE_MAX;
    for (size_t index = 0; index < length; index++) {
        if (bytes[index] == kLODDCGetVCPReplyOpcode) {
            opcodeIndex = index;
            break;
        }
    }

    if (opcodeIndex == SIZE_MAX || opcodeIndex + 7 >= length) {
        return NO;
    }

    if (bytes[opcodeIndex + 1] != 0x00 || bytes[opcodeIndex + 2] != controlID) {
        return NO;
    }

    if (maximumValue != NULL) {
        *maximumValue = (uint16_t)((bytes[opcodeIndex + 4] << 8) | bytes[opcodeIndex + 5]);
    }

    if (currentValue != NULL) {
        *currentValue = (uint16_t)((bytes[opcodeIndex + 6] << 8) | bytes[opcodeIndex + 7]);
    }

    return YES;
}

static NSInteger LOReadViaAVService(io_service_t service, uint16_t *currentValue, uint16_t *maximumValue) {
    IOAVService avService = IOAVServiceCreateWithService(kCFAllocatorDefault, service);
    if (avService == NULL) {
        return LOPrivateDDCStatusAVCreateFailed;
    }

    uint8_t writeBuffer[4] = { 0x82, 0x01, kLODDCInputSourceControlID, 0x00 };
    writeBuffer[3] = kLODDCDisplayWriteAddress ^ writeBuffer[0] ^ writeBuffer[1] ^ writeBuffer[2];

    IOReturn writeStatus = IOAVServiceWriteI2C(avService, kLODDCChipAddress, kLODDCDataAddress, writeBuffer, sizeof(writeBuffer));
    if (writeStatus != KERN_SUCCESS) {
        CFRelease(avService);
        return LOPrivateDDCStatusAVWriteFailed;
    }

    usleep(50000);

    uint8_t replyBuffer[12] = {0};
    IOReturn readStatus = IOAVServiceReadI2C(avService, kLODDCChipAddress, kLODDCDataAddress, replyBuffer, sizeof(replyBuffer));
    CFRelease(avService);

    if (readStatus != KERN_SUCCESS) {
        return LOPrivateDDCStatusAVReadFailed;
    }

    return LOParseDDCReply(replyBuffer, sizeof(replyBuffer), kLODDCInputSourceControlID, currentValue, maximumValue)
        ? LOPrivateDDCStatusSuccessAVService
        : LOPrivateDDCStatusAVReadFailed;
}

static NSInteger LOReadViaGlobalAVService(uint16_t *currentValue, uint16_t *maximumValue) {
    IOAVService avService = IOAVServiceCreate(kCFAllocatorDefault);
    if (avService == NULL) {
        return LOPrivateDDCStatusGlobalAVCreateFailed;
    }

    uint8_t writeBuffer[4] = { 0x82, 0x01, kLODDCInputSourceControlID, 0x00 };
    writeBuffer[3] = kLODDCDisplayWriteAddress ^ writeBuffer[0] ^ writeBuffer[1] ^ writeBuffer[2];

    IOReturn writeStatus = IOAVServiceWriteI2C(avService, kLODDCChipAddress, kLODDCDataAddress, writeBuffer, sizeof(writeBuffer));
    if (writeStatus != KERN_SUCCESS) {
        CFRelease(avService);
        return LOPrivateDDCStatusGlobalAVWriteFailed;
    }

    usleep(50000);

    uint8_t replyBuffer[12] = {0};
    IOReturn readStatus = IOAVServiceReadI2C(avService, kLODDCChipAddress, kLODDCDataAddress, replyBuffer, sizeof(replyBuffer));
    CFRelease(avService);

    if (readStatus != KERN_SUCCESS) {
        return LOPrivateDDCStatusGlobalAVReadFailed;
    }

    return LOParseDDCReply(replyBuffer, sizeof(replyBuffer), kLODDCInputSourceControlID, currentValue, maximumValue)
        ? LOPrivateDDCStatusSuccessGlobalAVService
        : LOPrivateDDCStatusGlobalAVReadFailed;
}

static NSInteger LOReadViaI2C(io_service_t service, uint16_t *currentValue, uint16_t *maximumValue) {
    IOItemCount busCount = 0;
    IOReturn busCountStatus = IOFBGetI2CInterfaceCount(service, &busCount);
    if (busCountStatus != KERN_SUCCESS) {
        return LOPrivateDDCStatusI2CBusCountFailed;
    }
    if (busCount == 0) {
        return LOPrivateDDCStatusI2CNoBuses;
    }

    for (IOItemCount busIndex = 0; busIndex < busCount; busIndex++) {
        io_service_t interface = IO_OBJECT_NULL;
        IOReturn copyStatus = IOFBCopyI2CInterfaceForBus(service, (IOOptionBits)busIndex, &interface);
        if (copyStatus != KERN_SUCCESS || interface == IO_OBJECT_NULL) {
            continue;
        }

        IOI2CConnectRef connect = NULL;
        IOReturn openStatus = IOI2CInterfaceOpen(interface, kNilOptions, &connect);
        IOObjectRelease(interface);
        if (openStatus != KERN_SUCCESS || connect == NULL) {
            continue;
        }

        uint8_t sendBuffer[5] = {
            kLODDCHostAddress,
            0x82,
            0x01,
            kLODDCInputSourceControlID,
            0x00
        };
        sendBuffer[4] = LOChecksum(sendBuffer, 4, kLODDCDisplayWriteAddress);

        uint8_t replyBuffer[16] = {0};
        IOI2CRequest request;
        bzero(&request, sizeof(request));
        request.sendTransactionType = kIOI2CSimpleTransactionType;
        request.replyTransactionType = kIOI2CDDCciReplyTransactionType;
        request.sendAddress = kLODDCDisplayWriteAddress;
        request.replyAddress = kLODDCDisplayReadAddress;
        request.sendBytes = (UInt32)sizeof(sendBuffer);
        request.replyBytes = (UInt32)sizeof(replyBuffer);
        request.minReplyDelay = 10000000;
        request.sendBuffer = (vm_address_t)(uintptr_t)sendBuffer;
        request.replyBuffer = (vm_address_t)(uintptr_t)replyBuffer;

        IOReturn requestStatus = IOI2CSendRequest(connect, kNilOptions, &request);
        IOI2CInterfaceClose(connect, kNilOptions);

        if (requestStatus == KERN_SUCCESS &&
            request.result == KERN_SUCCESS &&
            LOParseDDCReply(replyBuffer, request.replyBytes, kLODDCInputSourceControlID, currentValue, maximumValue)) {
            return LOPrivateDDCStatusSuccessI2C;
        }
    }

    return LOPrivateDDCStatusI2CReadFailed;
}

NSInteger LOReadInputSourceForDisplay(CGDirectDisplayID display, uint16_t *currentValue, uint16_t *maximumValue) {
    io_service_t service = IO_OBJECT_NULL;
    CGSServiceForDisplayNumber(display, &service);
    if (service != IO_OBJECT_NULL) {
        NSInteger avStatus = LOReadViaAVService(service, currentValue, maximumValue);
        if (avStatus > 0) {
            return avStatus;
        }

        NSInteger i2cStatus = LOReadViaI2C(service, currentValue, maximumValue);
        if (i2cStatus > 0) {
            return i2cStatus;
        }

        NSInteger globalAVStatus = LOReadViaGlobalAVService(currentValue, maximumValue);
        if (globalAVStatus > 0) {
            return globalAVStatus;
        }

        if (avStatus != LOPrivateDDCStatusAVCreateFailed) {
            return avStatus;
        }

        if (i2cStatus != LOPrivateDDCStatusI2CBusCountFailed && i2cStatus != LOPrivateDDCStatusI2CNoBuses) {
            return i2cStatus;
        }

        return globalAVStatus;
    }

    NSInteger globalAVStatus = LOReadViaGlobalAVService(currentValue, maximumValue);
    if (globalAVStatus > 0) {
        return globalAVStatus;
    }

    return globalAVStatus == LOPrivateDDCStatusGlobalAVCreateFailed
        ? LOPrivateDDCStatusCGSNoService
        : globalAVStatus;
}
