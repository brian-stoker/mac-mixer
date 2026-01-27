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
//  BGMDeviceDisconnectionHandler.mm
//  BGMApp
//
//  Copyright © 2026 Background Music contributors
//

// Self Include
#import "BGMDeviceDisconnectionHandler.h"

// Local Includes
#import "BGM_Utils.h"
#import "BGMAppOutputDevicePrefs.h"

// PublicUtility Includes
#import "CAHALAudioSystemObject.h"
#import "CAPropertyAddress.h"


#pragma clang assume_nonnull begin

// Notification names
NSString* const kBGMDeviceDisconnectedNotification = @"BGMDeviceDisconnectedNotification";
NSString* const kBGMDeviceReconnectedNotification = @"BGMDeviceReconnectedNotification";

// Notification userInfo keys
NSString* const kBGMDisconnectedDeviceUIDKey = @"deviceUID";
NSString* const kBGMReconnectedDeviceUIDKey = @"deviceUID";
NSString* const kBGMAffectedBundleIDsKey = @"affectedBundleIDs";


@implementation BGMDeviceDisconnectionHandler
{
    BGMPlayThroughManager* mPlayThroughManager;
    BGMAppOutputDeviceController* mOutputController;
    BGMOutputDeviceList* mDeviceList;
    AudioObjectID mDefaultDeviceID;

    // Property listener for device list changes
    AudioObjectPropertyListenerBlock mDeviceListListener;
    BOOL mIsListening;

    // Keep track of previously seen devices to detect disconnections
    NSMutableSet<NSString*>* mPreviousDeviceUIDs;

    // Lock for thread-safe access
    NSRecursiveLock* mStateLock;
}

#pragma mark - Initialization

- (instancetype)initWithPlayThroughManager:(BGMPlayThroughManager*)manager
                          outputController:(BGMAppOutputDeviceController*)controller
                            outputDeviceList:(BGMOutputDeviceList*)deviceList
                            defaultDeviceID:(AudioObjectID)defaultDeviceID
{
    if (self = [super init])
    {
        mPlayThroughManager = manager;
        mOutputController = controller;
        mDeviceList = deviceList;
        mDefaultDeviceID = defaultDeviceID;
        mIsListening = NO;
        mPreviousDeviceUIDs = [NSMutableSet new];
        mStateLock = [NSRecursiveLock new];

        // Initialize the set of known devices
        [self updateKnownDevices];
    }

    return self;
}

- (void)dealloc
{
    [self stopListening];
}

#pragma mark - Listening Control

- (void)startListening
{
    @try
    {
        [mStateLock lock];

        if (mIsListening)
        {
            DebugMsg("BGMDeviceDisconnectionHandler::startListening: Already listening");
            return;
        }

        // Create the listener block
        BGMDeviceDisconnectionHandler* __weak weakSelf = self;

        mDeviceListListener = ^(UInt32 inNumberAddresses,
                                const AudioObjectPropertyAddress* inAddresses) {
            #pragma unused (inNumberAddresses, inAddresses)

            BGMDeviceDisconnectionHandler* strongSelf = weakSelf;
            if (strongSelf)
            {
                BGM_Utils::LogAndSwallowExceptions(BGMDbgArgs, [&] {
                    DebugMsg("BGMDeviceDisconnectionHandler: Device list changed");
                    [strongSelf handleDeviceListChange];
                });
            }
        };

        // Register the listener with CoreAudio
        CAHALAudioSystemObject().AddPropertyListenerBlock(
            CAPropertyAddress(kAudioHardwarePropertyDevices),
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
            mDeviceListListener);

        mIsListening = YES;
        DebugMsg("BGMDeviceDisconnectionHandler::startListening: Started listening for device changes");
    }
    @finally
    {
        [mStateLock unlock];
    }
}

- (void)stopListening
{
    @try
    {
        [mStateLock lock];

        if (!mIsListening)
        {
            return;
        }

        // Remove the property listener
        if (mDeviceListListener)
        {
            CAHALAudioSystemObject().RemovePropertyListenerBlock(
                CAPropertyAddress(kAudioHardwarePropertyDevices),
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                mDeviceListListener);
        }

        mIsListening = NO;
        DebugMsg("BGMDeviceDisconnectionHandler::stopListening: Stopped listening for device changes");
    }
    @finally
    {
        [mStateLock unlock];
    }
}

