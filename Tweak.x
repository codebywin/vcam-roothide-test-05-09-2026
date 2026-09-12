#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "VCAMLicenseManager.h"
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/stat.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static const char *kVCamTempFileName    = "vcam_temp.mov";
static const char *kVCamEnabledFlagName = "vcam_enabled";
static const char *kVCamPauseFlagName   = "vcam_paused";
static const char *kVCamScaleFileName   = "vcam_scale";
static const char *kVCamOffsetXFileName = "vcam_offset_x";
static const char *kVCamOffsetYFileName = "vcam_offset_y";

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
    NSString *bestPath = nil;
    NSDate *bestDate = nil;
    for (NSString *dir in VCamPossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        if (access([filePath UTF8String], F_OK) == 0) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath error:nil];
            NSDate *mod = [attrs fileModificationDate];
            if (!bestDate || (mod && [mod compare:bestDate] == NSOrderedDescending)) {
                bestDate = mod;
                bestPath = filePath;
            }
        }
    }
    if (bestPath) return bestPath;
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/rootfs/private/var/tmp"]) {
        return [@"/rootfs/private/var/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
    }
    return [@"/var/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
}

static BOOL VCamIsActive(void) {
    NSString *processName = NSProcessInfo.processInfo.processName;
    if ([processName isEqualToString:@"SpringBoard"]) {
        if (![[VCAMLicenseManager sharedManager] isLicenseValid]) {
            return NO;
        }
    }
    return VCamCheckFileExists(kVCamEnabledFlagName);
}

static BOOL VCamIsPaused(void) {
    return VCamCheckFileExists(kVCamPauseFlagName);
}

static CGFloat VCamGetScale(void) {
    NSString *path = VCamFindExistingFilePath(kVCamScaleFileName);
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        float val = 1.0f;
        if (fscanf(f, "%f", &val) == 1) {
            fclose(f);
            if (val >= 1.0f && val <= 2.5f) return (CGFloat)val;
        } else {
            fclose(f);
        }
    }
    return 1.0f;
}

static void VCamSetScale(CGFloat scale) {
    if (scale < 1.0f) scale = 1.0f;
    if (scale > 2.5f) scale = 2.5f;
    char buf[32];
    snprintf(buf, sizeof(buf), "%.2f", scale);
    VCamWriteFlag(kVCamScaleFileName, buf);
}

static CGFloat VCamGetOffsetX(void) {
    NSString *path = VCamFindExistingFilePath(kVCamOffsetXFileName);
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        float val = 0.0f;
        if (fscanf(f, "%f", &val) == 1) {
            fclose(f);
            return (CGFloat)val;
        }
        fclose(f);
    }
    return 0.0f;
}

static CGFloat VCamGetOffsetY(void) {
    NSString *path = VCamFindExistingFilePath(kVCamOffsetYFileName);
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        float val = 0.0f;
        if (fscanf(f, "%f", &val) == 1) {
            fclose(f);
            return (CGFloat)val;
        }
        fclose(f);
    }
    return 0.0f;
}

static void VCamSetOffsets(CGFloat x, CGFloat y) {
    char bufX[32], bufY[32];
    snprintf(bufX, sizeof(bufX), "%.1f", x);
    snprintf(bufY, sizeof(bufY), "%.1f", y);
    VCamWriteFlag(kVCamOffsetXFileName, bufX);
    VCamWriteFlag(kVCamOffsetYFileName, bufY);
}

typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
typedef OSStatus (*VTPixelTransferSessionCreateFunc)(CFAllocatorRef, VTPixelTransferSessionRef *);
typedef OSStatus (*VTPixelTransferSessionTransferImageFunc)(VTPixelTransferSessionRef, CVPixelBufferRef, CVPixelBufferRef);
typedef OSStatus (*VTSessionSetPropertyFunc)(CFTypeRef, CFStringRef, CFTypeRef);

static VTPixelTransferSessionRef gTransferSession = NULL;
static VTPixelTransferSessionTransferImageFunc gVTPixelTransferSessionTransferImage = NULL;
static dispatch_once_t gTransferOnce;

