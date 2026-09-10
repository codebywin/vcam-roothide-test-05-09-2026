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

static const char *kVCamTempFilePath    = "/var/tmp/vcam_temp.mov";
static const char *kVCamEnabledFlagPath = "/var/tmp/vcam_enabled";
static const char *kVCamPauseFlagPath   = "/var/tmp/vcam_paused";
static const char *kVCamScaleFilePath   = "/var/tmp/vcam_scale";
static const char *kVCamOffsetXFilePath = "/var/tmp/vcam_offset_x";
static const char *kVCamOffsetYFilePath = "/var/tmp/vcam_offset_y";

static NSString *const kVCamTempFile = @"/var/tmp/vcam_temp.mov";

static NSFileManager *gFileManager = nil;
static BOOL gNeedsReaderReload = YES;
static NSDate *gLastTempFileModified = nil;
static int32_t gVideoExifOrientation = 1;

static void VCamWriteFlag(const char *path, const char *val) {
    FILE *f = fopen(path, "w");
    if (f) {
        if (val) fputs(val, f);
        fclose(f);
    }
    chmod(path, 0666);
}

static void VCamRemoveFlag(const char *path) {
    unlink(path);
}

static BOOL VCamIsActive(void) {
    if (![[VCAMLicenseManager sharedManager] isLicenseValid]) {
        return NO;
    }
    return (access(kVCamEnabledFlagPath, F_OK) == 0);
}

static BOOL VCamIsPaused(void) {
    return (access(kVCamPauseFlagPath, F_OK) == 0);
}

static CGFloat VCamGetScale(void) {
    FILE *f = fopen(kVCamScaleFilePath, "r");
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
    VCamWriteFlag(kVCamScaleFilePath, buf);
}

static CGFloat VCamGetOffsetX(void) {
    FILE *f = fopen(kVCamOffsetXFilePath, "r");
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
    FILE *f = fopen(kVCamOffsetYFilePath, "r");
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
    VCamWriteFlag(kVCamOffsetXFilePath, bufX);
    VCamWriteFlag(kVCamOffsetYFilePath, bufY);
}

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

    // High quality GPU rendering with CIImage (handles Zoom In, Zoom Out, Pan & 100% Solid Black Canvas)
    static CIContext *ciCtx = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ciCtx = [CIContext contextWithOptions:@{
            kCIContextUseSoftwareRenderer: @NO,
            kCIContextHighQualityDownsample: @YES
        }];
    });
    if (!ciCtx) return -2;

    CIImage *img = [CIImage imageWithCVPixelBuffer:source];

    int32_t orient = gVideoExifOrientation;
    if (orient == 1 && srcW > srcH && dstH > dstW) orient = 8;

    if (orient != 1) {
        img = [img imageByApplyingOrientation:orient];
        CGRect ext = img.extent;
        img = [img imageByApplyingTransform:
               CGAffineTransformMakeTranslation(-ext.origin.x, -ext.origin.y)];
    }

    // Aspect-fill scale with user zoom factor (supports Zoom In >= 1.0 and Zoom Out < 1.0)
    CGRect ext = img.extent;
    CGFloat sx = (CGFloat)dstW / ext.size.width;
    CGFloat sy = (CGFloat)dstH / ext.size.height;
    CGFloat baseScale = MAX(sx, sy);
    CGFloat totalScale = baseScale * userScale;

    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(totalScale, totalScale)];
    ext = img.extent;
    CGFloat tx = (dstW - ext.size.width) * 0.5 - ext.origin.x + userOffsetX;
    CGFloat ty = (dstH - ext.size.height) * 0.5 - ext.origin.y + userOffsetY;
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];

    // 100% Pure Solid Black Canvas covering entire camera buffer (eliminates any real camera exposure)
    CIImage *blackCanvas = [[CIImage imageWithColor:[CIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:1.0]]
                           imageByCroppingToRect:CGRectMake(0, 0, dstW, dstH)];
    CIImage *finalImg = [img imageByCompositingOverImage:blackCanvas];

    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [ciCtx render:finalImg toCVPixelBuffer:target
           bounds:CGRectMake(0, 0, dstW, dstH)
       colorSpace:srgb];
    CGColorSpaceRelease(srgb);
    return noErr;
}

