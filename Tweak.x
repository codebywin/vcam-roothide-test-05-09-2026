#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "VCAMLicenseManager.h"
#import "VCAMFlashLivenessManager.h"
#import "VCAMFlashBurstManager.h"
#import "VCAMTransformManager.h"
#import "VCAMSecurityGuard.h"
#import "VCAMPhotoManager.h"
#import "VCAMVideoManager.h"
#import "VCAMShadingManager.h"
#import <ImageIO/ImageIO.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/stat.h>
#import <os/lock.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static const char *kVCamTempFileName      = "vcam_temp.mov";
static const char *kVCamTempPhotoFileName = "vcam_temp.jpg";
static const char *kVCamEnabledFlagName   = "vcam_enabled";
static const char *kVCamPauseFlagName     = "vcam_paused";


#ifdef VCAM_DEBUG
static void VCamDebugLog(NSString *msg) {
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    FILE *f = fopen("/var/tmp/vcam_ui.log", "a");
    if (f) {
        fputs([line UTF8String], f);
        fclose(f);
    }
}
#else
static inline void VCamDebugLog(NSString *msg) {}
#endif

static NSFileManager *gFileManager = nil;
static BOOL gNeedsReaderReload = YES;
static NSDate *gLastTempFileModified = nil;
static int32_t gVideoExifOrientation = 1;

static NSArray<NSString *> *VCamPossibleTmpDirs(void) {
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

static void VCamWriteFlag(const char *name, const char *val) {
    for (NSString *dir in VCamPossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        FILE *f = fopen([filePath UTF8String], "w");
        if (f) {
            if (val) fputs(val, f);
            fclose(f);
        }
        chmod([filePath UTF8String], 0666);
    }
}

static void VCamRemoveFlag(const char *name) {
    for (NSString *dir in VCamPossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        unlink([filePath UTF8String]);
    }
}

static BOOL VCamCheckFileExists(const char *name) {
    for (NSString *dir in VCamPossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        if (access([filePath UTF8String], F_OK) == 0) {
            return YES;
        }
    }
    return NO;
}

static NSString *VCamFindExistingFilePath(const char *name) {
    static NSString *primaryDir = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSString *dir in VCamPossibleTmpDirs()) {
            if (access([dir UTF8String], W_OK | R_OK) == 0) {
                primaryDir = dir;
                break;
            }
        }
        if (!primaryDir) primaryDir = @"/var/tmp";
    });

    NSString *directPath = [primaryDir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
    if (access([directPath UTF8String], F_OK) == 0) {
        return directPath;
    }

    for (NSString *dir in VCamPossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        if (access([filePath UTF8String], F_OK) == 0) {
            return filePath;
        }
    }
    return directPath;
}

static BOOL VCamIsActive(void) {
    // Khóa cứng tầng Camera (mediaserverd & SpringBoard): Bắt buộc phải có token chữ ký số hợp lệ
    if (!VCAMVerifyProcessAuthorization()) {
        return NO;
    }
    return VCamCheckFileExists(kVCamEnabledFlagName);
}

static BOOL VCamIsPaused(void) {
    return VCamCheckFileExists(kVCamPauseFlagName);
}

static CGFloat VCamGetScale(void) {
    return [[VCAMTransformManager sharedManager] scale];
}

static void VCamSetScale(CGFloat scale) {
    [[VCAMTransformManager sharedManager] setScale:scale];
}

static CGFloat VCamGetOffsetX(void) {
    return [[VCAMTransformManager sharedManager] offsetX];
}

static CGFloat VCamGetOffsetY(void) {
    return [[VCAMTransformManager sharedManager] offsetY];
}



static int VCamGetRotation(void) {
    return [[VCAMTransformManager sharedManager] rotation];
}



typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef OSStatus (*VTPixelTransferSessionCreateFunc)(CFAllocatorRef, VTPixelTransferSessionRef *);
typedef OSStatus (*VTPixelTransferSessionTransferImageFunc)(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
typedef OSStatus (*VTSessionSetPropertyFunc)(CFTypeRef, CFStringRef, CFTypeRef);

static VTPixelTransferSessionRef gTransferSession = NULL;
static VTPixelTransferSessionTransferImageFunc gVTPixelTransferSessionTransferImage = NULL;
static os_unfair_lock gTransferLock = OS_UNFAIR_LOCK_INIT;


static OSStatus VCamCopyPixelBuffer(CVPixelBufferRef source, CVPixelBufferRef target) {
    if (!source || !target) return -1;

    size_t srcW = CVPixelBufferGetWidth(source);
    size_t srcH = CVPixelBufferGetHeight(source);
    size_t dstW = CVPixelBufferGetWidth(target);
    size_t dstH = CVPixelBufferGetHeight(target);

    VCAMTransformState transformState = [VCAMTransformManager currentTransformState];
    CGFloat userScale = transformState.scale;
    CGFloat userOffsetX = transformState.offsetX;
    CGFloat userOffsetY = transformState.offsetY;

    // === DIAGNOSTIC: log mỗi 3 giây để xác nhận pipeline đang chạy ===
    {
        static NSTimeInterval sLastEntryLog = 0;
        static int sCallCount = 0;
        sCallCount++;
        NSTimeInterval _t = [NSDate timeIntervalSinceReferenceDate];
        if (_t - sLastEntryLog > 3.0) {
            sLastEntryLog = _t;
            FILE *lf = fopen("/rootfs/private/var/tmp/vcam_pipeline.log", "a");
            if (!lf) lf = fopen("/var/tmp/vcam_pipeline.log", "a");
            if (lf) {
                fprintf(lf, "[VCamPipeline] Entry calls=%d src=%zux%zu dst=%zux%zu\n",
                        sCallCount, srcW, srcH, dstW, dstH);
                fclose(lf);
                chmod("/rootfs/private/var/tmp/vcam_pipeline.log", 0666);
                chmod("/var/tmp/vcam_pipeline.log", 0666);
            }
        }
    }

    // Khởi tạo Metal GPU CIContext một lần duy nhất
    static CIContext *gCIContext = nil;
    static dispatch_once_t gCIOnce;
    dispatch_once(&gCIOnce, ^{
        // Thử Metal context (dùng nil options để tránh crash với [NSNull null] trong mediaserverd sandbox)
        @try {
            id<MTLDevice> device = MTLCreateSystemDefaultDevice();
            if (device) {
                gCIContext = [CIContext contextWithMTLDevice:device options:nil];
            }
        } @catch (...) {}

        // Fallback 1: CIContext không options
        if (!gCIContext) {
            @try { gCIContext = [CIContext context]; } @catch (...) {}
        }

        // Fallback 2: CIContext với Software Renderer tắt
        if (!gCIContext) {
            @try {
                gCIContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @(NO)}];
            } @catch (...) {}
        }

        // Production log — ghi ra file để xác nhận trạng thái Metal/CIContext trong mediaserverd
        const char *status = gCIContext ? "OK" : "FAILED";
        FILE *lf = fopen("/rootfs/private/var/tmp/vcam_pipeline.log", "a");
        if (!lf) lf = fopen("/var/tmp/vcam_pipeline.log", "a");
        if (lf) {
            fprintf(lf, "[VCamPipeline] CIContext init: %s\n", status);
            fclose(lf);
            chmod("/rootfs/private/var/tmp/vcam_pipeline.log", 0666);
            chmod("/var/tmp/vcam_pipeline.log", 0666);
        }
    });

    VCAMFlashState flashState = [VCAMFlashLivenessManager currentFlashState];
    BOOL hasFlash = (flashState.active && flashState.intensity > 0.01f);

    OSStatus status = -1;

    if (gCIContext) {
        CGFloat scale = userScale;
        if (scale < 0.4f) scale = 0.4f;
        if (scale > 2.5f) scale = 2.5f;

        // Xóa sạch buffer target về màu đen khi thu nhỏ hoặc có dịch chuyển để viền ngoài đen sạch sẽ
        if (scale < 0.999f || fabs(userOffsetX) > 0.1f || fabs(userOffsetY) > 0.1f) {
            CVPixelBufferLockBaseAddress(target, 0);
            if (CVPixelBufferIsPlanar(target)) {
                size_t planes = CVPixelBufferGetPlaneCount(target);
                for (size_t p = 0; p < planes; p++) {
                    void *base = CVPixelBufferGetBaseAddressOfPlane(target, p);
                    size_t bpr = CVPixelBufferGetBytesPerRowOfPlane(target, p);
                    size_t rows = CVPixelBufferGetHeightOfPlane(target, p);
                    memset(base, (p == 0) ? 0 : 128, bpr * rows);
                }
            } else {
                void *base = CVPixelBufferGetBaseAddress(target);
                size_t bpr = CVPixelBufferGetBytesPerRow(target);
                size_t rows = CVPixelBufferGetHeight(target);
                memset(base, 0, bpr * rows);
            }
            CVPixelBufferUnlockBaseAddress(target, 0);
        }

        @try {
            CIImage *img = [CIImage imageWithCVPixelBuffer:source];

            // 1. Áp dụng góc xoay bằng GPU (Metal Orientation) - Khử hoàn toàn CPU loop
            int rot = ((transformState.rotation + 270) % 360 + 360) % 360;
            int orientation = 1;
            if (rot == 90)       orientation = 6; // 90 CW
            else if (rot == 180) orientation = 3; // 180
            else if (rot == 270) orientation = 8; // 270 CW (90 CCW)

            if (orientation != 1) {
                img = [img imageByApplyingOrientation:orientation];
            }

            // 2. Áp dụng thu phóng, lật gương và dịch chuyển D-Pad qua GPU
            CGSize currentSize = img.extent.size;
            img = [VCAMTransformManager applyTransformToImage:img
                                                      srcSize:currentSize
                                                      dstSize:CGSizeMake(dstW, dstH)
                                                        state:transformState];

            // 3. Áp dụng hiệu ứng ánh sáng phản quang KYC Flash Liveness
            if (hasFlash) {
                img = [VCAMFlashLivenessManager applyFlashLightingToImage:img size:CGSizeMake(dstW, dstH) state:flashState];
            }

            // 3.1. Áp dụng cú chớp sáng Flash Burst phản quang (Catchlight & Specular Highlight)
            if ([VCAMFlashBurstManager isFlashBurstActive]) {
                img = [VCAMFlashBurstManager applyFlashBurstToImage:img size:CGSizeMake(dstW, dstH)];
            }

            // 3.2. Áp dụng Đổ bóng tạo khối 3D khuôn mặt & Hạt nhiễu cảm biến camera (3D Shading & CMOS Sensor Grain)
            VCAMShadingState shadingState = [VCAMShadingManager currentShadingState];
            img = [VCAMShadingManager apply3DShadingAndGrainToImage:img size:CGSizeMake(dstW, dstH) state:shadingState];

            // 4. Render trực tiếp vào target CVPixelBuffer bằng GPU Metal trong 1 pass duy nhất
            [gCIContext render:img toCVPixelBuffer:target bounds:CGRectMake(0, 0, dstW, dstH) colorSpace:nil];
            status = noErr;
        } @catch (NSException *e) {
            // Ghi exception ra file để debug trong mediaserverd
            static NSTimeInterval sLastErrLog = 0;
            NSTimeInterval _now = [NSDate timeIntervalSinceReferenceDate];
            if (_now - sLastErrLog > 2.0) {
                sLastErrLog = _now;
                FILE *ef = fopen("/rootfs/private/var/tmp/vcam_pipeline.log", "a");
                if (!ef) ef = fopen("/var/tmp/vcam_pipeline.log", "a");
                if (ef) {
                    fprintf(ef, "[VCamPipeline] @try exception: %s\n", [[e description] UTF8String]);
                    fclose(ef);
                    chmod("/rootfs/private/var/tmp/vcam_pipeline.log", 0666);
                }
            }
        }
    }

    // Fallback VideoToolbox nếu GPU context không sẵn sàng
    if (status != noErr) {
        os_unfair_lock_lock(&gTransferLock);
        static VTPixelTransferSessionCreateFunc createFunc = NULL;
        static VTSessionSetPropertyFunc setPropFunc = NULL;
        static dispatch_once_t gSymbolsOnce;
        dispatch_once(&gSymbolsOnce, ^{
            dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW | RTLD_GLOBAL);
            createFunc = (VTPixelTransferSessionCreateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionCreate");
            gVTPixelTransferSessionTransferImage = (VTPixelTransferSessionTransferImageFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionTransferImage");
            setPropFunc = (VTSessionSetPropertyFunc)dlsym(RTLD_DEFAULT, "VTSessionSetProperty");
        });

        static size_t gLastSrcW = 0, gLastSrcH = 0;
        static size_t gLastDstW = 0, gLastDstH = 0;
        OSType srcFmt = CVPixelBufferGetPixelFormatType(source);
        OSType dstFmt = CVPixelBufferGetPixelFormatType(target);
        static OSType gLastSrcFmt = 0, gLastDstFmt = 0;

        if (!gTransferSession || srcW != gLastSrcW || srcH != gLastSrcH || dstW != gLastDstW || dstH != gLastDstH || srcFmt != gLastSrcFmt || dstFmt != gLastDstFmt) {
            if (gTransferSession) {
                CFRelease(gTransferSession);
                gTransferSession = NULL;
            }
            if (createFunc && gVTPixelTransferSessionTransferImage) {
                OSStatus err = createFunc(kCFAllocatorDefault, &gTransferSession);
                if (err == noErr && gTransferSession && setPropFunc) {
                    setPropFunc(gTransferSession, CFSTR("ScalingMode"), CFSTR("Normal"));
                }
            }
            gLastSrcW = srcW; gLastSrcH = srcH;
            gLastDstW = dstW; gLastDstH = dstH;
            gLastSrcFmt = srcFmt; gLastDstFmt = dstFmt;
        }

        if (gTransferSession && gVTPixelTransferSessionTransferImage) {
            status = gVTPixelTransferSessionTransferImage(gTransferSession, source, target);
        }
        os_unfair_lock_unlock(&gTransferLock);
    }

    return status;
}

static AVAsset                  *gAsset = nil;
static AVAssetTrack             *gVideoTrack = nil;
static AVAssetReader            *gAssetReader = nil;
static AVAssetReaderTrackOutput *gTrackOutput = nil;
static OSType                    gReaderFormat = 0;
static CVPixelBufferRef          gCachedPixelBuffer = nil;
static CMSampleBufferRef         gNextSampleBuffer = nil;
static Float64                   gNextFramePTS = 0.0;
static CFTimeInterval            gPlaybackStartRealTime = 0;
static Float64                   gCachedDuration = 0.0;
static float                     gVideoFPS = 30.0f;
static NSString                 *gLoadedVideoPath = nil;

static CVPixelBufferRef gRawPhotoBuffer = NULL;

static void VCamResetReader(void) {
    if (gCachedPixelBuffer) {
        CFRelease(gCachedPixelBuffer);
        gCachedPixelBuffer = NULL;
    }
    if (gRawPhotoBuffer) {
        CFRelease(gRawPhotoBuffer);
        gRawPhotoBuffer = NULL;
    }
    if (gNextSampleBuffer) {
        CFRelease(gNextSampleBuffer);
        gNextSampleBuffer = nil;
    }
    if (gAssetReader) {
        [gAssetReader cancelReading];
        gAssetReader = nil;
    }
    gTrackOutput = nil;
    gVideoTrack = nil;
    gAsset = nil;
}

