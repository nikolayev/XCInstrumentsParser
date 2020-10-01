//
//  main.m
//  XCInstrumentsParser
//
//  Created by Ruslan Nikolayev on 2/13/20.
//  Copyright © 2020 Ruslan Nikolayev. All rights reserved.
//

@import Foundation;
#import "Instruments.h"
#import "AllocationsTemplateParser.h"
#import "ActivityMonitorTemplateParser.h"

#import <objc/runtime.h>

// Workaround to fix search paths for Instruments plugins and packages.
static NSBundle *(*NSBundle_mainBundle_original)(id self, SEL _cmd);
static NSBundle *NSBundle_mainBundle_replaced(id self, SEL _cmd) {
    return [NSBundle bundleWithPath:@"/Applications/Xcode.app/Contents/Applications/Instruments.app"];
}
static void __attribute__((constructor)) hook() {
    Method NSBundle_mainBundle = class_getClassMethod(NSBundle.class, @selector(mainBundle));
    NSBundle_mainBundle_original = (void *)method_getImplementation(NSBundle_mainBundle);
    method_setImplementation(NSBundle_mainBundle, (IMP)NSBundle_mainBundle_replaced);
}

static long long timeIntervalFromRun(XRRun *run) {
    double startDate = [run startTime];
    return (long long)(ceil(startDate));
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // Required. Each instrument is a plugin and we have to load them before we can process their data.
        DVTInitializeSharedFrameworks();
        [DVTDeveloperPaths initializeApplicationDirectoryName:@"Instruments"];
        [XRInternalizedSettingsStore configureWithAdditionalURLs:nil];
        [[XRCapabilityRegistry applicationCapabilities]registerCapability:@"com.apple.dt.instruments.track_pinning" versions:NSMakeRange(1, 1)];
        PFTLoadPlugins();
        // Instruments has its own subclass of NSDocumentController without overriding sharedDocumentController method.
        // We have to call this eagerly to make sure the correct document controller is initialized.
        [PFTDocumentController sharedDocumentController];
        // Open a trace document.
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        NSString *tracePath;
        if (arguments.count < 2) {
            tracePath= @"/Users/rnikolayev/Downloads/allocations.trace";
        } else{
            tracePath = arguments[1];
        }
    
        NSError *error = nil;
        PFTTraceDocument *document = [[PFTTraceDocument alloc]initWithContentsOfURL:[NSURL fileURLWithPath:tracePath] ofType:@"com.apple.instruments.trace" error:&error];
        if (error) {
            NSLog(@"Error: %@\n", error);
            return 1;
        }
        
        // Each trace document consists of data from several different instruments.
        XRTrace *trace = document.trace;
        for (XRInstrument *instrument in trace.allInstrumentsList.allInstruments) {
            NSLog(@"\nInstrument: %@ (%@)\n", instrument.type.name, instrument.type.uuid);
            // We only need the last run
            XRRun *run = [instrument.allRuns lastObject];
            if (run == nil) {
                NSLog(@"No data.\n");
                continue;
            }

            // Different instruments can have different data structure.
            // Here are some straightforward example code demonstrating how to process the data from several commonly used instruments.
            NSString *instrumentID = instrument.type.uuid;
            NSString *allocationsId = @"com.apple.xray.instrument-type.oa";
            NSString *activityMonitorId = @"com.apple.xray.instrument-type.activity";
            
            // Time Profiler: com.apple.xray.instrument-type.coresampler2
            // Core Animations: com.apple.dt.coreanimation-fps
            // Network: com.apple.dt.network-connections
            // Leaks: com.apple.xray.instrument-type.homeleaks
            
            instrument.currentRun = run;
            // Common routine to obtain contexts for the instrument.
            NSMutableArray<XRContext *> *contexts = [NSMutableArray array];
            if (![instrument isKindOfClass:XRLegacyInstrument.class]) {
                XRAnalysisCoreStandardController *standardController = [[XRAnalysisCoreStandardController alloc]initWithInstrument:instrument document:document];
                instrument.viewController = standardController;
                [standardController instrumentDidChangeSwitches];
                [standardController instrumentChangedTableRequirements];
                XRAnalysisCoreDetailViewController *detailController = GetVariable(standardController, _detailController);
                [detailController restoreViewState];

                // XRContextFromDetailNode isn't available anymore. This is commented out for now until better solution is found.
                /*
                XRAnalysisCoreDetailNode *detailNode = GetVariable(detailController, _firstNode);
                while (detailNode) {
                    [contexts addObject:XRContextFromDetailNode(detailController, detailNode)];
                    detailNode = detailNode.nextSibling;
                }
                */
            }
            if ([instrumentID isEqualToString:allocationsId]) {
                NSArray<NSString *> *results = [AllocationsTemplateParser parseAllocationsWithInstrument:instrument];
                XRRun *run = [[instrument allRuns] lastObject];
                printf("\nRAM allocations results since %lld:\n", timeIntervalFromRun(run));
                for (NSString *row in results) {
                    printf("%s",[row cStringUsingEncoding:NSUTF8StringEncoding]);
                    printf("\n");
                }
                printf("RAM allocations end.\n");
            } else if ([instrumentID isEqualToString:activityMonitorId]) {
                // CPU instrument analizer won't work until we fix XRContextFromDetailNode
                NSArray<NSString *> *results = [ActivityMonitorTemplateParser parseCPUWithInstrument:instrument contexts: contexts];
                XRRun *run = [[instrument allRuns] lastObject];
                printf("\nCPU results since %lld:\n", timeIntervalFromRun(run));
                for (NSString *row in results) {
                    printf("%s",[row cStringUsingEncoding:NSUTF8StringEncoding]);
                    printf("\n");
                }
                printf("CPU end.\n");
            }
                
            if (![instrument isKindOfClass:XRLegacyInstrument.class]) {
                [instrument.viewController instrumentWillBecomeInvalid];
                instrument.viewController = nil;
            }
        }
        // Close the document safely.
        [document close];
        PFTClosePlugins();
    }
    return 0;
}
