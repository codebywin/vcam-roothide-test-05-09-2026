//
//  VCAMAudioManager.m
//  VCAM iOS - Virtual Microphone & Audio Injection Engine
//

#import "VCAMAudioManager.h"
#import <os/lock.h>
#include <sys/stat.h>
#include <unistd.h>
#include <math.h>

static const char *kVCamAudioEnabledFlagName = "vcam_audio_enabled";

static void VCamAudioLog(NSString *msg) {
    static int logCount = 0;
    if (logCount++ < 50) {
        FILE *f = fopen("/var/tmp/vcam_audio.log", "a");
        if (f) {
            fputs([msg UTF8String], f);
            fputs("\n", f);
            fclose(f);
            chmod("/var/tmp/vcam_audio.log", 0666);
        }
    }
}

static NSArray<NSString *> *AudioPossibleTmpDirs(void) {
    static NSArray<NSString *> *dirs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *list = [NSMutableArray array];
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/rootfs/private/var/tmp"]) {
            [list addObject:@"/rootfs/private/var/tmp"];
        }
        [list addObject:@"/var/tmp"];
        [list addObject:@"/private/var/tmp"];
        dirs = [list copy];
    });
    return dirs;
}

static BOOL CheckAudioFlag(const char *name) {
    for (NSString *dir in AudioPossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        if (access([filePath UTF8String], F_OK) == 0) {
            NSString *val = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
            if (val && [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0) {
                return ![val isEqualToString:@"0"];
            }
            return YES;
        }
    }
    return YES; // Mặc định bật
}

static void WriteAudioFlag(const char *name, BOOL enabled) {
    for (NSString *dir in AudioPossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        [@(enabled ? "1" : "0") writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([filePath UTF8String], 0666);
    }
}

@interface VCAMAudioManager () {
    os_unfair_lock _lock;
    NSMutableData *_pcmData;     // Chứa dữ liệu Linear PCM 32-bit Float Stereo (Interleaved: L, R, L, R...)
    double _playbackFramePos;    // Vị trí frame phát hiện tại (có phần lẻ thập phân để nội suy mẫu resample)
    size_t _totalFrames;         // Tổng số frame stereo của video
    double _srcSampleRate;       // Tần số lấy mẫu nguồn (44100.0)
    
    NSString *_loadedVideoPath;
}
@end

@implementation VCAMAudioManager

+ (instancetype)sharedManager {
    static VCAMAudioManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMAudioManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _pcmData = [NSMutableData data];
        _isAudioEnabled = CheckAudioFlag(kVCamAudioEnabledFlagName);
        _hasAudioTrack = NO;
        _duration = 0.0;
        _playbackFramePos = 0.0;
        _totalFrames = 0;
        _srcSampleRate = 44100.0;
    }
    return self;
}

#pragma mark - Audio Extraction & Decoding (Float32 Canonical Format)

- (void)loadAudioFromVideoPath:(nullable NSString *)videoPath {
    os_unfair_lock_lock(&_lock);

    if (!videoPath || access([videoPath UTF8String], F_OK) != 0) {
        [self _cleanupUnlocked];
        os_unfair_lock_unlock(&_lock);
        return;
    }

    if ([videoPath isEqualToString:_loadedVideoPath] && _pcmData.length > 0 && _totalFrames > 0) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    [self _cleanupUnlocked];

    NSURL *url = [NSURL fileURLWithPath:videoPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];

    if (!audioTrack) {
        VCamAudioLog(@"[VCAMAudio] Video không có track âm thanh");
        _hasAudioTrack = NO;
        os_unfair_lock_unlock(&_lock);
        return;
    }

    // Luôn giải mã âm thanh về chuẩn cao cấp: 44.1kHz, 32-bit Float, Stereo Interleaved Linear PCM
    _srcSampleRate = 44100.0;
    NSDictionary *outputSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(44100.0),
        AVNumberOfChannelsKey: @(2),
        AVLinearPCMBitDepthKey: @(32),
        AVLinearPCMIsFloatKey: @(YES),
        AVLinearPCMIsBigEndianKey: @(NO),
        AVLinearPCMIsNonInterleavedKey: @(NO)
    };

    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (!reader || error) {
        VCamAudioLog([NSString stringWithFormat:@"[VCAMAudio] Lỗi tạo assetReader: %@", error]);
        os_unfair_lock_unlock(&_lock);
        return;
    }

    AVAssetReaderTrackOutput *trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:outputSettings];
    trackOutput.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:trackOutput]) {
        VCamAudioLog(@"[VCAMAudio] Không thể add trackOutput vào reader");
        os_unfair_lock_unlock(&_lock);
        return;
    }
    [reader addOutput:trackOutput];

    if (![reader startReading]) {
        VCamAudioLog([NSString stringWithFormat:@"[VCAMAudio] startReading thất bại: %@", reader.error]);
        os_unfair_lock_unlock(&_lock);
        return;
    }

    // Đọc tất cả sample buffers và giải nén trực tiếp vào RAM
    while (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sbuf = [trackOutput copyNextSampleBuffer];
        if (!sbuf) break;

        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sbuf);
        if (blockBuffer) {
            size_t length = CMBlockBufferGetDataLength(blockBuffer);
            if (length > 0) {
                size_t curLen = _pcmData.length;
                [_pcmData increaseLengthBy:length];
                CMBlockBufferCopyDataBytes(blockBuffer, 0, length, (char *)_pcmData.mutableBytes + curLen);
            }
        }
        CFRelease(sbuf);
    }

    [reader cancelReading];

    // Mỗi frame stereo float32 gồm: 2 channel * 4 bytes = 8 bytes
    _totalFrames = _pcmData.length / (sizeof(float) * 2);
    _hasAudioTrack = (_totalFrames > 0);
    _loadedVideoPath = [videoPath copy];
    _duration = CMTimeGetSeconds(asset.duration);
    _playbackFramePos = 0.0;

    VCamAudioLog([NSString stringWithFormat:@"[VCAMAudio] Đã nạp audio: %zu frames (%.2f s, %lu bytes, path: %@)",
                  _totalFrames, _duration, (unsigned long)_pcmData.length, videoPath]);

    os_unfair_lock_unlock(&_lock);
}

