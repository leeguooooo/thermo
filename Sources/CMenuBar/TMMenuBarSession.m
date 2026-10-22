#import "TMMenuBarSession.h"
#import <dlfcn.h>

// These declarations describe the observed system message signatures only.
// No framework symbols are linked, and older macOS never instantiates them.
@protocol TMSystemConfiguration <NSObject>
- (instancetype)initWithAllowedSystemItems:(NSArray<NSNumber *> *)items
                 allowedBundleIdentifiers:(NSArray<NSString *> *)bundles;
@end
@protocol TMSystemAssertion <NSObject>
- (void)activateWithConfiguration:(id)configuration completionHandler:(void (^)(NSError *))completion;
- (void)invalidate;
@end

@interface TMMenuBarSession ()
@property(nonatomic, strong) id<TMSystemConfiguration> configuration;
@property(nonatomic, strong) id<TMSystemAssertion> assertion;
@end

@implementation TMMenuBarSession
+ (NSError *)failure:(NSString *)message {
    return [NSError errorWithDomain:@"dev.thermo.menubar" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}
+ (BOOL)isAvailable {
    if (@available(macOS 27.0, *)) {
        static void *library;
        static dispatch_once_t token;
        dispatch_once(&token, ^{
            library = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LOCAL | RTLD_LAZY);
        });
        if (!library) return NO;
        Class configuration = NSClassFromString(@"MBAssessmentModeConfiguration");
        Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
        return [configuration instancesRespondToSelector:@selector(initWithAllowedSystemItems:allowedBundleIdentifiers:)] &&
            [assertion instancesRespondToSelector:@selector(activateWithConfiguration:completionHandler:)] &&
            [assertion instancesRespondToSelector:@selector(invalidate)];
    }
    return NO;
}
+ (instancetype)sessionWithAllowedBundles:(NSArray<NSString *> *)bundles error:(NSError **)error {
    if (![self isAvailable]) {
        if (error) *error = [self failure:@"Menu bar visibility is unavailable on this macOS version."];
        return nil;
    }
    @try {
        TMMenuBarSession *session = [TMMenuBarSession new];
        Class configClass = NSClassFromString(@"MBAssessmentModeConfiguration");
        // Retain every known system-item category. Application assignment does
        // not imply permission to hide Clock, input source or Control Center.
        NSMutableArray<NSNumber *> *systemItems = [NSMutableArray array];
        for (NSInteger index = 0; index <= 8; index++) [systemItems addObject:@(index)];
        session.configuration = [(id<TMSystemConfiguration>)[configClass alloc]
            initWithAllowedSystemItems:systemItems allowedBundleIdentifiers:bundles];
        session.assertion = [[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
        if (!session.configuration || !session.assertion) {
            if (error) *error = [self failure:@"macOS could not create a menu bar visibility session."];
            return nil;
        }
        return session;
    } @catch (NSException *exception) {
        if (error) *error = [self failure:exception.reason ?: @"Menu bar session creation failed."];
        return nil;
    }
}
- (void)activateWithCompletion:(void (^)(NSError *))completion {
    @try { [self.assertion activateWithConfiguration:self.configuration completionHandler:completion]; }
    @catch (NSException *exception) {
        completion([TMMenuBarSession failure:exception.reason ?: @"Menu bar activation failed."]);
    }
}
- (BOOL)invalidateWithError:(NSError **)error {
    @try { [self.assertion invalidate]; return YES; }
    @catch (NSException *exception) {
        if (error) *error = [TMMenuBarSession failure:exception.reason ?: @"Menu bar restoration failed."];
        return NO;
    }
}
- (void)dealloc { @try { [_assertion invalidate]; } @catch (NSException *exception) {} }
@end