static OSStatus VCamCopyPixelBuffer(CVPixelBufferRef source, CVPixelBufferRef target) {
    if (!source || !target) return -1;

    size_t srcW = CVPixelBufferGetWidth(source);
    size_t srcH = CVPixelBufferGetHeight(source);
    size_t dstW = CVPixelBufferGetWidth(target);
    size_t dstH = CVPixelBufferGetHeight(target);
    OSType srcFmt = CVPixelBufferGetPixelFormatType(source);
    OSType dstFmt = CVPixelBufferGetPixelFormatType(target);
    CGFloat userScale = VCamGetScale();
    CGFloat userOffsetX = VCamGetOffsetX();
    CGFloat userOffsetY = VCamGetOffsetY();

    // Fast path: scale exactly 1.0, zero offset, same format & size
    if (fabs(userScale - 1.0f) < 0.001f && fabs(userOffsetX) < 0.1f && fabs(userOffsetY) < 0.1f &&
        gVideoExifOrientation == 1 && srcFmt == dstFmt && srcW == dstW && srcH == dstH) {
        CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(target, 0);
        size_t planes = CVPixelBufferIsPlanar(source) ? CVPixelBufferGetPlaneCount(source) : 1;
        for (size_t plane = 0; plane < planes; plane++) {
            void *srcBase = CVPixelBufferIsPlanar(source)
                ? CVPixelBufferGetBaseAddressOfPlane(source, plane)
                : CVPixelBufferGetBaseAddress(source);
            void *dstBase = CVPixelBufferIsPlanar(target)
                ? CVPixelBufferGetBaseAddressOfPlane(target, plane)
                : CVPixelBufferGetBaseAddress(target);
            size_t srcBPR = CVPixelBufferIsPlanar(source)
                ? CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                : CVPixelBufferGetBytesPerRow(source);
            size_t dstBPR = CVPixelBufferIsPlanar(target)
                ? CVPixelBufferGetBytesPerRowOfPlane(target, plane)
                : CVPixelBufferGetBytesPerRow(target);
            size_t rows = CVPixelBufferIsPlanar(source)
                ? CVPixelBufferGetHeightOfPlane(source, plane)
                : srcH;
            size_t bpr = MIN(srcBPR, dstBPR);
            for (size_t row = 0; row < rows; row++) {
                memcpy((uint8_t *)dstBase + row * dstBPR,
                       (uint8_t *)srcBase + row * srcBPR, bpr);
            }
        }
        CVPixelBufferUnlockBaseAddress(target, 0);
        CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
        return noErr;
    }

    // Hardware accelerated scaling & format conversion via VideoToolbox
    // (100% Native, 0% Metal IOFence / GPU deadlock)
    dispatch_once(&gTransferOnce, ^{
        dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW | RTLD_GLOBAL);
        VTPixelTransferSessionCreateFunc createFunc = (VTPixelTransferSessionCreateFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionCreate");
        gVTPixelTransferSessionTransferImage = (VTPixelTransferSessionTransferImageFunc)dlsym(RTLD_DEFAULT, "VTPixelTransferSessionTransferImage");
        VTSessionSetPropertyFunc setPropFunc = (VTSessionSetPropertyFunc)dlsym(RTLD_DEFAULT, "VTSessionSetProperty");

        if (createFunc && gVTPixelTransferSessionTransferImage) {
            OSStatus err = createFunc(kCFAllocatorDefault, &gTransferSession);
            if (err == noErr && gTransferSession && setPropFunc) {
                setPropFunc(gTransferSession, CFSTR("ScalingMode"), CFSTR("CropAspectRatioPreserving"));
            }
        }
    });

    if (gTransferSession && gVTPixelTransferSessionTransferImage) {
        OSStatus status = gVTPixelTransferSessionTransferImage(gTransferSession, source, target);
        if (status == noErr) {
            return noErr;
        }
    }

    return -1;
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

static void VCamResetReader(void) {
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
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(outputFormat)}];
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

    // Đọc ngay frame đầu tiên vào gCachedPixelBuffer
    CMSampleBufferRef firstBuf = [gTrackOutput copyNextSampleBuffer];
    if (firstBuf) {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(firstBuf);
        if (pb) {
            if (gCachedPixelBuffer) CFRelease(gCachedPixelBuffer);
            gCachedPixelBuffer = (CVPixelBufferRef)CFRetain(pb);
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

static CMSampleBufferRef VCamCopyFrameMatching(CMSampleBufferRef originSampleBuffer) {
    if (!originSampleBuffer) return nil;

    CFTimeInterval now = CACurrentMediaTime();

    // Throttled flag check (chỉ kiểm tra cờ mỗi 0.3s để giảm I/O trên camera thread)
    static BOOL gCachedActive = NO;
    static BOOL gCachedPaused = NO;
    static CFTimeInterval gLastFlagCheck = 0;
    if (now - gLastFlagCheck > 0.3) {
        gLastFlagCheck = now;
        gCachedActive = VCamIsActive() && VCamCheckFileExists(kVCamTempFileName);
        gCachedPaused = VCamIsPaused();
    }

    if (!gCachedActive) return nil;

    CMFormatDescriptionRef originFormat = CMSampleBufferGetFormatDescription(originSampleBuffer);
    if (!originFormat || CMFormatDescriptionGetMediaType(originFormat) != kCMMediaType_Video) return nil;

    OSType originSubtype = CMFormatDescriptionGetMediaSubType(originFormat);
    CMTime originPTS = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer);

    // ── Xử lý tính năng Tạm dừng (Pause / Freeze Frame) ──
    if (gCachedPaused && gCachedPixelBuffer) {
        CMSampleTimingInfo timing = {
            .duration               = CMSampleBufferGetDuration(originSampleBuffer),
            .presentationTimeStamp  = originPTS,
            .decodeTimeStamp        = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer),
        };
        CMVideoFormatDescriptionRef fakeFormat = nil;
        CMSampleBufferRef fakeBuffer = nil;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, gCachedPixelBuffer, &fakeFormat);
        if (fakeFormat) {
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, gCachedPixelBuffer, true,
                                               nil, nil, fakeFormat, &timing, &fakeBuffer);
            CFRelease(fakeFormat);
        }
        return fakeBuffer;
    }

    // Throttled file check (quét file mới nhất mỗi 0.5s)
    static NSString *gActiveTempPath = nil;
    static CFTimeInterval gLastPathCheck = 0;
    if (now - gLastPathCheck > 0.5 || !gActiveTempPath) {
        gLastPathCheck = now;
        NSString *found = VCamFindExistingFilePath(kVCamTempFileName);
        if (![found isEqualToString:gActiveTempPath]) {
            gActiveTempPath = found;
            gNeedsReaderReload = YES;
        }
        NSDate *modified = [[NSFileManager defaultManager] attributesOfItemAtPath:gActiveTempPath error:nil].fileModificationDate;
        if (modified && ![modified isEqualToDate:gLastTempFileModified]) {
            gLastTempFileModified = modified;
            gNeedsReaderReload = YES;
            if (gCachedPixelBuffer) {
                CFRelease(gCachedPixelBuffer);
                gCachedPixelBuffer = nil;
            }
        }
    }

    if (gReaderFormat != originSubtype) gNeedsReaderReload = YES;

    // Khởi tạo hoặc tải lại reader nếu cần
    if (gNeedsReaderReload || !gAssetReader || gAssetReader.status != AVAssetReaderStatusReading) {
        BOOL ok = VCamSetupReader(gActiveTempPath, originSubtype);
        if (!ok) {
            gNeedsReaderReload = YES;
            if (gCachedPixelBuffer) {
                CMSampleTimingInfo timing = {
                    .duration               = CMSampleBufferGetDuration(originSampleBuffer),
                    .presentationTimeStamp  = originPTS,
                    .decodeTimeStamp        = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer),
                };
                CMVideoFormatDescriptionRef fakeFormat = nil;
                CMSampleBufferRef fakeBuffer = nil;
                CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, gCachedPixelBuffer, &fakeFormat);
                if (fakeFormat) {
                    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, gCachedPixelBuffer, true,
                                                       nil, nil, fakeFormat, &timing, &fakeBuffer);
                    CFRelease(fakeFormat);
                }
                return fakeBuffer;
            }
            return nil;
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

    // Tiến trình hiển thị frame theo đúng PTS thực của video
    while (gNextSampleBuffer && elapsed >= gNextFramePTS) {
        CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(gNextSampleBuffer);
        if (pb) {
            if (gCachedPixelBuffer) CFRelease(gCachedPixelBuffer);
            gCachedPixelBuffer = (CVPixelBufferRef)CFRetain(pb);
        }
        CFRelease(gNextSampleBuffer);
        gNextSampleBuffer = [gTrackOutput copyNextSampleBuffer];
        if (gNextSampleBuffer) {
            CMTime pts = CMSampleBufferGetPresentationTimeStamp(gNextSampleBuffer);
            gNextFramePTS = CMTimeGetSeconds(pts);
        } else {
            gNextFramePTS = gCachedDuration;
        }
    }

    if (!gCachedPixelBuffer) return nil;

    CMSampleTimingInfo timing = {
        .duration               = CMSampleBufferGetDuration(originSampleBuffer),
        .presentationTimeStamp  = originPTS,
        .decodeTimeStamp        = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer),
    };
    CMVideoFormatDescriptionRef fakeFormat = nil;
    CMSampleBufferRef fakeBuffer = nil;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, gCachedPixelBuffer, &fakeFormat);
    if (fakeFormat) {
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, gCachedPixelBuffer, true,
                                           nil, nil, fakeFormat, &timing, &fakeBuffer);
        CFRelease(fakeFormat);
    }
    return fakeBuffer;
}

