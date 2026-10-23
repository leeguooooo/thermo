#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Private macOS 27 API isolated behind runtime capability checks. Loading this
/// class never activates assessment mode or requests Accessibility permission.
@interface TMMenuBarSession : NSObject
+ (BOOL)isAvailable;
+ (nullable instancetype)sessionWithAllowedBundles:(NSArray<NSString *> *)bundles
                                             error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(make(allowedBundles:));
- (void)activateWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (BOOL)invalidateWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(invalidate());
@end
NS_ASSUME_NONNULL_END
