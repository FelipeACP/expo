// Copyright 2015-present 650 Industries. All rights reserved.

#import "EXDevLauncher.h"
#import "EXDevLauncherController.h"

#import <EXDevLauncher-Swift.h>

@implementation EXDevLauncher

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup
{
  return YES;
}

- (NSDictionary *)constantsToExport
{
  NSString *manifestString = [EXDevLauncherController.sharedInstance appManifest].rawData;
  NSString *manifestURLString = [EXDevLauncherController.sharedInstance appManifestURL].absoluteString;
  return @{
    @"manifestString": manifestString ?: [NSNull null],
    @"manifestURL": manifestURLString ?: [NSNull null]
  };
}

@end