static void (*orig_BWNodeOutput_emitSampleBuffer)(id, SEL, CMSampleBufferRef) = NULL;
static void hook_BWNodeOutput_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    if (!sampleBuffer) {
        if (orig_BWNodeOutput_emitSampleBuffer) orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }

    CVPixelBufferRef targetPb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!targetPb) {
        if (orig_BWNodeOutput_emitSampleBuffer) orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }

    CMSampleBufferRef fakeBuffer = VCamCopyFrameMatching(sampleBuffer);
    if (fakeBuffer) {
        CVPixelBufferRef srcPb = CMSampleBufferGetImageBuffer(fakeBuffer);
        if (srcPb) {
            VCamCopyPixelBuffer(srcPb, targetPb);
        }
        CFRelease(fakeBuffer);
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

@interface VCamPickerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamPickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) {
        url = info[UIImagePickerControllerReferenceURL];
    }
    if (!url) return;

    VCamRemoveFlag(kVCamPauseFlagName);

    // Bắt đầu truy cập security-scoped URL (cần thiết trên iOS 15 & 16)
    BOOL accessed = [url startAccessingSecurityScopedResource];

    // Đọc data video an toàn
    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&err];

    BOOL anySaved = NO;
    for (NSString *dir in VCamPossibleTmpDirs()) {
        NSString *destPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamTempFileName]];
        unlink([destPath UTF8String]);

        BOOL saved = NO;
        if (data && data.length > 0) {
            FILE *f = fopen([destPath UTF8String], "wb");
            if (f) {
                size_t written = fwrite(data.bytes, 1, data.length, f);
                fflush(f);
                fclose(f);
                saved = (written == data.length);
            }
        }
        if (!saved) {
            [gFileManager removeItemAtPath:destPath error:nil];
            saved = [gFileManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:destPath] error:nil];
        }
        if (!saved) {
            saved = [gFileManager copyItemAtPath:url.path toPath:destPath error:nil];
        }

        if (saved || (access([destPath UTF8String], F_OK) == 0)) {
            chmod([destPath UTF8String], 0666);
            anySaved = YES;
        }
    }

    if (accessed) {
        [url stopAccessingSecurityScopedResource];
    }

    if (anySaved) {
        if ([[VCAMLicenseManager sharedManager] isLicenseValid]) {
            VCamWriteFlag(kVCamEnabledFlagName, "1");
            NSLog(@"[vcamios] Video đã được lưu thành công vào toàn bộ thư mục tmp!");
        } else {
            [[VCAMLicenseManager sharedManager] promptActivationDialogWithReason:@"Vui lòng kích hoạt mã bản quyền để sử dụng video ảo!" presenter:VCamPresenter()];
        }
    } else {
        NSLog(@"[vcamios] LỖI: Không thể sao chép video vào các thư mục tmp! Chi tiết: %@", err.localizedDescription);
    }
    VCamFloatRefreshButton();
    VCamFloatHideMenu();
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end
 
