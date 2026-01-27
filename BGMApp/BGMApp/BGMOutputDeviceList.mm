// This file is part of Background Music.
//
// Background Music is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation, either version 2 of the
// License, or (at your option) any later version.
//
// Background Music is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Background Music. If not, see <http://www.gnu.org/licenses/>.

//
//  BGMOutputDeviceList.mm
//  BGMApp
//
//  Copyright © 2026 Kyle Neideck
//

// Self Include
#import "BGMOutputDeviceList.h"

// Local Includes
#import "BGM_Types.h"
#import "BGM_Utils.h"
#import "BGMAudioDevice.h"

// PublicUtility Includes
#import "CAAutoDisposer.h"
#import "CAHALAudioSystemObject.h"
#import "CAPropertyAddress.h"


#pragma clang assume_nonnull begin

#pragma mark - BGMOutputDevice Implementation

@implementation BGMOutputDevice

- (instancetype) initWithDeviceID:(AudioObjectID)deviceID
                              uid:(NSString*)uid
                             name:(NSString*)name
                      isConnected:(BOOL)isConnected {
    if ((self = [super init])) {
        _deviceID = deviceID;
        _uid = [uid copy];
        _name = [name copy];
        _isConnected = isConnected;
    }

    return self;
}

- (NSString*) description {
    return [NSString stringWithFormat:@"<BGMOutputDevice: %p deviceID=%u uid=%@ name=%@ connected=%d>",
            self, _deviceID, _uid, _name, _isConnected];
}

- (BOOL) isEqual:(id)object {
    if (self == object) {
        return YES;
    }

    if (![object isKindOfClass:[BGMOutputDevice class]]) {
        return NO;
    }

    BGMOutputDevice* other = (BGMOutputDevice*)object;
    return _deviceID == other.deviceID && [_uid isEqualToString:other.uid];
}

- (NSUInteger) hash {
    return _deviceID ^ [_uid hash];
}

@end

#pragma mark - BGMOutputDeviceList Implementation

@implementation BGMOutputDeviceList {
    // Lock for thread-safe access to the device list
    NSRecursiveLock* _stateLock;

    // Cached list of available output devices
    NSArray<BGMOutputDevice*>* _devices;

    // Property listener for device list changes
    AudioObjectPropertyListenerBlock _deviceListListener;
}

#pragma mark Singleton

+ (instancetype) sharedInstance {
    static BGMOutputDeviceList* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BGMOutputDeviceList alloc] init];
    });
    return instance;
}

#pragma mark Initialization

- (instancetype) init {
    if ((self = [super init])) {
        _stateLock = [NSRecursiveLock new];
        _devices = @[];

        // Build initial device list
        [self refreshDeviceList];

        // Listen for device list changes
        [self listenForDeviceListChanges];
    }

    return self;
}

- (void) dealloc {
    @try {
        [_stateLock lock];

        // Remove the property listener
        if (_deviceListListener) {
            CAHALAudioSystemObject().RemovePropertyListenerBlock(
                CAPropertyAddress(kAudioHardwarePropertyDevices),
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                _deviceListListener);
        }
    } @finally {
        [_stateLock unlock];
    }
}

#pragma mark Device List Access

- (NSArray<BGMOutputDevice*>*) availableOutputDevices {
    @try {
        [_stateLock lock];
        return [_devices copy];
    } @finally {
        [_stateLock unlock];
    }
}

- (nullable BGMOutputDevice*) deviceWithUID:(NSString*)uid {
    if (!uid) {
        return nil;
    }

    @try {
        [_stateLock lock];

        for (BGMOutputDevice* device in _devices) {
            if ([device.uid isEqualToString:uid]) {
                return device;
            }
        }

        return nil;
    } @finally {
        [_stateLock unlock];
    }
}

- (nullable BGMOutputDevice*) deviceWithName:(NSString*)name {
    if (!name) {
        return nil;
    }

    @try {
        [_stateLock lock];

        for (BGMOutputDevice* device in _devices) {
            if ([device.name isEqualToString:name]) {
                return device;
            }
        }

        return nil;
    } @finally {
        [_stateLock unlock];
    }
}

- (BOOL) isDeviceAvailable:(NSString*)uid {
    return [self deviceWithUID:uid] != nil;
}

#pragma mark Device List Management

