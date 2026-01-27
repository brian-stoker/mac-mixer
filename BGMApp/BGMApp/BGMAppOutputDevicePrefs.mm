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
//  BGMAppOutputDevicePrefs.mm
//  BGMApp
//
//  Copyright © 2026 Background Music contributors
//

// Self Include
#import "BGMAppOutputDevicePrefs.h"

// System Includes
#import <CoreAudio/AudioHardware.h>


#pragma clang assume_nonnull begin

// Keys
static NSString* const kBGMAppOutputDevicesUserDefaultsKey = @"BGMAppOutputDevices";

@implementation BGMAppOutputDevicePrefs

+ (instancetype)sharedInstance {
    static BGMAppOutputDevicePrefs* instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BGMAppOutputDevicePrefs alloc] init];
    });
    return instance;
}

- (nullable NSString*)outputDeviceUIDForBundleID:(NSString*)bundleID {
    if (!bundleID || bundleID.length == 0) {
        return nil;
    }

    NSDictionary<NSString*, NSString*>* mappings = [self loadMappings];
    NSString* __nullable deviceUID = mappings[bundleID];

    // Log a warning if the stored device UID refers to a disconnected device
    if (deviceUID) {
        NSString* nonNullUID = deviceUID;  // Convert to non-nullable for method call
        if (![self isDeviceConnected:nonNullUID]) {
            NSLog(@"BGMAppOutputDevicePrefs::outputDeviceUIDForBundleID: Stored device UID '%@' for "
                  @"bundle ID '%@' refers to a disconnected device", deviceUID, bundleID);
        }
    }

    return deviceUID;
}

- (void)setOutputDeviceUID:(nullable NSString*)deviceUID forBundleID:(NSString*)bundleID {
    if (!bundleID || bundleID.length == 0) {
        NSLog(@"BGMAppOutputDevicePrefs::setOutputDeviceUID: Invalid bundle ID");
        return;
    }

    NSMutableDictionary<NSString*, NSString*>* mappings = [[self loadMappings] mutableCopy];

    if (deviceUID && deviceUID.length > 0) {
        mappings[bundleID] = deviceUID;
    } else {
        [mappings removeObjectForKey:bundleID];
    }

    [self saveMappings:mappings];
}

- (NSDictionary<NSString*, NSString*>*)allOutputDeviceMappings {
    return [self loadMappings];
}

- (void)removeOutputDeviceForBundleID:(NSString*)bundleID {
    [self setOutputDeviceUID:nil forBundleID:bundleID];
}

- (void)resetAllMappings {
    [self saveMappings:@{}];
}

#pragma mark Private Methods

- (NSDictionary<NSString*, NSString*>*)loadMappings {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    id __nullable storedMappings = [defaults objectForKey:kBGMAppOutputDevicesUserDefaultsKey];

    // Validate data types when reading; reset to empty dictionary if invalid
    if (!storedMappings) {
        return @{};
    }

    if (![storedMappings isKindOfClass:[NSDictionary class]]) {
        NSString* className = @"(unknown)";
        if (storedMappings) {
            Class cls = [storedMappings class];
            className = NSStringFromClass(cls);
        }
        NSLog(@"BGMAppOutputDevicePrefs::loadMappings: Invalid stored data type (expected "
              @"NSDictionary, got %@). Resetting to empty dictionary.", className);
        [self saveMappings:@{}];
        return @{};
    }

    NSDictionary* dict = (NSDictionary*)storedMappings;

    // Validate that all keys and values are strings
    for (id key in dict) {
        if (![key isKindOfClass:[NSString class]]) {
            NSString* className = @"(unknown)";
            if (key) {
                Class cls = [key class];
                className = NSStringFromClass(cls);
            }
            NSLog(@"BGMAppOutputDevicePrefs::loadMappings: Invalid key type in stored mappings "
                  @"(expected NSString, got %@). Resetting to empty dictionary.", className);
            [self saveMappings:@{}];
            return @{};
        }

        id value = dict[key];
        if (![value isKindOfClass:[NSString class]]) {
            NSString* className = @"(unknown)";
            if (value) {
                Class cls = [value class];
                className = NSStringFromClass(cls);
            }
            NSLog(@"BGMAppOutputDevicePrefs::loadMappings: Invalid value type in stored mappings "
                  @"(expected NSString, got %@). Resetting to empty dictionary.", className);
            [self saveMappings:@{}];
            return @{};
        }
    }

    return dict;
}

- (void)saveMappings:(NSDictionary<NSString*, NSString*>*)mappings {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:mappings forKey:kBGMAppOutputDevicesUserDefaultsKey];
    [defaults synchronize];
}

- (BOOL)isDeviceConnected:(NSString*)deviceUID {
    // Query Core Audio to check if a device with this UID exists
    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                                   &propertyAddress,
                                                   0,
                                                   NULL,
                                                   &dataSize);

    if (err != noErr) {
        return NO;
    }

    UInt32 deviceCount = dataSize / sizeof(AudioObjectID);
    AudioObjectID* devices = (AudioObjectID*)malloc(dataSize);

    err = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                     &propertyAddress,
                                     0,
                                     NULL,
                                     &dataSize,
                                     devices);

    if (err != noErr) {
        free(devices);
        return NO;
    }

    BOOL found = NO;

    // Check each device's UID
    for (UInt32 i = 0; i < deviceCount; i++) {
        AudioObjectPropertyAddress uidAddress = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };

        CFStringRef __nullable deviceUIDRef = NULL;
        UInt32 uidSize = sizeof(deviceUIDRef);

        err = AudioObjectGetPropertyData(devices[i],
                                         &uidAddress,
                                         0,
                                         NULL,
                                         &uidSize,
                                         &deviceUIDRef);

        if (err == noErr && deviceUIDRef != NULL) {
            NSString* currentDeviceUID = (__bridge_transfer NSString*)deviceUIDRef;
            if ([currentDeviceUID isEqualToString:deviceUID]) {
                found = YES;
                break;
            }
        }
    }

    free(devices);
    return found;
}

@end

#pragma clang assume_nonnull end