static BOOL VCamSetupReader(NSString *videoPath, OSType subtype) {
    VCamResetReader();

    if (!videoPath || access([videoPath UTF8String], F_OK) != 0) return NO;

    NSURL *url = [NSURL fileURLWithPath:videoPath];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
    AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!track) return NO;

    double angle = atan2(track.preferredTransform.b, track.preferredTransform.a);
    if (fabs(angle - M_PI_2) < 0.05)          gVideoExifOrientation = 6;
    else if (fabs(angle + M_PI_2) < 0.05)     gVideoExifOrientation = 8;
    else if (fabs(fabs(angle) - M_PI) < 0.05) gVideoExifOrientation = 3;
    else                                       gVideoExifOrientation = 1;

    OSType outputFormat = subtype;
    if (outputFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        outputFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
        outputFormat != kCVPixelFormatType_32BGRA) {
        outputFormat = kCVPixelFormatType_32BGRA;
    }

    NSError *err = nil;
    AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!r) return NO;

    AVAssetReaderTrackOutput *outp = [[AVAssetReaderTrackOutput alloc]
        initWithTrack:track
        outputSettings:@{
            (id)kCVPixelBufferPixelFormatTypeKey: @(outputFormat),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        }];
    outp.alwaysCopiesSampleData = NO;
    [r addOutput:outp];

    if (![r startReading]) {
        return NO;
    }

    gAsset = asset;
    gVideoTrack = track;
    gAssetReader = r;
    gTrackOutput = outp;
    gReaderFormat = outputFormat;

    Float64 dur = CMTimeGetSeconds(asset.duration);
    gCachedDuration = (dur > 0.05) ? dur : 1.0;

    float f = track.nominalFrameRate;
    gVideoFPS = (f >= 1.0f && f <= 120.0f) ? f : 30.0f;

    // Đọc ngay frame đầu tiên vào gCachedPixelBuffer (Zero-copy retain)
    CMSampleBufferRef firstBuf = [gTrackOutput copyNextSampleBuffer];
    if (firstBuf) {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(firstBuf);
        if (pb) {
            CFRetain(pb);
            if (gCachedPixelBuffer) CFRelease(gCachedPixelBuffer);
            gCachedPixelBuffer = pb;
        }
        CFRelease(firstBuf);
    }

    // Pre-fetch frame thứ hai và lấy PTS
    gNextSampleBuffer = [gTrackOutput copyNextSampleBuffer];
    if (gNextSampleBuffer) {
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(gNextSampleBuffer);
        gNextFramePTS = CMTimeGetSeconds(pts);
    } else {
        gNextFramePTS = gCachedDuration;
    }

    return YES;
}

static CVPixelBufferRef VCamGetPixelBufferMatching(CMSampleBufferRef originSampleBuffer) {
    if (!originSampleBuffer) return NULL;

    CFTimeInterval now = CACurrentMediaTime();

    // Throttled flag check (chỉ kiểm tra cờ mỗi 0.3s để giảm I/O trên camera thread)
    static BOOL gCachedActive = NO;
    static BOOL gCachedPaused = NO;
    static int  gCachedRotation = -1;
    static CFTimeInterval gLastFlagCheck = 0;
    if (now - gLastFlagCheck > 0.3) {
        gLastFlagCheck = now;
        gCachedActive = VCamIsActive() && (VCamCheckFileExists(kVCamTempFileName) || VCamCheckFileExists(kVCamTempPhotoFileName));
        gCachedPaused = VCamIsPaused();
        int rot = VCamGetRotation();
        if (rot != gCachedRotation) {
            if (gCachedRotation != -1) {
                gNeedsReaderReload = YES;
            }
            gCachedRotation = rot;
        }
    }

    if (!gCachedActive) return NULL;

    CMFormatDescriptionRef originFormat = CMSampleBufferGetFormatDescription(originSampleBuffer);
    if (!originFormat || CMFormatDescriptionGetMediaType(originFormat) != kCMMediaType_Video) return NULL;

    OSType originSubtype = CMFormatDescriptionGetMediaSubType(originFormat);

    // ── Xử lý tính năng Tạm dừng (Pause / Freeze Frame) ──
    if (gCachedPaused && gCachedPixelBuffer) {
        return gCachedPixelBuffer;
    }

    // Throttled file check (quét file mới nhất mỗi 0.5s)
    static NSString *gActiveTempPath = nil;
    static CFTimeInterval gLastPathCheck = 0;
    static BOOL gIsPhotoMode = NO;
    if (now - gLastPathCheck > 0.5 || !gActiveTempPath) {
        gLastPathCheck = now;
        NSString *foundPhoto = VCamFindExistingFilePath(kVCamTempPhotoFileName);
        NSString *foundVideo = VCamFindExistingFilePath(kVCamTempFileName);

        NSString *found = nil;
        BOOL isPhoto = NO;
        if (foundPhoto && access([foundPhoto UTF8String], R_OK) == 0) {
            found = foundPhoto;
            isPhoto = YES;
        } else if (foundVideo && access([foundVideo UTF8String], R_OK) == 0) {
            found = foundVideo;
            isPhoto = NO;
        }

        if (![found isEqualToString:gActiveTempPath] || isPhoto != gIsPhotoMode) {
            gActiveTempPath = found;
            gIsPhotoMode = isPhoto;
            gNeedsReaderReload = YES;
            if (gRawPhotoBuffer) {
                CFRelease(gRawPhotoBuffer);
                gRawPhotoBuffer = NULL;
            }
            if (gCachedPixelBuffer) {
                CFRelease(gCachedPixelBuffer);
                gCachedPixelBuffer = NULL;
            }
        }
        if (gActiveTempPath) {
            NSDate *modified = [[NSFileManager defaultManager] attributesOfItemAtPath:gActiveTempPath error:nil].fileModificationDate;
            if (modified && ![modified isEqualToDate:gLastTempFileModified]) {
                gLastTempFileModified = modified;
                gNeedsReaderReload = YES;
                if (gRawPhotoBuffer) {
                    CFRelease(gRawPhotoBuffer);
                    gRawPhotoBuffer = NULL;
                }
                if (gCachedPixelBuffer) {
                    CFRelease(gCachedPixelBuffer);
                    gCachedPixelBuffer = NULL;
                }
            }
        }
    }

    if (!gIsPhotoMode && gReaderFormat != originSubtype) gNeedsReaderReload = YES;

    // ── NẠP ẢNH TĨNH (PHOTO MODE) ──
    if (gIsPhotoMode) {
        if (gNeedsReaderReload || !gCachedPixelBuffer) {
            if (!gRawPhotoBuffer && gActiveTempPath) {
                gRawPhotoBuffer = [VCAMPhotoManager createPixelBufferFromImageFile:gActiveTempPath];
            }
            if (gCachedPixelBuffer) {
                CFRelease(gCachedPixelBuffer);
                gCachedPixelBuffer = NULL;
            }
            if (gRawPhotoBuffer) {
                CFRetain(gRawPhotoBuffer);
                gCachedPixelBuffer = gRawPhotoBuffer;
            }
            gNeedsReaderReload = NO;
        }

        return gCachedPixelBuffer;
    }

    // Khởi tạo hoặc tải lại reader nếu cần
    if (gNeedsReaderReload || !gAssetReader || gAssetReader.status != AVAssetReaderStatusReading) {
        BOOL ok = VCamSetupReader(gActiveTempPath, originSubtype);
        if (!ok) {
            gNeedsReaderReload = YES;
            return gCachedPixelBuffer;
        }

        gNeedsReaderReload = NO;
        gPlaybackStartRealTime = now;
    }

    if (gPlaybackStartRealTime == 0) gPlaybackStartRealTime = now;
    CFTimeInterval elapsed = now - gPlaybackStartRealTime;

    // Seamless Infinite Loop: Tái sinh reader khi hết thời lượng video
    if (gCachedDuration > 0.05 && elapsed >= gCachedDuration) {
        gPlaybackStartRealTime = now;
        elapsed = 0;
        VCamSetupReader(gActiveTempPath, gReaderFormat);
    }

    // Tiến trình hiển thị frame theo đúng PTS thực của video (Zero-copy retain)
    // Giới hạn tối đa 2 frame mỗi nhịp để không bao giờ block luồng camera thời gian thực
    int advanceCount = 0;
    while (gNextSampleBuffer && elapsed >= gNextFramePTS && advanceCount < 2) {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(gNextSampleBuffer);
        if (pb) {
            CFRetain(pb);
            if (gCachedPixelBuffer) CFRelease(gCachedPixelBuffer);
            gCachedPixelBuffer = pb;
        }
        CFRelease(gNextSampleBuffer);
        gNextSampleBuffer = [gTrackOutput copyNextSampleBuffer];
        if (gNextSampleBuffer) {
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(gNextSampleBuffer);
            gNextFramePTS = CMTimeGetSeconds(pts);
        } else {
            gNextFramePTS = gCachedDuration;
        }
        advanceCount++;
    }

    // Cơ chế chống treo máy khi app vào background hoặc camera bị lag:
    // Nếu thời gian elapsed vượt quá xa frame hiện tại (> 0.1s), đồng bộ lại clock thay vì decode dồn dập
    if (gNextSampleBuffer && elapsed > gNextFramePTS + 0.1) {
        gPlaybackStartRealTime = now - gNextFramePTS;
    }

    return gCachedPixelBuffer;
}

