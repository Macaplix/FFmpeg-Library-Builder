//
//  MCXInstaller.m
//  FFmpeg
//
//  Created by Pierre Boué on 25/02/2022.
//  Copyright © 2022 Macaplix. All rights reserved.
//

#import "MCXInstaller.h"
#include "libtar_listhash.h"
#include "libtar.h"
#include "bzlib.h"
#include <XcodeEditor/XcodeEditor.h>


#define MCX_CONFIGURE_ARGUMENTS @[@"--enable-static", @"--disable-shared", @"--enable-gpl", @"--enable-version3", @"--enable-pthreads", @"--enable-postproc", @"--enable-filters", @"--disable-asm", @"--disable-programs", @"--enable-runtime-cpudetect", @"--enable-bzlib", @"--enable-zlib", @"--enable-opengl", @"--enable-libvpx", @"--enable-libspeex", @"--enable-libopenjpeg", @"--enable-libvorbis", @"--enable-openssl"]
// @"--enable-libfdk-aac", @"--enable-libx264", @"--enable-nonfree",  @"--nm=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/llvm-nm"

#define MCX_SOURCE_ZIP_FILENAME @"ffmpeg-snapshot.tar.bz2"
#define MCX_SOURCE_URL @"https://ffmpeg.org/releases/ffmpeg-snapshot.tar.bz2"
//@"fftools",
#define MCX_LIB_DIRS @[@"libavcodec",@"libavdevice",@"libavfilter",@"libavformat",\
@"libavresample",@"libavutil",@"libpostproc",@"libswresample",@"libswscale"]
#define MCX_INSTALL_STEP_NAMES @[@"Backup and clean FFmpeg source and destination",@"Download FFmpeg Source", @"Unzip FFmpeg Source", @"Configure FFmpeg", @"Make FFmpeg ( without actually building )", @"Move source files to Xcode project folder", @"Add FFmpeg Sources to Xcode project", @"Finish moving & patching source files", @"Build FFmpeg Library"]
#define MCX_LAST_STEP MCXInstallStepBuildLibrary

//FFmpeg-in-Xcode-master/FFmpeg/libswresample/dither.c:24:10: 'noise_shaping_data.c' file not found
//FFmpeg-in-Xcode-master/Build/build.pch:36:10: 'scpr3.c' file not found
//FFmpeg-in-Xcode-master/Build/build.pch:37:10: 'signature_lookup.c' file not found
//FFmpeg-in-Xcode-master/FFmpeg/libavutil/mathematics.h:37:10: 'blend_modes.c' file not found
//FFmpeg-in-Xcode-master/FFmpeg/libavutil/internal.h:31:10: 'eac3dec.c' file not found
//FFmpeg-in-Xcode-master/Build/build.pch:24:10: 'aacps.c' file not found
//FFmpeg-in-Xcode-master/FFmpeg/libavutil/internal.h:27:10: 'aacpsdata.c' file not found
#define MCX_NO_COMPIL_C_FILES @[ @"libswresample/noise_shaping_data.c", @"libavcodec/scpr3.c", @"libavfilter/signature_lookup.c", @"libavfilter/blend_modes.c", @"libavcodec/eac3dec.c", @"libavcodec/ac3dec.c", @"libavcodec/aacps.c", @"libavcodec/aacpsdata.c"]

BOOL unzip(const char *fname, char **outfile );
BOOL untar(const char * filename);
BOOL SGFCopy(NSString *s, NSString *d, BOOL force);
BOOL SGFCopyExt(NSString *s, NSString *d, BOOL force, NSString *e, NSArray<NSString *> *es);
BOOL SGFRemove(NSString *s);
BOOL SGFReplace(NSString *s, NSString *f, NSString *t);
NSString * SGFAppend(NSString *s, NSString *a);

@interface MCXInstaller()<NSURLSessionDownloadDelegate>
{
    MCXInstallStep _currentStep;
}
@property(readwrite, retain)NSArray<NSString *> *_fileSystem2deleteItems;
@property(readwrite, retain)NSString *_fileDownloadFinalPath;
@property(readwrite, retain)dispatch_semaphore_t _waitHandle;
-(BOOL)_downloadFileAtURL:(NSString *)fileURL
                                toDir:(NSString *)toDir
                      timeout:(unsigned)timeout;
