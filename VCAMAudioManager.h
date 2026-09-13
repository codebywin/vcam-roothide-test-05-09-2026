//
//  VCAMAudioManager.h
//  VCAM iOS - Virtual Microphone & Audio Injection Engine
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAMAudioManager : NSObject

+ (instancetype)sharedManager;

/// Trạng thái bật/tắt tính năng âm thanh ảo
@property (nonatomic, assign) BOOL isAudioEnabled;

/// Video hiện tại có track âm thanh hay không
@property (nonatomic, readonly) BOOL hasAudioTrack;

/// Độ dài âm thanh (giây)
@property (nonatomic, readonly) Float64 duration;

/// Nạp và giải mã âm thanh PCM từ file video vào RAM
- (void)loadAudioFromVideoPath:(nullable NSString *)videoPath;

/// Xóa cache âm thanh khi đổi video hoặc tắt VCAM
- (void)reset;

/// Tua lại luồng âm thanh về đầu (đồng bộ khi video Loop)
- (void)resetPlayback;

/// Đồng bộ vị trí âm thanh theo thời gian phát của video (giây)
- (void)syncWithVideoElapsed:(Float64)elapsed;

/// Bật / Tắt âm thanh ảo (lưu cờ vào hệ thống)
- (void)toggleAudioEnabled;

/// Xử lý và ghi đè CMSampleBufferRef âm thanh trong mediaserverd (BWNodeOutput)
- (void)processAudioSampleBuffer:(CMSampleBufferRef)sampleBuffer;

/// Ghi đè AudioBufferList cho AudioUnitRender (TikTok, Shopee, VoIP...)
- (void)fillAudioBufferList:(AudioBufferList *)ioData
             numberOfFrames:(UInt32)frames
                       asbd:(const AudioStreamBasicDescription *)asbd;

@end

NS_ASSUME_NONNULL_END

