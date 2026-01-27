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
//  BGMUserNotifications.h
//  BGMApp
//
//  Copyright © 2026 Kyle Neideck
//
//  Provides user notifications for per-app audio routing events and errors.
//  Uses modern notification APIs (UNUserNotificationCenter on macOS 10.14+)
//  with fallback to NSUserNotificationCenter for compatibility.
//

#ifndef BGMApp__BGMUserNotifications
#define BGMApp__BGMUserNotifications

// System Includes
#import <Foundation/Foundation.h>


#pragma clang assume_nonnull begin

/*!
 BGMUserNotifications provides a unified interface for displaying user notifications
 related to per-app audio routing. It handles API compatibility across macOS versions.

 This is a singleton class. Use [BGMUserNotifications sharedInstance] to access it.
 */
@interface BGMUserNotifications : NSObject

/*!
 Get the shared instance of BGMUserNotifications.

 @return The singleton instance.
 */
+ (instancetype) sharedInstance;

/*!
 Show notification when an output device is disconnected and apps are reassigned.

 @param deviceName The name of the disconnected device.
 @param appNames Array of app names that were using the disconnected device.
 @param fallbackDeviceName The name of the device apps were reassigned to.
 */
- (void) notifyDeviceDisconnected:(NSString*)deviceName
                     affectedApps:(NSArray<NSString*>*)appNames
                   fallbackDevice:(NSString*)fallbackDeviceName;

/*!
 Show notification when audio routing fails for an app.

 @param errorMessage A user-friendly error message explaining the failure.
 @param appName The name of the app that experienced the routing error.
 */
- (void) notifyRoutingError:(NSString*)errorMessage
                     forApp:(NSString*)appName;

/*!
 Show notification when a device's audio format is incompatible with the current setup.

 @param deviceName The name of the device with incompatible format.
 @param reason A user-friendly explanation of the incompatibility.
 */
- (void) notifyFormatIncompatible:(NSString*)deviceName
                           reason:(NSString*)reason;

/*!
 Show notification when the maximum number of concurrent output devices is reached.

 @param deviceName The name of the device that couldn't be added.
 @param maxDevices The maximum number of concurrent devices supported.
 */
- (void) notifyMaxConcurrentDevicesReached:(NSString*)deviceName
                                maxDevices:(NSUInteger)maxDevices;

@end

#pragma clang assume_nonnull end

#endif /* BGMApp__BGMUserNotifications */
