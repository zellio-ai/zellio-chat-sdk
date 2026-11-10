#import <RNZellioChatSpec/RNZellioChatSpec.h>

/// The Turbo Native Module. It only forwards to ZCRNBridge (Swift), which calls the ZeeChat iOS SDK.
@interface RNZellioChat : NativeZellioChatSpecBase <NativeZellioChatSpec>
@end
