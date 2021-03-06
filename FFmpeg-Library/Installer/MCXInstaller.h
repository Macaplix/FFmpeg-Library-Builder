//
//  MCXInstaller.h
//  FFmpeg
//
//  Created by Pierre Boué on 25/02/2022.
//  Copyright © 2022 Macaplix. All rights reserved.
//
#import <Foundation/Foundation.h>
#ifndef MCXInstaller_h
#define MCXInstaller_h
typedef enum:unsigned char
{
    MCXInstallStepBackupAndClean,
    MCXInstallStepDownloadSource,
    MCXInstallStepUnzipSource,
    MCXInstallStepPatchConfigureScript,
    MCXInstallStepConfigure,
    MCXInstallStepMake,
    MCXInstallStepMoveSrc2dest1,
    MCXInstallStepImportInXcode,
    MCXInstallStepMoveSrc2dest2,
    MCXInstallStepBuildLibrary,
    MCXInstallStepClean
}MCXInstallStep;
#define MCX_LAST_STEP MCXInstallStepBuildLibrary
@interface MCXInstaller:NSObject
@property(readwrite, retain)NSString *selfExecutablePath;
@property(readwrite, retain)NSString *sourceFFmpegDir;
@property(readwrite, retain)NSString *destinationFFmpegDir;
@property(readwrite, retain)NSString *resultDestinationPath;
@property(readwrite, retain)NSString *manualStep;
@property(readwrite, assign)MCXInstallStep firstStep;
@property(readwrite, assign)MCXInstallStep lastStep;
@property(readwrite, assign)BOOL noopMode;
@property(readwrite, assign)BOOL verboseMode;
@property(readwrite, assign)BOOL quietMode;
@property(readwrite, assign)unsigned char clean_level;
@property(readonly)MCXInstallStep currentStep;
@property(readonly)NSString *currentStepName;
-(BOOL)nextStep;
-(int)finish;
-(void)performTest;
@end
#endif /* MCXInstaller_h */
