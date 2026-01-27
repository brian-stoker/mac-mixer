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
//  BGMAppOutputDeviceController.h
//  BGMApp
//
//  Copyright © 2026 Background Music contributors
//
//  Coordinates routing decisions between BGMApp's multi-playthrough system and
//  BGMDriver's per-client output device assignments.
//

#ifndef BGMApp__BGMAppOutputDeviceController
#define BGMApp__BGMAppOutputDeviceController

// Local Includes
#import "BGMAppOutputDevicePrefs.h"
#import "BGMOutputDeviceList.h"
#import "BGMPlayThroughManager.h"
#import "BGMAudioDevice.h"

// System Includes
#import <Foundation/Foundation.h>
#import <CoreAudio/AudioHardware.h>


#pragma clang assume_nonnull begin

@interface BGMAppOutputDeviceController : NSObject

/*!
 Initialize the output device controller.

 @param manager The playthrough manager that handles audio routing.
 @param prefs The preferences storage for per-app output device assignments.
 @param deviceList The list of available output devices.
 @param bgmDevice The BGMDevice instance.
 */
- (instancetype)initWithPlayThroughManager:(BGMPlayThroughManager*)manager
                         outputDevicePrefs:(BGMAppOutputDevicePrefs*)prefs
                           outputDeviceList:(BGMOutputDeviceList*)deviceList
                                  bgmDevice:(BGMAudioDevice)bgmDevice;

/*!
 Apply stored preferences to BGMDriver. This sends all saved per-app output device
 assignments to BGMDriver via the kAudioDeviceCustomPropertyClientOutputDevices property.
 Should be called during initialization to restore previous state.
 */
- (void)applyStoredPreferences;

/*!
 Set output device for an application.

 @param deviceUID The UID of the output device, or nil to use the default output device.
 @param bundleID The bundle ID of the application.
 */
- (void)setOutputDeviceUID:(nullable NSString*)deviceUID forBundleID:(NSString*)bundleID;

/*!
 Get the output device UID for an application.

 @param bundleID The bundle ID of the application.
 @return The UID of the output device, or nil if using the default output device.
 */
- (nullable NSString*)outputDeviceUIDForBundleID:(NSString*)bundleID;

/*!
 Start listening for property changes from BGMDriver.
 This sets up a HAL property listener for kAudioDeviceCustomPropertyClientOutputDevices.
 */
- (void)startListeningForPropertyChanges;

/*!
 Stop listening for property changes from BGMDriver.
 This removes the HAL property listener.
 */
- (void)stopListeningForPropertyChanges;

@end

#pragma clang assume_nonnull end

#endif /* BGMApp__BGMAppOutputDeviceController */
