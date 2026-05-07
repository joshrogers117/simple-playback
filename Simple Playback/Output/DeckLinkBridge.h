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

@interface SPDeckLinkBridge : NSObject
@property (nonatomic, readonly, copy) NSString *runtimeStatus;

- (NSArray<SPDeckLinkDeviceInfo *> *)availableDevices;
- (BOOL)startWithDeviceIdentifier:(NSString *)deviceIdentifier
                   modeIdentifier:(NSString *)modeIdentifier
                            error:(NSError * _Nullable * _Nullable)error;
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
