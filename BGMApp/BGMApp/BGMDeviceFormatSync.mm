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
//  BGMDeviceFormatSync.mm
//  BGMApp
//
//  Copyright © 2026 Kyle Neideck
//

// Self Include
#include "BGMDeviceFormatSync.h"

// Local Includes
#include "BGM_Types.h"
#include "BGM_Utils.h"

// PublicUtility Includes
#include "CAHALAudioDevice.h"
#include "CAException.h"

// System Includes
#include <mach/mach_time.h>
#include <algorithm>
#include <set>


#pragma clang assume_nonnull begin

// Error domain for format sync errors
static NSString* const kBGMDeviceFormatSyncErrorDomain = @"com.bearisdriving.BGM.DeviceFormatSync";

// Error codes
typedef NS_ENUM(NSInteger, BGMDeviceFormatSyncError) {
    kBGMDeviceFormatSyncErrorIncompatibleDevice = 1,
    kBGMDeviceFormatSyncErrorNoCommonSampleRate = 2,
    kBGMDeviceFormatSyncErrorSynchronizationFailed = 3,
    kBGMDeviceFormatSyncErrorInvalidDevice = 4
};

#pragma mark Construction/Destruction

BGMDeviceFormatSync::BGMDeviceFormatSync(BGMAudioDevice inBGMDevice)
:
    mBGMDevice(inBGMDevice)
{
    DebugMsg("BGMDeviceFormatSync::BGMDeviceFormatSync: Initialized with BGMDevice %u",
             mBGMDevice.GetObjectID());
}

BGMDeviceFormatSync::~BGMDeviceFormatSync()
{
    CAMutex::Locker locker(mMutex);
    mCapabilitiesCache.clear();
}

#pragma mark Compatibility Checking

bool    BGMDeviceFormatSync::IsDeviceCompatible(const BGMAudioDevice& inDevice,
                                                 NSArray<NSNumber*>* inActiveDeviceIDs,
                                                 NSError* __nullable * __nullable outError)
{
    CAMutex::Locker locker(mMutex);

    // Empty device list is always compatible
    if (!inActiveDeviceIDs || inActiveDeviceIDs.count == 0)
    {
        return true;
    }

    // Get capabilities for the new device
    auto newDeviceCaps = GetDeviceCapabilities(inDevice.GetObjectID());
    if (!newDeviceCaps.has_value())
    {
        if (outError)
        {
            *outError = [NSError errorWithDomain:kBGMDeviceFormatSyncErrorDomain
                                            code:kBGMDeviceFormatSyncErrorInvalidDevice
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"Could not get capabilities for device %u", inDevice.GetObjectID()]
            }];
        }
        return false;
    }

    // Get capabilities for all active devices
    std::vector<DeviceCapabilities> allCapabilities;
    allCapabilities.push_back(newDeviceCaps.value());

    for (NSNumber* deviceIDNum in inActiveDeviceIDs)
    {
        AudioObjectID deviceID = deviceIDNum.unsignedIntValue;

        // Skip if this is the device we're checking
        if (deviceID == inDevice.GetObjectID())
        {
            continue;
        }

        auto caps = GetDeviceCapabilities(deviceID);
        if (caps.has_value())
        {
            allCapabilities.push_back(caps.value());
        }
    }

    // Check if there's a common sample rate
    Float64 commonSampleRate = FindHighestCommonSampleRate(allCapabilities);

    if (commonSampleRate == 0)
    {
        if (outError)
        {
            *outError = [NSError errorWithDomain:kBGMDeviceFormatSyncErrorDomain
                                            code:kBGMDeviceFormatSyncErrorIncompatibleDevice
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"No common sample rate found between devices"
            }];
        }

        LogWarning("BGMDeviceFormatSync::IsDeviceCompatible: Device %u has no common sample rate with active devices",
                   inDevice.GetObjectID());
        return false;
    }

    DebugMsg("BGMDeviceFormatSync::IsDeviceCompatible: Device %u is compatible (common rate: %.0f Hz)",
             inDevice.GetObjectID(), commonSampleRate);

    return true;
}

#pragma mark Format Synchronization

