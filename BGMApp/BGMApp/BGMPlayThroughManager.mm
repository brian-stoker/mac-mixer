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
//  BGMPlayThroughManager.mm
//  BGMApp
//
//  Copyright © 2026 Kyle Neideck
//

// Self Include
#include "BGMPlayThroughManager.h"

// Local Includes
#include "BGM_Utils.h"

// PublicUtility Includes
#include "CAMutex.h"

// System Includes
#include <mach/mach_time.h>


#pragma mark Construction/Destruction

BGMPlayThroughManager::BGMPlayThroughManager(BGMAudioDevice inInputDevice)
:
    mInputDevice(inInputDevice),
    mDefaultOutputDeviceID(kAudioObjectUnknown)
{
    DebugMsg("BGMPlayThroughManager::BGMPlayThroughManager: Initialized with input device %u",
             mInputDevice.GetObjectID());
}

BGMPlayThroughManager::~BGMPlayThroughManager()
{
    CAMutex::Locker locker(mMapMutex);

    DebugMsg("BGMPlayThroughManager::~BGMPlayThroughManager: Destroying manager with %lu active instances",
             static_cast<unsigned long>(mPlayThroughInstances.size()));

    // Deactivate all instances before destroying them
    for (auto& pair : mPlayThroughInstances)
    {
        BGMLogAndSwallowExceptionsMsg("BGMPlayThroughManager::~BGMPlayThroughManager",
                                      "Deactivating playthrough",
                                      [&]() {
            if (pair.second)
            {
                pair.second->Deactivate();
            }
        });
    }

    // unique_ptr will automatically clean up the instances
    mPlayThroughInstances.clear();
}

#pragma mark Playthrough Instance Management

BGMPlayThrough* __nullable BGMPlayThroughManager::GetPlayThroughForOutputDevice(const BGMAudioDevice& outputDevice)
{
    CAMutex::Locker locker(mMapMutex);

    AudioObjectID deviceID = outputDevice.GetObjectID();

    // Check if we already have an instance for this device
    auto it = mPlayThroughInstances.find(deviceID);
    if (it != mPlayThroughInstances.end())
    {
        DebugMsg("BGMPlayThroughManager::GetPlayThroughForOutputDevice: Returning existing instance for device %u",
                 deviceID);

        // Update activity time to prevent idle cleanup
        mLastActivityTime[deviceID] = mach_absolute_time();

        return it->second.get();
    }

    // Check if we've reached the maximum number of concurrent outputs
    if (mPlayThroughInstances.size() >= kMaxConcurrentOutputs)
    {
        LogWarning("BGMPlayThroughManager::GetPlayThroughForOutputDevice: Maximum concurrent outputs (%u) reached. "
                   "Cannot create instance for device %u",
                   static_cast<unsigned int>(kMaxConcurrentOutputs),
                   deviceID);
        return nullptr;
    }

    // Create a new playthrough instance
    DebugMsg("BGMPlayThroughManager::GetPlayThroughForOutputDevice: Creating new instance for device %u",
             deviceID);

    try
    {
        std::unique_ptr<BGMPlayThrough> newPlayThrough(new BGMPlayThrough(mInputDevice, outputDevice));

        BGMPlayThrough* playThroughPtr = newPlayThrough.get();

        // Store the instance in the map
        mPlayThroughInstances[deviceID] = std::move(newPlayThrough);

        // Track activity time for idle detection
        mLastActivityTime[deviceID] = mach_absolute_time();

        DebugMsg("BGMPlayThroughManager::GetPlayThroughForOutputDevice: Successfully created instance. "
                 "Active instances: %lu",
                 static_cast<unsigned long>(mPlayThroughInstances.size()));

        return playThroughPtr;
    }
    catch (const CAException& e)
    {
        LogError("BGMPlayThroughManager::GetPlayThroughForOutputDevice: Failed to create BGMPlayThrough for device %u. "
                 "Error: %d",
                 deviceID,
                 e.GetError());
        throw;
    }
}

