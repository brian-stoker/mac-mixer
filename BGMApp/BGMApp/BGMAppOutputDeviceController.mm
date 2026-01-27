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
//  BGMAppOutputDeviceController.mm
//  BGMApp
//
//  Copyright © 2026 Background Music contributors
//

// Self Include
#import "BGMAppOutputDeviceController.h"

// Local Includes
#import "BGM_Types.h"
#import "BGM_Utils.h"

// PublicUtility Includes
#import "CAException.h"
#import "CAPropertyAddress.h"

// System Includes
#import <Foundation/Foundation.h>


#pragma clang assume_nonnull begin

@implementation BGMAppOutputDeviceController
{
    BGMPlayThroughManager* mPlayThroughManager;
    BGMAppOutputDevicePrefs* mPrefs;
    BGMOutputDeviceList* mDeviceList;
    BGMAudioDevice mBGMDevice;

    // Listener block for HAL property notifications
    AudioObjectPropertyListenerBlock mListenerBlock;
    BOOL mIsListening;
}

- (instancetype)initWithPlayThroughManager:(BGMPlayThroughManager*)manager
                         outputDevicePrefs:(BGMAppOutputDevicePrefs*)prefs
                           outputDeviceList:(BGMOutputDeviceList*)deviceList
                                  bgmDevice:(BGMAudioDevice)bgmDevice
{
    if (self = [super init])
    {
        mPlayThroughManager = manager;
        mPrefs = prefs;
        mDeviceList = deviceList;
        mBGMDevice = bgmDevice;
        mIsListening = NO;
    }

    return self;
}

- (void)dealloc
{
    [self stopListeningForPropertyChanges];
}

- (void)applyStoredPreferences
{
    @try
    {
        // Get all stored mappings from preferences
        NSDictionary<NSString*, NSString*>* mappings = [mPrefs allOutputDeviceMappings];

        if (mappings.count == 0)
        {
            DebugMsg("BGMAppOutputDeviceController::applyStoredPreferences: No stored preferences to apply");
            return;
        }

        DebugMsg("BGMAppOutputDeviceController::applyStoredPreferences: Applying %lu stored mappings",
                 (unsigned long)mappings.count);

        // Send all mappings to BGMDriver in one call
        [self sendMappingsToBGMDriver:mappings];

        // Ensure playthrough instances exist for each device
        for (NSString* deviceUID in mappings.allValues)
        {
            if (deviceUID && deviceUID.length > 0)
            {
                [self ensurePlayThroughForDeviceUID:deviceUID];
            }
        }
    }
    @catch (NSException* exception)
    {
        NSLog(@"BGMAppOutputDeviceController::applyStoredPreferences: Exception: %@", exception);
    }
}

- (void)setOutputDeviceUID:(nullable NSString*)deviceUID forBundleID:(NSString*)bundleID
{
    if (!bundleID || bundleID.length == 0)
    {
        NSLog(@"BGMAppOutputDeviceController::setOutputDeviceUID: Invalid bundle ID");
        return;
    }

    @try
    {
        // Update persistent storage
        if (deviceUID && deviceUID.length > 0)
        {
            [mPrefs setOutputDeviceUID:deviceUID forBundleID:bundleID];
        }
        else
        {
            // nil or empty string means "use default output device"
            [mPrefs removeOutputDeviceForBundleID:bundleID];
        }

        // Send the change to BGMDriver
        NSDictionary<NSString*, NSString*>* mappings = [mPrefs allOutputDeviceMappings];
        [self sendMappingsToBGMDriver:mappings];

        // Ensure playthrough instance exists for the target device
        if (deviceUID && deviceUID.length > 0)
        {
            NSString* nonNullDeviceUID = deviceUID;  // deviceUID is already checked for non-null above
            [self ensurePlayThroughForDeviceUID:nonNullDeviceUID];
        }

        DebugMsg("BGMAppOutputDeviceController::setOutputDeviceUID: Set device %s for bundle %s",
                 deviceUID ? [deviceUID UTF8String] : "(default)",
                 [bundleID UTF8String]);
    }
    @catch (NSException* exception)
    {
        NSLog(@"BGMAppOutputDeviceController::setOutputDeviceUID: Exception: %@", exception);
    }
}

- (nullable NSString*)outputDeviceUIDForBundleID:(NSString*)bundleID
{
    if (!bundleID || bundleID.length == 0)
    {
        return nil;
    }

    return [mPrefs outputDeviceUIDForBundleID:bundleID];
}