static void (*orig_BWNodeOutput_emitSampleBuffer)(id, SEL, CMSampleBufferRef) = NULL;
static void hook_BWNodeOutput_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    if (!sampleBuffer) {
        if (orig_BWNodeOutput_emitSampleBuffer) orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }

    @autoreleasepool {
        CVPixelBufferRef targetPb = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (targetPb) {
            // Do not re-process buffers that have already been swapped by VCam in an upstream node
            static const CFStringRef kVCamProcessedKey = CFSTR("kVCamProcessedBuffer");
            if (!CVBufferGetAttachment(targetPb, kVCamProcessedKey, NULL)) {
                CVPixelBufferRef srcPb = VCamGetPixelBufferMatching(sampleBuffer);
                if (srcPb) {
                    OSStatus err = VCamCopyPixelBuffer(srcPb, targetPb);
                    if (err == noErr) {
                        CVBufferSetAttachment(targetPb, kVCamProcessedKey, kCFBooleanTrue, kCVAttachmentMode_ShouldPropagate);
                    }
                }
            }
        }
    }

    if (orig_BWNodeOutput_emitSampleBuffer) orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
}

static void HookIfPresent(const char *className, SEL selector, IMP replacement, IMP *original) {
    Class cls = objc_getClass(className);
    if (!cls) {
        NSLog(@"[vcamios] class missing: %s", className);
        return;
    }
    MSHookMessageEx(cls, selector, replacement, original);
    NSLog(@"[vcamios] hooked %s %@", className, NSStringFromSelector(selector));
}

static void VCamInitMediaServerHooks(void) {
    HookIfPresent("BWNodeOutput", @selector(emitSampleBuffer:),
                  (IMP)&hook_BWNodeOutput_emitSampleBuffer,
                  (IMP *)&orig_BWNodeOutput_emitSampleBuffer);

    NSLog(@"[vcamios] mediaserverd hooks loaded; source=%s", kVCamTempFileName);
}

// ─── SpringBoard UI (Compact Square HUD Layout ~175x175) ───────────────────

static void VCamFloatRefreshButton(void);
static void VCamFloatHideMenu(void);
static UIViewController *VCamPresenter(void);

@interface VCamFloatWindow : UIWindow
@end
@implementation VCamFloatWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    if (hit) VCamDebugLog([NSString stringWithFormat:@"[Window hitTest] pt=(%.0f,%.0f) hit=%@", point.x, point.y, [hit class]]);
    return hit;
}
@end

@interface VCamFloat : NSObject <UIGestureRecognizerDelegate>
+ (void)show;
+ (UIViewController *)presenter;
+ (void)refreshButton;
+ (void)hideMenu;
@end

@implementation VCamFloat {
    UIWindow *_win;
    UIViewController *_rootVC;
    UIButton *_btn;
    UIView  *_menuOverlay;
    UIView  *_panel;
    UISlider *_zoomSlider;
    UISegmentedControl *_modeControl;
    int _topSliderMode; // 0: Zoom, 1: Flash, 2: 3D & Grain
    CGFloat _curOffsetX;
    CGFloat _curOffsetY;
}

static VCamFloat *gVCamFloat = nil;
static CGRect sTweakButtonFrame;
static CGRect sTweakPanelFrame;
static BOOL sTweakPanelVisible = NO;

BOOL VCamIsScreenPointInTweakUI(CGFloat normX, CGFloat normY) {
    CGRect screen = UIScreen.mainScreen.bounds;
    if (screen.size.width <= 0 || screen.size.height <= 0) return NO;
    CGPoint pt = CGPointMake(normX * screen.size.width, normY * screen.size.height);
    if (!CGRectIsEmpty(sTweakButtonFrame) && CGRectContainsPoint(CGRectInset(sTweakButtonFrame, -8, -8), pt)) {
        return YES;
    }
    if (sTweakPanelVisible && !CGRectIsEmpty(sTweakPanelFrame) && CGRectContainsPoint(CGRectInset(sTweakPanelFrame, -8, -8), pt)) {
        return YES;
    }
    return NO;
}

+ (void)show {
    if (!gVCamFloat) gVCamFloat = [self new];
    [gVCamFloat _setup];
}

+ (UIViewController *)presenter {
    return gVCamFloat ? gVCamFloat->_rootVC : nil;
}

+ (void)refreshButton {
    if (!gVCamFloat) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL isLicensed = [[VCAMLicenseManager sharedManager] isLicenseValid];
        BOOL active = VCamIsActive();
        BOOL isPaused = VCamIsPaused();
        if (!isLicensed) {
            [gVCamFloat->_btn setTitle:@"🔒" forState:UIControlStateNormal];
            gVCamFloat->_btn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
            gVCamFloat->_btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.60].CGColor;
            gVCamFloat->_btn.layer.borderWidth = 1.2;
            gVCamFloat->_btn.alpha = 0.50;
        } else if (!active) {
            [gVCamFloat->_btn setTitle:@"📷" forState:UIControlStateNormal];
            gVCamFloat->_btn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
            gVCamFloat->_btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.60].CGColor;
            gVCamFloat->_btn.layer.borderWidth = 1.2;
            gVCamFloat->_btn.alpha = 0.50;
        } else {
            [gVCamFloat->_btn setTitle:isPaused ? @"⏸️" : @"🎥" forState:UIControlStateNormal];
            // KHI ĐÃ HOOK VIDEO: MÀU NỀN ĐỎ RỰC RỠ THEO YÊU CẦU CỦA USER
            gVCamFloat->_btn.backgroundColor = [UIColor colorWithRed:0.88 green:0.18 blue:0.18 alpha:0.90];
            gVCamFloat->_btn.layer.borderColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:0.95].CGColor;
            gVCamFloat->_btn.layer.borderWidth = 2.0;
            gVCamFloat->_btn.alpha = 0.95;
        }
    });
}

+ (void)hideMenu {
    if (gVCamFloat) [gVCamFloat _hideMenu];
}

- (void)_setup {
    if (_win) {
        _win.hidden = NO;
        return;
    }
    CGFloat sz = 58;
    CGRect screen = UIScreen.mainScreen.bounds;

    UIWindowScene *targetScene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                targetScene = (UIWindowScene *)s;
                break;
            }
        }
        if (!targetScene) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    targetScene = (UIWindowScene *)s;
                    break;
                }
            }
        }
    }

    if (targetScene) {
        _win = [[VCamFloatWindow alloc] initWithWindowScene:targetScene];
    } else {
        _win = [[VCamFloatWindow alloc] initWithFrame:screen];
    }

    _win.frame = screen;
    _win.windowLevel = 10000001.0;
    _win.backgroundColor = [UIColor clearColor];

    _rootVC = [UIViewController new];
    _rootVC.view.backgroundColor = [UIColor clearColor];
    _rootVC.view.userInteractionEnabled = NO;
    _win.rootViewController = _rootVC;

    // Mini Floating Ball (Enlarged to 58x58)
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, sz, sz);
    btn.center = CGPointMake(screen.size.width - sz / 2 - 10, screen.size.height * 0.40);
    btn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    btn.layer.cornerRadius = sz / 2;
    btn.layer.borderWidth = 1.5;
    btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.60].CGColor;
    [btn setTitle:@"📷" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:26];
    btn.userInteractionEnabled = YES;
    [btn addTarget:self action:@selector(_tap) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(_pan:)];
    [btn addGestureRecognizer:pan];
    [_rootVC.view addSubview:btn];
    _rootVC.view.userInteractionEnabled = YES;
    _btn = btn;
    sTweakButtonFrame = btn.frame;
    _win.hidden = NO;

    [VCamFloat refreshButton];
    [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(_periodicRefresh) userInfo:nil repeats:YES];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"kVCAMMediaChangedNotification" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        [VCamFloat refreshButton];
    }];

    if (@available(iOS 13.0, *)) {
        [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
            if ([note.object isKindOfClass:[UIWindowScene class]]) {
                self->_win.windowScene = (UIWindowScene *)note.object;
                self->_win.hidden = NO;
            }
        }];
    }
}

