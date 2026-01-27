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
#import "BGMOutputDeviceMenuSection.h"
#import "BGMAppVolumes.h"

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

    // Listener block for system default device changes
    AudioObjectPropertyListenerBlock mDefaultDeviceListenerBlock;
    BOOL mIsListeningForDefaultDevice;

    // UI components to notify when routing changes
    BGMOutputDeviceMenuSection* __weak mOutputDeviceMenuSection;
    BGMAppVolumes* __weak mAppVolumes;
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
        mIsListeningForDefaultDevice = NO;
    }

    return self;
}

- (void)dealloc
{
    [self stopListeningForPropertyChanges];
    [self stopListeningForDefaultDeviceChanges];
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

        // Notify UI components to update their indicators
        [self notifyUIComponentsOfRoutingChange];
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

- (void)setOutputDeviceMenuSection:(BGMOutputDeviceMenuSection* __nullable)menuSection
{
    mOutputDeviceMenuSection = menuSection;
}

- (void)setAppVolumes:(BGMAppVolumes* __nullable)appVolumes
{
    mAppVolumes = appVolumes;
}

- (void)startListeningForDefaultDeviceChanges
{
    if (mIsListeningForDefaultDevice)
    {
        // Already listening
        return;
    }

    // Create listener block for system default device changes
    AudioObjectPropertyListenerBlock block = ^(UInt32 inNumberAddresses,
                                               const AudioObjectPropertyAddress* _Nonnull inAddresses) {
        // Check if this is a default output device property change
        for (UInt32 i = 0; i < inNumberAddresses; i++)
        {
            if (inAddresses[i].mSelector == kAudioHardwarePropertyDefaultOutputDevice)
            {
                DebugMsg("BGMAppOutputDeviceController: Default output device changed");
                [self handleDefaultDeviceChanged];
                break;
            }
        }
    };

    mDefaultDeviceListenerBlock = (__bridge AudioObjectPropertyListenerBlock)Block_copy((__bridge void*)block);

    // Register the listener with the HAL for the system object
    CAPropertyAddress address(kAudioHardwarePropertyDefaultOutputDevice,
                             kAudioObjectPropertyScopeGlobal,
                             kAudioObjectPropertyElementMaster);

    BGM_Utils::LogAndSwallowExceptions(BGMDbgArgs, [&] {
        OSStatus err = AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,
                                                           &address,
                                                           dispatch_get_main_queue(),
                                                           mDefaultDeviceListenerBlock);
        if (err == noErr)
        {
            mIsListeningForDefaultDevice = YES;
            DebugMsg("BGMAppOutputDeviceController::startListeningForDefaultDeviceChanges: Registered listener");
        }
        else
        {
            NSLog(@"BGMAppOutputDeviceController::startListeningForDefaultDeviceChanges: Failed to register listener (error %d)", err);
        }
    });
}

- (void)stopListeningForDefaultDeviceChanges
{
    if (!mIsListeningForDefaultDevice)
    {
        return;
    }

    // Deregister the listener
    CAPropertyAddress address(kAudioHardwarePropertyDefaultOutputDevice,
                             kAudioObjectPropertyScopeGlobal,
                             kAudioObjectPropertyElementMaster);

    BGM_Utils::LogAndSwallowExceptions(BGMDbgArgs, [&] {
        OSStatus err = AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                                              &address,
                                                              dispatch_get_main_queue(),
                                                              mDefaultDeviceListenerBlock);
        if (err == noErr)
        {
            DebugMsg("BGMAppOutputDeviceController::stopListeningForDefaultDeviceChanges: Unregistered listener");
        }
        else
        {
            NSLog(@"BGMAppOutputDeviceController::stopListeningForDefaultDeviceChanges: Failed to unregister listener (error %d)", err);
        }
    });

    Block_release(mDefaultDeviceListenerBlock);
    mIsListeningForDefaultDevice = NO;
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

