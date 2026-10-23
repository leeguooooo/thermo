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

// macOS can track an app by bundle while tracking its menu item by executable.
// Return only the location kind, never executable paths or unrelated entries.
static NSDictionary<NSString *, NSArray<NSString *> *> *TrackedMenuItemKinds(BOOL *readable) {
    // The suite API can return no data for a caller outside Apple's group.
    // Read the existing on-disk snapshot without requesting group entitlement.
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"];
    NSData *file = [NSData dataWithContentsOfFile:path];
    if (!file) return @{};
    id root = [NSPropertyListSerialization propertyListWithData:file options:NSPropertyListImmutable format:NULL error:NULL];
    if (![root isKindOfClass:NSDictionary.class]) return @{};
    id data = root[@"trackedApplications"];
    if (![data isKindOfClass:NSData.class]) return @{};
    id decoded = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    if (![decoded isKindOfClass:NSArray.class] || [decoded count] % 2 != 0) return @{};
    *readable = YES;
    NSArray *entries = decoded;
    NSMutableDictionary *result = [NSMutableDictionary new];
    for (NSUInteger index = 0; index < entries.count; index += 2) {
        id key = entries[index], value = entries[index + 1];
        if (![key isKindOfClass:NSDictionary.class] || ![value isKindOfClass:NSDictionary.class]) continue;
        id bundleCase = key[@"bundle"];
        if (![bundleCase isKindOfClass:NSDictionary.class]) continue;
        id bundle = bundleCase[@"_0"], locations = value[@"menuItemLocations"];
        if (![bundle isKindOfClass:NSString.class] || ![locations isKindOfClass:NSArray.class]) continue;
        NSMutableSet<NSString *> *kinds = [NSMutableSet new];
        for (id location in locations) {
            if (![location isKindOfClass:NSDictionary.class]) continue;
            for (id kind in [location allKeys]) {
                if ([kind isKindOfClass:NSString.class]) [kinds addObject:kind];
            }
        }
        result[bundle] = [kinds.allObjects sortedArrayUsingSelector:@selector(compare:)];
    }
    return result;
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
        BOOL trackedPreferencesReadable = NO;
        NSDictionary *trackedKinds = TrackedMenuItemKinds(&trackedPreferencesReadable);
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
                @"trackedMenuItemLocationKinds": trackedKinds[bundle] ?: NSNull.null,
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
            @"trackedPreferencesReadable": @(trackedPreferencesReadable),
            @"trackedPreferencesSource": @"On-disk property list snapshot; may lag the live preferences service.",
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
