//
//  VCAMAudioManager.m
//  VCAM iOS - Virtual Microphone & Audio Injection Engine
//

#import "VCAMAudioManager.h"
#import <os/lock.h>
#include <sys/stat.h>
#include <unistd.h>

static const char *kVCamAudioEnabledFlagName = "vcam_audio_enabled";

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
    return YES; // Mặc định bật nếu có video
}

static void WriteAudioFlag(const char *name, BOOL enabled) {
    for (NSString *dir in AudioPossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        [@(enabled ? "1" : "0") writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([filePath UTF8String], 0666);
    }
}

typedef struct {
    VCAMAudioManager *manager;
    UInt32 requestedFrames;
} VCAMAudioInputContext;

@interface VCAMAudioManager () {
    os_unfair_lock _lock;
    NSMutableData *_pcmData;
    size_t _playbackByteOffset;
    size_t _totalPCMBytes;
    
    AudioStreamBasicDescription _srcASBD;
    AudioStreamBasicDescription _lastDstASBD;
    AudioConverterRef _audioConverter;
    
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
        _playbackByteOffset = 0;
        _totalPCMBytes = 0;
        _audioConverter = NULL;
        memset(&_srcASBD, 0, sizeof(_srcASBD));
        memset(&_lastDstASBD, 0, sizeof(_lastDstASBD));
    }
    return self;
}

- (void)dealloc {
    if (_audioConverter) {
        AudioConverterDispose(_audioConverter);
        _audioConverter = NULL;
    }
}

#pragma mark - Audio Extraction & Decoding

- (void)loadAudioFromVideoPath:(nullable NSString *)videoPath {
    os_unfair_lock_lock(&_lock);

    if (!videoPath || access([videoPath UTF8String], F_OK) != 0) {
        [self _cleanupUnlocked];
        os_unfair_lock_unlock(&_lock);
        return;
    }

    if ([videoPath isEqualToString:_loadedVideoPath] && _pcmData.length > 0) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    [self _cleanupUnlocked];

    NSURL *url = [NSURL fileURLWithPath:videoPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];

    if (!audioTrack) {
        _hasAudioTrack = NO;
        os_unfair_lock_unlock(&_lock);
        return;
    }

    // Thiết lập định dạng nguồn chuẩn: 44.1kHz, 16-bit Signed Integer, Stereo Interleaved Linear PCM
    _srcASBD.mSampleRate       = 44100.0;
    _srcASBD.mFormatID         = kAudioFormatLinearPCM;
    _srcASBD.mFormatFlags      = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    _srcASBD.mBytesPerPacket   = 4; // 2 channels * 2 bytes
    _srcASBD.mFramesPerPacket  = 1;
    _srcASBD.mBytesPerFrame    = 4;
    _srcASBD.mChannelsPerFrame = 2;
    _srcASBD.mBitsPerChannel   = 16;

    NSDictionary *outputSettings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(44100.0),
        AVNumberOfChannelsKey: @(2),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsFloatKey: @(NO),
        AVLinearPCMIsBigEndianKey: @(NO),
        AVLinearPCMIsNonInterleavedKey: @(NO)
    };

    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (!reader || error) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    AVAssetReaderTrackOutput *trackOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:outputSettings];
    trackOutput.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:trackOutput]) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    [reader addOutput:trackOutput];

    if (![reader startReading]) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    // Đọc tuần tự tất cả sample buffers và nối vào _pcmData
    while (reader.status == AVAssetReaderStatusReading) {
        CMSampleBufferRef sbuf = [trackOutput copyNextSampleBuffer];
        if (!sbuf) break;

        CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sbuf);
        if (blockBuffer) {
            size_t length = CMBlockBufferGetDataLength(blockBuffer);
            if (length > 0) {
                NSMutableData *tempBuf = [NSMutableData dataWithLength:length];
                OSStatus status = CMBlockBufferCopyDataBytes(blockBuffer, 0, length, tempBuf.mutableBytes);
                if (status == kCMBlockBufferNoErr) {
                    [_pcmData appendData:tempBuf];
                }
            }
        }
        CFRelease(sbuf);
    }

    [reader cancelReading];

    _totalPCMBytes = _pcmData.length;
    _hasAudioTrack = (_totalPCMBytes > 0);
    _loadedVideoPath = [videoPath copy];
    _duration = CMTimeGetSeconds(asset.duration);
    _playbackByteOffset = 0;

    os_unfair_lock_unlock(&_lock);
}