- (void)notifyUIComponentsOfRoutingChange
{
    // Update the output device menu section to show app counts
    // Assign to strong variable to avoid weak variable access warning
    BGMOutputDeviceMenuSection* outputDeviceMenuSection = mOutputDeviceMenuSection;
    if (outputDeviceMenuSection)
    {
        [outputDeviceMenuSection updateDeviceIndicators];
    }

    // Update the app volumes UI to show device labels
    // Assign to strong variable to avoid weak variable access warning
    BGMAppVolumes* appVolumes = mAppVolumes;
    if (appVolumes)
    {
        // The app volumes will be refreshed through the refreshOutputDeviceLists method
        // which updates the app name labels with device indicators
        [appVolumes refreshOutputDeviceLists];
    }

    DebugMsg("BGMAppOutputDeviceController::notifyUIComponentsOfRoutingChange: UI components notified");
}

- (void)handleDefaultDeviceChanged
{
    @try
    {
        // Get the new default output device ID
        AudioObjectID newDefaultDeviceID = [self getSystemDefaultOutputDeviceID];

        if (newDefaultDeviceID == kAudioObjectUnknown)
        {
            NSLog(@"BGMAppOutputDeviceController::handleDefaultDeviceChanged: Failed to get new default device");
            return;
        }

        // Check if the new default device is BGMDevice (prevent feedback loop)
        if ([self isBGMDevice:newDefaultDeviceID])
        {
            DebugMsg("BGMAppOutputDeviceController::handleDefaultDeviceChanged: New default is BGMDevice, ignoring");
            return;
        }

        // Look up the device UID by searching through available devices
        BGMOutputDevice* device = nil;
        NSArray<BGMOutputDevice*>* devices = [mDeviceList availableOutputDevices];
        for (BGMOutputDevice* d in devices)
        {
            if (d.deviceID == newDefaultDeviceID)
            {
                device = d;
                break;
            }
        }

        if (!device)
        {
            NSLog(@"BGMAppOutputDeviceController::handleDefaultDeviceChanged: Device not found for ID %u",
                  newDefaultDeviceID);
            return;
        }

        NSString* newDefaultDeviceUID = device.uid;
        DebugMsg("BGMAppOutputDeviceController::handleDefaultDeviceChanged: New default device: %s (%u)",
                 [newDefaultDeviceUID UTF8String], newDefaultDeviceID);

        // Update the primary BGMPlayThrough instance to use the new default device
        BGMAudioDevice outputDevice(newDefaultDeviceID);
        mPlayThroughManager->SetDefaultPlayThrough(outputDevice);

        // Ensure a playthrough instance exists for the new default device
        [self ensurePlayThroughForDeviceUID:newDefaultDeviceUID];

        // Apps assigned to "Default" (nil/empty UID) automatically follow the system default
        // No need to update mappings - BGMDriver will route based on current default
        // But we should notify UI components to update their display
        [self notifyUIComponentsOfRoutingChange];

        DebugMsg("BGMAppOutputDeviceController::handleDefaultDeviceChanged: Successfully updated to new default");
    }
    @catch (NSException* exception)
    {
        NSLog(@"BGMAppOutputDeviceController::handleDefaultDeviceChanged: Exception: %@", exception);
    }
}

- (AudioObjectID)getSystemDefaultOutputDeviceID
{
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);

    CAPropertyAddress address(kAudioHardwarePropertyDefaultOutputDevice,
                             kAudioObjectPropertyScopeGlobal,
                             kAudioObjectPropertyElementMaster);

    OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                              &address,
                                              0,
                                              NULL,
                                              &size,
                                              &deviceID);

    if (err != noErr)
    {
        NSLog(@"BGMAppOutputDeviceController::getSystemDefaultOutputDeviceID: Failed to get default device (error %d)", err);
        return kAudioObjectUnknown;
    }

    return deviceID;
}

- (BOOL)isBGMDevice:(AudioObjectID)deviceID
{
    @try
    {
        // Compare against BGMDevice's object ID
        if (deviceID == mBGMDevice.GetObjectID())
        {
            return YES;
        }

        // Also check the device UID to be thorough
        NSArray<BGMOutputDevice*>* devices = [mDeviceList availableOutputDevices];
        for (BGMOutputDevice* device in devices)
        {
            if (device.deviceID == deviceID && [device.uid isEqualToString:@kBGMDeviceUID])
            {
                return YES;
            }
        }

        return NO;
    }
    @catch (NSException* exception)
    {
        NSLog(@"BGMAppOutputDeviceController::isBGMDevice: Exception: %@", exception);
        return NO;
    }
}

@end

#pragma clang assume_nonnull end