static void VCamSelectVideo(void) {
    static VCamPickerDelegate *delegate = nil;
    if (!delegate) delegate = [VCamPickerDelegate new];

    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.movie"];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    picker.allowsEditing = NO; // Tắt màn hình cắt video để nhận video gốc ngay lập tức mà không bị lỗi export
    picker.delegate = delegate;
    if (@available(iOS 11.0, *)) picker.videoExportPreset = AVAssetExportPresetPassthrough;

    [VCamPresenter() presentViewController:picker animated:YES completion:nil];
}

@interface VCamFloatWindow : UIWindow
@end
@implementation VCamFloatWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

@interface VCamFloat : NSObject
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
    UISlider *_zoomSlider;
    CGFloat _curOffsetX;
    CGFloat _curOffsetY;
}

static VCamFloat *gVCamFloat = nil;

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
        gVCamFloat->_btn.alpha = active ? 0.90 : 0.40;
        if (!isLicensed) {
            [gVCamFloat->_btn setTitle:@"🔒" forState:UIControlStateNormal];
        } else if (!active) {
            [gVCamFloat->_btn setTitle:@"📷" forState:UIControlStateNormal];
        } else {
            [gVCamFloat->_btn setTitle:isPaused ? @"⏸️" : @"🎥" forState:UIControlStateNormal];
        }
    });
}