static CMSampleBufferRef VCamCopyFrameMatching(CMSampleBufferRef originSampleBuffer) {
    static AVAssetReader *reader = nil;
    static AVAssetReaderTrackOutput *output = nil;
    static OSType readerFormat = 0;
    static CVPixelBufferRef cachedPixelBuffer = nil;

    if (!originSampleBuffer || !VCamIsActive() || (access(kVCamTempFilePath, F_OK) != 0)) return nil;

    CMFormatDescriptionRef originFormat = CMSampleBufferGetFormatDescription(originSampleBuffer);
    if (!originFormat || CMFormatDescriptionGetMediaType(originFormat) != kCMMediaType_Video) return nil;

    OSType originSubtype = CMFormatDescriptionGetMediaSubType(originFormat);
    CMTime originPTS = CMSampleBufferGetPresentationTimeStamp(originSampleBuffer);

    // ── Xử lý tính năng Tạm dừng (Pause / Freeze Frame) ──
    BOOL isPaused = VCamIsPaused();
    if (isPaused && cachedPixelBuffer) {
        CMSampleTimingInfo timing = {
            .duration               = CMSampleBufferGetDuration(originSampleBuffer),
            .presentationTimeStamp  = originPTS,
            .decodeTimeStamp        = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer),
        };
        CMVideoFormatDescriptionRef fakeFormat = nil;
        CMSampleBufferRef fakeBuffer = nil;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, cachedPixelBuffer, &fakeFormat);
        if (fakeFormat) {
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, cachedPixelBuffer, true,
                                               nil, nil, fakeFormat, &timing, &fakeBuffer);
            CFRelease(fakeFormat);
        }
        return fakeBuffer;
    }

    static AVAsset *cachedAsset = nil;
    static AVAssetTrack *cachedTrack = nil;
    static CFTimeInterval gPlaybackStartRealTime = 0;
    static Float64 gCachedDuration = 0.0;
    static float gVideoFPS = 30.0f;
    static int gCurrentFrameNumber = -1;

    NSDate *modified = [[gFileManager attributesOfItemAtPath:kVCamTempFile error:nil] fileModificationDate];
    if (modified && ![modified isEqualToDate:gLastTempFileModified]) {
        gLastTempFileModified = modified;
        gNeedsReaderReload = YES;
        cachedAsset = nil;
        cachedTrack = nil;
        gPlaybackStartRealTime = 0;
        gCurrentFrameNumber = -1;
    }

    if (readerFormat != originSubtype) gNeedsReaderReload = YES;

    if (gNeedsReaderReload || !reader) {
        gNeedsReaderReload = NO;
        reader = nil;
        output = nil;

        if (!cachedAsset) {
            NSURL *url = [NSURL fileURLWithPath:kVCamTempFile];
            cachedAsset = [AVAsset assetWithURL:url];
            cachedTrack = [[cachedAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
            gCachedDuration = CMTimeGetSeconds(cachedAsset.duration);
            float f = cachedTrack ? cachedTrack.nominalFrameRate : 30.0f;
            gVideoFPS = (f >= 10.0f && f <= 120.0f) ? f : 30.0f;
        }

        if (!cachedAsset || !cachedTrack) {
            gNeedsReaderReload = YES;
            return nil;
        }

        double angle = atan2(cachedTrack.preferredTransform.b, cachedTrack.preferredTransform.a);
        if (fabs(angle - M_PI_2) < 0.05)          gVideoExifOrientation = 6;
        else if (fabs(angle + M_PI_2) < 0.05)     gVideoExifOrientation = 8;
        else if (fabs(fabs(angle) - M_PI) < 0.05) gVideoExifOrientation = 3;
        else                                       gVideoExifOrientation = 1;

        OSType outputFormat = originSubtype;
        if (outputFormat != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
            outputFormat != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
            outputFormat != kCVPixelFormatType_32BGRA) {
            outputFormat = kCVPixelFormatType_32BGRA;
        }

        NSError *error = nil;
        AVAssetReader *newReader = [AVAssetReader assetReaderWithAsset:cachedAsset error:&error];
        AVAssetReaderTrackOutput *newOutput = [[AVAssetReaderTrackOutput alloc]
            initWithTrack:cachedTrack
            outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(outputFormat)}];
        newOutput.alwaysCopiesSampleData = NO;
        [newReader addOutput:newOutput];

        if (![newReader startReading]) {
            gNeedsReaderReload = YES;
            return cachedPixelBuffer ? nil : nil;
        }

        reader = newReader;
        output = newOutput;
        readerFormat = outputFormat;
        gPlaybackStartRealTime = CACurrentMediaTime();
        gCurrentFrameNumber = -1;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (gPlaybackStartRealTime == 0) gPlaybackStartRealTime = now;

    CFTimeInterval elapsed = now - gPlaybackStartRealTime;
    if (gCachedDuration > 0.05 && elapsed >= gCachedDuration) {
        // Video loop transition: seamlessly restart reader without any black frame
        gPlaybackStartRealTime = now;
        elapsed = 0;
        gCurrentFrameNumber = -1;
        if (cachedAsset && cachedTrack) {
            NSError *err = nil;
            AVAssetReader *loopReader = [AVAssetReader assetReaderWithAsset:cachedAsset error:&err];
            AVAssetReaderTrackOutput *loopOutput = [[AVAssetReaderTrackOutput alloc]
                initWithTrack:cachedTrack
                outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(readerFormat)}];
            loopOutput.alwaysCopiesSampleData = NO;
            [loopReader addOutput:loopOutput];
            if ([loopReader startReading]) {
                reader = loopReader;
                output = loopOutput;
            }
        }
    }

    int targetFrameNumber = (int)(elapsed * gVideoFPS);
    if (targetFrameNumber != gCurrentFrameNumber) {
        CMSampleBufferRef rawBuffer = [output copyNextSampleBuffer];
        if (rawBuffer) {
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(rawBuffer);
            if (pb) {
                if (cachedPixelBuffer) CFRelease(cachedPixelBuffer);
                cachedPixelBuffer = (CVPixelBufferRef)CFRetain(pb);
            }
            CFRelease(rawBuffer);
            gCurrentFrameNumber = targetFrameNumber;
        }
    }

    if (!cachedPixelBuffer) return nil;

    CMSampleTimingInfo timing = {
        .duration               = CMSampleBufferGetDuration(originSampleBuffer),
        .presentationTimeStamp  = originPTS,
        .decodeTimeStamp        = CMSampleBufferGetDecodeTimeStamp(originSampleBuffer),
    };
    CMVideoFormatDescriptionRef fakeFormat = nil;
    CMSampleBufferRef fakeBuffer = nil;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, cachedPixelBuffer, &fakeFormat);
    if (fakeFormat) {
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, cachedPixelBuffer, true,
                                           nil, nil, fakeFormat, &timing, &fakeBuffer);
        CFRelease(fakeFormat);
    }
    return fakeBuffer;
}