bool    BGMDeviceFormatSync::SynchronizeFormatForActiveDevices(NSArray<NSNumber*>* inActiveDeviceIDs,
                                                                NSError* __nullable * __nullable outError)
{
    CAMutex::Locker locker(mMutex);

    // Nothing to synchronize if no active devices
    if (!inActiveDeviceIDs || inActiveDeviceIDs.count == 0)
    {
        DebugMsg("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: No active devices to synchronize");
        return true;
    }

    DebugMsg("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: Synchronizing with %lu active devices",
             (unsigned long)inActiveDeviceIDs.count);

    // Get capabilities for all active devices
    std::vector<DeviceCapabilities> allCapabilities;

    for (NSNumber* deviceIDNum in inActiveDeviceIDs)
    {
        AudioObjectID deviceID = deviceIDNum.unsignedIntValue;
        auto caps = GetDeviceCapabilities(deviceID);

        if (caps.has_value())
        {
            allCapabilities.push_back(caps.value());
        }
        else
        {
            LogWarning("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: "
                      "Could not get capabilities for device %u", deviceID);
        }
    }

    if (allCapabilities.empty())
    {
        LogError("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: No valid device capabilities");

        if (outError)
        {
            *outError = [NSError errorWithDomain:kBGMDeviceFormatSyncErrorDomain
                                            code:kBGMDeviceFormatSyncErrorInvalidDevice
                                        userInfo:@{
                NSLocalizedDescriptionKey: @"Could not get capabilities for any active devices"
            }];
        }
        return false;
    }

    // Determine the target sample rate
    Float64 targetSampleRate = FindHighestCommonSampleRate(allCapabilities);

    if (targetSampleRate == 0)
    {
        // No common rate found, use the lowest rate and warn
        targetSampleRate = FindLowestSampleRate(allCapabilities);

        LogWarning("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: "
                  "No common sample rate found. Using lowest rate: %.0f Hz. "
                  "Audio quality may be degraded.", targetSampleRate);

        // Note: We continue anyway instead of failing, as some audio is better than none
    }
    else
    {
        DebugMsg("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: "
                "Using highest common sample rate: %.0f Hz", targetSampleRate);
    }

    // Determine the target buffer size
    UInt32 targetBufferSize = FindSmallestCommonBufferSize(allCapabilities);
    DebugMsg("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: "
            "Using smallest common buffer size: %u frames", targetBufferSize);

    // Apply the settings to BGMDevice
    bool success = true;

    try
    {
        Float64 currentSampleRate = mBGMDevice.GetNominalSampleRate();

        if (currentSampleRate != targetSampleRate)
        {
            DebugMsg("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: "
                    "Setting BGMDevice sample rate from %.0f Hz to %.0f Hz",
                    currentSampleRate, targetSampleRate);

            mBGMDevice.SetNominalSampleRate(targetSampleRate);
        }
    }
    catch (CAException e)
    {
        LogError("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: "
                "Failed to set BGMDevice sample rate to %.0f Hz. Error: %d",
                targetSampleRate, e.GetError());
        success = false;

        if (outError)
        {
            *outError = [NSError errorWithDomain:kBGMDeviceFormatSyncErrorDomain
                                            code:kBGMDeviceFormatSyncErrorSynchronizationFailed
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"Failed to set sample rate: %d", e.GetError()]
            }];
        }
    }

    try
    {
        UInt32 currentBufferSize = mBGMDevice.GetIOBufferSize();

        if (currentBufferSize != targetBufferSize)
        {
            DebugMsg("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: "
                    "Setting BGMDevice buffer size from %u to %u frames",
                    currentBufferSize, targetBufferSize);

            mBGMDevice.SetIOBufferSize(targetBufferSize);
        }
    }
    catch (CAException e)
    {
        LogError("BGMDeviceFormatSync::SynchronizeFormatForActiveDevices: "
                "Failed to set BGMDevice buffer size to %u frames. Error: %d",
                targetBufferSize, e.GetError());
        success = false;

        if (outError && !*outError)  // Only set error if not already set
        {
            *outError = [NSError errorWithDomain:kBGMDeviceFormatSyncErrorDomain
                                            code:kBGMDeviceFormatSyncErrorSynchronizationFailed
                                        userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"Failed to set buffer size: %d", e.GetError()]
            }];
        }
    }

    return success;
}

#pragma mark Format Recommendations