+ (void)hideMenu {
    if (gVCamFloat) [gVCamFloat _hideMenu];
}

- (void)_setup {
    if (_win) return;
    CGFloat sz = 52;
    CGRect screen = UIScreen.mainScreen.bounds;

    if (@available(iOS 13.0, *)) {
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                _win = [[VCamFloatWindow alloc] initWithWindowScene:(UIWindowScene *)s];
                break;
            }
        }
    }
    if (!_win) _win = [[VCamFloatWindow alloc] initWithFrame:screen];

    _win.frame = screen;
    _win.windowLevel = UIWindowLevelAlert + 300;
    _win.backgroundColor = [UIColor clearColor];

    _rootVC = [UIViewController new];
    _rootVC.view.backgroundColor = [UIColor clearColor];
    _rootVC.view.userInteractionEnabled = NO;
    _win.rootViewController = _rootVC;

    // Mini Floating Ball (Enlarged)
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, sz, sz);
    btn.center = CGPointMake(screen.size.width - sz / 2 - 10, screen.size.height * 0.40);
    btn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    btn.layer.cornerRadius = sz / 2;
    btn.layer.borderWidth = 1.2;
    btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.60].CGColor;
    [btn setTitle:@"📷" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:22];
    btn.userInteractionEnabled = YES;
    [btn addTarget:self action:@selector(_tap) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(_pan:)];
    [btn addGestureRecognizer:pan];
    [_rootVC.view addSubview:btn];
    _rootVC.view.userInteractionEnabled = YES;
    _btn = btn;
    _win.hidden = NO;
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
    [UIView animateWithDuration:0.2 animations:^{ self->_menuOverlay.alpha = 0; }
                     completion:^(__unused BOOL f) { [self->_menuOverlay removeFromSuperview]; self->_menuOverlay = nil; }];
}