static void (*orig_BWNodeOutput_emitSampleBuffer)(id, SEL, CMSampleBufferRef) = NULL;
static void hook_BWNodeOutput_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    CMSampleBufferRef fakeBuffer = VCamCopyFrameMatching(sampleBuffer);
    if (fakeBuffer) {
        VCamCopyPixelBuffer(CMSampleBufferGetImageBuffer(fakeBuffer),
                            CMSampleBufferGetImageBuffer(sampleBuffer));
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
        CFRelease(fakeBuffer);
    } else {
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
    }
}

static void (*orig_BWPixelTransferNode_renderSampleBuffer)(id, SEL, CMSampleBufferRef, id) = NULL;
static void hook_BWPixelTransferNode_renderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    orig_BWPixelTransferNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
}

static void (*orig_BWNode_renderSampleBuffer)(id, SEL, CMSampleBufferRef, id) = NULL;
static void hook_BWNode_renderSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer, id input) {
    orig_BWNode_renderSampleBuffer(self, _cmd, sampleBuffer, input);
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
    HookIfPresent("BWPixelTransferNode", @selector(renderSampleBuffer:forInput:),
                  (IMP)&hook_BWPixelTransferNode_renderSampleBuffer,
                  (IMP *)&orig_BWPixelTransferNode_renderSampleBuffer);
    HookIfPresent("BWNode", @selector(renderSampleBuffer:forInput:),
                  (IMP)&hook_BWNode_renderSampleBuffer,
                  (IMP *)&orig_BWNode_renderSampleBuffer);

    NSLog(@"[vcamios] mediaserverd hooks loaded; source=%s", kVCamTempFilePath);
}