- (void)_cleanupUnlocked {
    [_pcmData setLength:0];
    _totalFrames = 0;
    _playbackFramePos = 0.0;
    _hasAudioTrack = NO;
    _duration = 0.0;
    _loadedVideoPath = nil;
}

- (void)reset {
    os_unfair_lock_lock(&_lock);
    [self _cleanupUnlocked];
    os_unfair_lock_unlock(&_lock);
}

- (void)resetPlayback {
    os_unfair_lock_lock(&_lock);
    _playbackFramePos = 0.0;
    os_unfair_lock_unlock(&_lock);
}

- (void)syncWithVideoElapsed:(Float64)elapsed {
    os_unfair_lock_lock(&_lock);
    if (_totalFrames > 0 && _srcSampleRate > 0) {
        double targetFrame = elapsed * _srcSampleRate;
        _playbackFramePos = fmod(targetFrame, (double)_totalFrames);
    }
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)isAudioEnabled {
    os_unfair_lock_lock(&_lock);
    static CFTimeInterval lastCheck = 0;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastCheck > 0.5) {
        lastCheck = now;
        _isAudioEnabled = CheckAudioFlag(kVCamAudioEnabledFlagName);
    }
    BOOL en = _isAudioEnabled;
    os_unfair_lock_unlock(&_lock);
    return en;
}