void    BGMPlayThroughManager::RemovePlayThroughForOutputDevice(const BGMAudioDevice& outputDevice)
{
    CAMutex::Locker locker(mMapMutex);

    AudioObjectID deviceID = outputDevice.GetObjectID();

    auto it = mPlayThroughInstances.find(deviceID);
    if (it != mPlayThroughInstances.end())
    {
        DebugMsg("BGMPlayThroughManager::RemovePlayThroughForOutputDevice: Removing instance for device %u",
                 deviceID);

        // Deactivate before removing
        BGMLogAndSwallowExceptionsMsg("BGMPlayThroughManager::RemovePlayThroughForOutputDevice",
                                      "Deactivating playthrough",
                                      [&]() {
            if (it->second)
            {
                it->second->Deactivate();
            }
        });

        mPlayThroughInstances.erase(it);

        // Remove activity tracking
        mLastActivityTime.erase(deviceID);

        DebugMsg("BGMPlayThroughManager::RemovePlayThroughForOutputDevice: Instance removed. "
                 "Active instances: %lu",
                 static_cast<unsigned long>(mPlayThroughInstances.size()));

        // Clear default if we just removed the default output device
        if (deviceID == mDefaultOutputDeviceID)
        {
            mDefaultOutputDeviceID = kAudioObjectUnknown;
        }
    }
    else
    {
        DebugMsg("BGMPlayThroughManager::RemovePlayThroughForOutputDevice: No instance found for device %u",
                 deviceID);
    }
}

#pragma mark Default Playthrough Management

BGMPlayThrough* __nullable BGMPlayThroughManager::GetDefaultPlayThrough() const
{
    CAMutex::Locker locker(mMapMutex);

    if (mDefaultOutputDeviceID == kAudioObjectUnknown)
    {
        return nullptr;
    }

    auto it = mPlayThroughInstances.find(mDefaultOutputDeviceID);
    if (it != mPlayThroughInstances.end())
    {
        return it->second.get();
    }

    LogWarning("BGMPlayThroughManager::GetDefaultPlayThrough: Default device ID is set (%u) but no instance exists",
               mDefaultOutputDeviceID);
    return nullptr;
}

void    BGMPlayThroughManager::SetDefaultPlayThrough(const BGMAudioDevice& outputDevice)
{
    AudioObjectID deviceID = outputDevice.GetObjectID();

    DebugMsg("BGMPlayThroughManager::SetDefaultPlayThrough: Setting default output device to %u",
             deviceID);

    // Get/create the playthrough instance first (this will take the mutex)
    BGMPlayThrough* playThrough = GetPlayThroughForOutputDevice(outputDevice);

    if (!playThrough)
    {
        LogError("BGMPlayThroughManager::SetDefaultPlayThrough: Failed to get/create playthrough for device %u",
                 deviceID);
        throw CAException(kAudioHardwareUnspecifiedError);
    }

    // Now set it as default (with mutex locked)
    CAMutex::Locker locker(mMapMutex);
    mDefaultOutputDeviceID = deviceID;
}

#pragma mark Lifecycle Management

void    BGMPlayThroughManager::StopAll()
{
    CAMutex::Locker locker(mMapMutex);

    DebugMsg("BGMPlayThroughManager::StopAll: Stopping all playthrough instances (%lu active)",
             static_cast<unsigned long>(mPlayThroughInstances.size()));

    for (auto& pair : mPlayThroughInstances)
    {
        if (pair.second)
        {
            BGMLogAndSwallowExceptionsMsg("BGMPlayThroughManager::StopAll",
                                          "Stopping playthrough",
                                          [&]() {
                pair.second->Stop();
            });
        }
    }
}

void    BGMPlayThroughManager::DeactivateAll()
{
    CAMutex::Locker locker(mMapMutex);

    DebugMsg("BGMPlayThroughManager::DeactivateAll: Deactivating all playthrough instances (%lu active)",
             static_cast<unsigned long>(mPlayThroughInstances.size()));

    for (auto& pair : mPlayThroughInstances)
    {
        if (pair.second)
        {
            BGMLogAndSwallowExceptionsMsg("BGMPlayThroughManager::DeactivateAll",
                                          "Deactivating playthrough",
                                          [&]() {
                pair.second->Deactivate();
            });
        }
    }
}