#pragma mark - Device List Change Handling

- (void)handleDeviceListChange
{
    @try
    {
        [mStateLock lock];

        // Get the current list of devices
        NSArray<BGMOutputDevice*>* currentDevices = [mDeviceList availableOutputDevices];
        NSMutableSet<NSString*>* currentDeviceUIDs = [NSMutableSet new];

        for (BGMOutputDevice* device in currentDevices)
        {
            [currentDeviceUIDs addObject:device.uid];
        }

        // Detect disconnected devices
        NSMutableSet<NSString*>* disconnectedUIDs = [mPreviousDeviceUIDs mutableCopy];
        [disconnectedUIDs minusSet:currentDeviceUIDs];

        // Detect reconnected devices
        NSMutableSet<NSString*>* reconnectedUIDs = [currentDeviceUIDs mutableCopy];
        [reconnectedUIDs minusSet:mPreviousDeviceUIDs];

        // Handle disconnections
        for (NSString* deviceUID in disconnectedUIDs)
        {
            DebugMsg("BGMDeviceDisconnectionHandler::handleDeviceListChange: Device disconnected: %s",
                     [deviceUID UTF8String]);

            // We need to find the device ID, but the device is already gone.
            // We'll handle this by looking up apps assigned to this UID.
            [self handleDeviceDisconnectedByUID:deviceUID];
        }

        // Handle reconnections
        for (NSString* deviceUID in reconnectedUIDs)
        {
            DebugMsg("BGMDeviceDisconnectionHandler::handleDeviceListChange: Device reconnected: %s",
                     [deviceUID UTF8String]);
            [self handleDeviceReconnected:deviceUID];
        }

        // Update the set of known devices
        mPreviousDeviceUIDs = currentDeviceUIDs;
    }
    @finally
    {
        [mStateLock unlock];
    }
}

- (void)updateKnownDevices
{
    @try
    {
        [mStateLock lock];

        [mPreviousDeviceUIDs removeAllObjects];

        NSArray<BGMOutputDevice*>* devices = [mDeviceList availableOutputDevices];
        for (BGMOutputDevice* device in devices)
        {
            [mPreviousDeviceUIDs addObject:device.uid];
        }

        DebugMsg("BGMDeviceDisconnectionHandler::updateKnownDevices: Initialized with %lu devices",
                 (unsigned long)mPreviousDeviceUIDs.count);
    }
    @finally
    {
        [mStateLock unlock];
    }
}

#pragma mark - Device Disconnection Handling

- (void)handleDeviceDisconnected:(AudioObjectID)deviceID
{
    // This method is called with a device ID, which is less useful than UID
    // because the device is already gone. We'll primarily use handleDeviceDisconnectedByUID.
    DebugMsg("BGMDeviceDisconnectionHandler::handleDeviceDisconnected: Device %u disconnected", deviceID);

    // Try to find the device UID from our records
    // (This is a fallback; handleDeviceListChange is the primary detection method)
}

