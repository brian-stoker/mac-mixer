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
//  BGMOutputDeviceList.h
//  BGMApp
//
//  Copyright © 2026 Kyle Neideck
//
//  Manages tracking of available audio output devices and their properties
//  for per-app audio routing decisions.
//

#ifndef BGMApp__BGMOutputDeviceList
#define BGMApp__BGMOutputDeviceList

// System Includes
#import <Foundation/Foundation.h>
#import <CoreAudio/AudioHardware.h>


#pragma clang assume_nonnull begin

#pragma mark - BGMOutputDevice

// A value class representing an audio output device and its properties.
@interface BGMOutputDevice : NSObject

@property (nonatomic, readonly) AudioObjectID deviceID;
@property (nonatomic, readonly, copy) NSString* uid;
@property (nonatomic, readonly, copy) NSString* name;
@property (nonatomic, readonly) BOOL isConnected;

- (instancetype) initWithDeviceID:(AudioObjectID)deviceID
                              uid:(NSString*)uid
                             name:(NSString*)name
                      isConnected:(BOOL)isConnected;

@end

#pragma mark - BGMOutputDeviceList

// Manages the list of available audio output devices, excluding BGMDevice variants.
// Thread-safe singleton that listens for device connection/disconnection events.
@interface BGMOutputDeviceList : NSObject

+ (instancetype) sharedInstance;

// Get all available output devices (excludes BGMDevice variants)
- (NSArray<BGMOutputDevice*>*) availableOutputDevices;

// Find device by UID
- (nullable BGMOutputDevice*) deviceWithUID:(NSString*)uid;

// Find device by name (fallback for display)
- (nullable BGMOutputDevice*) deviceWithName:(NSString*)name;

// Check if a device UID is valid/connected
- (BOOL) isDeviceAvailable:(NSString*)uid;

// Refresh the device list (called when HAL notifies of changes)
- (void) refreshDeviceList;

@end

#pragma clang assume_nonnull end

#endif /* BGMApp__BGMOutputDeviceList */
