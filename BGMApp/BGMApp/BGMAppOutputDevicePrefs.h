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
//  BGMAppOutputDevicePrefs.h
//  BGMApp
//
//  Copyright © 2026 Background Music contributors
//
//  Manages persistent storage of per-app output device assignments.
//  Stores mappings between application bundle IDs and audio output device UIDs.
//

// System Includes
#import <Foundation/Foundation.h>


#pragma clang assume_nonnull begin

@interface BGMAppOutputDevicePrefs : NSObject

+ (instancetype)sharedInstance;

// Get/set output device UID for a bundle ID
- (nullable NSString*)outputDeviceUIDForBundleID:(NSString*)bundleID;
- (void)setOutputDeviceUID:(nullable NSString*)deviceUID forBundleID:(NSString*)bundleID;

// Get all stored mappings
- (NSDictionary<NSString*, NSString*>*)allOutputDeviceMappings;

// Remove a mapping
- (void)removeOutputDeviceForBundleID:(NSString*)bundleID;

// Reset all mappings
- (void)resetAllMappings;

@end

#pragma clang assume_nonnull end

