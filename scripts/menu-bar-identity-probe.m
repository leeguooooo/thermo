// Read-only diagnostic for the identities used by macOS 27 menu bar hosts.
// Build and invocation: docs/menu-bar-management-study.md.
// Does not create status items, activate assertions or request permissions.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>

typedef CFTypeRef (*MakeASN)(CFAllocatorRef, UInt32, UInt32);
typedef CFTypeRef (*ReadItem)(int, CFTypeRef, CFStringRef);

static id ObjectValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *StringValue(id object, NSString *name) {
    id value = ObjectValue(object, name);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: menu-bar-identity-probe BUNDLE_ID [BUNDLE_ID ...]\n");
            return 2;
        }
        NSMutableSet<NSString *> *requested = [NSMutableSet new];
        for (int i = 1; i < argc; i++) {
            NSString *bundle = [NSString stringWithUTF8String:argv[i]];
            if (!bundle.length || ![bundle containsString:@"."] || [bundle hasPrefix:@"-"] ||
                [bundle rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
                fprintf(stderr, "Expected a bundle identifier, got invalid argument %d\n", i);
                return 2;
            }
            [requested addObject:bundle];
        }
        void *library = dlopen("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/LaunchServices", RTLD_LAZY | RTLD_LOCAL);
        MakeASN makeASN = library ? (MakeASN)dlsym(library, "_LSASNCreate") : NULL;
        ReadItem readItem = library ? (ReadItem)dlsym(library, "_LSCopyApplicationInformationItem") : NULL;
        Class processClass = NSClassFromString(@"BSProcessHandle");
        SEL byPID = NSSelectorFromString(@"processHandleForPID:");
        SEL byAudit = NSSelectorFromString(@"processHandleForAuditToken:");
        NSMethodSignature *pidSignature = [processClass methodSignatureForSelector:byPID];
        NSMethodSignature *auditSignature = [processClass methodSignatureForSelector:byAudit];
        BOOL pidAvailable = pidSignature.numberOfArguments == 3 && pidSignature.methodReturnType[0] == '@' &&
            [pidSignature getArgumentTypeAtIndex:2][0] == 'i';
        BOOL auditAvailable = auditSignature.numberOfArguments == 3 && auditSignature.methodReturnType[0] == '@' &&
            [auditSignature getArgumentTypeAtIndex:2][0] == '@';
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray new];
        for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
            NSString *bundle = app.bundleIdentifier;
            if (!bundle || ![requested containsObject:bundle] || app.terminated) continue;
            pid_t pid = app.processIdentifier;
            ProcessSerialNumber psn = {0};
            OSStatus status = GetProcessForPID(pid, &psn);
            CFTypeRef asn = status == noErr && makeASN ? makeASN(NULL, psn.highLongOfPSN, psn.lowLongOfPSN) : NULL;
            CFTypeRef value = asn && readItem ? readItem(-2, asn, kCFBundleIdentifierKey) : NULL;
            NSString *lsBundle = value && CFGetTypeID(value) == CFStringGetTypeID() ? (__bridge NSString *)value : nil;
            id handle = pidAvailable ? ((id (*)(id, SEL, pid_t))objc_msgSend)(processClass, byPID, pid) : nil;
            id token = ObjectValue(handle, @"auditToken");
            id auditHandle = token && auditAvailable ? ((id (*)(id, SEL, id))objc_msgSend)(processClass, byAudit, token) : nil;
            [rows addObject:@{
                @"pid": @(pid), @"runningBundle": bundle,
                @"launchServicesBundle": lsBundle ?: NSNull.null,
                @"processSerialNumberStatus": @(status),
                @"nativeHostBundle": StringValue(handle, @"bundleIdentifier") ?: NSNull.null,
                @"auditBundle": StringValue(auditHandle, @"bundleIdentifier") ?: NSNull.null,
                @"auditSigningIdentifier": StringValue(token, @"signingIdentifier") ?: NSNull.null,
                // A process may exit while the reads are in flight. Such a row
                // cannot establish an identity mismatch for a live application.
                @"terminatedDuringRead": @(app.terminated)
            }];
            if (value) CFRelease(value);
            if (asn) CFRelease(asn);
        }
        NSDictionary *report = @{
            @"schemaVersion": @1,
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"requestedBundles": [requested.allObjects sortedArrayUsingSelector:@selector(compare:)],
            @"launchServicesQueryAvailable": @((BOOL)(makeASN && readItem)),
            @"nativeHostQueryAvailable": @((BOOL)(pidAvailable && auditAvailable)),
            @"rows": rows,
            @"scope": @"Fresh process records only; not a readback of MenuBarAgent's cached NSStatusItemHost objects or of rendered visibility."
        };
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        if (!data) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
}