- (void)startListeningForPropertyChanges
{
    if (mIsListening)
    {
        // Already listening
        return;
    }

    // Create listener block for property changes
    AudioObjectPropertyListenerBlock block = ^(UInt32 inNumberAddresses,
                                               const AudioObjectPropertyAddress* _Nonnull inAddresses) {
        // Check if this is a client output devices property change
        for (UInt32 i = 0; i < inNumberAddresses; i++)
        {
            if (inAddresses[i].mSelector == kAudioDeviceCustomPropertyClientOutputDevices)
            {
                DebugMsg("BGMAppOutputDeviceController: Received property change notification");
                // We could read the current state from BGMDriver here if needed
                // For now, we trust that our updates are the source of truth
                break;
            }
        }
    };

    mListenerBlock = (__bridge AudioObjectPropertyListenerBlock)Block_copy((__bridge void*)block);

    // Register the listener with the HAL
    CAPropertyAddress address(kAudioDeviceCustomPropertyClientOutputDevices);

    BGM_Utils::LogAndSwallowExceptions(BGMDbgArgs, [&] {
        mBGMDevice.AddPropertyListenerBlock(address, dispatch_get_main_queue(), mListenerBlock);
        mIsListening = YES;
        DebugMsg("BGMAppOutputDeviceController::startListeningForPropertyChanges: Registered listener");
    });
}

- (void)stopListeningForPropertyChanges
{
    if (!mIsListening)
    {
        return;
    }

    // Deregister the listener
    CAPropertyAddress address(kAudioDeviceCustomPropertyClientOutputDevices);

    BGM_Utils::LogAndSwallowExceptions(BGMDbgArgs, [&] {
        mBGMDevice.RemovePropertyListenerBlock(address, dispatch_get_main_queue(), mListenerBlock);
        DebugMsg("BGMAppOutputDeviceController::stopListeningForPropertyChanges: Unregistered listener");
    });

    Block_release(mListenerBlock);
    mIsListening = NO;
}

#pragma mark - Private Methods

- (void)sendMappingsToBGMDriver:(NSDictionary<NSString*, NSString*>*)mappings
{
    @try
    {
        // Create a CFDictionary to send to BGMDriver
        // The property expects a dictionary mapping bundle IDs to output device UIDs
        CFMutableDictionaryRef dict = CFDictionaryCreateMutable(kCFAllocatorDefault,
                                                                 mappings.count,
                                                                 &kCFTypeDictionaryKeyCallBacks,
                                                                 &kCFTypeDictionaryValueCallBacks);

        if (!dict)
        {
            NSLog(@"BGMAppOutputDeviceController::sendMappingsToBGMDriver: Failed to create dictionary");
            return;
        }

        // Copy mappings into the CFDictionary
        for (NSString* bundleID in mappings)
        {
            NSString* deviceUID = mappings[bundleID];
            CFDictionarySetValue(dict, (__bridge CFStringRef)bundleID, (__bridge CFStringRef)deviceUID);
        }

        // Send to BGMDriver via HAL property
        CAPropertyAddress address(kAudioDeviceCustomPropertyClientOutputDevices);
        UInt32 dataSize = sizeof(CFDictionaryRef);

        OSStatus err = AudioObjectSetPropertyData(mBGMDevice.GetObjectID(),
                                                   &address,
                                                   0,
                                                   NULL,
                                                   dataSize,
                                                   &dict);

        CFRelease(dict);

        if (err != noErr)
        {
            NSLog(@"BGMAppOutputDeviceController::sendMappingsToBGMDriver: Failed to set property (error %d)", err);
        }
        else
        {
            DebugMsg("BGMAppOutputDeviceController::sendMappingsToBGMDriver: Successfully sent %lu mappings",
                     (unsigned long)mappings.count);
        }
    }
    @catch (NSException* exception)
    {
        NSLog(@"BGMAppOutputDeviceController::sendMappingsToBGMDriver: Exception: %@", exception);
    }
}

- (void)ensurePlayThroughForDeviceUID:(NSString*)deviceUID
{
    if (!deviceUID || deviceUID.length == 0)
    {
        return;
    }

    @try
    {
        // Look up the device
        BGMOutputDevice* device = [mDeviceList deviceWithUID:deviceUID];

        if (!device)
        {
            NSLog(@"BGMAppOutputDeviceController::ensurePlayThroughForDeviceUID: Device not found: %@",
                  deviceUID);
            return;
        }

        // Create BGMAudioDevice from the output device
        BGMAudioDevice outputDevice(device.deviceID);

        // Get or create the playthrough instance for this device
        BGMPlayThrough* playthrough = mPlayThroughManager->GetPlayThroughForOutputDevice(outputDevice);

        if (playthrough == nullptr)
        {
            NSLog(@"BGMAppOutputDeviceController::ensurePlayThroughForDeviceUID: "
                  "Failed to get/create playthrough for device %@", deviceUID);
        }
        else
        {
            DebugMsg("BGMAppOutputDeviceController::ensurePlayThroughForDeviceUID: "
                     "Ensured playthrough for device %s", [deviceUID UTF8String]);
        }
    }
    @catch (NSException* exception)
    {
        NSLog(@"BGMAppOutputDeviceController::ensurePlayThroughForDeviceUID: Exception: %@", exception);
    }
}

@end

#pragma clang assume_nonnull end
