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
//  BGMPlayThroughManager.h
//  BGMApp
//
//  Copyright © 2026 Kyle Neideck
//
//  Manages multiple BGMPlayThrough instances to support per-app audio output selection.
//  Each active output device gets its own BGMPlayThrough instance for streaming audio
//  from BGMDevice to that output device.
//

#ifndef BGMApp__BGMPlayThroughManager
#define BGMApp__BGMPlayThroughManager

// Local Includes
#include "BGMAudioDevice.h"
#include "BGMPlayThrough.h"

// PublicUtility Includes
#include "CAMutex.h"

// STL Includes
#include <map>
#include <memory>

// System Includes
#include <CoreAudio/AudioHardware.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif


#pragma clang assume_nonnull begin

class BGMPlayThroughManager
{

public:
    // Maximum number of concurrent output devices
    static const NSUInteger kMaxConcurrentOutputs = 8;

public:
                        BGMPlayThroughManager(BGMAudioDevice inInputDevice);
                        ~BGMPlayThroughManager();

                        // Disallow copying
                        BGMPlayThroughManager(const BGMPlayThroughManager&) = delete;
                        BGMPlayThroughManager& operator=(const BGMPlayThroughManager&) = delete;

    /*!
     Get the BGMPlayThrough instance for the specified output device. Creates a new instance
     if one doesn't exist yet and we haven't reached the maximum number of concurrent outputs.

     @param outputDevice The output device to get/create a playthrough instance for.
     @return A pointer to the BGMPlayThrough instance, or nullptr if the maximum number of
             concurrent outputs has been reached.
     @throws CAException If creating a new BGMPlayThrough instance fails.
     */
    BGMPlayThrough* __nullable GetPlayThroughForOutputDevice(const BGMAudioDevice& outputDevice);

    /*!
     Remove the BGMPlayThrough instance for the specified output device.

     @param outputDevice The output device whose playthrough instance should be removed.
     */
    void                RemovePlayThroughForOutputDevice(const BGMAudioDevice& outputDevice);

    /*!
     Get the default playthrough instance (for apps not assigned to a specific output device).

     @return A pointer to the default BGMPlayThrough instance, or nullptr if not set.
     */
    BGMPlayThrough* __nullable GetDefaultPlayThrough() const;

    /*!
     Set the default output device. The playthrough instance for this device will be used
     for apps that haven't been assigned to a specific output device.

     @param outputDevice The device to set as the default.
     @throws CAException If getting/creating the playthrough instance fails.
     */
    void                SetDefaultPlayThrough(const BGMAudioDevice& outputDevice);

    /*!
     Stop all active playthrough instances.
     */
    void                StopAll();

    /*!
     Deactivate all playthrough instances.
     */
    void                DeactivateAll();

#ifdef __OBJC__
    /*!
     Get the IDs of all output devices with active playthrough instances.

     @return An array of NSNumber objects containing AudioObjectID values.
     */
    NSArray<NSNumber*>* GetActiveOutputDeviceIDs() const;
#endif

    /*!
     Get the number of active playthrough instances.

     @return The number of active instances.
     */
    NSUInteger          GetActiveInstanceCount() const;

private:
    BGMAudioDevice      mInputDevice;

    // Map from output device ID to BGMPlayThrough instance
    std::map<AudioObjectID, std::unique_ptr<BGMPlayThrough>> mPlayThroughInstances;

    // The default output device ID (for unassigned apps)
    AudioObjectID       mDefaultOutputDeviceID;

    // Mutex for thread-safe access to the map
    mutable CAMutex     mMapMutex { "PlayThrough Manager map" };

};

#pragma clang assume_nonnull end

#endif /* BGMApp__BGMPlayThroughManager */