- (void)_periodicRefresh {
    [VCamFloat refreshButton];
}

- (void)_tap {
    if (![[VCAMLicenseManager sharedManager] isLicenseValid]) {
        [[VCAMLicenseManager sharedManager] promptActivationDialogWithReason:nil presenter:_rootVC];
        return;
    }
    if (_menuOverlay) { [self _hideMenu]; return; }
    [self _showMenu];
}

- (void)_hideMenu {
    VCamDebugLog(@"[UI] _hideMenu");
    sTweakPanelVisible = NO;
    UIView *ov = _menuOverlay;
    UIView *pan = _panel;
    _menuOverlay = nil;
    _panel = nil;
    [UIView animateWithDuration:0.2 animations:^{
        if (ov) ov.alpha = 0;
        if (pan) pan.alpha = 0;
    } completion:^(__unused BOOL f) {
        [ov removeFromSuperview];
        [pan removeFromSuperview];
    }];
}

- (UIButton *)_dpadButtonWithTitle:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h sel:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, h);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.32];
    b.layer.cornerRadius = 9;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.48].CGColor;
    b.showsTouchWhenHighlighted = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)_iconButtonWithTitle:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h color:(UIColor *)color sel:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, h);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:color forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:18];
    b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.40].CGColor;
    b.showsTouchWhenHighlighted = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)_showMenu {
    VCamDebugLog(@"[UI] _showMenu");
    BOOL isPaused = VCamIsPaused();
    CGFloat currentScale = VCamGetScale();
    _curOffsetX = VCamGetOffsetX();
    _curOffsetY = VCamGetOffsetY();

    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat w = 230, h = 262;

    // 1. Fully clear touch-outside dismiss overlay (behind panel)
    UIView *overlay = [[UIView alloc] initWithFrame:screen];
    overlay.backgroundColor = [UIColor clearColor];
    overlay.userInteractionEnabled = YES;
    UITapGestureRecognizer *dismiss = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_hideMenu)];
    [overlay addGestureRecognizer:dismiss];
    [_rootVC.view insertSubview:overlay belowSubview:_btn];
    _menuOverlay = overlay;

    CGFloat panelX = (_btn.center.x > screen.size.width / 2)
        ? _btn.frame.origin.x - w - 8
        : CGRectGetMaxX(_btn.frame) + 8;
    panelX = MAX(8, MIN(panelX, screen.size.width - w - 8));
    CGFloat panelY = MIN(_btn.center.y - h / 2,
                         screen.size.height - h - 15);
    panelY = MAX(15, panelY);

    // Enlarged Rounded Square Panel (230x262)
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(panelX, panelY, w, h)];
    panel.backgroundColor = [UIColor clearColor];
    panel.layer.cornerRadius = 22;
    panel.layer.masksToBounds = YES;
    _panel = panel;
    sTweakPanelFrame = panel.frame;
    sTweakPanelVisible = YES;

    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blurView.frame = panel.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.alpha = 0.25;
    blurView.userInteractionEnabled = NO;
    [panel addSubview:blurView];

    UIView *tintOverlay = [[UIView alloc] initWithFrame:panel.bounds];
    tintOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.22];
    tintOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tintOverlay.layer.borderWidth = 1.0;
    tintOverlay.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.40].CGColor;
    tintOverlay.layer.cornerRadius = 22;
    tintOverlay.userInteractionEnabled = NO;
    [panel addSubview:tintOverlay];

    // ── 0. Top Mode Selector: [ 🔍 Zoom ] vs [ ⚡ Flash ] vs [ 🎭 3D ] ──
    UISegmentedControl *modeCtrl = [[UISegmentedControl alloc] initWithItems:@[@"🔍 Zoom", @"⚡ Flash", @"🎭 3D"]];
    modeCtrl.frame = CGRectMake((w - 212) / 2.0, 8, 212, 26);
    modeCtrl.selectedSegmentIndex = _topSliderMode;
    if (@available(iOS 13.0, *)) {
        modeCtrl.selectedSegmentTintColor = [UIColor colorWithWhite:1.0 alpha:0.25];
        [modeCtrl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor], NSFontAttributeName: [UIFont boldSystemFontOfSize:11]} forState:UIControlStateNormal];
        [modeCtrl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithRed:0.3 green:0.85 blue:1.0 alpha:1.0], NSFontAttributeName: [UIFont boldSystemFontOfSize:11]} forState:UIControlStateSelected];
    }
    [modeCtrl addTarget:self action:@selector(_sliderModeChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:modeCtrl];
    _modeControl = modeCtrl;

    // ── 1. Top: Slider with [-] and [+] ──
    CGFloat minusBtnW = 32, plusBtnW = 32, ctrlY = 38, ctrlH = 30;
    UIButton *minusBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    minusBtn.frame = CGRectMake(10, ctrlY, minusBtnW, ctrlH);
    minusBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.32];
    minusBtn.layer.cornerRadius = 8;
    minusBtn.layer.borderWidth = 0.8;
    minusBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.40].CGColor;
    minusBtn.showsTouchWhenHighlighted = YES;
    [minusBtn setTitle:@"−" forState:UIControlStateNormal];
    [minusBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    minusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [minusBtn addTarget:self action:@selector(_zoomMinus) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:minusBtn];

    CGFloat sliderX = CGRectGetMaxX(minusBtn.frame) + 6;
    CGFloat sliderW = w - sliderX - plusBtnW - 10 - 6;
    _zoomSlider = [[UISlider alloc] initWithFrame:CGRectMake(sliderX, ctrlY, sliderW, ctrlH)];
    if (_topSliderMode == 1) {
        _zoomSlider.minimumValue = 0.10f;
        _zoomSlider.maximumValue = 0.90f;
        _zoomSlider.value = [[VCAMFlashLivenessManager sharedManager] flashIntensity];
        _zoomSlider.tintColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.18 alpha:1.0];
    } else if (_topSliderMode == 2) {
        _zoomSlider.minimumValue = 0.05f;
        _zoomSlider.maximumValue = 1.00f;
        _zoomSlider.value = [[VCAMShadingManager sharedManager] shadingIntensity];
        _zoomSlider.tintColor = [UIColor colorWithRed:0.85 green:0.45 blue:1.0 alpha:1.0];
    } else {
        _zoomSlider.minimumValue = 0.4f;
        _zoomSlider.maximumValue = 2.5f;
        _zoomSlider.value = currentScale;
        _zoomSlider.tintColor = [UIColor colorWithRed:0.3 green:0.85 blue:1.0 alpha:1.0];
    }
    [_zoomSlider addTarget:self action:@selector(_sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:_zoomSlider];

    UIButton *plusBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    plusBtn.frame = CGRectMake(w - plusBtnW - 10, ctrlY, plusBtnW, ctrlH);
    plusBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.32];
    plusBtn.layer.cornerRadius = 8;
    plusBtn.layer.borderWidth = 0.8;
    plusBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.40].CGColor;
    plusBtn.showsTouchWhenHighlighted = YES;
    [plusBtn setTitle:@"+" forState:UIControlStateNormal];
    [plusBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    plusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [plusBtn addTarget:self action:@selector(_zoomPlus) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:plusBtn];

    // ── 2. Middle: Enlarged D-Pad 4-Way Cross Controller + Rotate Control ──
    CGFloat dBtnW = 46, dBtnH = 36;
    CGFloat midX = (w - dBtnW) / 2.0;

    // Rotate Button (🔄) at top-left of D-Pad
    UIButton *rotBtn = [self _dpadButtonWithTitle:@"🔄" x:12 y:74 w:44 h:dBtnH sel:@selector(_menuRotateVideo)];
    rotBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    [panel addSubview:rotBtn];

    // Mirror Flip Button (🪞) at top-right of D-Pad
    BOOL isFlipped = [[VCAMTransformManager sharedManager] isMirrorFlipped];
    UIButton *flipBtn = [self _dpadButtonWithTitle:@"🪞" x:w - 44 - 12 y:74 w:44 h:dBtnH sel:@selector(_toggleMirrorFlip:)];
    flipBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    if (isFlipped) {
        flipBtn.backgroundColor = [UIColor colorWithRed:0.3 green:0.75 blue:1.0 alpha:0.38];
        flipBtn.layer.borderColor = [UIColor colorWithRed:0.3 green:0.85 blue:1.0 alpha:0.95].CGColor;
    }
    [panel addSubview:flipBtn];

    // Up
    [panel addSubview:[self _dpadButtonWithTitle:@"▲" x:midX y:74 w:dBtnW h:dBtnH sel:@selector(_moveUp)]];

    // Left | Center | Right
    CGFloat row2Y = 74 + dBtnH + 4;
    [panel addSubview:[self _dpadButtonWithTitle:@"◀" x:midX - dBtnW - 6 y:row2Y w:dBtnW h:dBtnH sel:@selector(_moveLeft)]];
    [panel addSubview:[self _dpadButtonWithTitle:@"●" x:midX y:row2Y w:dBtnW h:dBtnH sel:@selector(_moveReset)]];
    [panel addSubview:[self _dpadButtonWithTitle:@"▶" x:midX + dBtnW + 6 y:row2Y w:dBtnW h:dBtnH sel:@selector(_moveRight)]];

    // Down
    CGFloat row3Y = row2Y + dBtnH + 4;
    [panel addSubview:[self _dpadButtonWithTitle:@"▼" x:midX y:row3Y w:dBtnW h:dBtnH sel:@selector(_moveDown)]];

    // KYC Flash Liveness Toggle (⚡) at bottom-left of D-Pad
    BOOL isFlashOn = [[VCAMFlashLivenessManager sharedManager] isLivenessEnabled];
    UIButton *flashBtn = [self _dpadButtonWithTitle:@"⚡" x:12 y:row3Y w:44 h:dBtnH sel:@selector(_toggleKYCFlash:)];
    flashBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    if (isFlashOn) {
        flashBtn.backgroundColor = [UIColor colorWithRed:0.20 green:0.80 blue:0.40 alpha:0.35];
        flashBtn.layer.borderColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.9].CGColor;
    }
    [panel addSubview:flashBtn];

    // Chớp Sáng Phản Quang Flash Burst (📸) tại góc dưới bên phải D-Pad (1 chạm chớp 0.45s)
    UIButton *burstBtn = [self _dpadButtonWithTitle:@"📸" x:w - 44 - 12 y:row3Y w:44 h:dBtnH sel:@selector(_triggerFlashBurst:)];
    burstBtn.titleLabel.font = [UIFont systemFontOfSize:18];
    [panel addSubview:burstBtn];

    // ── 3. Bottom: 6 Action Icon Buttons (Horizontal Row, 32x38) ──
    CGFloat iconW = 32, iconH = 38, iconY = 208;
    CGFloat iconSpacing = 4;
    CGFloat totalIconsW = 6 * iconW + 5 * iconSpacing;
    CGFloat startIconX = (w - totalIconsW) / 2.0;

    // Icon 1: Chọn video (🎬)
    UIButton *pickBtn = [self _iconButtonWithTitle:@"🎬" x:startIconX y:iconY w:iconW h:iconH color:[UIColor whiteColor] sel:@selector(_menuSelectVideo)];
    [panel addSubview:pickBtn];

    // Icon 2: Chọn ảnh tĩnh (🖼️)
    UIButton *photoBtn = [self _iconButtonWithTitle:@"🖼️" x:startIconX + (iconW + iconSpacing) * 1 y:iconY w:iconW h:iconH color:[UIColor whiteColor] sel:@selector(_menuSelectPhoto)];
    [panel addSubview:photoBtn];

    // Icon 3: Tạm dừng / Tiếp tục (⏸️ / ▶️)
    NSString *pauseIcon = isPaused ? @"▶️" : @"⏸️";
    UIColor *pauseCol = isPaused ? [UIColor colorWithRed:0.4 green:0.95 blue:0.5 alpha:1] : [UIColor colorWithRed:1.0 green:0.85 blue:0.3 alpha:1];
    UIButton *pauseBtn = [self _iconButtonWithTitle:pauseIcon x:startIconX + (iconW + iconSpacing) * 2 y:iconY w:iconW h:iconH color:pauseCol sel:@selector(_menuTogglePause)];
    [panel addSubview:pauseBtn];

    // Icon 4: Quản lý Key / Hạn dùng (🔑)
    UIButton *licBtn = [self _iconButtonWithTitle:@"🔑" x:startIconX + (iconW + iconSpacing) * 3 y:iconY w:iconW h:iconH color:[UIColor colorWithRed:0.6 green:0.8 blue:1.0 alpha:1] sel:@selector(_menuShowLicense)];
    [panel addSubview:licBtn];

    // Icon 5: Xóa video / ảnh (🗑️)
    UIButton *trashBtn = [self _iconButtonWithTitle:@"🗑️" x:startIconX + (iconW + iconSpacing) * 4 y:iconY w:iconW h:iconH color:[UIColor colorWithRed:1 green:0.45 blue:0.45 alpha:1] sel:@selector(_menuDisable)];
    [panel addSubview:trashBtn];

    // Icon 6: Đóng (✕)
    UIButton *closeBtn = [self _iconButtonWithTitle:@"✕" x:startIconX + (iconW + iconSpacing) * 5 y:iconY w:iconW h:iconH color:[UIColor colorWithWhite:0.85 alpha:1] sel:@selector(_hideMenu)];
    [panel addSubview:closeBtn];

    [_rootVC.view insertSubview:panel aboveSubview:overlay];
    _panel = panel;

    overlay.alpha = 0;
    panel.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{
        overlay.alpha = 1.0;
        panel.alpha = 1.0;
    }];
}

