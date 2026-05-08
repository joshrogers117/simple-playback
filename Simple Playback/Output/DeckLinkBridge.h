#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPDeckLinkModeInfo : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) int64_t frameDuration;
@property (nonatomic) int64_t timeScale;
@end

@interface SPDeckLinkDeviceInfo : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSArray<SPDeckLinkModeInfo *> *modes;
@end

/// Genlock / external reference lock state surfaced from `IDeckLinkOutput::GetReferenceStatus`.
typedef NS_ENUM(NSInteger, SPDeckLinkReferenceState) {
    /// No DeckLink output is currently active — REF state cannot be determined.
    SPDeckLinkReferenceStateIdle = 0,
    /// Hardware does not support an external reference input (typical for entry-level cards).
    SPDeckLinkReferenceStateNotSupported,
    /// External reference input present but not locked — output is free-running.
    SPDeckLinkReferenceStateUnlocked,
    /// External reference locked. Output is genlocked.
    SPDeckLinkReferenceStateLocked
};

@interface SPDeckLinkBridge : NSObject
@property (nonatomic, readonly, copy) NSString *runtimeStatus;

/// Latest REF lock state. Refreshed every call to `pollReferenceState` and on start/stop.
@property (nonatomic, readonly) SPDeckLinkReferenceState referenceState;

- (NSArray<SPDeckLinkDeviceInfo *> *)availableDevices;
- (BOOL)startWithDeviceIdentifier:(NSString *)deviceIdentifier
                   modeIdentifier:(NSString *)modeIdentifier
                            error:(NSError * _Nullable * _Nullable)error;
/// Re-query the active output's REF status. Cheap to call on the render thread; caches into
/// `referenceState`. Returns the freshly-read value.
- (SPDeckLinkReferenceState)pollReferenceState;
- (BOOL)displayFrameWithBGRAData:(NSData *)data
                            width:(NSInteger)width
                           height:(NSInteger)height
                         rowBytes:(NSInteger)rowBytes
                            error:(NSError * _Nullable * _Nullable)error;
- (BOOL)writeAudioPCM16Data:(NSData *)data
           sampleFrameCount:(NSInteger)sampleFrameCount
                      error:(NSError * _Nullable * _Nullable)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
