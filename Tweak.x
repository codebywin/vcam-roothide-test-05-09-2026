#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <substrate.h>
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
        VCamWriteFlag(kVCamEnabledFlagPath, "1");
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
    UIButton *_btn;            // Circular floating ball
    UIView *_menuOverlay;      // Touch-outside dismiss layer
    UIView *_dockView;         // Vertical capsule dock
    UIView *_branchView;       // Popout horizontal branch for Zoom & Pan
    UILabel *_zoomLabel;
    UISlider *_zoomSlider;
    UIButton *_btnPause;
    UIButton *_btnZoom;
    BOOL _isBranchVisible;
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
        [gVCamFloat _updateFloatingState];
    });
}

+ (void)hideMenu {
    if (gVCamFloat) [gVCamFloat _hideMenu];
}

- (void)_updateFloatingState {
    BOOL active = VCamIsActive();
    BOOL isPaused = VCamIsPaused();
    _btn.alpha = active ? 0.95 : 0.45;
    if (!active) {
        [_btn setTitle:@"📷" forState:UIControlStateNormal];
        _btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.40].CGColor;
    } else {
        [_btn setTitle:isPaused ? @"⏸️" : @"🎥" forState:UIControlStateNormal];
        _btn.layer.borderColor = isPaused
            ? [UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:0.85].CGColor
            : [UIColor colorWithRed:0.25 green:0.90 blue:0.45 alpha:0.85].CGColor;
    }
}

- (void)_setup {
    if (_win) return;
    CGFloat sz = 50;
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

    // Floating Button (Model 5 Collapsed Ball)
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, sz, sz);
    btn.center = CGPointMake(screen.size.width - sz / 2 - 10, screen.size.height * 0.42);
    btn.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.75];
    btn.layer.cornerRadius = sz / 2;
    btn.layer.borderWidth = 1.5;
    btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.45].CGColor;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOpacity = 0.4;
    btn.layer.shadowRadius = 6.0;
    btn.layer.shadowOffset = CGSizeMake(0, 3);
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
    [self _updateFloatingState];
}

- (void)_tap {
    if (_dockView) {
        [self _hideMenu];
    } else {
        [self _showMenu];
    }
}