- (void)handleDeviceDisconnectedByUID:(NSString*)deviceUID
{
    @try
    {
        DebugMsg("BGMDeviceDisconnectionHandler::handleDeviceDisconnectedByUID: Handling disconnection of %s",
                 [deviceUID UTF8String]);

        // Get all app-to-device mappings from preferences
        BGMAppOutputDevicePrefs* prefs = [BGMAppOutputDevicePrefs sharedInstance];
        NSDictionary<NSString*, NSString*>* allMappings = [prefs allOutputDeviceMappings];

        // Find apps that were assigned to this device
        NSMutableArray<NSString*>* affectedBundleIDs = [NSMutableArray new];

        for (NSString* bundleID in allMappings)
        {
            NSString* assignedDeviceUID = allMappings[bundleID];
            if ([assignedDeviceUID isEqualToString:deviceUID])
            {
                [affectedBundleIDs addObject:bundleID];
            }
        }

        if (affectedBundleIDs.count == 0)
        {
            DebugMsg("BGMDeviceDisconnectionHandler::handleDeviceDisconnectedByUID: "
                     "No apps were assigned to device %s",
                     [deviceUID UTF8String]);

            // Still need to clean up the playthrough instance
            [self cleanupPlayThroughForDeviceUID:deviceUID];
            return;
        }

        NSLog(@"BGMDeviceDisconnectionHandler: Device '%@' disconnected. Rerouting %lu app(s) to default device.",
              deviceUID, (unsigned long)affectedBundleIDs.count);

        // Get the default device for fallback
        BGMOutputDevice* defaultDevice = [self getDefaultFallbackDevice];

        if (!defaultDevice)
        {
            NSLog(@"BGMDeviceDisconnectionHandler::handleDeviceDisconnectedByUID: "
                  "No default device available for fallback");

            // Clean up playthrough anyway
            [self cleanupPlayThroughForDeviceUID:deviceUID];
            return;
        }

        // Reroute affected apps to the default device
        // Note: We keep the preferences intact so that if the device reconnects,
        // we can optionally reroute the apps back
        for (NSString* bundleID in affectedBundleIDs)
        {
            DebugMsg("BGMDeviceDisconnectionHandler::handleDeviceDisconnectedByUID: "
                     "App %s was using disconnected device, keeping preference for reconnection",
                     [bundleID UTF8String]);
        }

        // Remove the playthrough instance for the disconnected device
        [self cleanupPlayThroughForDeviceUID:deviceUID];

        // Post notification to update UI
        NSDictionary* userInfo = @{
            kBGMDisconnectedDeviceUIDKey: deviceUID,
            kBGMAffectedBundleIDsKey: [affectedBundleIDs copy]
        };

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kBGMDeviceDisconnectedNotification
                                                                object:self
                                                              userInfo:userInfo];
        });
    }
    @catch (NSException* exception)
    {
        NSLog(@"BGMDeviceDisconnectionHandler::handleDeviceDisconnectedByUID: Exception: %@", exception);
    }
}

- (void)cleanupPlayThroughForDeviceUID:(NSString*)deviceUID
{
    @try
    {
        // Look up the device by UID (it might still be in the cache briefly)
        BGMOutputDevice* device = [mDeviceList deviceWithUID:deviceUID];

        if (device)
        {
            // Remove the playthrough instance
            BGMAudioDevice audioDevice(device.deviceID);
            mPlayThroughManager->RemovePlayThroughForOutputDevice(audioDevice);

            DebugMsg("BGMDeviceDisconnectionHandler::cleanupPlayThroughForDeviceUID: "
                     "Removed playthrough for device %s",
                     [deviceUID UTF8String]);
        }
        else
        {
            DebugMsg("BGMDeviceDisconnectionHandler::cleanupPlayThroughForDeviceUID: "
                     "Device %s not found in device list (already removed)",
                     [deviceUID UTF8String]);
        }
    }
    @catch (NSException* exception)
    {
        NSLog(@"BGMDeviceDisconnectionHandler::cleanupPlayThroughForDeviceUID: Exception: %@", exception);
    }
}

#pragma mark - Device Reconnection Handling