- (void)toggleAudioEnabled {
    os_unfair_lock_lock(&_lock);
    _isAudioEnabled = !_isAudioEnabled;
    WriteAudioFlag(kVCamAudioEnabledFlagName, _isAudioEnabled);
    VCamAudioLog([NSString stringWithFormat:@"[VCAMAudio] toggleAudioEnabled -> %d", _isAudioEnabled]);
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Pure Mathematical DSP Resampler & Universal Buffer Filler

- (void)_fillAudioBuffers:(AudioBufferList *)ioData
           numberOfFrames:(UInt32)frames
               targetASBD:(const AudioStreamBasicDescription *)targetASBD {
    if (!ioData || frames == 0 || !targetASBD || _totalFrames == 0 || _pcmData.length == 0) return;
    if (ioData->mNumberBuffers == 0 || !ioData->mBuffers[0].mData) return;

    double dstSampleRate = (targetASBD->mSampleRate > 1000.0) ? targetASBD->mSampleRate : 44100.0;
    double step = _srcSampleRate / dstSampleRate;

    BOOL isFloat = (targetASBD->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    BOOL isNonInterleaved = (targetASBD->mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0;
    UInt32 channels = (targetASBD->mChannelsPerFrame > 0) ? targetASBD->mChannelsPerFrame : 1;

    const float *srcFloats = (const float *)_pcmData.bytes;
    size_t totalFrames = _totalFrames;

    // Buffer pointers
    float *bufFloat0 = (float *)ioData->mBuffers[0].mData;
    float *bufFloat1 = (ioData->mNumberBuffers > 1) ? (float *)ioData->mBuffers[1].mData : NULL;

    int16_t *bufInt0 = (int16_t *)ioData->mBuffers[0].mData;
    int16_t *bufInt1 = (ioData->mNumberBuffers > 1) ? (int16_t *)ioData->mBuffers[1].mData : NULL;

    for (UInt32 f = 0; f < frames; f++) {
        size_t idx0 = ((size_t)_playbackFramePos) % totalFrames;
        size_t idx1 = (idx0 + 1) % totalFrames;
        float frac = (float)(_playbackFramePos - (size_t)_playbackFramePos);

        // Nội suy tuyến tính (Linear Interpolation) giữa các mẫu âm thanh để triệt tiêu 100% tiếng rè, sôi
        float l = srcFloats[idx0 * 2 + 0] * (1.0f - frac) + srcFloats[idx1 * 2 + 0] * frac;
        float r = srcFloats[idx0 * 2 + 1] * (1.0f - frac) + srcFloats[idx1 * 2 + 1] * frac;

        if (isFloat) {
            // Định dạng 32-bit Float (Chuẩn của TikTok Live & CoreAudio)
            if (channels == 1) {
                // Mono: Trộn kênh trái & phải (downmix)
                float mono = (l + r) * 0.5f;
                if (bufFloat0) bufFloat0[f] = mono;
            } else if (isNonInterleaved && bufFloat1) {
                // Stereo Non-Interleaved (2 buffers riêng biệt: Buffer 0 = L, Buffer 1 = R)
                if (bufFloat0) bufFloat0[f] = l;
                bufFloat1[f] = r;
            } else {
                // Stereo Interleaved (1 buffer: L, R, L, R...)
                if (bufFloat0) {
                    bufFloat0[f * 2 + 0] = l;
                    bufFloat0[f * 2 + 1] = r;
                }
            }
        } else {
            // Định dạng 16-bit Signed Integer (SInt16)
            int16_t sl = (int16_t)(fmaxf(-1.0f, fminf(1.0f, l)) * 32767.0f);
            int16_t sr = (int16_t)(fmaxf(-1.0f, fminf(1.0f, r)) * 32767.0f);

            if (channels == 1) {
                int16_t smono = (int16_t)(((int32_t)sl + (int32_t)sr) / 2);
                if (bufInt0) bufInt0[f] = smono;
            } else if (isNonInterleaved && bufInt1) {
                if (bufInt0) bufInt0[f] = sl;
                bufInt1[f] = sr;
            } else {
                if (bufInt0) {
                    bufInt0[f * 2 + 0] = sl;
                    bufInt0[f * 2 + 1] = sr;
                }
            }
        }

        _playbackFramePos += step;
        if (_playbackFramePos >= totalFrames) {
            _playbackFramePos -= totalFrames;
        }
    }

    // Cập nhật kích thước byte data tương ứng với số frame đã ghi
    UInt32 bytesPerSample = isFloat ? sizeof(float) : sizeof(int16_t);
    UInt32 bytesPerBuf = isNonInterleaved ? (frames * bytesPerSample) : (frames * bytesPerSample * channels);

    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        ioData->mBuffers[b].mDataByteSize = bytesPerBuf;
    }
}

#pragma mark - Public Injection Hooks

- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;

    if (![self isAudioEnabled]) return;

    os_unfair_lock_lock(&_lock);

    if (!_hasAudioTrack || _totalFrames == 0) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    CMFormatDescriptionRef formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!formatDesc || CMFormatDescriptionGetMediaType(formatDesc) != kCMMediaType_Audio) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc);
    if (!asbd) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    // Dự trữ dung lượng an toàn cho tối đa 8 kênh âm thanh
    char bufferListStorage[sizeof(AudioBufferList) + 8 * sizeof(AudioBuffer)];
    AudioBufferList *bufferList = (AudioBufferList *)bufferListStorage;
    UInt32 bufferListSize = sizeof(bufferListStorage);
    CMBlockBufferRef blockBuffer = NULL;

    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        NULL,
        bufferList,
        bufferListSize,
        kCFAllocatorDefault,
        kCFAllocatorDefault,
        0,
        &blockBuffer
    );

    if (status == noErr) {
        CMItemCount numSamples = CMSampleBufferGetNumSamples(sampleBuffer);
        if (numSamples > 0) {
            static int msLogCount = 0;
            if (msLogCount++ < 15) {
                VCamAudioLog([NSString stringWithFormat:@"[MS-Audio] Injected %ld frames, rate=%.0f, ch=%d, isFloat=%d",
                              (long)numSamples, asbd->mSampleRate, asbd->mChannelsPerFrame,
                              (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0]);
            }
            [self _fillAudioBuffers:bufferList numberOfFrames:(UInt32)numSamples targetASBD:asbd];
        }
    }

    if (blockBuffer) {
        CFRelease(blockBuffer);
    }

    os_unfair_lock_unlock(&_lock);
}

- (void)fillAudioBufferList:(AudioBufferList *)ioData
             numberOfFrames:(UInt32)frames
                       asbd:(const AudioStreamBasicDescription *)asbd {
    if (!ioData || frames == 0 || !asbd) return;

    if (![self isAudioEnabled]) return;

    os_unfair_lock_lock(&_lock);

    if (!_hasAudioTrack || _totalFrames == 0) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    static int auLogCount = 0;
    if (auLogCount++ < 15) {
        VCamAudioLog([NSString stringWithFormat:@"[AU-Audio] Injected %u frames, rate=%.0f, ch=%d, isFloat=%d",
                      (unsigned int)frames, asbd->mSampleRate, asbd->mChannelsPerFrame,
                      (asbd->mFormatFlags & kAudioFormatFlagIsFloat) != 0]);
    }

    [self _fillAudioBuffers:ioData numberOfFrames:frames targetASBD:asbd];

    os_unfair_lock_unlock(&_lock);
}

@end