- (UIButton *)_createDockRoundButtonWithTitle:(NSString *)title iconSize:(CGFloat)iconSize tag:(NSInteger)tag sel:(SEL)sel {
    CGFloat btnSz = 50;
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(0, 0, btnSz, btnSz);
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:iconSize];
    b.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.60];
    b.layer.cornerRadius = btnSz / 2;
    b.layer.borderWidth = 1.0;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    b.layer.shadowColor = [UIColor blackColor].CGColor;
    b.layer.shadowOpacity = 0.25;
    b.layer.shadowRadius = 4.0;
    b.layer.shadowOffset = CGSizeMake(0, 2);
    b.tag = tag;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)_showMenu {
    if (_dockView) return;

    CGRect screen = UIScreen.mainScreen.bounds;
    BOOL isRight = (_btn.center.x > screen.size.width / 2);
    _curOffsetX = VCamGetOffsetX();
    _curOffsetY = VCamGetOffsetY();
    _isBranchVisible = NO;

    // Full screen dismiss overlay
    UIView *overlay = [[UIView alloc] initWithFrame:_rootVC.view.bounds];
    overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.15];
    UITapGestureRecognizer *dismiss = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_hideMenu)];
    [overlay addGestureRecognizer:dismiss];

    // Vertical Capsule Dock Frame: 64 wide x 310 high (5 buttons)
    CGFloat dockW = 64, dockH = 310;
    CGFloat dockX = isRight ? (_btn.frame.origin.x - dockW - 10) : (CGRectGetMaxX(_btn.frame) + 10);
    dockX = MAX(10, MIN(dockX, screen.size.width - dockW - 10));

    CGFloat dockY = _btn.center.y - dockH / 2;
    dockY = MAX(60, MIN(dockY, screen.size.height - dockH - 40));

    UIView *dock = [[UIView alloc] initWithFrame:CGRectMake(dockX, dockY, dockW, dockH)];
    dock.backgroundColor = [UIColor clearColor];
    dock.layer.cornerRadius = dockW / 2; // Capsule shape
    dock.layer.masksToBounds = YES;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = dock.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.alpha = 0.88;
    [dock addSubview:blur];

    UIView *borderOverlay = [[UIView alloc] initWithFrame:dock.bounds];
    borderOverlay.backgroundColor = [UIColor clearColor];
    borderOverlay.layer.cornerRadius = dockW / 2;
    borderOverlay.layer.borderWidth = 1.2;
    borderOverlay.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    borderOverlay.userInteractionEnabled = NO;
    [dock addSubview:borderOverlay];

    // Buttons stacked vertically: 5 large 50x50 buttons
    CGFloat btnSz = 50;
    CGFloat startY = 10;
    CGFloat spacing = 10;

    // 1. Pick Video (🎬)
    UIButton *btnPick = [self _createDockRoundButtonWithTitle:@"🎬" iconSize:24 tag:1 sel:@selector(_menuSelectVideo)];
    btnPick.center = CGPointMake(dockW / 2, startY + btnSz / 2);
    [dock addSubview:btnPick];

    // 2. Play / Pause (⏯️)
    BOOL isPaused = VCamIsPaused();
    NSString *pauseTitle = isPaused ? @"▶️" : @"⏸️";
    _btnPause = [self _createDockRoundButtonWithTitle:pauseTitle iconSize:24 tag:2 sel:@selector(_menuTogglePause)];
    _btnPause.center = CGPointMake(dockW / 2, startY + (btnSz + spacing) + btnSz / 2);
    if (VCamIsActive()) {
        _btnPause.layer.borderColor = isPaused
            ? [UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:0.9].CGColor
            : [UIColor colorWithRed:0.25 green:0.90 blue:0.45 alpha:0.9].CGColor;
    }
    [dock addSubview:_btnPause];

    // 3. Zoom & Pan (🔍)
    _btnZoom = [self _createDockRoundButtonWithTitle:@"🔍" iconSize:22 tag:3 sel:@selector(_toggleBranch)];
    _btnZoom.center = CGPointMake(dockW / 2, startY + (btnSz + spacing) * 2 + btnSz / 2);
    [dock addSubview:_btnZoom];

    // 4. Trash / Disable (🗑️)
    UIButton *btnTrash = [self _createDockRoundButtonWithTitle:@"🗑️" iconSize:22 tag:4 sel:@selector(_menuDisable)];
    btnTrash.center = CGPointMake(dockW / 2, startY + (btnSz + spacing) * 3 + btnSz / 2);
    btnTrash.backgroundColor = [UIColor colorWithRed:0.8 green:0.15 blue:0.15 alpha:0.35];
    btnTrash.layer.borderColor = [UIColor colorWithRed:1.0 green:0.3 blue:0.3 alpha:0.5].CGColor;
    [dock addSubview:btnTrash];

    // 5. Close / Collapse (✕)
    UIButton *btnClose = [self _createDockRoundButtonWithTitle:@"✕" iconSize:20 tag:5 sel:@selector(_hideMenu)];
    btnClose.center = CGPointMake(dockW / 2, startY + (btnSz + spacing) * 4 + btnSz / 2);
    [btnClose setTitleColor:[UIColor colorWithWhite:0.9 alpha:1.0] forState:UIControlStateNormal];
    [dock addSubview:btnClose];

    [overlay addSubview:dock];
    _dockView = dock;
    _menuOverlay = overlay;

    // Popout Branch for Zoom & Pan (initially hidden/collapsed)
    [self _buildBranchViewIsRight:isRight dockFrame:dock.frame];

    [_rootVC.view insertSubview:overlay belowSubview:_btn];

    // Smooth opening spring animation
    dock.transform = CGAffineTransformMakeScale(0.7, 0.7);
    dock.alpha = 0;
    overlay.alpha = 0;
    [UIView animateWithDuration:0.30 delay:0
         usingSpringWithDamping:0.75 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        overlay.alpha = 1.0;
        dock.alpha = 1.0;
        dock.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)_buildBranchViewIsRight:(BOOL)isRight dockFrame:(CGRect)dockFrame {
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat branchW = 190, branchH = 145;

    // Align branch horizontally with Zoom button
    CGFloat zoomCenterY = dockFrame.origin.y + 10 + (50 + 10) * 2 + 25;
    CGFloat branchY = zoomCenterY - branchH / 2;
    branchY = MAX(60, MIN(branchY, screen.size.height - branchH - 40));

    CGFloat branchX = isRight ? (dockFrame.origin.x - branchW - 8) : (CGRectGetMaxX(dockFrame) + 8);
    branchX = MAX(8, MIN(branchX, screen.size.width - branchW - 8));

    UIView *branch = [[UIView alloc] initWithFrame:CGRectMake(branchX, branchY, branchW, branchH)];
    branch.backgroundColor = [UIColor clearColor];
    branch.layer.cornerRadius = 20;
    branch.layer.masksToBounds = YES;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
    blur.frame = branch.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.alpha = 0.90;
    [branch addSubview:blur];

    UIView *border = [[UIView alloc] initWithFrame:branch.bounds];
    border.layer.cornerRadius = 20;
    border.layer.borderWidth = 1.2;
    border.layer.borderColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:0.6].CGColor;
    border.userInteractionEnabled = NO;
    [branch addSubview:border];

    // Top: Zoom label & slider
    CGFloat curScale = VCamGetScale();
    _zoomLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, branchW - 20, 18)];
    _zoomLabel.text = [NSString stringWithFormat:@"Zoom: %.1fx", curScale];
    _zoomLabel.textColor = [UIColor whiteColor];
    _zoomLabel.font = [UIFont boldSystemFontOfSize:13];
    _zoomLabel.textAlignment = NSTextAlignmentCenter;
    [branch addSubview:_zoomLabel];

    _zoomSlider = [[UISlider alloc] initWithFrame:CGRectMake(12, 28, branchW - 24, 24)];
    _zoomSlider.minimumValue = 1.0f;
    _zoomSlider.maximumValue = 2.5f;
    _zoomSlider.value = curScale;
    _zoomSlider.tintColor = [UIColor colorWithRed:0.25 green:0.85 blue:1.0 alpha:1.0];
    [_zoomSlider addTarget:self action:@selector(_sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [branch addSubview:_zoomSlider];

    // Bottom: D-Pad 4 directional buttons + Center Reset
    CGFloat dW = 38, dH = 26;
    CGFloat midX = (branchW - dW) / 2;
    CGFloat padTopY = 56;

    // Up
    [branch addSubview:[self _dpadButtonWithTitle:@"▲" x:midX y:padTopY w:dW h:dH sel:@selector(_moveUp)]];

    // Left | Reset | Right
    CGFloat row2Y = padTopY + dH + 3;
    [branch addSubview:[self _dpadButtonWithTitle:@"◀" x:midX - dW - 6 y:row2Y w:dW h:dH sel:@selector(_moveLeft)]];
    [branch addSubview:[self _dpadButtonWithTitle:@"●" x:midX y:row2Y w:dW h:dH sel:@selector(_moveReset)]];
    [branch addSubview:[self _dpadButtonWithTitle:@"▶" x:midX + dW + 6 y:row2Y w:dW h:dH sel:@selector(_moveRight)]];

    // Down
    CGFloat row3Y = row2Y + dH + 3;
    [branch addSubview:[self _dpadButtonWithTitle:@"▼" x:midX y:row3Y w:dW h:dH sel:@selector(_moveDown)]];

    branch.alpha = 0;
    branch.hidden = YES;
    [_menuOverlay addSubview:branch];
    _branchView = branch;
}

- (UIButton *)_dpadButtonWithTitle:(NSString *)title x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h sel:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(x, y, w, h);
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    b.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.55];
    b.layer.cornerRadius = 6;
    b.layer.borderWidth = 0.8;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)_toggleBranch {
    _isBranchVisible = !_isBranchVisible;
    if (_isBranchVisible) {
        _branchView.hidden = NO;
        _btnZoom.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.9 alpha:0.45];
        _btnZoom.layer.borderColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:0.85].CGColor;
        _branchView.transform = CGAffineTransformMakeScale(0.8, 0.8);
        [UIView animateWithDuration:0.25 delay:0
             usingSpringWithDamping:0.75 initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self->_branchView.alpha = 1.0;
            self->_branchView.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        _btnZoom.backgroundColor = [UIColor colorWithWhite:0.18 alpha:0.60];
        _btnZoom.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
        [UIView animateWithDuration:0.20 animations:^{
            self->_branchView.alpha = 0;
            self->_branchView.transform = CGAffineTransformMakeScale(0.8, 0.8);
        } completion:^(__unused BOOL f) {
            self->_branchView.hidden = YES;
        }];
    }
}