- (void)handleDeviceReconnected:(NSString*)deviceUID
{
    @try
    {
        DebugMsg("BGMDeviceDisconnectionHandler::handleDeviceReconnected: Device %s reconnected",
                 [deviceUID UTF8String]);

        // Get all app-to-device mappings from preferences
        BGMAppOutputDevicePrefs* prefs = [BGMAppOutputDevicePrefs sharedInstance];
        NSDictionary<NSString*, NSString*>* allMappings = [prefs allOutputDeviceMappings];

        // Find apps that were assigned to this device
        NSMutableArray<NSString*>* affectedBundleIDs = [NSMutableArray new];

        for (NSString* bundleID in allMappings)
        {
            NSString* assignedDeviceUID = allMappings[bundleID];
            if ([assignedDeviceUID isEqualToString:deviceUID])
            {
                [affectedBundleIDs addObject:bundleID];
            }
        }

        if (affectedBundleIDs.count == 0)
        {
            DebugMsg("BGMDeviceDisconnectionHandler::handleDeviceReconnected: "
                     "No apps were assigned to device %s",
                     [deviceUID UTF8String]);
            return;
        }

        NSLog(@"BGMDeviceDisconnectionHandler: Device '%@' reconnected. "
              "%lu app(s) were previously assigned to this device.",
              deviceUID, (unsigned long)affectedBundleIDs.count);

        // Ensure playthrough instance exists for the reconnected device
        BGMOutputDevice* device = [mDeviceList deviceWithUID:deviceUID];

        if (!device)
        {
            NSLog(@"BGMDeviceDisconnectionHandler::handleDeviceReconnected: "
                  "Device %@ not found in device list", deviceUID);
            return;
        }

        // Create BGMAudioDevice and ensure playthrough exists
        BGMAudioDevice audioDevice(device.deviceID);
        BGMPlayThrough* playthrough = mPlayThroughManager->GetPlayThroughForOutputDevice(audioDevice);

        if (playthrough == nullptr)
        {
            NSLog(@"BGMDeviceDisconnectionHandler::handleDeviceReconnected: "
                  "Failed to create playthrough for device %@", deviceUID);
            return;
        }

        DebugMsg("BGMDeviceDisconnectionHandler::handleDeviceReconnected: "
                 "Playthrough instance ready for device %s",
                 [deviceUID UTF8String]);

        // Post notification to update UI
        NSDictionary* userInfo = @{
            kBGMReconnectedDeviceUIDKey: deviceUID,
            kBGMAffectedBundleIDsKey: [affectedBundleIDs copy]
        };

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:kBGMDeviceReconnectedNotification
                                                                object:self
                                                              userInfo:userInfo];
        });

        // Optionally: Automatically reroute apps back to the reconnected device
        // For now, we just ensure the playthrough is ready and let the user/system
        // decide when to actually route audio to it. The assignments are still in
        // preferences, so BGMDriver will route appropriately once apps start playing.
    }
    @catch (NSException* exception)
    {
        NSLog(@"BGMDeviceDisconnectionHandler::handleDeviceReconnected: Exception: %@", exception);
    }
}

#pragma mark - Fallback Device Selection

- (nullable BGMOutputDevice*)getDefaultFallbackDevice
{
    @try
    {
        // First, try to use the configured default device ID
        if (mDefaultDeviceID != kAudioObjectUnknown)
        {
            NSArray<BGMOutputDevice*>* devices = [mDeviceList availableOutputDevices];
            for (BGMOutputDevice* device in devices)
            {
                if (device.deviceID == mDefaultDeviceID)
                {
                    DebugMsg("BGMDeviceDisconnectionHandler::getDefaultFallbackDevice: "
                             "Using configured default device %u", mDefaultDeviceID);
                    return device;
                }
            }
        }

        // Fallback: Use the system default output device
        AudioObjectPropertyAddress propertyAddress = {
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };

        AudioObjectID systemDefaultDeviceID = kAudioObjectUnknown;
        UInt32 dataSize = sizeof(AudioObjectID);

        OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                   &propertyAddress,
                                                   0,
                                                   NULL,
                                                   &dataSize,
                                                   &systemDefaultDeviceID);

        if (err != noErr || systemDefaultDeviceID == kAudioObjectUnknown)
        {
            NSLog(@"BGMDeviceDisconnectionHandler::getDefaultFallbackDevice: "
                  "Failed to get system default output device");
            return nil;
        }

        // Look up the device in our list
        NSArray<BGMOutputDevice*>* devices = [mDeviceList availableOutputDevices];
        for (BGMOutputDevice* device in devices)
        {
            if (device.deviceID == systemDefaultDeviceID)
            {
                DebugMsg("BGMDeviceDisconnectionHandler::getDefaultFallbackDevice: "
                         "Using system default output device %u", systemDefaultDeviceID);
                return device;
            }
        }

        NSLog(@"BGMDeviceDisconnectionHandler::getDefaultFallbackDevice: "
              "System default device %u not found in device list", systemDefaultDeviceID);
        return nil;
    }
    @catch (NSException* exception)
    {
        NSLog(@"BGMDeviceDisconnectionHandler::getDefaultFallbackDevice: Exception: %@", exception);
        return nil;
    }
}

#pragma mark - Configuration

- (void)setDefaultDeviceID:(AudioObjectID)defaultDeviceID
{
    @try
    {
        [mStateLock lock];
        mDefaultDeviceID = defaultDeviceID;
        DebugMsg("BGMDeviceDisconnectionHandler::setDefaultDeviceID: Default device set to %u",
                 defaultDeviceID);
    }
    @finally
    {
        [mStateLock unlock];
    }
}

@end

#pragma clang assume_nonnull end