// static
Float64 BGMDeviceFormatSync::RecommendedSampleRateForDevices(NSArray<NSNumber*>* inDeviceIDs)
{
    if (!inDeviceIDs || inDeviceIDs.count == 0)
    {
        return 44100.0;  // Default sample rate
    }

    BGMDeviceFormatSync tempSync(BGMAudioDevice(kAudioObjectUnknown));
    std::vector<DeviceCapabilities> allCapabilities;

    for (NSNumber* deviceIDNum in inDeviceIDs)
    {
        AudioObjectID deviceID = deviceIDNum.unsignedIntValue;
        auto caps = tempSync.GetDeviceCapabilities(deviceID);

        if (caps.has_value())
        {
            allCapabilities.push_back(caps.value());
        }
    }

    if (allCapabilities.empty())
    {
        return 44100.0;
    }

    Float64 commonRate = FindHighestCommonSampleRate(allCapabilities);

    if (commonRate == 0)
    {
        commonRate = FindLowestSampleRate(allCapabilities);
    }

    return commonRate;
}

// static
UInt32  BGMDeviceFormatSync::RecommendedBufferSizeForDevices(NSArray<NSNumber*>* inDeviceIDs)
{
    if (!inDeviceIDs || inDeviceIDs.count == 0)
    {
        return 512;  // Default buffer size
    }

    BGMDeviceFormatSync tempSync(BGMAudioDevice(kAudioObjectUnknown));
    std::vector<DeviceCapabilities> allCapabilities;

    for (NSNumber* deviceIDNum in inDeviceIDs)
    {
        AudioObjectID deviceID = deviceIDNum.unsignedIntValue;
        auto caps = tempSync.GetDeviceCapabilities(deviceID);

        if (caps.has_value())
        {
            allCapabilities.push_back(caps.value());
        }
    }

    if (allCapabilities.empty())
    {
        return 512;
    }

    return FindSmallestCommonBufferSize(allCapabilities);
}

#pragma mark Device Capabilities Cache

std::optional<BGMDeviceFormatSync::DeviceCapabilities>
    BGMDeviceFormatSync::GetDeviceCapabilities(AudioObjectID inDeviceID)
{
    // Check cache first
    auto it = mCapabilitiesCache.find(inDeviceID);

    if (it != mCapabilitiesCache.end())
    {
        // Check if cache entry is still valid
        UInt64 now = mach_absolute_time();

        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        UInt64 elapsedNsec = ((now - it->second.cacheTime) * info.numer) / info.denom;

        if (elapsedNsec < kCacheTimeoutNsec)
        {
            DebugMsg("BGMDeviceFormatSync::GetDeviceCapabilities: Using cached capabilities for device %u",
                    inDeviceID);
            return it->second;
        }
        else
        {
            DebugMsg("BGMDeviceFormatSync::GetDeviceCapabilities: Cache expired for device %u, refreshing",
                    inDeviceID);
            mCapabilitiesCache.erase(it);
        }
    }

    // Query device capabilities
    DeviceCapabilities caps;
    caps.deviceID = inDeviceID;
    caps.cacheTime = mach_absolute_time();

    try
    {
        CAHALAudioDevice device(inDeviceID);

        if (!device.IsAlive())
        {
            LogWarning("BGMDeviceFormatSync::GetDeviceCapabilities: Device %u is not alive", inDeviceID);
            return std::nullopt;
        }

        // Get current sample rate
        caps.nominalSampleRate = device.GetNominalSampleRate();

        // Get available sample rates
        UInt32 numRanges = device.GetNumberAvailableNominalSampleRateRanges();

        if (numRanges > 0)
        {
            std::vector<AudioValueRange> ranges(numRanges);
            device.GetAvailableNominalSampleRateRanges(numRanges, ranges.data());
            caps.availableSampleRates = ranges;
        }
        else
        {
            // If no ranges available, use current rate
            AudioValueRange currentRange;
            currentRange.mMinimum = caps.nominalSampleRate;
            currentRange.mMaximum = caps.nominalSampleRate;
            caps.availableSampleRates.push_back(currentRange);
        }

        // Get buffer size information
        caps.ioBufferSize = device.GetIOBufferSize();
        caps.bufferSizeSettable = device.IsIOBufferSizeSettable();

        if (device.HasIOBufferSizeRange())
        {
            device.GetIOBufferSizeRange(caps.minBufferSize, caps.maxBufferSize);
        }
        else
        {
            caps.minBufferSize = caps.ioBufferSize;
            caps.maxBufferSize = caps.ioBufferSize;
        }

        DebugMsg("BGMDeviceFormatSync::GetDeviceCapabilities: Device %u - "
                "SampleRate: %.0f Hz, BufferSize: %u-%u frames (current: %u)",
                inDeviceID, caps.nominalSampleRate,
                caps.minBufferSize, caps.maxBufferSize, caps.ioBufferSize);

        // Cache the capabilities
        mCapabilitiesCache[inDeviceID] = caps;

        return caps;
    }
    catch (CAException e)
    {
        LogError("BGMDeviceFormatSync::GetDeviceCapabilities: Failed to get capabilities for device %u. Error: %d",
                inDeviceID, e.GetError());
        return std::nullopt;
    }
}