#pragma mark Status Queries

#ifdef __OBJC__

NSArray<NSNumber*>* BGMPlayThroughManager::GetActiveOutputDeviceIDs() const
{
    CAMutex::Locker locker(mMapMutex);

    // Performance: Use @autoreleasepool to ensure temporary NSNumber objects are
    // deallocated promptly, reducing memory pressure in tight loops
    @autoreleasepool {
        NSMutableArray<NSNumber*>* deviceIDs = [NSMutableArray arrayWithCapacity:mPlayThroughInstances.size()];

        for (const auto& pair : mPlayThroughInstances)
        {
            [deviceIDs addObject:@(pair.first)];
        }

        return [deviceIDs copy];
    }
}

#endif

NSUInteger  BGMPlayThroughManager::GetActiveInstanceCount() const
{
    CAMutex::Locker locker(mMapMutex);
    return static_cast<NSUInteger>(mPlayThroughInstances.size());
}

#pragma mark Performance Optimization

void    BGMPlayThroughManager::CheckForIdleInstances()
{
    CAMutex::Locker locker(mMapMutex);

    if (mPlayThroughInstances.empty())
    {
        return;
    }

    UInt64 now = mach_absolute_time();
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);

    // Convert timeout to mach_absolute_time units
    UInt64 timeoutNsec = static_cast<UInt64>(kIdleTimeoutSeconds * NSEC_PER_SEC);

    // Collect idle instances (don't modify map while iterating)
    std::vector<AudioObjectID> idleDevices;

    for (const auto& pair : mPlayThroughInstances)
    {
        AudioObjectID deviceID = pair.first;

        // Never clean up the default playthrough instance
        if (deviceID == mDefaultOutputDeviceID)
        {
            continue;
        }

        // Check if we have activity time for this device
        auto activityIt = mLastActivityTime.find(deviceID);
        if (activityIt == mLastActivityTime.end())
        {
            // No activity recorded, skip (shouldn't happen, but be safe)
            continue;
        }

        // Calculate elapsed time since last activity
        UInt64 elapsedTicks = now - activityIt->second;
        UInt64 elapsedNsec = (elapsedTicks * info.numer) / info.denom;

        if (elapsedNsec > timeoutNsec)
        {
            DebugMsg("BGMPlayThroughManager::CheckForIdleInstances: Device %u has been idle for %.1f seconds",
                     deviceID, static_cast<Float64>(elapsedNsec) / NSEC_PER_SEC);
            idleDevices.push_back(deviceID);
        }
    }

    // Clean up idle instances
    // Performance Note: This reduces CPU and memory usage by deallocating unused
    // playthrough instances and their ring buffers after 30 seconds of inactivity.
    for (AudioObjectID deviceID : idleDevices)
    {
        CleanupIdleInstance(deviceID);
    }

    if (!idleDevices.empty())
    {
        DebugMsg("BGMPlayThroughManager::CheckForIdleInstances: Cleaned up %lu idle instance(s). "
                 "Active instances: %lu",
                 static_cast<unsigned long>(idleDevices.size()),
                 static_cast<unsigned long>(mPlayThroughInstances.size()));
    }
}

void    BGMPlayThroughManager::CleanupIdleInstance(AudioObjectID deviceID)
{
    // mMapMutex should already be locked by caller

    DebugMsg("BGMPlayThroughManager::CleanupIdleInstance: Cleaning up idle instance for device %u",
             deviceID);

    auto it = mPlayThroughInstances.find(deviceID);
    if (it != mPlayThroughInstances.end())
    {
        // Deactivate and stop the playthrough before removing
        BGMLogAndSwallowExceptionsMsg("BGMPlayThroughManager::CleanupIdleInstance",
                                      "Deactivating playthrough",
                                      [&]() {
            if (it->second)
            {
                it->second->Deactivate();
            }
        });

        // Remove the instance (unique_ptr will deallocate)
        mPlayThroughInstances.erase(it);

        // Remove activity tracking
        mLastActivityTime.erase(deviceID);
    }
}
