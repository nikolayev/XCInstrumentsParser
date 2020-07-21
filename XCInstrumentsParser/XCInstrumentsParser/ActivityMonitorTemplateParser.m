//
//  ActivityMonitorTemplateParser.m
//  XCInstrumentsParser
//
//  Created by Ruslan Nikolayev on 2/17/20.
//  Copyright © 2020 Ruslan Nikolayev. All rights reserved.
//

#import "ActivityMonitorTemplateParser.h"
#import "Instruments.h"
#import <objc/runtime.h>

@implementation ActivityMonitorTemplateParser

+(NSArray<NSString *> *) parseCPUWithInstrument: (XRInstrument *) instrument contexts: (NSArray<XRContext *> *) contexts {
    // Find right context
    XRContext *cpuContext = nil;
    for (XRContext *context in contexts) {
        if ([[context label] isEqualToString:@"System CPU Summary"]) {
            cpuContext = context;
            break;
        }
    }
    if (cpuContext == nil) {
        printf("\nUnable to locate CPU Summary\n");
        return @[];
    }
    // Display the context so we can have access to internal UI state
    [cpuContext display];
    
    // Activity Monitor has a very exotic internal UI state so we'll have to use XRAnalysisCorePivotArrayAccessor
    // and iterate over each row with it
    XRAnalysisCoreTableViewController *controller = GetVariable(cpuContext.container, _tabularViewController);
    XRAnalysisCorePivotArray *array = controller._currentResponse.content.rows;
    XREngineeringTypeFormatter *formatter = CastVariable(array.source, _filter, XRAnalysisCoreTableQuery * const).fullTextSearchSpec.formatter;
    
    NSMutableArray<NSString *> *results = @[].mutableCopy;
    [array access:^(XRAnalysisCorePivotArrayAccessor *accessor) {
        NSMutableSet<NSString *> *existingTimestamps = [NSMutableSet new];
        // Skip first entry because it always shows maximum load
        [accessor readRowsStartingAt:1 dimension:0 block:^(XRAnalysisCoreReadCursor *cursor) {
            while (XRAnalysisCoreReadCursorNext(cursor)) {
                XRAnalysisCoreValue *object = nil;
                NSString *result = @"";
                // Desired data: Time, Total Load %
                for (SInt64 column = 0; column < 4; column++) {
                    if (column == 0) {
                        // Time
                        XRAnalysisCoreReadCursorGetValue(cursor, column, &object);
                        // 00:00.000.000
                        NSString *timeNanoSeconds = [formatter stringForObjectValue:object];
                        NSString *seconds = [self formatSeconds:timeNanoSeconds];
                        // Sometimes stats print out more than once in scope of 1 second
                        // Filtering out those...
                        if ([existingTimestamps containsObject:seconds]) {
                            break;
                        }
                        [existingTimestamps addObject:seconds];
                        result = seconds;
                    }
                    if (column == 3) {
                        // CPU
                        XRAnalysisCoreReadCursorGetValue(cursor, column, &object);
                        NSString *cpu = [formatter stringForObjectValue:object];
                        result = [result stringByAppendingFormat:@" %@", cpu];
                    }
                    continue;
                }
                if (result.length > 0) {
                    [results addObject:result];
                }
            }
        }];
    }];
    return results;
}

+(NSString *) formatSeconds: (NSString *) nanoSecondsString {
    // 00:00.000.000 -> 00:00
    NSString *secondsFormat = [[nanoSecondsString componentsSeparatedByString:@"."] firstObject];
    // 00:00 -> 00
    NSString *onlyMinutes = [[secondsFormat componentsSeparatedByString:@":"] firstObject];
    NSString *onlySeconds = [[secondsFormat componentsSeparatedByString:@":"] lastObject];
    NSInteger minutes = [onlyMinutes integerValue];
    NSInteger seconds = [onlySeconds integerValue];
    NSInteger totalSeconds = 60 * minutes + seconds;
    return [NSString stringWithFormat:@"%lds", (long)totalSeconds];
}

@end
