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

#define MCX_LIB_DIRS @[@"libavcodec",@"libavdevice",@"libavfilter",@"libavformat",\
@"libavresample",@"libavutil",@"libpostproc",@"libswresample",@"libswscale"]
#define MCX_INSTALL_STEP_NAMES @[@"Backup and clean FFmpeg source and destination",@"Download FFmpeg Source", @"Unzip FFmpeg Source", @"Configure FFmpeg", @"Make FFmpeg ( without actually building )", @"Move source files to Xcode project folder", @"Add FFmpeg Sources to Xcode project", @"Finish moving & patching source files", @"Build FFmpeg Library"]
#define MCX_LAST_STEP MCXInstallStepBuildLibrary

#define MCX_NO_COMPIL_C_FILES @[ @"libswresample/noise_shaping_data.c", @"libavcodec/scpr3.c", @"libavfilter/signature_lookup.c", @"libavfilter/blend_modes.c", @"libavcodec/eac3dec.c", @"libavcodec/ac3dec.c", @"libavcodec/aacps.c", @"libavcodec/aacpsdata.c"]
#define MCX_TO_DELETE_LIST_FILENAME @".ffmpeg_installer_trash_files.txt"
#define MCX_FFMPEGLIB_FILENAME @"libFFmpeg.a"
BOOL unzip(const char *fname, char **outfile );
BOOL untar(const char * filename);

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
-(BOOL)_SGFCopy:(NSString *)src toDest:( NSString *)dest forcing:( BOOL) force;
//-(BOOL)_SGFCopySource:(NSString *)src toDest:( NSString *)dest forcing:(BOOL)force;
-(BOOL)_SGFCopyExtSource:(NSString *)src toDest:(NSString *)dest forcing:(BOOL) force withExt:( NSString *)ext exts2copy:( NSArray<NSString *> *) exts;
-(BOOL)_SGFRemove:(NSString *)src;
-(BOOL)_SGFReplaceInfile:(NSString *)fpath search:(NSString *)srch withText:( NSString *)txt;
-(NSString *) _SGFAppendTo:(NSString *)src suffix:( NSString *)appd;
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
//-(BOOL)_clean;
@end
@implementation MCXInstaller
@synthesize sourceFFmpegDir = _sourceFFmpegDir, destinationFFmpegDir =_destinationFFmpegDir, firstStep = _firstStep, lastStep = _lastStep, manualStep=_manualStep, noopMode=_noopMode, verboseMode=_verboseMode, quietMode = _quietMode, selfExecutablePath=_selfExecutablePath, clean_level=_clean_level;
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
        _clean_level = 0;
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
    if ( ( rez ) &&( _verboseMode )) printf("\n * Manual:\n\n%s\n\n", _manualStep.UTF8String);
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
            if ( _clean_level > 1 ) [self set_fileSystem2deleteItems:[[self _fileSystem2deleteItems] arrayByAddingObject:backupPath]];
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
        if ( [destFiles  count] > 2 )// some invisible files makes an empty directory look full....
        {
            backupPath = [[_destinationFFmpegDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:[prefx stringByAppendingString:[_destinationFFmpegDir lastPathComponent]]];
            rez = [fm moveItemAtPath:_destinationFFmpegDir toPath:backupPath error:&err];
            if ( ! rez )
            {
                fprintf(stderr, "*** Failed to move %s to %s\n%s\n", _destinationFFmpegDir.UTF8String, backupPath.UTF8String, [[err localizedDescription] UTF8String] );
                return NO;
            //} else printf("destination ffmpeg directory backup: %s\n", backupPath.UTF8String);
            } else {
                if ( ! _quietMode ) printf("\tFFmpeg directory backup: %s\n", backupPath.UTF8String);
                if ( _clean_level > 1 ) [self set_fileSystem2deleteItems:[[self _fileSystem2deleteItems] arrayByAddingObject:backupPath]];
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
        rez = [self _downloadFileAtURL:MCX_SOURCE_URL toDir:[_sourceFFmpegDir stringByDeletingLastPathComponent] timeout:1000.0] ;
        if ( rez && ( _clean_level == 2 ))[self set_fileSystem2deleteItems:[[self _fileSystem2deleteItems] arrayByAddingObject:zipath]];
        puts("");//leaves the line with download progress empty
    }
    if ( rez && ( _clean_level > 2 ))[self set_fileSystem2deleteItems:[[self _fileSystem2deleteItems] arrayByAddingObject:zipath]];
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
    if ( _clean_level > 1 )[self set_fileSystem2deleteItems:[[self _fileSystem2deleteItems] arrayByAddingObject:_sourceFFmpegDir]];
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
    for (NSString * dirname in MCX_LIB_DIRS)
    {
        //SGFCopyExt(SGFAppend(_sourceFFmpegDir, dirname), SGFAppend(_destinationFFmpegDir, dirname), YES, @".h", nil);
        [self _SGFCopyExtSource:[self _SGFAppendTo:_sourceFFmpegDir suffix:dirname] toDest:[self _SGFAppendTo:_destinationFFmpegDir suffix:dirname] forcing:YES withExt:@".h" exts2copy:nil];
        //SGFCopyExt(SGFAppend(_sourceFFmpegDir, o), SGFAppend(_destinationFFmpegDir, o), YES, @".o", @[@".c", @".m"]);
        [self _SGFCopyExtSource:[self _SGFAppendTo:_sourceFFmpegDir suffix:dirname] toDest:[self _SGFAppendTo:_destinationFFmpegDir suffix:dirname] forcing:YES withExt:@".o" exts2copy:@[@".c", @".m"]];
    }
    //SGFCopy(SGFAppend(_sourceFFmpegDir, @"config.h"), SGFAppend(_destinationFFmpegDir, @"config.h"), YES);
    [self _SGFCopy:[self _SGFAppendTo:_sourceFFmpegDir suffix:@"config.h"] toDest:[self _SGFAppendTo:_destinationFFmpegDir suffix:@"config.h"] forcing:YES];
    // SGFRemove(SGFAppend(_destinationFFmpegDir, @"libavutil/time.h"));
    [self _SGFRemove:[self _SGFAppendTo:_destinationFFmpegDir suffix:@"libavutil/time.h"]];
    return rez;
}
-(void)_clearFFmpegGroupIncludingFiles:(BOOL)delt
{
    NSString *projpath = [[_destinationFFmpegDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"FFmpeg.xcodeproj"];
    XCProject* project = [[XCProject alloc] initWithFilePath:projpath];
    XCGroup* group = [project groupWithPathFromRoot:@"FFmpeg"];
    if ( group ) [group removeFromParentDeletingChildren:delt];
    if ( delt ) [project save];
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
        } else if ( [ext isEqualToString:@"h"]) {
            [subgroup addFileReference:fileURL.path withType:SourceCodeHeader];
            continue;
        } else if ( [ext isEqualToString:@"m"]) {
             typ=SourceCodeObjC;
        } else {
            fprintf(stderr, "File extension %s unknown for %s\n", ext.UTF8String, relativePath.UTF8String);
            continue;
        }
        [subgroup addFileReference:fileURL.path withType:typ];
        XCSourceFile* sourceFile = [project fileWithName:[fileURL path]];
        if ( sourceFile )
        {
            if ( typ != SourceCodeHeader )
            {
                [libFFmpegTarget addMember:sourceFile];
                if ( ! _quietMode ) printf("Imported %s\n", relativePath.UTF8String );
            }
            
        } else fprintf(stderr, "sourceFile %s not created\n", [relativePath lastPathComponent].UTF8String );
        //printf("%s\n", relativePath.UTF8String );
        c++;
    }
    if ( ! _quietMode) printf("%u files added to Xcode project\n", c);
    [project save];
    if ( rez && ( _clean_level > 1 ))[self set_fileSystem2deleteItems:[[self _fileSystem2deleteItems] arrayByAddingObject:@"***FFmpeg"]];
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
    for (NSString * dirname in MCX_LIB_DIRS)
    {
        NSString *destdirpath =[self _SGFAppendTo:_destinationFFmpegDir suffix:dirname];
        // copy all the headers files
        [self _SGFCopyExtSource:[self _SGFAppendTo:_sourceFFmpegDir suffix:dirname] toDest:destdirpath forcing:YES withExt:@".h" exts2copy:nil];
        // copy all files whose name contains template or list ( SGFCopyExt hack )
        [self _SGFCopyExtSource:[self _SGFAppendTo:_sourceFFmpegDir suffix:dirname] toDest:destdirpath forcing:YES withExt:@"t" exts2copy:@[@".c"]];
        if ( _clean_level > 1 ) [self set_fileSystem2deleteItems:[[self _fileSystem2deleteItems] arrayByAddingObject:destdirpath]];
        /* the files copied bellow are not all necessary and will be imported in xcode if previous step is ran again
        SGFCopyExt(SGFAppend(_sourceFFmpegDir, o), SGFAppend(_destinationFFmpegDir, o), YES, @".c", nil);
        SGFCopyExt(SGFAppend(_sourceFFmpegDir, o), SGFAppend(_destinationFFmpegDir, o), YES, @".inc", nil);
         */
    }
    [self _SGFCopyExtSource:[self _SGFAppendTo:_sourceFFmpegDir suffix:@"compat"] toDest:[self _SGFAppendTo:_destinationFFmpegDir suffix:@"compat"] forcing:YES withExt:@".h" exts2copy:nil];
    
    // copying included C files that doesn't need to be compiled separetly
    // to do: get this list automatically scanning each to be compiled .c file for extra included .c files
    // to make sure the installer would work with ffmpeg future updates without updating MCX_NO_COMPIL_C_FILES list
    for ( NSString *relpath in MCX_NO_COMPIL_C_FILES )
    {
        [self _SGFCopy:[_sourceFFmpegDir stringByAppendingPathComponent:relpath] toDest:[_destinationFFmpegDir stringByAppendingPathComponent:relpath] forcing:YES];
    }


    // Edit
    [self _SGFReplaceInfile:[_destinationFFmpegDir stringByAppendingPathComponent:@"libavcodec/videotoolbox.c"]
                     search: @"#include \"mpegvideo.h\""
                   withText:@"// Edit by Single\n#define Picture FFPicture\n#include \"mpegvideo.h\"\n#undef Picture"];
    
    [self _SGFReplaceInfile:[_destinationFFmpegDir stringByAppendingPathComponent:@"libavfilter/vsrc_mandelbrot.c"]
                     search:@"typedef struct Point {"
                   withText:@"// Edit by Single\ntypedef struct {"];
    //This file would also reference 2 different definition of struct Point
    [self _SGFReplaceInfile:[_destinationFFmpegDir stringByAppendingPathComponent:@"libavfilter/signature.h"]
                     search:@"typedef struct Point {"
                   withText:@"// Edit by MCX\ntypedef struct {"];
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
    if ( _clean_level > 1 )
    {
        NSString *interbuildpath = [[_destinationFFmpegDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Build"];
        [self set_fileSystem2deleteItems:[[self _fileSystem2deleteItems] arrayByAddingObject:interbuildpath]];
    }
    if ( [[self _fileSystem2deleteItems] count] )
    {
        NSString *lpath =[[_sourceFFmpegDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:MCX_TO_DELETE_LIST_FILENAME];
        NSError *err = nil;
        NSData *wdata = [[[self _fileSystem2deleteItems] componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        if ( ! [wdata writeToFile:lpath atomically:YES] ) fprintf(stderr, "can't write files to delete list\n%s\n", err.description.UTF8String );
    }
    return YES;
}
-(int)finish
{
    int rez = 0;
    NSError *err = nil;
    NSString *libpath = [_sourceFFmpegDir stringByDeletingLastPathComponent];
    NSString *flistpath = [libpath stringByAppendingPathComponent:MCX_TO_DELETE_LIST_FILENAME];
    libpath = [libpath stringByAppendingPathComponent:[@"Debug" stringByAppendingPathComponent:MCX_FFMPEGLIB_FILENAME]];
    NSFileManager *fm =[NSFileManager defaultManager];
    if ( [fm fileExistsAtPath:libpath] )
    {
        NSDictionary<NSFileAttributeKey, id> *attrdict = [fm attributesOfItemAtPath:libpath error:&err];
        if ( attrdict )
        {
            NSDate *modif = [attrdict fileModificationDate];
            if ( ( ! modif ) ||( -[modif timeIntervalSinceNow] > 15.0 ))
            {
                fprintf(stderr, "Library seems to old: %s\n", ((modif)?[modif descriptionWithLocale:nil].UTF8String:"[no date available]"));
                return 1;
            }
        } else {
            fprintf(stderr, "Impossible to get library's attributes\n%s\n", err.description.UTF8String);
            return 1;
        }
    } else {
        fprintf(stderr, "Library file doesn't exist at path: %s\n", libpath.UTF8String );
        return 1;
    }
    if ( ! _quietMode ) printf("Library seems properly built\nCleaning...\n");
    NSString *scpt = [@"tell application \"Finder\"\n\t open POSIX file \"" stringByAppendingFormat:@"%@\"\n\tactivate\nend tell\n", [_selfExecutablePath stringByDeletingLastPathComponent]];
    if ( _verboseMode ) printf("running\n%s\n", scpt.UTF8String );
    NSDictionary<NSString *,id> *errdict = nil;
    NSAppleScript *ascpt = [[NSAppleScript alloc] initWithSource:scpt];
    [ascpt executeAndReturnError:&errdict];
    if ( errdict )
    {
        fprintf(stderr, "Can't execute script:\n%s\n%s\n", scpt.UTF8String, errdict.description.UTF8String);
        rez = 1;
    }
    if ( [fm fileExistsAtPath:flistpath] )
    {
        //NSInputStream *instrm = [NSInputStream inputStreamWithFileAtPath:flistpath];
        NSArray<NSString *> *fpaths = [[NSString stringWithContentsOfFile:flistpath encoding:NSUTF8StringEncoding error:&err] componentsSeparatedByString:@"\n"];
        //(NSArray<NSString *> *)[NSPropertyListSerialization propertyListWithStream:instrm options:NSPropertyListImmutable format:nil error:&err];
        if ( ! fpaths )
        {
            fprintf(stderr, "Impossible to read file to delete list file %s\n%s\n", flistpath.lastPathComponent.UTF8String, err.description.UTF8String);
            return 1;
        }
        fpaths = [fpaths arrayByAddingObject:flistpath];
        BOOL isdir=NO;
        for ( NSString *ipath in fpaths )
        {
            if ( [[ipath substringToIndex:3] isEqualToString:@"***"] )
            {
                [self _clearFFmpegGroupIncludingFiles:YES];
                continue;
            }
            if ( [fm fileExistsAtPath:ipath isDirectory:&isdir])
            {
                //(! [fm removeItemAtPath:ipath error:&err] )
                if (! [fm trashItemAtURL:[NSURL fileURLWithPath:ipath] resultingItemURL:nil error:&err] )
                {
                    fprintf(stderr, "Can't move %s to trash\n%s\n", ipath.UTF8String, err.description.UTF8String );
                } else if ( ! _quietMode ) printf("%s %s moved to trash\n", ((isdir)?"Directory":"File"), ipath.lastPathComponent.UTF8String );
            }
        }
    } else if ( ! _quietMode ) printf("No cleaning requested\n");
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

-(BOOL) _SGFCopyExtSource:(NSString *)src toDest:(NSString *)dest forcing:(BOOL) force withExt:( NSString *)ext exts2copy:( NSArray<NSString *> *) exts
{
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *o in [fm enumeratorAtPath:src])
    {
        NSString *p = [src stringByAppendingPathComponent:o];
        if (([o hasSuffix:ext]) || (( [ext isEqualToString:@"t"]) && (( [o containsString:@"template"]) || ( [o containsString:@"list"]))))
        {
            NSString *r = p;
            if (exts.count)
            {
                r = nil;
                for (NSString *m in exts)
                {
                    r = ( [ext isEqualToString:@"t"])?p:[p stringByReplacingOccurrencesOfString:ext withString:m];
                    if ([fm fileExistsAtPath:r])
                    {
                        break;
                    }
                }
            }
            if (!r)
            {
                fprintf(stderr, "Not Found : %s\n", o.UTF8String);
                return NO;
            }
            NSString *t = [r stringByReplacingOccurrencesOfString:src withString:dest];
            //if (  _verboseMode ) printf("Copied %s\n", t.lastPathComponent.UTF8String );
            [self _SGFCopy:r toDest:t forcing:YES];
        }
    }
    return YES;
}
-(BOOL)_SGFCopy:(NSString *)src toDest:( NSString *)dest forcing:( BOOL) force
{
    BOOL dir = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:src isDirectory:&dir] || ([fm fileExistsAtPath:dest] && !force))
    {
        return NO;
    }
    [fm removeItemAtPath:dest error:nil];
    NSMutableArray *c = [dest.pathComponents mutableCopy];
    [(NSMutableArray *)c removeLastObject];
    for (int i = 0; i < c.count; i++)
    {
        NSArray *c_t = [c subarrayWithRange:NSMakeRange(0, c.count - i)];
        NSString *p = [NSString pathWithComponents:c_t];
        if (![fm fileExistsAtPath:p])
        {
            [fm createDirectoryAtPath:p withIntermediateDirectories:yearMask ? YES : NO attributes:nil error:nil];
        }
    }
    [fm copyItemAtPath:src toPath:dest error:nil];
    if (_verboseMode) printf("\tcopy %s -> %s\n", src.UTF8String, dest.UTF8String);
    return YES;
}

-(BOOL)_SGFRemove:(NSString *)src
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:src])
    {
        if ( _verboseMode ) printf("Removed %s\n", src.lastPathComponent.UTF8String );
        return [fm removeItemAtPath:src error:nil];
    }
    return NO;
}
-(BOOL)_SGFReplaceInfile:(NSString *)fpath search:(NSString *)srch withText:( NSString *)txt
{
    BOOL dir = NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:fpath isDirectory:&dir] || dir)
    {
        return NO;
    }
    NSString *cntnt = [NSString stringWithContentsOfFile:fpath encoding:NSUTF8StringEncoding error:nil];
    if (cntnt.length == 0)
    {
        return NO;
    }
    cntnt = [cntnt stringByReplacingOccurrencesOfString:srch withString:txt];
    BOOL rez =[cntnt writeToFile:fpath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    if ( rez && _verboseMode ) printf("File %s patched\n", fpath.lastPathComponent.UTF8String);
    return rez;
}
-(NSString *)_SGFAppendTo:(NSString *)src suffix:( NSString *)appd
{
    return [src stringByAppendingPathComponent:appd];
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
