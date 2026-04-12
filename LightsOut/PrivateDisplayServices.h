#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSInteger, LOPrivateDDCStatus) {
    LOPrivateDDCStatusSuccessAVService = 1,
    LOPrivateDDCStatusSuccessI2C = 2,
    LOPrivateDDCStatusSuccessGlobalAVService = 3,
    LOPrivateDDCStatusNoService = -1,
    LOPrivateDDCStatusAVCreateFailed = -2,
    LOPrivateDDCStatusAVWriteFailed = -3,
    LOPrivateDDCStatusAVReadFailed = -4,
    LOPrivateDDCStatusI2CBusCountFailed = -5,
    LOPrivateDDCStatusI2CNoBuses = -6,
    LOPrivateDDCStatusI2CReadFailed = -7,
    LOPrivateDDCStatusGlobalAVCreateFailed = -8,
    LOPrivateDDCStatusGlobalAVWriteFailed = -9,
    LOPrivateDDCStatusGlobalAVReadFailed = -10,
    LOPrivateDDCStatusCGSNoService = -11,
};

FOUNDATION_EXPORT NSInteger LOReadInputSourceForDisplay(CGDirectDisplayID display, uint16_t *currentValue, uint16_t *maximumValue);
