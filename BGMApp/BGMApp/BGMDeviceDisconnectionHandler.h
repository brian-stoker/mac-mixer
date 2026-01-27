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
//  BGMDeviceDisconnectionHandler.h
//  BGMApp
//
//  Copyright © 2026 Background Music contributors
//
//  Handles graceful recovery when output devices are disconnected while
//  actively routing audio to them. Monitors device connection/disconnection
//  events and reroutes affected apps to fallback devices.
//

#ifndef BGMApp__BGMDeviceDisconnectionHandler
#define BGMApp__BGMDeviceDisconnectionHandler

// Local Includes
#import "BGMPlayThroughManager.h"
#import "BGMAppOutputDeviceController.h"
#import "BGMOutputDeviceList.h"
#import "BGMAudioDevice.h"

// System Includes
#import <Foundation/Foundation.h>
#import <CoreAudio/AudioHardware.h>


#pragma clang assume_nonnull begin

// Notification posted when a device is disconnected and apps are rerouted
extern NSString* const kBGMDeviceDisconnectedNotification;

// Notification posted when a device is reconnected
extern NSString* const kBGMDeviceReconnectedNotification;

// Keys for notification userInfo dictionary
extern NSString* const kBGMDisconnectedDeviceUIDKey;
extern NSString* const kBGMReconnectedDeviceUIDKey;
extern NSString* const kBGMAffectedBundleIDsKey;


@interface BGMDeviceDisconnectionHandler : NSObject

/*!
 Initialize the device disconnection handler.

 @param manager The playthrough manager that handles audio routing.
 @param controller The output device controller that manages device assignments.
 @param deviceList The list of available output devices.
 @param defaultDeviceID The ID of the default/fallback output device.
 */
- (instancetype)initWithPlayThroughManager:(BGMPlayThroughManager*)manager
                          outputController:(BGMAppOutputDeviceController*)controller
                            outputDeviceList:(BGMOutputDeviceList*)deviceList
                            defaultDeviceID:(AudioObjectID)defaultDeviceID;

/*!
 Start listening for device disconnection/reconnection events.
 Registers a HAL property listener for kAudioHardwarePropertyDevices.
 */
- (void)startListening;

/*!
 Stop listening for device events.
 Removes the HAL property listener.
 */
- (void)stopListening;

/*!
 Handle a device disconnection event.
 Called internally when a device is removed from the system.

 @param deviceID The AudioObjectID of the disconnected device.
 */
- (void)handleDeviceDisconnected:(AudioObjectID)deviceID;

/*!
 Handle a device reconnection event.
 Called internally when a device is added to the system.

 @param deviceUID The UID of the reconnected device.
 */
- (void)handleDeviceReconnected:(NSString*)deviceUID;

/*!
 Manually update the default/fallback device ID.

 @param defaultDeviceID The new default device ID.
 */
- (void)setDefaultDeviceID:(AudioObjectID)defaultDeviceID;

@end

#pragma clang assume_nonnull end

#endif /* BGMApp__BGMDeviceDisconnectionHandler */
