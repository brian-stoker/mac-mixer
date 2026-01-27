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
//  BGMUserNotifications.mm
//  BGMApp
//
//  Copyright © 2026 Kyle Neideck
//

// Self Include
#import "BGMUserNotifications.h"

// PublicUtility Includes
#import "CADebugMacros.h"

// System Includes
#import <UserNotifications/UserNotifications.h>


#pragma clang assume_nonnull begin

static NSString* const kNotificationCategoryID = @"com.bearisdriving.BGM.PerAppRouting";
static NSString* const kNotificationIdentifierPrefix = @"com.bearisdriving.BGM.";


@implementation BGMUserNotifications {
    // Track whether we've requested notification permissions
    BOOL hasRequestedPermissions;
}

#pragma mark Initialization

+ (instancetype) sharedInstance
{
    static BGMUserNotifications* sSharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sSharedInstance = [[BGMUserNotifications alloc] init];
    });
    return sSharedInstance;
}

- (instancetype) init
{
    if ((self = [super init]))
    {
        hasRequestedPermissions = NO;

        // Request notification permissions on macOS 10.14+
        if (@available(macOS 10.14, *))
        {
            [self requestNotificationPermissions];
        }

        DebugMsg("BGMUserNotifications::init: Initialized user notifications");
    }

    return self;
}

#pragma mark Permissions

- (void) requestNotificationPermissions API_AVAILABLE(macos(10.14))
{
    if (hasRequestedPermissions)
    {
        return;
    }

    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];

    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError* __nullable error) {
        if (error)
        {
            LogWarning("BGMUserNotifications::requestNotificationPermissions: "
                      "Failed to request notification permissions: %s",
                      [[error localizedDescription] UTF8String]);
        }
        else if (!granted)
        {
            DebugMsg("BGMUserNotifications::requestNotificationPermissions: "
                    "User denied notification permissions");
        }
        else
        {
            DebugMsg("BGMUserNotifications::requestNotificationPermissions: "
                    "Notification permissions granted");
        }
    }];

    hasRequestedPermissions = YES;
}

#pragma mark Public Notification Methods

- (void) notifyDeviceDisconnected:(NSString*)deviceName
                     affectedApps:(NSArray<NSString*>*)appNames
                   fallbackDevice:(NSString*)fallbackDeviceName
{
    NSString* title = @"Output Device Disconnected";
    NSString* body;

    if (appNames.count == 0)
    {
        body = [NSString stringWithFormat:@"%@ was disconnected.", deviceName];
    }
    else if (appNames.count == 1)
    {
        body = [NSString stringWithFormat:
                @"%@ was disconnected. %@ has been reassigned to %@.",
                deviceName, appNames[0], fallbackDeviceName];
    }
    else
    {
        body = [NSString stringWithFormat:
                @"%@ was disconnected. %lu apps have been reassigned to %@.",
                deviceName, (unsigned long)appNames.count, fallbackDeviceName];
    }

    DebugMsg("BGMUserNotifications::notifyDeviceDisconnected: Device=%s, Apps=%lu, Fallback=%s",
             [deviceName UTF8String],
             (unsigned long)appNames.count,
             [fallbackDeviceName UTF8String]);

    [self postNotificationWithIdentifier:@"DeviceDisconnected"
                                   title:title
                                    body:body];
}

- (void) notifyRoutingError:(NSString*)errorMessage
                     forApp:(NSString*)appName
{
    NSString* title = @"Audio Routing Error";
    NSString* body = [NSString stringWithFormat:
                      @"Failed to route audio for %@: %@",
                      appName, errorMessage];

    LogWarning("BGMUserNotifications::notifyRoutingError: App=%s, Error=%s",
               [appName UTF8String],
               [errorMessage UTF8String]);

    [self postNotificationWithIdentifier:@"RoutingError"
                                   title:title
                                    body:body];
}

- (void) notifyFormatIncompatible:(NSString*)deviceName
                           reason:(NSString*)reason
{
    NSString* title = @"Incompatible Audio Format";
    NSString* body = [NSString stringWithFormat:
                      @"%@ cannot be used: %@",
                      deviceName, reason];

    LogWarning("BGMUserNotifications::notifyFormatIncompatible: Device=%s, Reason=%s",
               [deviceName UTF8String],
               [reason UTF8String]);

    [self postNotificationWithIdentifier:@"FormatIncompatible"
                                   title:title
                                    body:body];
}

- (void) notifyMaxConcurrentDevicesReached:(NSString*)deviceName
                                maxDevices:(NSUInteger)maxDevices
{
    NSString* title = @"Maximum Output Devices Reached";
    NSString* body = [NSString stringWithFormat:
                      @"Cannot add %@. Background Music supports up to %lu concurrent output devices.",
                      deviceName, (unsigned long)maxDevices];

    LogWarning("BGMUserNotifications::notifyMaxConcurrentDevicesReached: Device=%s, Max=%lu",
               [deviceName UTF8String],
               (unsigned long)maxDevices);

    [self postNotificationWithIdentifier:@"MaxDevicesReached"
                                   title:title
                                    body:body];
}

#pragma mark Internal Notification Posting

- (void) postNotificationWithIdentifier:(NSString*)identifier
                                  title:(NSString*)title
                                   body:(NSString*)body
{
    NSString* fullIdentifier = [kNotificationIdentifierPrefix stringByAppendingString:identifier];

    // Use modern API on macOS 10.14+
    if (@available(macOS 10.14, *))
    {
        [self postModernNotification:fullIdentifier title:title body:body];
    }
    else
    {
        [self postLegacyNotification:fullIdentifier title:title body:body];
    }
}

- (void) postModernNotification:(NSString*)identifier
                          title:(NSString*)title
                           body:(NSString*)body API_AVAILABLE(macos(10.14))
{
    UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
    content.title = title;
    content.body = body;
    content.sound = [UNNotificationSound defaultSound];
    content.categoryIdentifier = kNotificationCategoryID;

    // Create a time-based trigger (deliver immediately)
    UNTimeIntervalNotificationTrigger* trigger =
        [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1 repeats:NO];

    UNNotificationRequest* request =
        [UNNotificationRequest requestWithIdentifier:identifier
                                             content:content
                                             trigger:trigger];

    UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
    [center addNotificationRequest:request
             withCompletionHandler:^(NSError* __nullable error) {
        if (error)
        {
            LogWarning("BGMUserNotifications::postModernNotification: "
                      "Failed to post notification '%s': %s",
                      [identifier UTF8String],
                      [[error localizedDescription] UTF8String]);
        }
        else
        {
            DebugMsg("BGMUserNotifications::postModernNotification: "
                    "Posted notification '%s'",
                    [identifier UTF8String]);
        }
    }];
}

- (void) postLegacyNotification:(NSString*)identifier
                          title:(NSString*)title
                           body:(NSString*)body
{
    // Use deprecated NSUserNotificationCenter for macOS < 10.14
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSUserNotification* notification = [[NSUserNotification alloc] init];
    notification.title = title;
    notification.informativeText = body;
    notification.soundName = NSUserNotificationDefaultSoundName;
    notification.identifier = identifier;

    NSUserNotificationCenter* center = [NSUserNotificationCenter defaultUserNotificationCenter];
    [center deliverNotification:notification];

    DebugMsg("BGMUserNotifications::postLegacyNotification: Posted notification '%s'",
             [identifier UTF8String]);
#pragma clang diagnostic pop
}

@end

#pragma clang assume_nonnull end