-(BOOL)_performCurrentStep;
-(NSString *)_prefixBackup;
-(void)_clearFFmpegGroupIncludingFiles:(BOOL)delt;
/* STEPS */
-(BOOL)_backupAndClean;
-(BOOL)_downloadSource;
-(BOOL)_unzipSource;
-(BOOL)_configureFFmpeg;
-(BOOL)_makeFFmpeg;
-(BOOL)_moveSrc2dest1;
-(BOOL)_importInXcode;
-(BOOL)_moveSrc2dest2;
-(BOOL)_buildLibrary;
-(BOOL)_clean;
@end
@implementation MCXInstaller
@synthesize sourceFFmpegDir = _sourceFFmpegDir, destinationFFmpegDir =_destinationFFmpegDir, firstStep = _firstStep, lastStep = _lastStep, manualStep=_manualStep, noopMode=_noopMode, verbroseMode=_verbroseMode, quietMode = _quietMode, selfExecutablePath=_selfExecutablePath;
-(instancetype)init
{
    self = [super init];
    if ( self )
    {
        // PROJECT_SRC_DIR is a macro added by Xcode build settings with clang flag: OTHER_CFLAGS -DPROJECT_SRC_DIR=\"$(SRCROOT)\"
        _sourceFFmpegDir = [NSString stringWithUTF8String:PROJECT_SRC_DIR];
        _destinationFFmpegDir = [_sourceFFmpegDir stringByAppendingPathComponent:@"FFmpeg"];
        _sourceFFmpegDir = [[_sourceFFmpegDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"ffmpeg"];
        _currentStep = MCXInstallStepBackupAndClean;
        _manualStep =@"no manual step provided";
        [self set_fileSystem2deleteItems:@[]];
        _noopMode = NO;
    }
    return self;
}
-(BOOL)nextStep
{
    if ( _currentStep < _firstStep ) _currentStep = _firstStep;
    BOOL rez = [self _performCurrentStep];
    if ( rez )
    {
        _currentStep++;
        if ( _currentStep > _lastStep )
        {
            _currentStep = _lastStep;
            if (( ! _noopMode ) && ( ! _quietMode )) printf("All the selected steps have been done successfully\n"); else if (! _quietMode ) puts("");
            return NO;
        }
        return [self nextStep];
    } else {
        fprintf(stderr, "The step %s failed\nTry to manually run %s\nAborting...", [self currentStepName].UTF8String, "" );
    }
    return rez;
}
-(BOOL)_performCurrentStep
{
    BOOL rez = YES;
    if ( ! _quietMode ) printf("%u - %s\n", _currentStep +1 , [[self currentStepName] UTF8String]);
    switch (_currentStep) {
        case MCXInstallStepBackupAndClean:
            rez = [self _backupAndClean];
            break;
        case MCXInstallStepDownloadSource:
            rez = [self _downloadSource];
            break;
        case MCXInstallStepUnzipSource:
            [self _unzipSource];
            break;
        case MCXInstallStepConfigure:
            [self _configureFFmpeg];
            break;
        case MCXInstallStepMake:
            [self _makeFFmpeg];
            break;
        case MCXInstallStepMoveSrc2dest1:
            [self _moveSrc2dest1];
            break;
        case MCXInstallStepImportInXcode:
            [self _importInXcode];
            break;
        case MCXInstallStepMoveSrc2dest2:
            [self _moveSrc2dest2];
            break;
        case MCXInstallStepBuildLibrary:
            [self _buildLibrary];
            break;
        case MCXInstallStepClean:
            //[self ];
            break;
        default:
            fprintf(stderr, "Step # %u unknown\n", _currentStep);
            return NO;
            break;
    }
    if ( ! rez ) fprintf(stderr, "*** step %u %s\nfailed ***\n", _currentStep + 1, [self currentStepName].UTF8String);
    if ( ( rez ) &&( _verbroseMode )) printf("\n * Manual:\n\n%s\n\n", _manualStep.UTF8String);
    return rez;
}
#pragma mark STEPS
-(BOOL)_backupAndClean
{
    BOOL rez = YES;
    _manualStep = [NSString stringWithFormat:
                   @"\t1 - Remove or rename folder %@\n"
                   @"\t2 - Delete content of folder %@\n"
                   ,_sourceFFmpegDir, _destinationFFmpegDir];
    if ( _noopMode ) return YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *prefx = [self _prefixBackup];
    NSString *backupPath = [[_sourceFFmpegDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:[prefx stringByAppendingString:[_sourceFFmpegDir lastPathComponent]]];
    NSError *err = nil;
    BOOL isdir=NO;
    if ([fm fileExistsAtPath:_sourceFFmpegDir isDirectory:&isdir] && isdir )
    {
        rez = [fm moveItemAtPath:_sourceFFmpegDir toPath:backupPath error:&err];
        if ( ! rez )
        {
            fprintf(stderr, "*** Failed to move %s to %s\n%s\n", _sourceFFmpegDir.UTF8String, backupPath.UTF8String, [[err localizedDescription] UTF8String] );
            return NO;
        } else {
            if ( ! _quietMode ) printf("\tsource ffmpeg directory backup: %s\n", backupPath.UTF8String);
            [self set_fileSystem2deleteItems:[[self _fileSystem2deleteItems] arrayByAddingObject:backupPath]];
        }

    } else if ( ! _quietMode ) printf("\tSource ffmpeg directory doesn't exist. Nothing done\n");
    isdir = NO;
    BOOL needsDir = YES;
    if ([fm fileExistsAtPath:_destinationFFmpegDir isDirectory:&isdir] && isdir )
    {
        NSArray<NSString *> *destFiles = [fm contentsOfDirectoryAtPath:_destinationFFmpegDir error:&err];
        if ( ! destFiles )
        {
            fprintf(stderr, "*** Unable to read content of %s\n", _destinationFFmpegDir.UTF8String);
            return NO;
        }
        if ( [destFiles  count] )
        {
            backupPath = [[_destinationFFmpegDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:[prefx stringByAppendingString:[_destinationFFmpegDir lastPathComponent]]];
            rez = [fm moveItemAtPath:_destinationFFmpegDir toPath:backupPath error:&err];
            if ( ! rez )
            {
                fprintf(stderr, "*** Failed to move %s to %s\n%s\n", _destinationFFmpegDir.UTF8String, backupPath.UTF8String, [[err localizedDescription] UTF8String] );
                return NO;
            //} else printf("destination ffmpeg directory backup: %s\n", backupPath.UTF8String);
            } else {
                if ( ! _quietMode ) printf("\tsource ffmpeg directory backup: %s\n", backupPath.UTF8String);
                [self set_fileSystem2deleteItems:[[self _fileSystem2deleteItems] arrayByAddingObject:backupPath]];
            }

        } else {
            needsDir = NO;
            if ( ! _quietMode ) printf("\tDirectroy %s exists but is empty. Nothing done\n", _destinationFFmpegDir.UTF8String);
        }
    }
    if ( needsDir )
    {
        rez = [fm createDirectoryAtPath:_destinationFFmpegDir withIntermediateDirectories:NO attributes:nil error:&err];
        if ( ! rez )
        {
            fprintf(stderr, "*** Failed to create directory at  %s\n%s\n", _destinationFFmpegDir.UTF8String, [[err localizedDescription] UTF8String] );
            return NO;
        }
    }
    return rez;
}
-(BOOL)_downloadSource
{
    BOOL rez = YES;
    _manualStep = [NSString stringWithFormat:
                   @"\t1 - Download file at %@\n"
                   @"\t2 - Put file %@ in folder %@",
                   MCX_SOURCE_URL, MCX_SOURCE_ZIP_FILENAME,[_sourceFFmpegDir stringByDeletingLastPathComponent]];
    if ( _noopMode ) return YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *zipath = [[_sourceFFmpegDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:MCX_SOURCE_ZIP_FILENAME];
    if ( [fm fileExistsAtPath:zipath] )
    {
        if ( ! _quietMode ) printf("\tFile %s is already present. Nothing done\n", MCX_SOURCE_ZIP_FILENAME.UTF8String);
    } else {
        // git clone https://git.ffmpeg.org/ffmpeg.git ffmpeg
        // https://ffmpeg.org/releases/ffmpeg-snapshot.tar.bz2
        rez = [self _downloadFileAtURL:MCX_SOURCE_URL toDir:[_sourceFFmpegDir stringByDeletingLastPathComponent] timeout:1000.0] ;
    }
    return rez;
}
-(BOOL)_unzipSource
{
    BOOL rez = YES;
    _manualStep = [NSString stringWithFormat:
                 @"\tDouble click on the file %@ to unzip and untar", MCX_SOURCE_ZIP_FILENAME];
    if ( _noopMode ) return YES;
    NSError *err = nil;
    NSString *destdir =[_sourceFFmpegDir stringByDeletingLastPathComponent];
    NSString *srcfile =[destdir stringByAppendingPathComponent:MCX_SOURCE_ZIP_FILENAME];
    char *outpath = calloc( [destdir length] + [MCX_SOURCE_ZIP_FILENAME length] + 2, sizeof(char));
    rez = unzip([[destdir stringByAppendingPathComponent:MCX_SOURCE_ZIP_FILENAME] UTF8String], &outpath);
    if ( rez ) printf("\tfile %s unzipped\n", MCX_SOURCE_ZIP_FILENAME.UTF8String );
    if ( rez && strlen(outpath) ) rez = untar(outpath); else fprintf(stderr, "unzip failed...\n");
    if ( rez )
    {
        srcfile =[NSString stringWithUTF8String:outpath] ;
        if ( ! _quietMode ) printf("\tfile %s untared\n",  [srcfile lastPathComponent].UTF8String );
    }
    free(outpath);

    NSFileManager *fm =[NSFileManager defaultManager];
    [fm removeItemAtPath:srcfile error:&err];
    //[fm removeItemAtPath:[_sourceFFmpegDir stringByAppendingPathComponent:@"tests"] error:&err];
    return rez;
}
-(BOOL)_configureFFmpeg
{
    BOOL rez = YES;
    NSArray *args= [@[[@"--prefix=" stringByAppendingString:_destinationFFmpegDir]] arrayByAddingObjectsFromArray:MCX_CONFIGURE_ARGUMENTS];
    NSString *confCommand = [@"\t./configure " stringByAppendingString:[args componentsJoinedByString:@" "]];
    _manualStep = [NSString stringWithFormat:@"\tcd \"%@\"\n%@", _sourceFFmpegDir, confCommand];
    if ( _noopMode ) return YES;
    NSTask *task = [[NSTask alloc] init];
    [task setArguments:args];
    [task setCurrentDirectoryPath:_sourceFFmpegDir];
    [task setExecutableURL:[NSURL fileURLWithPath:[_sourceFFmpegDir stringByAppendingPathComponent:@"configure"]]];
    if ( ! _quietMode ) printf("%s\n", confCommand.UTF8String);
    [task setEnvironment:@{@"TERM":@"xterm-256color",@"PATH":[@"/opt/local/bin:" stringByAppendingFormat:@"%s", getenv("PATH")]}];
    [task launch];
    [task waitUntilExit];
    if ( [task terminationStatus] )
    {
        NSString *msg = [@"*** Error configuring " stringByAppendingFormat:@"%ld", [task terminationReason]];
        fprintf(stderr, "%s\n", msg.UTF8String);
        rez = NO;
    } else {
        if ( ! _quietMode ) printf("\tffmpeg configured\n");

    }
    return rez;
}
-(BOOL)_makeFFmpeg
{
    BOOL rez = YES;
    NSArray *args= @[@"-t"];
    NSTask *task = [[NSTask alloc] init];
    [task setArguments:args];
    [task setCurrentDirectoryPath:_sourceFFmpegDir];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *xpath =@"/usr/local/bin/make";
    while (! [fm isExecutableFileAtPath:xpath])
    {
        if ( [xpath length] < 16 ) break;
        xpath = @"/usr/bin/make";
    }
    _manualStep = [NSString stringWithFormat:@"\tcd \"%@\"\n\t%@ %@", _sourceFFmpegDir, xpath, [args componentsJoinedByString:@" "]];
    if ( _noopMode ) return YES;
    [task setExecutableURL:[NSURL fileURLWithPath:xpath]];
    if ( ! _quietMode ) printf("\trunning make....\n");
    [task launch];
    [task waitUntilExit];
    if ( [task terminationStatus] )
    {
        NSString *msg = [@"*** Error making " stringByAppendingFormat:@"%ld", [task terminationReason]];
        fprintf(stderr, "%s\n", msg.UTF8String);
        rez = NO;
    } else {
        if ( ! _quietMode ) printf("\tffmpeg maked\n");

    }
    return rez;

}
-(BOOL)_moveSrc2dest1
{
    BOOL rez = YES;
    _manualStep = @"\tRun script \"build1\" from original  Single FFmpeg-in-Xcode project\nhttps://github.com/libobjc/FFmpeg-in-Xcode\n"
    @"it consist on:\n"
    @"\t1 - removing the FFmpeg group physically deleting all the files it contains\n"
    @"\t2 - copying any header file in source ffmpeg directory to project folder\n"
    
    @"\t3 - copying any c source file for which make has generated a .o file\n"
    @"\t4 - copying extra header file config.h\n"
    @"\t5 - removing libavutil/time.h\n";

    if ( _noopMode ) return YES;
    // Clean
    [self _clearFFmpegGroupIncludingFiles:YES];
    /*
    for (NSString * o in MCX_LIB_DIRS)
    {
        SGFRemove(SGFAppend(_destinationFFmpegDir, o));
    }
    SGFRemove(SGFAppend(_destinationFFmpegDir, @"compat"));
    SGFRemove(SGFAppend(_destinationFFmpegDir, @"config.h"));
     */
    // Copy
    for (NSString * o in MCX_LIB_DIRS)
    {
        SGFCopyExt(SGFAppend(_sourceFFmpegDir, o), SGFAppend(_destinationFFmpegDir, o), YES, @".h", nil);
        SGFCopyExt(SGFAppend(_sourceFFmpegDir, o), SGFAppend(_destinationFFmpegDir, o), YES, @".o", @[@".c", @".m"]);
    }
    SGFCopy(SGFAppend(_sourceFFmpegDir, @"config.h"), SGFAppend(_destinationFFmpegDir, @"config.h"), YES);
    SGFRemove(SGFAppend(_destinationFFmpegDir, @"libavutil/time.h"));
    return rez;
}
-(void)_clearFFmpegGroupIncludingFiles:(BOOL)delt
{
    NSString *projpath = [[_destinationFFmpegDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"FFmpeg.xcodeproj"];
    XCProject* project = [[XCProject alloc] initWithFilePath:projpath];
    XCGroup* group = [project groupWithPathFromRoot:@"FFmpeg"];
    if ( group ) [group removeFromParentDeletingChildren:delt];
}
-(BOOL)_importInXcode;
{
    BOOL rez = YES;
    //NSLog(@"%s\n%s", BUILT_PRODUCTS_DIR, TARGET_TEMP_DIR );
    _manualStep =@"\tIn Xcode FFmpeg project choose add Files to FFmpeg in the File menu\n"
    @"\tSelect FFmpeg folder inside the project folder ( ";
    _manualStep = [_manualStep stringByAppendingFormat:@"%@ ) and click \"Add\"", _destinationFFmpegDir];
    if ( _noopMode ) return YES;
    NSString *projpath = [[NSString stringWithUTF8String:PROJECT_SRC_DIR] stringByAppendingPathComponent:@"FFmpeg.xcodeproj"];
    XCProject* project = [[XCProject alloc] initWithFilePath:projpath];
    XCGroup* group = [project groupWithPathFromRoot:@"FFmpeg"];
    if ( group ) [group removeFromParentDeletingChildren:NO];
    group = [[project mainGroup] addGroupWithPath:@"FFmpeg"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator<NSURL *> *enumer = [fm enumeratorAtURL:[NSURL fileURLWithPath:_destinationFFmpegDir] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL * _Nonnull url, NSError * _Nonnull error) {
        fprintf(stderr, "Error enumerator %s: %s\n", url.lastPathComponent.UTF8String, error.description.UTF8String);
        return YES;
    }];
    unsigned c =0;
    NSUInteger l = [_destinationFFmpegDir length] +1;
    XCGroup* subgroup = group;
    NSMutableDictionary<NSString *, XCGroup *> *foldersAndGroup = [NSMutableDictionary dictionaryWithDictionary:@{@"":group}];
    XCTarget* libFFmpegTarget = [project targetWithName:@"FFmpeg"];

    for (NSURL *fileURL in enumer )
    {
        XcodeSourceFileType typ = SourceCodeHeader;
        NSString *ext = [fileURL pathExtension];
        NSString *relativePath=[[fileURL path] substringFromIndex:l];
        NSString *parentFolder = [relativePath stringByDeletingLastPathComponent];
        subgroup = [foldersAndGroup objectForKey:parentFolder];
        if ( ! subgroup )
        {
            fprintf(stderr, "No group for folder %s\n", parentFolder.UTF8String);
            return NO;
        }
        if (( [ext isEqualToString:@""]) && ( [fileURL hasDirectoryPath] ) )
        {
            
            subgroup = [subgroup addGroupWithPath:[relativePath lastPathComponent]];
            [foldersAndGroup setObject:subgroup forKey:relativePath];
            continue;
        } else if ( [ext isEqualToString:@"c"]) {
            typ =SourceCodeObjC;
            //[subgroup addFileReference:fileURL.path withType:SourceCodeObjC];
        } else if ( [ext isEqualToString:@"h"]) {
            //typ=SourceCodeHeader;
            [subgroup addFileReference:fileURL.path withType:SourceCodeHeader];
            continue;
        } else if ( [ext isEqualToString:@"m"]) {
            //[subgroup addFileReference:fileURL.path withType:SourceCodeObjC];
            typ=SourceCodeObjC;
        } else {
            fprintf(stderr, "File extension %s unknown for %s\n", ext.UTF8String, relativePath.UTF8String);
            continue;
        }
        [subgroup addFileReference:fileURL.path withType:typ];
        XCSourceFile* sourceFile = [project fileWithName:[fileURL path]];
        if ( sourceFile )
        {
           if ( typ == SourceCodeHeader )
           {
               //[libFFmpegTarget addDependency:sourceFile.key];
           } else [libFFmpegTarget addMember:sourceFile];
            if ( ! _quietMode) printf("%s added to target\n", [relativePath lastPathComponent].UTF8String);
        } else fprintf(stderr, "sourceFile %s not created\n", [relativePath lastPathComponent].UTF8String );
        //printf("%s\n", relativePath.UTF8String );
        c++;
    }
    if ( ! _quietMode) printf("%u files added to Xcode project\n", c);
    [project save];
    return rez;
}
-(BOOL)_moveSrc2dest2;
{
    BOOL rez = YES;
    _manualStep = @"\tRun script \"build2\" from original  Single FFmpeg-in-Xcode project\nhttps://github.com/libobjc/FFmpeg-in-Xcode\n"
    @"it consist on:\n"
    @"\t1 - copying all header files from source ffmpeg directory to project\n"
    @"\t2 - copying any source .c file whose name contains template or list\n"
    @"\t\t( Those files are included in other c files but doesn't need to be compiled separately )\n"
    @"\t3 - copying source .c file listed in MCX_NO_COMPIL_C_FILES\n"
    @"\t\t( Those files are also included in other c files but there names doesn't show it )\n";
    if ( _noopMode ) return YES;
    // Copy
    for (NSString * o in MCX_LIB_DIRS)
    {
        // copy all the headers files
        SGFCopyExt(SGFAppend(_sourceFFmpegDir, o), SGFAppend(_destinationFFmpegDir, o), YES, @".h", nil);
        // copy all files whose name contains template or list ( SGFCopyExt hack )
        SGFCopyExt(SGFAppend(_sourceFFmpegDir, o), SGFAppend(_destinationFFmpegDir, o), YES, @"t", @[@".c"]);
        /* the files copied bellow are not all necessary and will be imported in xcode if previous step is ran again
        SGFCopyExt(SGFAppend(_sourceFFmpegDir, o), SGFAppend(_destinationFFmpegDir, o), YES, @".c", nil);
        SGFCopyExt(SGFAppend(_sourceFFmpegDir, o), SGFAppend(_destinationFFmpegDir, o), YES, @".inc", nil);
         */
    }
    SGFCopyExt(SGFAppend(_sourceFFmpegDir, @"compat"), SGFAppend(_destinationFFmpegDir, @"compat"), YES, @".h", nil);
    //SGFCopyExt(SGFAppend(_sourceFFmpegDir, @"compat"), SGFAppend(_destinationFFmpegDir, @"compat"), YES, @".c", nil);
    
    // copying included C files that doesn't need to be compiled separetly
    // to do: get this list automatically scanning each to be compiled .c file for extra included .c files
    // to make sure the installer would work with ffmpeg future updates without updating MCX_NO_COMPIL_C_FILES list
    for ( NSString *relpath in MCX_NO_COMPIL_C_FILES )
    {
        SGFCopy([_sourceFFmpegDir stringByAppendingPathComponent:relpath], [_destinationFFmpegDir stringByAppendingPathComponent:relpath], YES);
    }


    // Edit
    SGFReplace(SGFAppend(_destinationFFmpegDir, @"libavcodec/videotoolbox.c"),
               @"#include \"mpegvideo.h\"",
               @"// Edit by Single\n#define Picture FFPicture\n#include \"mpegvideo.h\"\n#undef Picture");
    SGFReplace(SGFAppend(_destinationFFmpegDir, @"libavfilter/vsrc_mandelbrot.c"),
               @"typedef struct Point {",
               @"// Edit by Single\ntypedef struct {");
    //This file would also reference 2 different definition of struct Point
    SGFReplace(SGFAppend(_destinationFFmpegDir, @"libavfilter/signature.h"),
               @"typedef struct Point {",
               @"// Edit by MCX\ntypedef struct {");
    return rez;
}
-(BOOL)_buildLibrary;
{
    _manualStep = [NSString stringWithFormat:@"\tSelect scheme FFmpeg in Xcode project and build Library (  B )"];
    if ( _noopMode ) return YES;
    NSDictionary<NSString *,id> *errdict = nil;
    NSURL *scpturl = [NSURL fileURLWithPath:[_destinationFFmpegDir stringByDeletingLastPathComponent]];
    scpturl = [scpturl URLByAppendingPathComponent:@"Installer/buildFFmpegLib.scpt"];
    NSAppleScript *ascpt = [[NSAppleScript alloc] initWithContentsOfURL:scpturl error:&errdict];
    if ( errdict )
    {
        fprintf(stderr, "Can't open script %s\n%s\n", scpturl.fileSystemRepresentation, errdict.description.UTF8String);
        return NO;
    }
    puts("Building FFmpeg Library...");
    puts("Please wait till Xcode has finish building");
    [ascpt executeAndReturnError:&errdict];
    if ( errdict )
    {
        fprintf(stderr, "Can't execute script %s\n%s\n", scpturl.fileSystemRepresentation, errdict.description.UTF8String);
        return NO;
    }
    NSString *scpt = [@"tell application \"Finder\"\n\t open POSIX file \"" stringByAppendingFormat:@"%@\"\n\tactivate\nend tell\n", [_selfExecutablePath stringByDeletingLastPathComponent]];
    if ( ! _quietMode ) printf("running\n%s\n", scpt.UTF8String );
    ascpt = [[NSAppleScript alloc] initWithSource:scpt];
    [ascpt executeAndReturnError:&errdict];
    if ( errdict )
    {
        fprintf(stderr, "Can't execute script:\n%s\n%s\n", scpt.UTF8String, errdict.description.UTF8String);
        return NO;
    }

    return YES;
}
-(BOOL)_clean
{
    BOOL rez =YES;
    return rez;
}
#pragma mark HELPERS
-(BOOL)_downloadFileAtURL:(NSString *)fileURL
                                    toDir:(NSString *)toDir
                                  timeout:(unsigned)timeout
{
    BOOL rez = YES;
    // completion handler semaphore to indicate download is done
    [self set_waitHandle:dispatch_semaphore_create(0)];
    // save file name for later
    NSString *downloadFileName = [fileURL lastPathComponent];
    [self set_fileDownloadFinalPath:[toDir stringByAppendingPathComponent:downloadFileName]];
    // Configure Cache behavior for default session
    NSURLSessionConfiguration
    *defaultConfigObject = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSString *cachePath = [NSTemporaryDirectory()
                           stringByAppendingPathComponent:@"/downloadFileCache"];
    NSURLCache *myCache = [[NSURLCache alloc] initWithMemoryCapacity: 16384
                                                        diskCapacity: 268435456 diskPath: cachePath];
    defaultConfigObject.URLCache = myCache;
    defaultConfigObject.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
    defaultConfigObject.timeoutIntervalForRequest = 100;
    defaultConfigObject.timeoutIntervalForResource = 100;
    
    dispatch_queue_global_t q =dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    NSURLSession *session =
    [NSURLSession sessionWithConfiguration: defaultConfigObject
                                  delegate: self
                             delegateQueue: nil];
    NSURLSessionDownloadTask *dltsk =  [session downloadTaskWithURL:[NSURL URLWithString:fileURL]];
    if ( ! dltsk )
    {
        fprintf(stderr, "*** Error trying to download %s\n", fileURL.UTF8String);
        return NO;
    }
    dispatch_async(q, ^(void){
         [dltsk resume];
    });
    dispatch_semaphore_wait([self _waitHandle], timeout ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout * 1000000000 ) :DISPATCH_TIME_FOREVER);
  //  NSError *error = nil;
    rez = [[NSFileManager defaultManager] fileExistsAtPath:[self _fileDownloadFinalPath]];
    return rez;
}

-(void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if ( ! _quietMode ) printf("\tReceived %.1f Mo ( %.0f %% ) / %.1f Mo\r",
           (float)totalBytesWritten /1000000.0, 100.0 * (float)totalBytesWritten / (float)totalBytesExpectedToWrite, (float)totalBytesExpectedToWrite / 1000000.0);
}

- (void)URLSession:(nonnull NSURLSession *)session downloadTask:(nonnull NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(nonnull NSURL *)location
{
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if ( [fileManager fileExistsAtPath:[location path]])
    {
        NSError *error = nil;
        BOOL fileCopied = [fileManager moveItemAtPath:[location path]
                                               toPath:[self _fileDownloadFinalPath]
                                                error:&error];
       if ((! fileCopied) || ( error )) fprintf(stderr,"Error copying: %s", error.description.UTF8String );
        //NSLog(fileCopied ? @"File Copied OK" : @"ERROR Copying file.");
        dispatch_semaphore_signal([self _waitHandle]);
    }
}
-(NSString *)_prefixBackup
{
    NSDate *dat = [NSDate date];
    static NSDateFormatter *df = nil;
    if ( ! df )
    {
        df =[[NSDateFormatter alloc] init];
        [df setLocale:[NSLocale currentLocale]];
        [df setDateFormat:@"yyyyMMddHHmmss"];
    }
    //NSLog(@"%@", [df stringFromDate:dat] );
    return [df stringFromDate:dat];
}
-(MCXInstallStep)currentStep
{
    return _currentStep;
}
-(NSString *)currentStepName
{
    return  MCX_INSTALL_STEP_NAMES[_currentStep];
}
@end
BOOL untar(const char * filename)
{

    TAR * tar_file = NULL;
    char *rootdir = calloc(strlen(filename) + 1, sizeof(char));// malloc(sizeof(filename) + 1);//
    char *ptr = strrchr(filename, '/');
    strncpy(rootdir, filename,  ptr -filename );
    if (tar_open(&tar_file, filename, NULL, O_RDONLY, 0, TAR_GNU) == -1)
    {
        fprintf(stderr, "tar_open(): %s\n", strerror(errno));
        return NO;
    }
    if ( ! tar_file ) fprintf(stderr, "no tar_file !!!\n");
    if( th_read(tar_file) == -1 ) fprintf(stderr, "th_read error! %s\n", strerror(errno));
    if (tar_extract_all(tar_file, rootdir) != 0)
    {
        fprintf(stderr, "tar_extract_all(): %s\n", strerror(errno));
        return NO;
    }

    if (tar_close(tar_file) != 0)
    {
        fprintf(stderr, "tar_close(): %s\n", strerror(errno));
        return NO;
    }
    free(rootdir);
   // printf("Successfully untared %s\n", filename);
    return YES;
}

BOOL unzip(const char *fname, char **rootfilename )
{
    FILE *f = fopen(fname, "rb");
    size_t leng =strrchr(fname, '.')- fname;
    strncpy(*rootfilename, fname, leng );
    FILE *df = fopen(*rootfilename, "wb");
    int bzError;
    BZFILE *bzf;
    char buf[4096];
    bzf = BZ2_bzReadOpen(&bzError, f, 0, 0, NULL, 0);
    if (bzError != BZ_OK)
    {
       fprintf(stderr, "Error: BZ2_bzReadOpen: %d\n", bzError);
       return NO;
    }
    while (bzError == BZ_OK)
    {
      int nread = BZ2_bzRead(&bzError, bzf, buf, sizeof buf);
      if (bzError == BZ_OK || bzError == BZ_STREAM_END)
      {
        size_t nwritten = fwrite(buf, 1, nread, df);
        if (nwritten != (size_t) nread)
        {
          fprintf(stderr, "Error: short write\n");
          return NO;
        }
      }
    }
    if (bzError != BZ_STREAM_END)
    {
      fprintf(stderr, "Error: bzip error after read: %d\n", bzError);
      return NO;
    }
    fclose(f);
    fclose(df);
    BZ2_bzReadClose(&bzError, bzf);
    // printf("Successfully uncompressed %s to %s\n", fname, dfname);
    return YES;
}
BOOL SGFCopy(NSString *s, NSString *d, BOOL force)
{
    BOOL dir = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:s isDirectory:&dir] || ([fm fileExistsAtPath:d] && !force)) {
        return NO;
    }
    [fm removeItemAtPath:d error:nil];
    NSMutableArray *c = [d.pathComponents mutableCopy];
    [(NSMutableArray *)c removeLastObject];
    for (int i = 0; i < c.count; i++) {
        NSArray *c_t = [c subarrayWithRange:NSMakeRange(0, c.count - i)];
        NSString *p = [NSString pathWithComponents:c_t];
        if (![fm fileExistsAtPath:p]) {
            [fm createDirectoryAtPath:p withIntermediateDirectories:yearMask ? YES : NO attributes:nil error:nil];
        }
    }
    [fm copyItemAtPath:s toPath:d error:nil];
    //printf("\tcopy %s -> %s\n", s.UTF8String, d.UTF8String);
    return YES;
}

BOOL SGFCopyExt(NSString *s, NSString *d, BOOL force, NSString *e, NSArray<NSString *> *es)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *o in [fm enumeratorAtPath:s])
    {
        NSString *p = [s stringByAppendingPathComponent:o];
        if (([o hasSuffix:e]) || (( [e isEqualToString:@"t"]) && (( [o containsString:@"template"]) || ( [o containsString:@"list"]))))
        {
            NSString *r = p;
            if (es.count)
            {
                r = nil;
                for (NSString *m in es)
                {
                    r = ( [e isEqualToString:@"t"])?p:[p stringByReplacingOccurrencesOfString:e withString:m];
                    //if ( r && [e isEqualToString:@"t"]) printf("%s\n", r.UTF8String );
                    if ([fm fileExistsAtPath:r])
                    {
                        break;
                    }
                }
            }
            if (!r)
            {
                //NSLog(@"Not Found : %@", o);
                fprintf(stderr, "Not Found : %s\n", o.UTF8String);
                return NO;
            }
            NSString *t = [r stringByReplacingOccurrencesOfString:s withString:d];
            SGFCopy(r, t, force);
        }
    }
    return YES;
}

BOOL SGFRemove(NSString *s)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:s]) {
        return [fm removeItemAtPath:s error:nil];
    }
    return NO;
}

BOOL SGFReplace(NSString *s, NSString *f, NSString *t)
{
    BOOL dir = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:s isDirectory:&dir] || dir) {
        return NO;
    }
    NSString *c = [NSString stringWithContentsOfFile:s encoding:NSUTF8StringEncoding error:nil];
    if (c.length == 0) {
        return NO;
    }
    c = [c stringByReplacingOccurrencesOfString:f withString:t];
    return [c writeToFile:s atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

NSString * SGFAppend(NSString *s, NSString *a)
{
    return [s stringByAppendingPathComponent:a];
}