- (void)_showToast:(NSString *)msg {
    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 160, 38)];
    lbl.center = CGPointMake(_rootVC.view.bounds.size.width / 2, _rootVC.view.bounds.size.height * 0.35);
    lbl.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];
    lbl.textColor = [UIColor whiteColor];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.font = [UIFont boldSystemFontOfSize:14];
    lbl.text = msg;
    lbl.layer.cornerRadius = 10;
    lbl.layer.masksToBounds = YES;
    lbl.alpha = 0;
    [_rootVC.view addSubview:lbl];
    [UIView animateWithDuration:0.2 animations:^{
        lbl.alpha = 1.0;
    } completion:^(BOOL fin1) {
        [UIView animateWithDuration:0.2 delay:0.6 options:0 animations:^{
            lbl.alpha = 0;
        } completion:^(BOOL fin2) {
            [lbl removeFromSuperview];
        }];
    }];
}

- (void)_menuRotateVideo {
    int next = [[VCAMTransformManager sharedManager] rotate90];
    [self _hideMenu];
    [self _showToast:[NSString stringWithFormat:@"Đã xoay: %d°", next]];
}

- (void)_sliderModeChanged:(UISegmentedControl *)sender {
    _topSliderMode = (int)sender.selectedSegmentIndex;
    if (_topSliderMode == 1) { // ⚡ Flash
        if (![[VCAMFlashLivenessManager sharedManager] isLivenessEnabled]) {
            [[VCAMFlashLivenessManager sharedManager] setLivenessEnabled:YES];
        }
        CGFloat curIntensity = [[VCAMFlashLivenessManager sharedManager] flashIntensity];
        _zoomSlider.minimumValue = 0.10f;
        _zoomSlider.maximumValue = 0.90f;
        _zoomSlider.value = curIntensity;
        _zoomSlider.tintColor = [UIColor colorWithRed:1.0 green:0.82 blue:0.18 alpha:1.0];
        [self _showToast:[NSString stringWithFormat:@"⚡ Độ đậm: %.0f%%", curIntensity * 100.0f]];
    } else if (_topSliderMode == 2) { // 🎭 3D & Hạt
        CGFloat curShading = [[VCAMShadingManager sharedManager] shadingIntensity];
        if (curShading < 0.05f) curShading = 0.45f; // Default nếu chưa từng set
        _zoomSlider.minimumValue = 0.05f;
        _zoomSlider.maximumValue = 1.00f;
        _zoomSlider.value = curShading;
        _zoomSlider.tintColor = [UIColor colorWithRed:0.85 green:0.45 blue:1.0 alpha:1.0];
        // Tự động bật shading + grain khi chọn tab 🎭
        [[VCAMShadingManager sharedManager] setShadingEnabled:YES];
        [[VCAMShadingManager sharedManager] setGrainEnabled:YES];
        [[VCAMShadingManager sharedManager] setShadingIntensity:curShading];
        [[VCAMShadingManager sharedManager] setGrainIntensity:curShading * 0.65f];
        [self _showToast:[NSString stringWithFormat:@"🎭 Khối 3D & Hạt: %.0f%%", curShading * 100.0f]];
    } else { // 🔍 Zoom
        CGFloat curScale = VCamGetScale();
        _zoomSlider.minimumValue = 0.4f;
        _zoomSlider.maximumValue = 2.5f;
        _zoomSlider.value = curScale;
        _zoomSlider.tintColor = [UIColor colorWithRed:0.3 green:0.85 blue:1.0 alpha:1.0];
        [self _showToast:[NSString stringWithFormat:@"🔍 Thu phóng: %.1fx", curScale]];
    }
}

