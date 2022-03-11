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
            if ( strcmp(rgestr, "--finish") == 0 )
            {
                return [installer finish];
            }
            if ( strlen(rgestr) < 1 ) continue;
            if ( rgestr[0] == '-' )
            {
                for (unsigned char sarg=1; sarg < strlen(rgestr); sarg++)
                {
                    if (( sarg == 1 ) && ( rgestr[sarg] == 'c' ) && ( strlen(rgestr) > 3 ) && ( rgestr[2] == '=') ) //arg -c=n
                    {
                        char *endptr="";
                        unsigned char cleanlevel = strtoul(rgestr +3, &endptr, 0);
                        if ( strlen(endptr) ) fprintf(stderr, "ignored %s end of argument%s\n", endptr, rgestr );
                        [installer setClean_level:cleanlevel];
                        break;
                    }
                    switch (rgestr[sarg])
                    {
                        case 'h':
                            showHelp();
                            [installer setNoopMode:YES];
                            break;
                        case 'v':
                            [installer setVerboseMode:YES];
                            [installer setQuietMode:NO];
                            break;
                        case 'q':
                            [installer setVerboseMode:NO];
                            [installer setQuietMode:YES];
                            break;
                        case 'c':
                            //lstep = MCXInstallStepClean;
                            [installer setClean_level:2];
                             break;
                        default:
                            fprintf(stderr, "unknow argument -%c\n", rgestr[sarg]);
                            break;
                    }
                }
            } else {
                
                char *pt = strchr(rgestr, '-');
                if ( pt )
                {
                    char deb[8]="";
                    strncpy(deb, rgestr, pt -rgestr);
                    fstep = strlen(deb)?strtoul(deb, NULL, 0):0;
                    lstep = strlen(pt+1)?strtoul(pt + 1, NULL, 0):9;///MCX_LAST_STEP;
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
    printf("# installer [-hvqc] [-c=n] [n1-n2] [n]\n\n"
           "\t-h help. prints this help message\n\n"
           "\tn1-n2 starts with step number n1 and ends with step number n2\n"
           "\t\tboth steps n1 & n2 are included\n"
           "\t\tto perform only step n, use n-n\n"
           "\t\tdefault is to perform all the steps from 1st to last\n"
           "\t\tusing n without \"-\" will start at step n and continue to the last one\n\n"
           "\t-v verbose - prints more detailed messages and help\n\n"
           "\t-q quiet - only prints errors ( on stderr )\n\n"
           "\t-c clean intermediary files once Library is build\n\n"
           "\t-c=n apply clean level n to intermediary files once Library is build\n\n"
           "\t\tdefault clean level with -c is 2 without 0\n"
           "Here are the steps preceded by there numbers:\n"
           "\n"
           );
}