- (UIButton *)_dpadButtonWithTitle:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h sel:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, h);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 0.8;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)_iconButtonWithTitle:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h color:(UIColor *)color sel:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, h);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:color forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17];
    b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    b.layer.cornerRadius = 10;
    b.layer.borderWidth = 0.8;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)_showMenu {
    BOOL isPaused = VCamIsPaused();
    CGFloat currentScale = VCamGetScale();
    _curOffsetX = VCamGetOffsetX();
    _curOffsetY = VCamGetOffsetY();

    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat w = 175, h = 175;

    // Fully clear touch-outside dismiss overlay
    UIView *overlay = [[UIView alloc] initWithFrame:_rootVC.view.bounds];
    overlay.backgroundColor = [UIColor clearColor];
    UITapGestureRecognizer *dismiss = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_hideMenu)];
    [overlay addGestureRecognizer:dismiss];

    CGFloat panelX = (_btn.center.x > screen.size.width / 2)
        ? _btn.frame.origin.x - w - 8
        : CGRectGetMaxX(_btn.frame) + 8;
    panelX = MAX(8, MIN(panelX, screen.size.width - w - 8));
    CGFloat panelY = MIN(_btn.center.y - h / 2,
                         screen.size.height - h - 15);
    panelY = MAX(15, panelY);

    // Compact Rounded Square Panel (~175x175)
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(panelX, panelY, w, h)];
    panel.backgroundColor = [UIColor clearColor];
    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = YES;

    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blurView.frame = panel.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.alpha = 0.20;
    [panel addSubview:blurView];

    UIView *tintOverlay = [[UIView alloc] initWithFrame:panel.bounds];
    tintOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
    tintOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tintOverlay.layer.borderWidth = 0.8;
    tintOverlay.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    tintOverlay.layer.cornerRadius = 18;
    [panel addSubview:tintOverlay];

    UITapGestureRecognizer *noop = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [panel addGestureRecognizer:noop];

    // ── 1. Top: Mini Zoom Slider with [-] and [+] ──
    CGFloat minusBtnW = 22, plusBtnW = 22, ctrlY = 8, ctrlH = 22;
    UIButton *minusBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    minusBtn.frame = CGRectMake(8, ctrlY, minusBtnW, ctrlH);
    [minusBtn setTitle:@"−" forState:UIControlStateNormal];
    [minusBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    minusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    minusBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    minusBtn.layer.cornerRadius = 5;
    minusBtn.layer.borderWidth = 0.6;
    minusBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
    [minusBtn addTarget:self action:@selector(_zoomMinus) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:minusBtn];

    CGFloat sliderX = CGRectGetMaxX(minusBtn.frame) + 6;
    CGFloat sliderW = w - sliderX - plusBtnW - 8 - 6;
    _zoomSlider = [[UISlider alloc] initWithFrame:CGRectMake(sliderX, ctrlY, sliderW, ctrlH)];
    _zoomSlider.minimumValue = 1.0f;
    _zoomSlider.maximumValue = 2.5f;
    _zoomSlider.value = currentScale;
    _zoomSlider.tintColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
    [_zoomSlider addTarget:self action:@selector(_sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:_zoomSlider];

    UIButton *plusBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    plusBtn.frame = CGRectMake(w - plusBtnW - 8, ctrlY, plusBtnW, ctrlH);
    [plusBtn setTitle:@"+" forState:UIControlStateNormal];
    [plusBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    plusBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    plusBtn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    plusBtn.layer.cornerRadius = 5;
    plusBtn.layer.borderWidth = 0.6;
    plusBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
    [plusBtn addTarget:self action:@selector(_zoomPlus) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:plusBtn];

    // ── 2. Middle: D-Pad 4-Way Cross Controller ──
    CGFloat dBtnW = 34, dBtnH = 24;
    CGFloat midX = (w - dBtnW) / 2.0;

    // Up
    [panel addSubview:[self _dpadButtonWithTitle:@"▲" x:midX y:36 w:dBtnW h:dBtnH sel:@selector(_moveUp)]];

    // Left | Center | Right
    CGFloat row2Y = 36 + dBtnH + 3;
    [panel addSubview:[self _dpadButtonWithTitle:@"◀" x:midX - dBtnW - 5 y:row2Y w:dBtnW h:dBtnH sel:@selector(_moveLeft)]];
    [panel addSubview:[self _dpadButtonWithTitle:@"●" x:midX y:row2Y w:dBtnW h:dBtnH sel:@selector(_moveReset)]];
    [panel addSubview:[self _dpadButtonWithTitle:@"▶" x:midX + dBtnW + 5 y:row2Y w:dBtnW h:dBtnH sel:@selector(_moveRight)]];

    // Down
    CGFloat row3Y = row2Y + dBtnH + 3;
    [panel addSubview:[self _dpadButtonWithTitle:@"▼" x:midX y:row3Y w:dBtnW h:dBtnH sel:@selector(_moveDown)]];

    // ── 3. Bottom: 5 Action Icon Buttons (Horizontal Row) ──
    CGFloat iconW = 29, iconH = 28, iconY = 135;
    CGFloat iconSpacing = 5;
    CGFloat totalIconsW = 5 * iconW + 4 * iconSpacing;
    CGFloat startIconX = (w - totalIconsW) / 2.0;

    // Icon 1: Chọn video (🎬)
    UIButton *pickBtn = [self _iconButtonWithTitle:@"🎬" x:startIconX y:iconY w:iconW h:iconH color:[UIColor whiteColor] sel:@selector(_menuSelectVideo)];
    [panel addSubview:pickBtn];

    // Icon 2: Tạm dừng / Tiếp tục (⏸️ / ▶️)
    NSString *pauseIcon = isPaused ? @"▶️" : @"⏸️";
    UIColor *pauseCol = isPaused ? [UIColor colorWithRed:0.4 green:0.95 blue:0.5 alpha:1] : [UIColor colorWithRed:1.0 green:0.85 blue:0.3 alpha:1];
    UIButton *pauseBtn = [self _iconButtonWithTitle:pauseIcon x:startIconX + (iconW + iconSpacing) * 1 y:iconY w:iconW h:iconH color:pauseCol sel:@selector(_menuTogglePause)];
    [panel addSubview:pauseBtn];

    // Icon 3: Quản lý Key / Hạn dùng (🔑)
    UIButton *licBtn = [self _iconButtonWithTitle:@"🔑" x:startIconX + (iconW + iconSpacing) * 2 y:iconY w:iconW h:iconH color:[UIColor colorWithRed:0.6 green:0.8 blue:1.0 alpha:1] sel:@selector(_menuShowLicense)];
    [panel addSubview:licBtn];

    // Icon 4: Xóa video (🗑️)
    UIButton *trashBtn = [self _iconButtonWithTitle:@"🗑️" x:startIconX + (iconW + iconSpacing) * 3 y:iconY w:iconW h:iconH color:[UIColor colorWithRed:1 green:0.45 blue:0.45 alpha:1] sel:@selector(_menuDisable)];
    [panel addSubview:trashBtn];

    // Icon 5: Đóng (✕)
    UIButton *closeBtn = [self _iconButtonWithTitle:@"✕" x:startIconX + (iconW + iconSpacing) * 4 y:iconY w:iconW h:iconH color:[UIColor colorWithWhite:0.85 alpha:1] sel:@selector(_hideMenu)];
    [panel addSubview:closeBtn];

    [overlay addSubview:panel];
    [_rootVC.view insertSubview:overlay belowSubview:_btn];
    _menuOverlay = overlay;

    overlay.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ overlay.alpha = 1.0; }];
}

