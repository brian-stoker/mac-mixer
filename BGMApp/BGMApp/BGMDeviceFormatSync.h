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
//  BGMDeviceFormatSync.h
//  BGMApp
//
//  Copyright © 2026 Kyle Neideck
//
//  Synchronizes sample rate and buffer size across BGMDevice and multiple output devices.
//  Ensures all devices operate at compatible formats when using per-app audio routing.
//
//  Thread safe.
//

#ifndef BGMApp__BGMDeviceFormatSync
#define BGMApp__BGMDeviceFormatSync

// Local Includes
#include "BGMAudioDevice.h"

// PublicUtility Includes
#include "CAMutex.h"

// STL Includes
#include <map>
#include <optional>
#include <vector>

// System Includes
#include <CoreAudio/AudioHardware.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif


#pragma clang assume_nonnull begin

class BGMDeviceFormatSync
{

#pragma mark Construction/Destruction

public:
    /*!
     Initialize the format synchronizer with the BGMDevice.

     @param inBGMDevice The BGMDevice that will be synchronized with output devices.
     */
                        BGMDeviceFormatSync(BGMAudioDevice inBGMDevice);
                        ~BGMDeviceFormatSync();

                        // Disallow copying
                        BGMDeviceFormatSync(const BGMDeviceFormatSync&) = delete;
                        BGMDeviceFormatSync& operator=(const BGMDeviceFormatSync&) = delete;

#ifdef __OBJC__
                        // Only intended as a convenience for Objective-C instance vars
                        BGMDeviceFormatSync()
                        : BGMDeviceFormatSync(BGMAudioDevice(kAudioObjectUnknown)) { };
#endif

#pragma mark Compatibility Checking

#ifdef __OBJC__
    /*!
     Check if a device is compatible with the currently active output devices.

     @param inDevice The device to check for compatibility.
     @param inActiveDeviceIDs Array of AudioObjectIDs of currently active output devices.
     @param outError Optional pointer to receive error information if the check fails.
     @return YES if the device is compatible, NO otherwise.
     */
    bool                IsDeviceCompatible(const BGMAudioDevice& inDevice,
                                          NSArray<NSNumber*>* inActiveDeviceIDs,
                                          NSError* __nullable * __nullable outError);
#endif

#pragma mark Format Synchronization

#ifdef __OBJC__
    /*!
     Synchronize BGMDevice format with the active output devices.
     Adjusts sample rate and buffer size to values compatible with all active devices.

     @param inActiveDeviceIDs Array of AudioObjectIDs of currently active output devices.
     @param outError Optional pointer to receive error information if synchronization fails.
     @return YES if synchronization succeeded, NO otherwise.
     */
    bool                SynchronizeFormatForActiveDevices(NSArray<NSNumber*>* inActiveDeviceIDs,
                                                         NSError* __nullable * __nullable outError);
#endif

#pragma mark Format Recommendations

#ifdef __OBJC__
    /*!
     Get the recommended sample rate for a set of devices.
     Uses the highest common sample rate supported by all devices.
     If no common rate exists, returns the lowest supported rate.

     @param inDeviceIDs Array of AudioObjectIDs to analyze.
     @return The recommended sample rate in Hz.
     */
    static Float64      RecommendedSampleRateForDevices(NSArray<NSNumber*>* inDeviceIDs);

    /*!
     Get the recommended buffer size for a set of devices.
     Uses the smallest buffer size that all devices can support.

     @param inDeviceIDs Array of AudioObjectIDs to analyze.
     @return The recommended buffer size in frames.
     */
    static UInt32       RecommendedBufferSizeForDevices(NSArray<NSNumber*>* inDeviceIDs);
#endif

#pragma mark Device Capabilities Cache

private:
    // Structure to cache device capabilities
    struct DeviceCapabilities
    {
        AudioObjectID       deviceID;
        Float64             nominalSampleRate;
        std::vector<AudioValueRange> availableSampleRates;
        UInt32              ioBufferSize;
        UInt32              minBufferSize;
        UInt32              maxBufferSize;
        bool                bufferSizeSettable;
        UInt64              cacheTime;  // mach_absolute_time when cached
    };

    /*!
     Get cached capabilities for a device, or query and cache them if not present.

     @param inDeviceID The device to get capabilities for.
     @return The device capabilities, or std::nullopt if the device is invalid.
     */
    std::optional<DeviceCapabilities> GetDeviceCapabilities(AudioObjectID inDeviceID);

    /*!
     Clear the capabilities cache. Should be called when devices are added/removed.
     */
    void                ClearCapabilitiesCache();

#pragma mark Helper Methods

    /*!
     Find the highest sample rate supported by all devices.

     @param inCapabilities Vector of device capabilities to analyze.
     @return The highest common sample rate, or 0 if no common rate exists.
     */
    static Float64      FindHighestCommonSampleRate(const std::vector<DeviceCapabilities>& inCapabilities);

    /*!
     Find the lowest sample rate among all devices.

     @param inCapabilities Vector of device capabilities to analyze.
     @return The lowest sample rate.
     */
    static Float64      FindLowestSampleRate(const std::vector<DeviceCapabilities>& inCapabilities);

    /*!
     Find the smallest buffer size that all devices can support.

     @param inCapabilities Vector of device capabilities to analyze.
     @return The smallest common buffer size.
     */
    static UInt32       FindSmallestCommonBufferSize(const std::vector<DeviceCapabilities>& inCapabilities);

#pragma mark Member Variables

private:
    BGMAudioDevice      mBGMDevice { kAudioObjectUnknown };

    // Cache of device capabilities to avoid repeated HAL queries
    std::map<AudioObjectID, DeviceCapabilities> mCapabilitiesCache;

    // Mutex for thread-safe access
    mutable CAMutex     mMutex { "Device Format Sync" };

    // Cache timeout in nanoseconds (5 seconds)
    static const UInt64 kCacheTimeoutNsec = 5ULL * NSEC_PER_SEC;
};

#pragma clang assume_nonnull end

#endif /* BGMApp__BGMDeviceFormatSync */