- (void)_cleanupUnlocked {
    if (_audioConverter) {
        AudioConverterDispose(_audioConverter);
        _audioConverter = NULL;
    }
    memset(&_lastDstASBD, 0, sizeof(_lastDstASBD));
    [_pcmData setLength:0];
    _totalPCMBytes = 0;
    _playbackByteOffset = 0;
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
    _playbackByteOffset = 0;
    os_unfair_lock_unlock(&_lock);
}

- (void)syncWithVideoElapsed:(Float64)elapsed {
    os_unfair_lock_lock(&_lock);
    if (_totalPCMBytes > 0 && _srcASBD.mBytesPerFrame > 0 && _srcASBD.mSampleRate > 0) {
        size_t targetByte = (size_t)(elapsed * _srcASBD.mSampleRate) * _srcASBD.mBytesPerFrame;
        _playbackByteOffset = targetByte % _totalPCMBytes;
        // Căn chỉnh byte offset theo mBytesPerFrame
        _playbackByteOffset -= (_playbackByteOffset % _srcASBD.mBytesPerFrame);
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)toggleAudioEnabled {
    os_unfair_lock_lock(&_lock);
    _isAudioEnabled = !_isAudioEnabled;
    WriteAudioFlag(kVCamAudioEnabledFlagName, _isAudioEnabled);
    os_unfair_lock_unlock(&_lock);
}

#pragma mark - Audio Conversion & Delivery

static OSStatus VCAMAudioConverterInputDataProc(AudioConverterRef inAudioConverter,
                                               UInt32 *ioNumberDataPackets,
                                               AudioBufferList *ioData,
                                               AudioStreamPacketDescription **outDataPacketDescription,
                                               void *inUserData) {
    VCAMAudioInputContext *ctx = (VCAMAudioInputContext *)inUserData;
    VCAMAudioManager *mgr = ctx->manager;

    if (!mgr || mgr->_totalPCMBytes == 0) {
        *ioNumberDataPackets = 0;
        return noErr;
    }

    UInt32 requestedPackets = *ioNumberDataPackets;
    UInt32 bytesNeeded = requestedPackets * mgr->_srcASBD.mBytesPerPacket;

    // Lấy con trỏ tại vị trí phát hiện tại
    const uint8_t *rawBytes = (const uint8_t *)mgr->_pcmData.bytes;
    size_t availableBytes = mgr->_totalPCMBytes - mgr->_playbackByteOffset;

    if (availableBytes == 0) {
        // Tự động lặp lại (Loop) từ đầu
        mgr->_playbackByteOffset = 0;
        availableBytes = mgr->_totalPCMBytes;
    }

    size_t bytesToProvide = MIN(bytesNeeded, availableBytes);
    UInt32 packetsProvided = (UInt32)(bytesToProvide / mgr->_srcASBD.mBytesPerPacket);
    bytesToProvide = packetsProvided * mgr->_srcASBD.mBytesPerPacket;

    ioData->mNumberBuffers = 1;
    ioData->mBuffers[0].mNumberChannels = mgr->_srcASBD.mChannelsPerFrame;
    ioData->mBuffers[0].mDataByteSize   = (UInt32)bytesToProvide;
    ioData->mBuffers[0].mData           = (void *)(rawBytes + mgr->_playbackByteOffset);

    mgr->_playbackByteOffset = (mgr->_playbackByteOffset + bytesToProvide) % mgr->_totalPCMBytes;
    *ioNumberDataPackets = packetsProvided;

    return noErr;
}

- (BOOL)_ensureAudioConverterForTargetASBD:(const AudioStreamBasicDescription *)dstASBD {
    if (!dstASBD || dstASBD->mFormatID != kAudioFormatLinearPCM) return NO;

    if (_audioConverter && memcmp(&_lastDstASBD, dstASBD, sizeof(AudioStreamBasicDescription)) == 0) {
        return YES;
    }

    if (_audioConverter) {
        AudioConverterDispose(_audioConverter);
        _audioConverter = NULL;
    }

    OSStatus status = AudioConverterNew(&_srcASBD, dstASBD, &_audioConverter);
    if (status == noErr && _audioConverter) {
        memcpy(&_lastDstASBD, dstASBD, sizeof(AudioStreamBasicDescription));
        return YES;
    }

    return NO;
}

- (void)_fillAudioBuffers:(AudioBufferList *)ioData
           numberOfFrames:(UInt32)frames
               targetASBD:(const AudioStreamBasicDescription *)targetASBD {
    if (!ioData || frames == 0 || !targetASBD) return;

    if (![self _ensureAudioConverterForTargetASBD:targetASBD]) {
        // Nếu không thể tạo converter, thử fast-path nếu định dạng tương đồng
        if (targetASBD->mSampleRate == _srcASBD.mSampleRate &&
            targetASBD->mChannelsPerFrame == _srcASBD.mChannelsPerFrame &&
            targetASBD->mBitsPerChannel == _srcASBD.mBitsPerChannel &&
            ioData->mNumberBuffers > 0 && ioData->mBuffers[0].mData) {
            size_t bytesToCopy = MIN((size_t)(frames * _srcASBD.mBytesPerFrame), (size_t)ioData->mBuffers[0].mDataByteSize);
            size_t avail = _totalPCMBytes - _playbackByteOffset;
            const uint8_t *src = (const uint8_t *)_pcmData.bytes;
            if (avail >= bytesToCopy) {
                memcpy(ioData->mBuffers[0].mData, src + _playbackByteOffset, bytesToCopy);
                _playbackByteOffset = (_playbackByteOffset + bytesToCopy) % _totalPCMBytes;
            } else {
                memcpy(ioData->mBuffers[0].mData, src + _playbackByteOffset, avail);
                size_t remaining = bytesToCopy - avail;
                memcpy((uint8_t *)ioData->mBuffers[0].mData + avail, src, remaining);
                _playbackByteOffset = remaining % _totalPCMBytes;
            }
        }
        return;
    }

    UInt32 ioOutputDataPackets = frames;
    VCAMAudioInputContext ctx;
    ctx.manager = self;
    ctx.requestedFrames = frames;

    AudioConverterFillComplexBuffer(_audioConverter,
                                   VCAMAudioConverterInputDataProc,
                                   &ctx,
                                   &ioOutputDataPackets,
                                   ioData,
                                   NULL);
}

#pragma mark - Public Injection Hooks

- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!sampleBuffer) return;

    os_unfair_lock_lock(&_lock);

    if (!_isAudioEnabled || !_hasAudioTrack || _totalPCMBytes == 0) {
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

    AudioBufferList bufferList;
    CMBlockBufferRef blockBuffer = NULL;
    OSStatus status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        NULL,
        &bufferList,
        sizeof(bufferList),
        kCFAllocatorDefault,
        kCFAllocatorDefault,
        0,
        &blockBuffer
    );

    if (status == noErr) {
        CMItemCount numSamples = CMSampleBufferGetNumSamples(sampleBuffer);
        if (numSamples > 0) {
            [self _fillAudioBuffers:&bufferList numberOfFrames:(UInt32)numSamples targetASBD:asbd];
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

    os_unfair_lock_lock(&_lock);

    if (!_isAudioEnabled || !_hasAudioTrack || _totalPCMBytes == 0) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    [self _fillAudioBuffers:ioData numberOfFrames:frames targetASBD:asbd];

    os_unfair_lock_unlock(&_lock);
}

@end