- (void)_updateZoomValue:(CGFloat)scale {
    if (scale < 1.0f) scale = 1.0f;
    if (scale > 2.5f) scale = 2.5f;
    VCamSetScale(scale);
    _zoomSlider.value = scale;
}

- (void)_sliderChanged:(UISlider *)slider {
    [self _updateZoomValue:slider.value];
}

- (void)_zoomMinus {
    CGFloat current = VCamGetScale();
    [self _updateZoomValue:current - 0.05f];
}

- (void)_zoomPlus {
    CGFloat current = VCamGetScale();
    [self _updateZoomValue:current + 0.05f];
}

- (void)_moveUp {
    _curOffsetY += 15.0f;
    if (_curOffsetY > 400.0f) _curOffsetY = 400.0f;
    VCamSetOffsets(_curOffsetX, _curOffsetY);
}

- (void)_moveDown {
    _curOffsetY -= 15.0f;
    if (_curOffsetY < -400.0f) _curOffsetY = -400.0f;
    VCamSetOffsets(_curOffsetX, _curOffsetY);
}

- (void)_moveLeft {
    _curOffsetX -= 15.0f;
    if (_curOffsetX < -400.0f) _curOffsetX = -400.0f;
    VCamSetOffsets(_curOffsetX, _curOffsetY);
}

- (void)_moveRight {
    _curOffsetX += 15.0f;
    if (_curOffsetX > 400.0f) _curOffsetX = 400.0f;
    VCamSetOffsets(_curOffsetX, _curOffsetY);
}

- (void)_moveReset {
    _curOffsetX = 0.0f;
    _curOffsetY = 0.0f;
    VCamSetOffsets(0.0f, 0.0f);
    [self _updateZoomValue:1.0f];
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
    VCamSelectVideo();
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
    [self _hideMenu];
    VCamFloatRefreshButton();
}

- (void)_pan:(UIPanGestureRecognizer *)gr {
    CGPoint d = [gr translationInView:_rootVC.view];
    _btn.center = CGPointMake(_btn.center.x + d.x, _btn.center.y + d.y);
    [gr setTranslation:CGPointZero inView:_rootVC.view];
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
                     animations:^{ btn.center = CGPointMake(x, y); }
                     completion:nil];
}

@end

static UIViewController *VCamPresenter(void) { return [VCamFloat presenter]; }
static void VCamFloatRefreshButton(void)     { [VCamFloat refreshButton]; }
static void VCamFloatHideMenu(void)          { [VCamFloat hideMenu]; }

static void VCamInitSpringBoardHooks(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
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
}

%ctor {
    @autoreleasepool {
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
