#import "DeckLinkBridge.h"

#include "DeckLinkSDK.h"

#include <atomic>

static NSString * const SPDeckLinkErrorDomain = @"SimplePlayback.DeckLink";
static constexpr HRESULT SPBMD_OK = 0;
static constexpr uint32_t SPDeckLinkPrerollFrameCount = 3;
static constexpr uint32_t SPDeckLinkBufferedFrameTarget = 3;

@interface SPDeckLinkBridge ()
@property (nonatomic, readwrite, copy) NSString *runtimeStatus;
- (void)scheduledFrameCompletedWithResult:(BMDOutputFrameCompletionResult)result;
- (void)scheduledPlaybackStopped;
@end

class SPDeckLinkOutputCallback final : public IDeckLinkVideoOutputCallback {
public:
    explicit SPDeckLinkOutputCallback(SPDeckLinkBridge *bridge) : _bridge(bridge), _refCount(1) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (!ppv) {
            return E_POINTER;
        }

        CFUUIDBytes iunknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (memcmp(&iid, &iunknown, sizeof(REFIID)) == 0) {
            *ppv = this;
            AddRef();
            return S_OK;
        }

        if (memcmp(&iid, &IID_IDeckLinkVideoOutputCallback, sizeof(REFIID)) == 0) {
            *ppv = static_cast<IDeckLinkVideoOutputCallback *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override {
        return ++_refCount;
    }

    ULONG STDMETHODCALLTYPE Release() override {
        ULONG count = --_refCount;
        if (count == 0) {
            delete this;
        }
        return count;
    }

    HRESULT STDMETHODCALLTYPE ScheduledFrameCompleted(IDeckLinkVideoFrame *, BMDOutputFrameCompletionResult result) override {
        [_bridge scheduledFrameCompletedWithResult:result];
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE ScheduledPlaybackHasStopped() override {
        [_bridge scheduledPlaybackStopped];
        return S_OK;
    }

private:
    SPDeckLinkBridge *__unsafe_unretained _bridge;
    std::atomic<ULONG> _refCount;
};

@implementation SPDeckLinkModeInfo
@end

@implementation SPDeckLinkDeviceInfo
@end

@implementation SPDeckLinkBridge {
    IDeckLinkOutput_v15_3_1 *_output;
    IDeckLink *_activeDevice;
    SPDeckLinkOutputCallback *_outputCallback;
    IDeckLinkMutableVideoFrame *_reusableFrame;
    NSInteger _reusableFrameWidth;
    NSInteger _reusableFrameHeight;
    NSInteger _reusableFrameRowBytes;
    NSData *_latestFrameData;
    NSInteger _latestFrameWidth;
    NSInteger _latestFrameHeight;
    NSInteger _latestFrameRowBytes;
    BMDTimeValue _frameDuration;
    BMDTimeScale _frameTimescale;
    BMDTimeValue _nextScheduledFrameTime;
    BOOL _scheduledPlaybackStarted;
    NSString *_activeDeviceIdentifier;
    NSString *_activeModeIdentifier;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _runtimeStatus = @"DeckLink runtime not loaded";
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (NSArray<SPDeckLinkDeviceInfo *> *)availableDevices {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance_v15_3_1();
    if (!iterator) {
        self.runtimeStatus = @"DeckLinkAPI.framework not found";
        return @[];
    }

    NSMutableArray<SPDeckLinkDeviceInfo *> *devices = [NSMutableArray array];
    IDeckLink *deckLink = nullptr;
    NSInteger index = 0;

    while (iterator->Next(&deckLink) == SPBMD_OK && deckLink) {
        IDeckLinkOutput_v15_3_1 *output = nullptr;
        HRESULT queryResult = deckLink->QueryInterface(IID_IDeckLinkOutput_v15_3_1, reinterpret_cast<void **>(&output));
        if (queryResult == SPBMD_OK && output) {
            NSArray<SPDeckLinkModeInfo *> *modes = [self outputModesForOutput:output];
            if (modes.count > 0) {
                SPDeckLinkDeviceInfo *device = [[SPDeckLinkDeviceInfo alloc] init];
                device.identifier = [self identifierForDevice:deckLink fallbackIndex:index];
                device.name = [self displayNameForDevice:deckLink fallback:[NSString stringWithFormat:@"DeckLink %ld", (long)index + 1]];
                device.modes = modes;
                [devices addObject:device];
            }
            output->Release();
        }
        deckLink->Release();
        deckLink = nullptr;
        index += 1;
    }

    iterator->Release();
    self.runtimeStatus = devices.count > 0 ? @"DeckLink devices available" : @"Desktop Video runtime loaded; no output-capable 1080p devices found";
    return devices;
}

- (BOOL)startWithDeviceIdentifier:(NSString *)deviceIdentifier
                   modeIdentifier:(NSString *)modeIdentifier
                            error:(NSError **)error {
    [self stop];

    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance_v15_3_1();
    if (!iterator) {
        [self assignError:error message:@"DeckLinkAPI.framework was not found in /Library/Frameworks."];
        return NO;
    }

    IDeckLink *deckLink = nullptr;
    NSInteger index = 0;
    while (iterator->Next(&deckLink) == SPBMD_OK && deckLink) {
        NSString *candidateIdentifier = [self identifierForDevice:deckLink fallbackIndex:index];
        NSString *fallbackIdentifier = [self fallbackIdentifierForIndex:index];
        if ([candidateIdentifier isEqualToString:deviceIdentifier] || [fallbackIdentifier isEqualToString:deviceIdentifier]) {
            break;
        }
        deckLink->Release();
        deckLink = nullptr;
        index += 1;
    }
    iterator->Release();

    if (!deckLink) {
        [self assignError:error message:@"Selected DeckLink device is no longer available."];
        return NO;
    }

    IDeckLinkOutput_v15_3_1 *output = nullptr;
    if (deckLink->QueryInterface(IID_IDeckLinkOutput_v15_3_1, reinterpret_cast<void **>(&output)) != SPBMD_OK || !output) {
        deckLink->Release();
        [self assignError:error message:@"Selected DeckLink device does not support output."];
        return NO;
    }

    BMDDisplayMode displayMode = [self displayModeFromModeIdentifier:modeIdentifier];
    if (displayMode == 0) {
        output->Release();
        deckLink->Release();
        [self assignError:error message:@"Invalid DeckLink display mode."];
        return NO;
    }

    bool modeSupported = false;
    BMDDisplayMode actualMode = bmdModeUnknown;
    HRESULT supportResult = output->DoesSupportVideoMode(
        bmdVideoConnectionUnspecified,
        displayMode,
        bmdFormat8BitBGRA,
        bmdNoVideoOutputConversion,
        bmdSupportedVideoModeDefault,
        &actualMode,
        &modeSupported
    );
    if (supportResult != SPBMD_OK || !modeSupported) {
        output->Release();
        deckLink->Release();
        [self assignError:error message:@"Selected DeckLink mode does not support BGRA output."];
        return NO;
    }

    if (output->EnableVideoOutput(displayMode, bmdVideoOutputFlagDefault) != SPBMD_OK) {
        output->Release();
        deckLink->Release();
        [self assignError:error message:@"DeckLink video output could not be enabled."];
        return NO;
    }

    SPDeckLinkOutputCallback *callback = new SPDeckLinkOutputCallback(self);
    if (output->SetScheduledFrameCompletionCallback(callback) != SPBMD_OK) {
        callback->Release();
        output->DisableVideoOutput();
        output->Release();
        deckLink->Release();
        [self assignError:error message:@"DeckLink scheduled output callback could not be configured."];
        return NO;
    }

    HRESULT audioResult = output->EnableAudioOutput(bmdAudioSampleRate48kHz, bmdAudioSampleType16bitInteger, 2, bmdAudioOutputStreamContinuous);
    if (audioResult != SPBMD_OK) {
        output->SetScheduledFrameCompletionCallback(nullptr);
        callback->Release();
        output->DisableVideoOutput();
        output->Release();
        deckLink->Release();
        [self assignError:error message:@"DeckLink audio output could not be enabled."];
        return NO;
    }

    _output = output;
    _activeDevice = deckLink;
    _outputCallback = callback;
    [self timingFromModeIdentifier:modeIdentifier frameDuration:&_frameDuration timeScale:&_frameTimescale];
    _nextScheduledFrameTime = 0;
    _scheduledPlaybackStarted = NO;
    _latestFrameData = nil;
    _latestFrameWidth = 0;
    _latestFrameHeight = 0;
    _latestFrameRowBytes = 0;
    _activeDeviceIdentifier = [deviceIdentifier copy];
    _activeModeIdentifier = [modeIdentifier copy];
    self.runtimeStatus = @"DeckLink scheduled output enabled";
    return YES;
}

- (BOOL)displayFrameWithBGRAData:(NSData *)data
                            width:(NSInteger)width
                           height:(NSInteger)height
                         rowBytes:(NSInteger)rowBytes
                            error:(NSError **)error {
    if (!_output) {
        [self assignError:error message:@"DeckLink output is not running."];
        return NO;
    }
    if (data.length < static_cast<NSUInteger>(rowBytes * height)) {
        [self assignError:error message:@"Video frame buffer is smaller than expected."];
        return NO;
    }

    @synchronized (self) {
        _latestFrameData = [data copy];
        _latestFrameWidth = width;
        _latestFrameHeight = height;
        _latestFrameRowBytes = rowBytes;
    }
    [self scheduleBufferedFramesToTarget:SPDeckLinkBufferedFrameTarget error:error];
    return YES;
}

- (BOOL)writeAudioPCM16Data:(NSData *)data
           sampleFrameCount:(NSInteger)sampleFrameCount
                      error:(NSError **)error {
    if (!_output || data.length == 0 || sampleFrameCount <= 0) {
        return YES;
    }

    uint32_t written = 0;
    HRESULT result = _output->WriteAudioSamplesSync(const_cast<void *>(data.bytes), static_cast<uint32_t>(sampleFrameCount), &written);
    if (result != SPBMD_OK) {
        [self assignError:error message:@"DeckLink rejected the audio samples."];
        return NO;
    }
    return YES;
}

- (void)scheduledFrameCompletedWithResult:(BMDOutputFrameCompletionResult)result {
    if (result == bmdOutputFrameFlushed) {
        return;
    }
    [self scheduleBufferedFramesToTarget:SPDeckLinkBufferedFrameTarget error:nil];
}

- (void)scheduledPlaybackStopped {
    @synchronized (self) {
        _scheduledPlaybackStarted = NO;
        _nextScheduledFrameTime = 0;
    }
}

- (BOOL)scheduleBufferedFramesToTarget:(uint32_t)target error:(NSError **)error {
    BOOL didSchedule = NO;

    while (true) {
        IDeckLinkOutput_v15_3_1 *output = nullptr;
        NSData *frameData = nil;
        NSInteger width = 0;
        NSInteger height = 0;
        NSInteger rowBytes = 0;
        BMDTimeValue displayTime = 0;
        BMDTimeValue frameDuration = 0;
        BMDTimeScale frameTimescale = 0;
        BOOL playbackStarted = NO;

        @synchronized (self) {
            if (!_output || !_latestFrameData || _frameDuration <= 0 || _frameTimescale <= 0) {
                return didSchedule;
            }

            uint32_t bufferedFrameCount = 0;
            if (_output->GetBufferedVideoFrameCount(&bufferedFrameCount) != SPBMD_OK) {
                return didSchedule;
            }
            if (bufferedFrameCount >= target) {
                return didSchedule;
            }

            output = _output;
            output->AddRef();
            frameData = _latestFrameData;
            width = _latestFrameWidth;
            height = _latestFrameHeight;
            rowBytes = _latestFrameRowBytes;
            displayTime = _nextScheduledFrameTime;
            frameDuration = _frameDuration;
            frameTimescale = _frameTimescale;
            playbackStarted = _scheduledPlaybackStarted;
            _nextScheduledFrameTime += _frameDuration;
        }

        IDeckLinkMutableVideoFrame *frame = [self createVideoFrameWithOutput:output
                                                                        data:frameData
                                                                       width:width
                                                                      height:height
                                                                    rowBytes:rowBytes
                                                                       error:error];
        if (!frame) {
            output->Release();
            return didSchedule;
        }

        HRESULT scheduleResult = output->ScheduleVideoFrame(frame, displayTime, frameDuration, frameTimescale);
        frame->Release();
        output->Release();

        if (scheduleResult != SPBMD_OK) {
            [self assignError:error message:@"DeckLink rejected the scheduled video frame."];
            return didSchedule;
        }
        didSchedule = YES;

        if (!playbackStarted) {
            [self startScheduledPlaybackIfReady:error];
        }
    }
}

- (void)startScheduledPlaybackIfReady:(NSError **)error {
    @synchronized (self) {
        if (!_output || _scheduledPlaybackStarted || _frameTimescale <= 0) {
            return;
        }

        uint32_t bufferedFrameCount = 0;
        if (_output->GetBufferedVideoFrameCount(&bufferedFrameCount) != SPBMD_OK || bufferedFrameCount < SPDeckLinkPrerollFrameCount) {
            return;
        }

        HRESULT startResult = _output->StartScheduledPlayback(0, _frameTimescale, 1.0);
        if (startResult == SPBMD_OK) {
            _scheduledPlaybackStarted = YES;
            self.runtimeStatus = @"DeckLink scheduled playback running";
        } else {
            [self assignError:error message:@"DeckLink scheduled playback could not start."];
        }
    }
}

- (IDeckLinkMutableVideoFrame *)createVideoFrameWithOutput:(IDeckLinkOutput_v15_3_1 *)output
                                                      data:(NSData *)data
                                                     width:(NSInteger)width
                                                    height:(NSInteger)height
                                                  rowBytes:(NSInteger)rowBytes
                                                     error:(NSError **)error {
    IDeckLinkMutableVideoFrame *frame = nullptr;
    HRESULT createResult = output->CreateVideoFrame(
        static_cast<int32_t>(width),
        static_cast<int32_t>(height),
        static_cast<int32_t>(rowBytes),
        bmdFormat8BitBGRA,
        bmdFrameFlagFlipVertical,
        &frame
    );
    if (createResult != SPBMD_OK || !frame) {
        [self assignError:error message:@"Could not allocate DeckLink video frame."];
        return nullptr;
    }

    IDeckLinkVideoBuffer_v15_3_1 *videoBuffer = nullptr;
    if (frame->QueryInterface(IID_IDeckLinkVideoBuffer_v15_3_1, reinterpret_cast<void **>(&videoBuffer)) != SPBMD_OK || !videoBuffer) {
        frame->Release();
        [self assignError:error message:@"Could not access DeckLink video frame buffer."];
        return nullptr;
    }

    if (videoBuffer->StartAccess(bmdBufferAccessWrite) != SPBMD_OK) {
        videoBuffer->Release();
        frame->Release();
        [self assignError:error message:@"Could not lock DeckLink video frame buffer."];
        return nullptr;
    }

    void *frameBytes = nullptr;
    if (videoBuffer->GetBytes(&frameBytes) != SPBMD_OK || !frameBytes) {
        videoBuffer->EndAccess(bmdBufferAccessWrite);
        videoBuffer->Release();
        frame->Release();
        [self assignError:error message:@"Could not access DeckLink video frame memory."];
        return nullptr;
    }

    memcpy(frameBytes, data.bytes, static_cast<size_t>(rowBytes * height));
    videoBuffer->EndAccess(bmdBufferAccessWrite);
    videoBuffer->Release();
    return frame;
}

- (void)stop {
    [self releaseReusableVideoFrame];
    if (_output) {
        _output->SetScheduledFrameCompletionCallback(nullptr);
        BMDTimeValue actualStop = 0;
        _output->StopScheduledPlayback(0, &actualStop, _frameTimescale > 0 ? _frameTimescale : 1000);
        _output->FlushBufferedAudioSamples();
        _output->DisableAudioOutput();
        _output->DisableVideoOutput();
        _output->Release();
        _output = nullptr;
    }
    if (_outputCallback) {
        _outputCallback->Release();
        _outputCallback = nullptr;
    }
    if (_activeDevice) {
        _activeDevice->Release();
        _activeDevice = nullptr;
    }
    _latestFrameData = nil;
    _latestFrameWidth = 0;
    _latestFrameHeight = 0;
    _latestFrameRowBytes = 0;
    _frameDuration = 0;
    _frameTimescale = 0;
    _nextScheduledFrameTime = 0;
    _scheduledPlaybackStarted = NO;
    _activeDeviceIdentifier = nil;
    _activeModeIdentifier = nil;
}

- (IDeckLinkMutableVideoFrame *)reusableVideoFrameWithWidth:(NSInteger)width
                                                     height:(NSInteger)height
                                                   rowBytes:(NSInteger)rowBytes
                                                      error:(NSError **)error {
    if (_reusableFrame &&
        _reusableFrameWidth == width &&
        _reusableFrameHeight == height &&
        _reusableFrameRowBytes == rowBytes) {
        return _reusableFrame;
    }

    [self releaseReusableVideoFrame];

    IDeckLinkMutableVideoFrame *frame = nullptr;
    HRESULT createResult = _output->CreateVideoFrame(
        static_cast<int32_t>(width),
        static_cast<int32_t>(height),
        static_cast<int32_t>(rowBytes),
        bmdFormat8BitBGRA,
        bmdFrameFlagFlipVertical,
        &frame
    );
    if (createResult != SPBMD_OK || !frame) {
        [self assignError:error message:@"Could not allocate DeckLink video frame."];
        return nullptr;
    }

    _reusableFrame = frame;
    _reusableFrameWidth = width;
    _reusableFrameHeight = height;
    _reusableFrameRowBytes = rowBytes;
    return _reusableFrame;
}

- (void)releaseReusableVideoFrame {
    if (_reusableFrame) {
        _reusableFrame->Release();
        _reusableFrame = nullptr;
    }
    _reusableFrameWidth = 0;
    _reusableFrameHeight = 0;
    _reusableFrameRowBytes = 0;
}

- (NSArray<SPDeckLinkModeInfo *> *)outputModesForOutput:(IDeckLinkOutput_v15_3_1 *)output {
    IDeckLinkDisplayModeIterator *iterator = nullptr;
    if (output->GetDisplayModeIterator(&iterator) != SPBMD_OK || !iterator) {
        return @[];
    }

    NSMutableArray<SPDeckLinkModeInfo *> *modes = [NSMutableArray array];
    IDeckLinkDisplayMode *mode = nullptr;
    while (iterator->Next(&mode) == SPBMD_OK && mode) {
        long width = mode->GetWidth();
        long height = mode->GetHeight();
        BMDFieldDominance dominance = mode->GetFieldDominance();

        bool modeSupported = false;
        BMDDisplayMode displayMode = mode->GetDisplayMode();
        output->DoesSupportVideoMode(
            bmdVideoConnectionUnspecified,
            displayMode,
            bmdFormat8BitBGRA,
            bmdNoVideoOutputConversion,
            bmdSupportedVideoModeDefault,
            nullptr,
            &modeSupported
        );

        if (width == 1920 && height == 1080 && dominance != bmdUnknownFieldDominance && modeSupported) {
            BMDTimeValue frameDuration = 0;
            BMDTimeScale timeScale = 0;
            mode->GetFrameRate(&frameDuration, &timeScale);

            CFStringRef modeName = nullptr;
            NSString *name = nil;
            if (mode->GetName(&modeName) == SPBMD_OK && modeName) {
                name = CFBridgingRelease(modeName);
            }
            if (name.length == 0) {
                name = [self fallbackNameFor1080ModeWithDominance:dominance frameDuration:frameDuration timeScale:timeScale];
            }

            SPDeckLinkModeInfo *info = [[SPDeckLinkModeInfo alloc] init];
            info.identifier = [NSString stringWithFormat:@"decklink-mode:%u:%lld:%lld", displayMode, frameDuration, timeScale];
            info.name = name;
            info.width = width;
            info.height = height;
            info.frameDuration = frameDuration;
            info.timeScale = timeScale;
            [modes addObject:info];
        }
        mode->Release();
        mode = nullptr;
    }

    iterator->Release();
    return modes;
}

- (NSString *)displayNameForDevice:(IDeckLink *)device fallback:(NSString *)fallback {
    CFStringRef displayName = nullptr;
    if (device->GetDisplayName(&displayName) == SPBMD_OK && displayName) {
        return CFBridgingRelease(displayName);
    }

    CFStringRef modelName = nullptr;
    if (device->GetModelName(&modelName) == SPBMD_OK && modelName) {
        return CFBridgingRelease(modelName);
    }

    return fallback;
}

- (NSString *)fallbackNameFor1080ModeWithDominance:(BMDFieldDominance)dominance
                                     frameDuration:(BMDTimeValue)frameDuration
                                         timeScale:(BMDTimeScale)timeScale {
    NSString *scanType = @"";
    if (dominance == bmdProgressiveFrame) {
        scanType = @"p";
    } else if (dominance == bmdProgressiveSegmentedFrame) {
        scanType = @"PsF";
    } else if (dominance == bmdLowerFieldFirst || dominance == bmdUpperFieldFirst) {
        scanType = @"i";
    }
    return [NSString stringWithFormat:@"1080%@ %.2f", scanType, [self framesPerSecondWithDuration:frameDuration timeScale:timeScale]];
}

- (NSString *)identifierForDevice:(IDeckLink *)device fallbackIndex:(NSInteger)index {
    IDeckLinkProfileAttributes *attributes = nullptr;
    HRESULT queryResult = device->QueryInterface(IID_IDeckLinkProfileAttributes, reinterpret_cast<void **>(&attributes));
    if (queryResult == SPBMD_OK && attributes) {
        int64_t persistentID = 0;
        HRESULT idResult = attributes->GetInt(BMDDeckLinkPersistentID, &persistentID);
        attributes->Release();
        if (idResult == SPBMD_OK) {
            return [NSString stringWithFormat:@"decklink-persistent:%lld", static_cast<long long>(persistentID)];
        }
    }

    return [self fallbackIdentifierForIndex:index];
}

- (NSString *)fallbackIdentifierForIndex:(NSInteger)index {
    return [NSString stringWithFormat:@"decklink:%ld", (long)index];
}

- (BMDDisplayMode)displayModeFromModeIdentifier:(NSString *)identifier {
    if (![identifier hasPrefix:@"decklink-mode:"]) {
        return 0;
    }
    NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@":"];
    if (parts.count < 2) {
        return 0;
    }
    return static_cast<BMDDisplayMode>([parts[1] longLongValue]);
}

- (void)timingFromModeIdentifier:(NSString *)identifier
                    frameDuration:(BMDTimeValue *)frameDuration
                        timeScale:(BMDTimeScale *)timeScale {
    if (frameDuration) {
        *frameDuration = 1;
    }
    if (timeScale) {
        *timeScale = 30;
    }

    if (![identifier hasPrefix:@"decklink-mode:"]) {
        return;
    }

    NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@":"];
    if (parts.count < 4) {
        return;
    }

    long long parsedFrameDuration = [parts[2] longLongValue];
    long long parsedTimeScale = [parts[3] longLongValue];
    if (parsedFrameDuration <= 0 || parsedTimeScale <= 0) {
        return;
    }

    if (frameDuration) {
        *frameDuration = static_cast<BMDTimeValue>(parsedFrameDuration);
    }
    if (timeScale) {
        *timeScale = static_cast<BMDTimeScale>(parsedTimeScale);
    }
}

- (double)framesPerSecondWithDuration:(BMDTimeValue)frameDuration timeScale:(BMDTimeScale)timeScale {
    if (frameDuration <= 0) {
        return 0;
    }
    return static_cast<double>(timeScale) / static_cast<double>(frameDuration);
}

- (void)assignError:(NSError **)error message:(NSString *)message {
    self.runtimeStatus = message;
    if (error) {
        *error = [NSError errorWithDomain:SPDeckLinkErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}

@end