- (void)_hideMenu {
    if (!_dockView) return;
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_dockView.alpha = 0;
        self->_dockView.transform = CGAffineTransformMakeScale(0.7, 0.7);
        if (self->_branchView) {
            self->_branchView.alpha = 0;
            self->_branchView.transform = CGAffineTransformMakeScale(0.7, 0.7);
        }
        self->_menuOverlay.alpha = 0;
    } completion:^(__unused BOOL f) {
        [self->_dockView removeFromSuperview];
        [self->_branchView removeFromSuperview];
        [self->_menuOverlay removeFromSuperview];
        self->_dockView = nil;
        self->_branchView = nil;
        self->_menuOverlay = nil;
        self->_isBranchVisible = NO;
    }];
}

- (void)_sliderChanged:(UISlider *)slider {
    CGFloat scale = slider.value;
    if (scale < 1.0f) scale = 1.0f;
    if (scale > 2.5f) scale = 2.5f;
    VCamSetScale(scale);
    _zoomLabel.text = [NSString stringWithFormat:@"Zoom: %.1fx", scale];
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
    VCamSetScale(1.0f);
    _zoomSlider.value = 1.0f;
    _zoomLabel.text = @"Zoom: 1.0x";
}

- (void)_menuTogglePause {
    if (VCamIsPaused()) {
        VCamRemoveFlag(kVCamPauseFlagPath);
    } else {
        VCamWriteFlag(kVCamPauseFlagPath, "1");
    }
    BOOL isPaused = VCamIsPaused();
    [_btnPause setTitle:(isPaused ? @"▶️" : @"⏸️") forState:UIControlStateNormal];
    _btnPause.layer.borderColor = isPaused
        ? [UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:0.9].CGColor
        : [UIColor colorWithRed:0.25 green:0.90 blue:0.45 alpha:0.9].CGColor;
    [self _updateFloatingState];
}

- (void)_menuSelectVideo {
    [self _hideMenu];
    VCamSelectVideo();
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
    CGFloat pad = 12 + btn.bounds.size.width / 2;
    CGFloat x = btn.center.x < screen.size.width / 2
        ? pad : screen.size.width - pad;
    CGFloat halfH = btn.bounds.size.height / 2;
    CGFloat y = MAX(80 + halfH, MIN(btn.center.y, screen.size.height - 80 - halfH));
    [UIView animateWithDuration:0.35 delay:0
         usingSpringWithDamping:0.72 initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ btn.center = CGPointMake(x, y); }
                     completion:nil];
}

@end

static UIViewController *VCamPresenter(void) { return [VCamFloat presenter]; }
static void VCamFloatRefreshButton(void)     { [VCamFloat refreshButton]; }
static void VCamFloatHideMenu(void)          { [VCamFloat hideMenu]; }

static void VCamInitSpringBoardHooks(void) {
    if (@available(iOS 13.0, *)) {
        [[NSNotificationCenter defaultCenter] addObserverForName:UISceneDidActivateNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            [VCamFloat show];
        }];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [VCamFloat show];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
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
