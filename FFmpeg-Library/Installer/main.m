//
//  main.m
//
//
//  Created by Pierre Boué on 2022/02/22.
//  Copyright © 2022 Macaplix. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MCXInstaller.h"

void showHelp( void );

int main(int argc, const char * argv[])
{
    @autoreleasepool
    {
        MCXInstaller *installer = [[MCXInstaller alloc] init];
        [installer setSelfExecutablePath:[NSString stringWithUTF8String:argv[0]]];
        MCXInstallStep fstep=MCXInstallStepBackupAndClean, lstep=MCX_LAST_STEP;
        // parsing arguments ....
        for (unsigned char argi=1; argi < argc; argi++)
        {
            const char *rgestr = argv[argi];
            if (( strcmp(rgestr, "-h") == 0 ) || ( strcmp(rgestr, "-help") == 0  ))
            {
                showHelp();
                [installer setNoopMode:YES];
            } else if (strcmp(rgestr, "-v") == 0 ) {
                [installer setVerboseMode:YES];
                [installer setQuietMode:NO];
            } else if (strcmp(rgestr, "-c") == 0 ) {
                lstep = MCXInstallStepClean;
            } else if (strcmp(rgestr, "-q") == 0 ) {
                [installer setQuietMode:YES];
                [installer setVerboseMode:NO];
            } else {
                char *pt = strchr(rgestr, '-');
                if ( pt )
                {
                    char deb[8]="";
                    strncpy(deb, rgestr, pt -rgestr);
                    fstep = strlen(deb)?strtoul(deb, NULL, 0):0;
                    lstep = strlen(pt+1)?strtoul(pt + 1, NULL, 0):MCX_LAST_STEP;
                    if ( lstep > 0 )lstep--;
                } else {
                    fstep = strtoul(rgestr, NULL, 0);
                }
                if ( fstep > 0 )fstep--;
                if ( lstep > MCXInstallStepBuildLibrary ) lstep = MCXInstallStepBuildLibrary;
                if ( lstep > MCX_LAST_STEP ) lstep = MCX_LAST_STEP;

            }
        }
        [installer setFirstStep:fstep];
        [installer setLastStep:lstep];
        [installer nextStep];
    }
    return 0;
}
void showHelp( void )
{
    printf("%% installer [-h][-help][-v][-q][-c][n1-n2]\n\n"
           "\t-h -help prints this help message\n\n"
           "\tn1-n2 starts with step number n1 and ends with step number n2\n"
           "\t\tboth steps n1 & n2 are included\n"
           "\t\tto perform only step n, use n-n\n"
           "\t\tdefault is to perform all the steps from 1st to last\n"
           "\t\tusing n without \"-\" will start at step n and continue to the last one\n\n"
           "\t-v verbose - prints more detailed messages and help\n\n"
           "\t-q quiet - only prints errors ( on stderr )\n\n"
           "\t-c clean intermediary files once Library is build\n\n"
           "Here are the steps preceded by there numbers:\n"
           "\n"
           );
}
