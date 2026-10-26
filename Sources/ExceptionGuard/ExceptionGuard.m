// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
#import "ExceptionGuard.h"
BOOL USBGuard(void (^operation)(void), NSError **error) {
    @try { operation(); return YES; }
    @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"org.sapd.longcable.Exception" code:1
            userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: exception.name}];
        return NO;
    }
}