// ─── SpringBoard UI (Compact Square HUD Layout ~175x175) ───────────────────

static void VCamFloatRefreshButton(void);
static void VCamFloatHideMenu(void);

@interface VCamPickerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end

@implementation VCamPickerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker
didFinishPickingMediaWithInfo:(NSDictionary *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) return;

    [gFileManager removeItemAtPath:kVCamTempFile error:nil];
    VCamRemoveFlag(kVCamPauseFlagPath);

    NSError *err = nil;
    BOOL copied = [gFileManager copyItemAtPath:url.path toPath:kVCamTempFile error:&err];
    if (!copied && [gFileManager fileExistsAtPath:kVCamTempFile]) {
        copied = [gFileManager replaceItemAtURL:[NSURL fileURLWithPath:kVCamTempFile]
                                  withItemAtURL:url
                                 backupItemName:nil
                                        options:NSFileManagerItemReplacementUsingNewMetadataOnly
                               resultingItemURL:nil
                                          error:&err];
    }
    if ([gFileManager fileExistsAtPath:kVCamTempFile]) {
        chmod(kVCamTempFilePath, 0666);
        if ([[VCAMLicenseManager sharedManager] isLicenseValid]) {
            VCamWriteFlag(kVCamEnabledFlagPath, "1");
        } else {
            [[VCAMLicenseManager sharedManager] promptActivationDialogWithReason:@"Vui lòng kích hoạt mã bản quyền để sử dụng video ảo!" presenter:[VCamFloat presenter]];
        }
    }
    VCamFloatRefreshButton();
    VCamFloatHideMenu();
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

@end

static UIViewController *VCamPresenter(void);

static void VCamSelectVideo(void) {
    static VCamPickerDelegate *delegate = nil;
    if (!delegate) delegate = [VCamPickerDelegate new];

    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.movie"];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    picker.allowsEditing = YES;
    picker.videoMaximumDuration = 600.0;
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
    CGFloat sz = 46;
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

    // Mini Floating Ball
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, sz, sz);
    btn.center = CGPointMake(screen.size.width - sz / 2 - 10, screen.size.height * 0.40);
    btn.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    btn.layer.cornerRadius = sz / 2;
    btn.layer.borderWidth = 1.0;
    btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
    [btn setTitle:@"📷" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:19];
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
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13.5];
    b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.25];
    b.layer.cornerRadius = 6;
    b.layer.borderWidth = 0.6;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.40].CGColor;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)_iconButtonWithTitle:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h color:(UIColor *)color sel:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, h);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:color forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14];
    b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.22];
    b.layer.cornerRadius = 8;
    b.layer.borderWidth = 0.6;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;
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
        VCamRemoveFlag(kVCamPauseFlagPath);
    } else {
        VCamWriteFlag(kVCamPauseFlagPath, "1");
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
    VCamRemoveFlag(kVCamEnabledFlagPath);
    VCamRemoveFlag(kVCamPauseFlagPath);
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
            VCamRemoveFlag(kVCamEnabledFlagPath);
            VCamRemoveFlag(kVCamPauseFlagPath);
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