void    BGMDeviceFormatSync::ClearCapabilitiesCache()
{
    CAMutex::Locker locker(mMutex);

    DebugMsg("BGMDeviceFormatSync::ClearCapabilitiesCache: Clearing %lu cached entries",
            (unsigned long)mCapabilitiesCache.size());

    mCapabilitiesCache.clear();
}

#pragma mark Helper Methods

// static
Float64 BGMDeviceFormatSync::FindHighestCommonSampleRate(const std::vector<DeviceCapabilities>& inCapabilities)
{
    if (inCapabilities.empty())
    {
        return 0;
    }

    // Collect all possible sample rates from all devices
    std::set<Float64> commonRates;
    bool firstDevice = true;

    for (const auto& caps : inCapabilities)
    {
        std::set<Float64> deviceRates;

        // Extract all supported rates from the device's available ranges
        for (const auto& range : caps.availableSampleRates)
        {
            // Common sample rates to check
            static const Float64 standardRates[] = {
                44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0
            };

            for (Float64 rate : standardRates)
            {
                if (rate >= range.mMinimum && rate <= range.mMaximum)
                {
                    deviceRates.insert(rate);
                }
            }

            // Also include the range endpoints
            deviceRates.insert(range.mMinimum);
            deviceRates.insert(range.mMaximum);
        }

        if (firstDevice)
        {
            commonRates = deviceRates;
            firstDevice = false;
        }
        else
        {
            // Keep only rates that are in both sets (intersection)
            std::set<Float64> intersection;
            std::set_intersection(commonRates.begin(), commonRates.end(),
                                deviceRates.begin(), deviceRates.end(),
                                std::inserter(intersection, intersection.begin()));
            commonRates = intersection;
        }

        // If no common rates remain, we can stop early
        if (commonRates.empty())
        {
            return 0;
        }
    }

    // Return the highest common rate
    if (!commonRates.empty())
    {
        return *commonRates.rbegin();
    }

    return 0;
}

// static
Float64 BGMDeviceFormatSync::FindLowestSampleRate(const std::vector<DeviceCapabilities>& inCapabilities)
{
    if (inCapabilities.empty())
    {
        return 44100.0;
    }

    Float64 lowestRate = std::numeric_limits<Float64>::max();

    for (const auto& caps : inCapabilities)
    {
        for (const auto& range : caps.availableSampleRates)
        {
            lowestRate = std::min(lowestRate, range.mMinimum);
        }
    }

    return lowestRate;
}

// static
UInt32  BGMDeviceFormatSync::FindSmallestCommonBufferSize(const std::vector<DeviceCapabilities>& inCapabilities)
{
    if (inCapabilities.empty())
    {
        return 512;
    }

    UInt32 smallestMax = std::numeric_limits<UInt32>::max();
    UInt32 largestMin = 0;

    // Find the range that all devices support
    for (const auto& caps : inCapabilities)
    {
        smallestMax = std::min(smallestMax, caps.maxBufferSize);
        largestMin = std::max(largestMin, caps.minBufferSize);
    }

    // If ranges don't overlap, use the smallest maximum
    if (largestMin > smallestMax)
    {
        LogWarning("BGMDeviceFormatSync::FindSmallestCommonBufferSize: "
                  "Buffer size ranges don't overlap. Using smallest maximum: %u", smallestMax);
        return smallestMax;
    }

    // Use the largest minimum (which is within all devices' supported range)
    return largestMin;
}

#pragma clang assume_nonnull end