- (void)_updateZoomValue:(CGFloat)scale {
    if (scale < 0.4f) scale = 0.4f;
    if (scale > 2.5f) scale = 2.5f;
    VCamSetScale(scale);
    _zoomSlider.value = scale;
    VCamDebugLog([NSString stringWithFormat:@"[UI] _updateZoomValue: %.2f", scale]);
}

- (void)_sliderChanged:(UISlider *)slider {
    if (_topSliderMode == 1) {
        CGFloat val = slider.value;
        if (val < 0.10f) val = 0.10f;
        if (val > 0.90f) val = 0.90f;
        [[VCAMFlashLivenessManager sharedManager] setFlashIntensity:val];
        [self _showToast:[NSString stringWithFormat:@"⚡ Độ đậm: %.0f%%", val * 100.0f]];
    } else if (_topSliderMode == 2) {
        CGFloat val = slider.value;
        if (val < 0.08f) {
            [[VCAMShadingManager sharedManager] setShadingEnabled:NO];
            [[VCAMShadingManager sharedManager] setGrainEnabled:NO];
            [self _showToast:@"🎭 Khối 3D & Hạt: TẮT"];
        } else {
            [[VCAMShadingManager sharedManager] setShadingEnabled:YES];
            [[VCAMShadingManager sharedManager] setGrainEnabled:YES];
            [[VCAMShadingManager sharedManager] setShadingIntensity:val];
            [[VCAMShadingManager sharedManager] setGrainIntensity:val * 0.65f];
            [self _showToast:[NSString stringWithFormat:@"🎭 Khối 3D & Hạt: %.0f%%", val * 100.0f]];
        }
    } else {
        [self _updateZoomValue:slider.value];
    }
}

- (void)_zoomMinus {
    if (_topSliderMode == 1) {
        CGFloat current = _zoomSlider ? _zoomSlider.value : [[VCAMFlashLivenessManager sharedManager] flashIntensity];
        CGFloat next = current - 0.05f;
        if (next < 0.10f) next = 0.10f;
        if (_zoomSlider) _zoomSlider.value = next;
        [[VCAMFlashLivenessManager sharedManager] setFlashIntensity:next];
        [self _showToast:[NSString stringWithFormat:@"⚡ Độ đậm: %.0f%%", next * 100.0f]];
    } else if (_topSliderMode == 2) {
        CGFloat current = _zoomSlider ? _zoomSlider.value : [[VCAMShadingManager sharedManager] shadingIntensity];
        CGFloat next = current - 0.05f;
        if (next < 0.05f) next = 0.05f;
        if (_zoomSlider) _zoomSlider.value = next;
        [[VCAMShadingManager sharedManager] setShadingIntensity:next];
        [[VCAMShadingManager sharedManager] setGrainIntensity:next * 0.65f];
        [self _showToast:[NSString stringWithFormat:@"🎭 Khối 3D & Hạt: %.0f%%", next * 100.0f]];
    } else {
        CGFloat current = _zoomSlider ? _zoomSlider.value : VCamGetScale();
        CGFloat next = current - 0.10f;
        if (next < 0.4f) next = 0.4f;
        [self _updateZoomValue:next];
        [self _showToast:[NSString stringWithFormat:@"Thu nhỏ: %.1fx", next]];
    }
}

- (void)_zoomPlus {
    if (_topSliderMode == 1) {
        CGFloat current = _zoomSlider ? _zoomSlider.value : [[VCAMFlashLivenessManager sharedManager] flashIntensity];
        CGFloat next = current + 0.05f;
        if (next > 0.90f) next = 0.90f;
        if (_zoomSlider) _zoomSlider.value = next;
        [[VCAMFlashLivenessManager sharedManager] setFlashIntensity:next];
        [self _showToast:[NSString stringWithFormat:@"⚡ Độ đậm: %.0f%%", next * 100.0f]];
    } else if (_topSliderMode == 2) {
        CGFloat current = _zoomSlider ? _zoomSlider.value : [[VCAMShadingManager sharedManager] shadingIntensity];
        CGFloat next = current + 0.05f;
        if (next > 1.00f) next = 1.00f;
        if (_zoomSlider) _zoomSlider.value = next;
        [[VCAMShadingManager sharedManager] setShadingIntensity:next];
        [[VCAMShadingManager sharedManager] setGrainIntensity:next * 0.65f];
        [self _showToast:[NSString stringWithFormat:@"🎭 Khối 3D & Hạt: %.0f%%", next * 100.0f]];
    } else {
        CGFloat current = _zoomSlider ? _zoomSlider.value : VCamGetScale();
        CGFloat next = current + 0.10f;
        if (next > 2.5f) next = 2.5f;
        [self _updateZoomValue:next];
        [self _showToast:[NSString stringWithFormat:@"Phóng to: %.1fx", next]];
    }
}

- (void)_moveUp {
    [[VCAMTransformManager sharedManager] moveUp];
    _curOffsetY = [[VCAMTransformManager sharedManager] offsetY];
    VCamDebugLog([NSString stringWithFormat:@"[UI] _moveUp: offsetY=%.1f", _curOffsetY]);
    [self _showToast:@"▲ Lên"];
}

- (void)_moveDown {
    [[VCAMTransformManager sharedManager] moveDown];
    _curOffsetY = [[VCAMTransformManager sharedManager] offsetY];
    VCamDebugLog([NSString stringWithFormat:@"[UI] _moveDown: offsetY=%.1f", _curOffsetY]);
    [self _showToast:@"▼ Xuống"];
}

- (void)_moveLeft {
    [[VCAMTransformManager sharedManager] moveLeft];
    _curOffsetX = [[VCAMTransformManager sharedManager] offsetX];
    VCamDebugLog([NSString stringWithFormat:@"[UI] _moveLeft: offsetX=%.1f", _curOffsetX]);
    [self _showToast:@"◀ Trái"];
}

- (void)_moveRight {
    [[VCAMTransformManager sharedManager] moveRight];
    _curOffsetX = [[VCAMTransformManager sharedManager] offsetX];
    VCamDebugLog([NSString stringWithFormat:@"[UI] _moveRight: offsetX=%.1f", _curOffsetX]);
    [self _showToast:@"▶ Phải"];
}

