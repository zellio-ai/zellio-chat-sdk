#import "RNZellioChat.h"

#if __has_include("ZellioChatReactNative/ZellioChatReactNative-Swift.h")
#import "ZellioChatReactNative/ZellioChatReactNative-Swift.h"
#else
#import "ZellioChatReactNative-Swift.h"
#endif

@implementation RNZellioChat

RCT_EXPORT_MODULE(RNZellioChat)

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

- (instancetype)init
{
  if ((self = [super init])) {
    __weak RNZellioChat *weakSelf = self;
    [ZCRNBridge attachUnread:^(NSInteger count) {
      [weakSelf emitOnUnread:@{@"count" : @(count)}];
    }
        event:^(NSString *name, NSString * _Nullable code) {
          NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObject:name forKey:@"name"];
          if (code != nil) {
            payload[@"code"] = code;
          }
          [weakSelf emitOnEvent:payload];
        }
        tokenRequest:^(NSString *requestId) {
          [weakSelf emitOnTokenRequest:@{@"requestId" : requestId}];
        }];
  }
  return self;
}

- (void)invalidate
{
  [ZCRNBridge detach];
}

- (void)configure:(NSString *)appKey options:(NSDictionary *)options
{
  [ZCRNBridge configureWithAppKey:appKey options:options];
}

- (void)identify
{
  [ZCRNBridge identify];
}

- (void)resolveToken:(NSString *)requestId token:(NSString * _Nullable)token errorCode:(NSString * _Nullable)errorCode
{
  [ZCRNBridge resolveTokenWithRequestId:requestId token:token errorCode:errorCode];
}

- (void)logout
{
  [ZCRNBridge logout];
}

- (void)present
{
  [ZCRNBridge present];
}

- (void)presentConversation:(NSString * _Nullable)conversationId
{
  [ZCRNBridge presentConversationWithId:conversationId];
}

- (void)dismiss
{
  [ZCRNBridge dismiss];
}

- (void)setContext:(NSDictionary * _Nullable)context
{
  [ZCRNBridge setContext:context];
}

- (void)getUnreadCount:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  resolve(@([ZCRNBridge unreadCount]));
}

- (void)setPushToken:(NSString *)token environment:(NSString * _Nullable)environment
{
  [ZCRNBridge setPushTokenWithHex:token environment:environment];
}

- (NSNumber *)isZellioPush:(NSString *)payloadJson
{
  return @([ZCRNBridge isZellioPushWithJson:payloadJson]);
}

- (void)handlePush:(NSString *)payloadJson resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject
{
  resolve(@([ZCRNBridge handlePushWithJson:payloadJson]));
}

- (void)handleNotificationTap:(NSString *)payloadJson
                      resolve:(RCTPromiseResolveBlock)resolve
                       reject:(RCTPromiseRejectBlock)reject
{
  resolve(@([ZCRNBridge handleNotificationTapWithJson:payloadJson]));
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeZellioChatSpecJSI>(params);
}

@end