- (void) refreshDeviceList {
    @try {
        [_stateLock lock];

        NSMutableArray<BGMOutputDevice*>* devices = [NSMutableArray new];

        BGM_Utils::LogAndSwallowExceptions(BGMDbgArgs, [&] {
            CAHALAudioSystemObject audioSystem;
            UInt32 numDevices = audioSystem.GetNumberAudioDevices();

            if (numDevices == 0) {
                DebugMsg("BGMOutputDeviceList::refreshDeviceList: No audio devices found");
                return;
            }

            // Get all audio devices from the system
            CAAutoArrayDelete<AudioObjectID> deviceIDs(numDevices);
            audioSystem.GetAudioDevices(numDevices, deviceIDs);

            // Process each device
            for (UInt32 i = 0; i < numDevices; i++) {
                BGM_Utils::LogAndSwallowExceptions(BGMDbgArgs, [&] {
                    BGMAudioDevice device(deviceIDs[i]);

                    // Skip devices that can't be output devices in BGMApp
                    // (this filters out BGMDevice, BGMDevice_UISounds, and input-only devices)
                    if (!device.CanBeOutputDeviceInBGMApp()) {
                        return;
                    }

                    // Get device UID
                    NSString* __nullable deviceUID =
                        (__bridge_transfer NSString* __nullable)device.CopyDeviceUID();

                    if (!deviceUID) {
                        LogWarning("BGMOutputDeviceList::refreshDeviceList: Device %u has no UID",
                                   deviceIDs[i]);
                        return;
                    }

                    // Skip BGMDevice variants by checking UID
                    if ([deviceUID isEqualToString:@kBGMDeviceUID] ||
                        [deviceUID isEqualToString:@kBGMDeviceUID_UISounds] ||
                        [deviceUID isEqualToString:@kBGMNullDeviceUID]) {
                        DebugMsg("BGMOutputDeviceList::refreshDeviceList: "
                                 "Skipping BGMDevice variant: %s",
                                 deviceUID.UTF8String);
                        return;
                    }

                    // Get device name
                    NSString* __nullable deviceName = nil;
                    CFStringRef nameCF = NULL;

                    AudioObjectPropertyAddress propertyAddress = {
                        kAudioObjectPropertyName,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMaster
                    };

                    UInt32 dataSize = sizeof(CFStringRef);
                    OSStatus err = AudioObjectGetPropertyData(deviceIDs[i],
                                                             &propertyAddress,
                                                             0,
                                                             NULL,
                                                             &dataSize,
                                                             &nameCF);

                    if (err == noErr && nameCF) {
                        deviceName = (__bridge_transfer NSString*)nameCF;
                    } else {
                        LogWarning("BGMOutputDeviceList::refreshDeviceList: "
                                   "Failed to get name for device %u (UID: %s)",
                                   deviceIDs[i],
                                   deviceUID.UTF8String);
                        deviceName = deviceUID; // Fallback to UID
                    }

                    // Check if device is connected/alive
                    BOOL isConnected = YES;
                    BGM_Utils::LogAndSwallowExceptions(BGMDbgArgs, [&] {
                        isConnected = device.IsAlive();
                    });

                    // Create device object and add to list
                    BGMOutputDevice* outputDevice =
                        [[BGMOutputDevice alloc] initWithDeviceID:deviceIDs[i]
                                                              uid:BGMNN(deviceUID)
                                                             name:BGMNN(deviceName)
                                                      isConnected:isConnected];

                    [devices addObject:outputDevice];

                    DebugMsg("BGMOutputDeviceList::refreshDeviceList: Added device: %s",
                             outputDevice.description.UTF8String);
                });
            }
        });

        _devices = [devices copy];

        DebugMsg("BGMOutputDeviceList::refreshDeviceList: Device list updated with %lu devices",
                 (unsigned long)_devices.count);

    } @finally {
        [_stateLock unlock];
    }
}

#pragma mark Device List Change Notifications

- (void) listenForDeviceListChanges {
    // Create the listener block
    BGMOutputDeviceList* __weak weakSelf = self;

    _deviceListListener = ^(UInt32 inNumberAddresses,
                           const AudioObjectPropertyAddress* inAddresses) {
        #pragma unused (inNumberAddresses, inAddresses)

        BGM_Utils::LogAndSwallowExceptions(BGMDbgArgs, [&] {
            DebugMsg("BGMOutputDeviceList::deviceListChanged: Device list changed, refreshing");
            [weakSelf refreshDeviceList];
        });
    };

    // Register the listener with CoreAudio
    CAHALAudioSystemObject().AddPropertyListenerBlock(
        CAPropertyAddress(kAudioHardwarePropertyDevices),
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
        _deviceListListener);
}

@end

#pragma clang assume_nonnull end