- (void)_toggleMirrorFlip:(UIButton *)sender {
    BOOL flipped = [[VCAMTransformManager sharedManager] toggleMirrorFlip];
    if (flipped) {
        sender.backgroundColor = [UIColor colorWithRed:0.3 green:0.75 blue:1.0 alpha:0.38];
        sender.layer.borderColor = [UIColor colorWithRed:0.3 green:0.85 blue:1.0 alpha:0.95].CGColor;
        [self _showToast:@"🪞 Lật gương: BẬT"];
    } else {
        sender.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.32];
        sender.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.48].CGColor;
        [self _showToast:@"🪞 Lật gương: TẮT"];
    }
}

- (void)_toggleKYCFlash:(UIButton *)sender {
    BOOL next = ![[VCAMFlashLivenessManager sharedManager] isLivenessEnabled];
    [[VCAMFlashLivenessManager sharedManager] setLivenessEnabled:next];
    if (next) {
        sender.backgroundColor = [UIColor colorWithRed:0.20 green:0.80 blue:0.40 alpha:0.35];
        sender.layer.borderColor = [UIColor colorWithRed:0.20 green:0.85 blue:0.45 alpha:0.9].CGColor;
        if (_modeControl) {
            _modeControl.selectedSegmentIndex = 1;
            [self _sliderModeChanged:_modeControl];
        }
        [self _showToast:@"⚡ KYC Flash: ĐÃ BẬT"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self _hideMenu];
        });
    } else {
        sender.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.32];
        sender.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.48].CGColor;
        if (_modeControl) {
            _modeControl.selectedSegmentIndex = 0;
            [self _sliderModeChanged:_modeControl];
        }
        [self _showToast:@"⚡ KYC Flash: ĐÃ TẮT"];
    }
}

- (void)_triggerFlashBurst:(UIButton *)sender {
    [VCAMFlashBurstManager triggerFlashBurst];
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    [self _showToast:@"📸 Phản quang Flash (0.45s)"];
}

- (void)_moveReset {
    VCamDebugLog(@"[UI] _moveReset");
    [[VCAMTransformManager sharedManager] reset];
    _curOffsetX = 0.0f;
    _curOffsetY = 0.0f;
    [self _updateZoomValue:1.0f];
    [self _showToast:@"Đặt lại vị trí (1.0x)"];
}

- (void)_menuTogglePause {
    if (![[VCAMLicenseManager sharedManager] isLicenseValid]) {
        [self _hideMenu];
        [[VCAMLicenseManager sharedManager] promptActivationDialogWithReason:@"Bản quyền chưa kích hoạt hoặc đã bị khóa!" presenter:_rootVC];
        return;
    }
    if (VCamIsPaused()) {
        VCamRemoveFlag(kVCamPauseFlagName);
    } else {
        VCamWriteFlag(kVCamPauseFlagName, "1");
    }
    [self _hideMenu];
    VCamFloatRefreshButton();
}

- (void)_menuSelectVideo {
    [self _hideMenu];
    if (![[VCAMLicenseManager sharedManager] isLicenseValid]) {
        [[VCAMLicenseManager sharedManager] promptActivationDialogWithReason:@"Vui lòng kích hoạt bản quyền để chọn video!" presenter:_rootVC];
        return;
    }
    [[VCAMVideoManager sharedManager] presentVideoPickerFromViewController:_rootVC];
}

- (void)_menuSelectPhoto {
    [self _hideMenu];
    if (![[VCAMLicenseManager sharedManager] isLicenseValid]) {
        [[VCAMLicenseManager sharedManager] promptActivationDialogWithReason:@"Vui lòng kích hoạt bản quyền để chọn ảnh!" presenter:_rootVC];
        return;
    }
    [[VCAMPhotoManager sharedManager] presentPhotoPickerFromViewController:_rootVC];
}

- (void)_menuShowLicense {
    [self _hideMenu];
    NSString *timeText = [[VCAMLicenseManager sharedManager] remainingTimeString];
    NSString *hwidShort = [VCAMLicenseManager sharedManager].hwid;
    if (hwidShort.length > 16) hwidShort = [hwidShort substringToIndex:16];
    NSString *reason = [NSString stringWithFormat:@"Trạng thái: %@\nMã máy (HWID):\n%@...\n\nNhập mã mới nếu bạn muốn gia hạn hoặc đổi key:", timeText, hwidShort];
    [[VCAMLicenseManager sharedManager] promptActivationDialogWithReason:reason presenter:_rootVC];
}

- (void)_menuDisable {
    VCamRemoveFlag(kVCamEnabledFlagName);
    VCamRemoveFlag(kVCamPauseFlagName);
    for (NSString *dir in VCamPossibleTmpDirs()) {
        unlink([[dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamTempFileName]] UTF8String]);
        unlink([[dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamTempPhotoFileName]] UTF8String]);
    }
    [[VCAMTransformManager sharedManager] reset];
    [[VCAMTransformManager sharedManager] setRotation:0];
    [[VCAMTransformManager sharedManager] setMirrorFlipped:NO];
    [self _hideMenu];
    VCamFloatRefreshButton();
}

- (void)_pan:(UIPanGestureRecognizer *)gr {
    CGPoint d = [gr translationInView:_rootVC.view];
    _btn.center = CGPointMake(_btn.center.x + d.x, _btn.center.y + d.y);
    [gr setTranslation:CGPointZero inView:_rootVC.view];
    sTweakButtonFrame = _btn.frame;
    if (gr.state == UIGestureRecognizerStateEnded ||
        gr.state == UIGestureRecognizerStateCancelled) {
        [self _snapButton:_btn];
    }
}

- (void)_snapButton:(UIView *)btn {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat pad = 10 + btn.bounds.size.width / 2;
    CGFloat x = btn.center.x < screen.size.width / 2
        ? pad : screen.size.width - pad;
    CGFloat halfH = btn.bounds.size.height / 2;
    CGFloat y = MAX(80 + halfH, MIN(btn.center.y, screen.size.height - 80 - halfH));
    [UIView animateWithDuration:0.35 delay:0
         usingSpringWithDamping:0.7 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ 
                         btn.center = CGPointMake(x, y); 
                         sTweakButtonFrame = btn.frame;
                     }
                     completion:^(BOOL finished) {
                         sTweakButtonFrame = btn.frame;
                     }];
}

@end

static UIViewController *VCamPresenter(void) { return [VCamFloat presenter]; }
static void VCamFloatRefreshButton(void)     { [VCamFloat refreshButton]; }
static void VCamFloatHideMenu(void)          { [VCamFloat hideMenu]; }

static void VCamInitSpringBoardHooks(void) {
    void (^startUI)(void) = ^{
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [[VCAMLicenseManager sharedManager] startHeartbeat];
            [[NSNotificationCenter defaultCenter] addObserverForName:kVCAMLicenseRevokedNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification * _Nonnull note) {
                VCamRemoveFlag(kVCamEnabledFlagName);
                VCamRemoveFlag(kVCamPauseFlagName);
                VCamFloatHideMenu();
                VCamFloatRefreshButton();
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:kVCAMLicenseStatusChangedNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification * _Nonnull note) {
                VCamFloatRefreshButton();
            }];
            [VCamFloat show];
        });
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), startUI);
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), startUI);
    }];
}

%ctor {
    @autoreleasepool {
        unlink("/var/tmp/vcam_ui.log");
        unlink("/rootfs/private/var/tmp/vcam_ui.log");
        unlink("/private/var/tmp/vcam_ui.log");

        gFileManager = NSFileManager.defaultManager;
        [gFileManager createDirectoryAtPath:@"/var/tmp"
                withIntermediateDirectories:YES attributes:nil error:nil];
        chmod("/var/tmp", 0777);

        NSString *processName = NSProcessInfo.processInfo.processName;
        if ([processName isEqualToString:@"mediaserverd"]) {
            VCamInitMediaServerHooks();
        } else if ([processName isEqualToString:@"SpringBoard"]) {
            VCamInitSpringBoardHooks();
        }
    }
}
