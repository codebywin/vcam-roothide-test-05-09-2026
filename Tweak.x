#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <VideoToolbox/VideoToolbox.h>
#if __has_include(<VideoToolbox/VTPixelTransferSession.h>)
#import <VideoToolbox/VTPixelTransferSession.h>
#endif

#ifndef VTPixelTransferSessionRef
typedef struct OpaqueVTPixelTransferSession *VTPixelTransferSessionRef;
#endif

#ifdef __cplusplus
extern "C" {
#endif
OSStatus VTPixelTransferSessionCreate(CFAllocatorRef allocator, VTPixelTransferSessionRef *pixelTransferSessionOut);
OSStatus VTPixelTransferSessionTransferImage(VTPixelTransferSessionRef session, CVPixelBufferRef sourceBuffer, CVPixelBufferRef destinationBuffer);
void VTPixelTransferSessionInvalidate(VTPixelTransferSessionRef session);
#ifdef __cplusplus
}
#endif

#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <substrate.h>
#include <string.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/stat.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static const char *kVCamTempFilePath         = "/private/var/tmp/vcam_temp.mov";
static const char *kVCamTempFilePathAlt      = "/var/tmp/vcam_temp.mov";
static const char *kVCamEnabledFlagPath      = "/private/var/tmp/vcam_enabled";
static const char *kVCamEnabledFlagPathAlt   = "/var/tmp/vcam_enabled";
static const char *kVCamPauseFlagPath        = "/private/var/tmp/vcam_paused";
static const char *kVCamPauseFlagPathAlt     = "/var/tmp/vcam_paused";
static const char *kVCamScaleFilePath        = "/private/var/tmp/vcam_scale";
static const char *kVCamScaleFilePathAlt     = "/var/tmp/vcam_scale";
static const char *kVCamOffsetXFilePath      = "/private/var/tmp/vcam_offset_x";
static const char *kVCamOffsetXFilePathAlt   = "/var/tmp/vcam_offset_x";
static const char *kVCamOffsetYFilePath      = "/private/var/tmp/vcam_offset_y";
static const char *kVCamOffsetYFilePathAlt   = "/var/tmp/vcam_offset_y";

static NSString *const kVCamTempFile         = @"/private/var/tmp/vcam_temp.mov";
static NSString *const kVCamTempFileAlt      = @"/var/tmp/vcam_temp.mov";

static NSFileManager *gFileManager = nil;
static NSDate *gLastTempFileModified = nil;
static int32_t gVideoExifOrientation = 1;

static void VCamWriteFlag(const char *path, const char *val) {
    if (!path) return;
    FILE *f = fopen(path, "w");
    if (f) {
        if (val) fputs(val, f);
        fclose(f);
    }
    chmod(path, 0666);
}

static void VCamRemoveFlag(const char *path) {
    if (path) unlink(path);
}

static void VCamWriteFlagDual(const char *p1, const char *p2, const char *val) {
    VCamWriteFlag(p1, val);
    if (p2 && strcmp(p1, p2) != 0) VCamWriteFlag(p2, val);
}

static void VCamRemoveFlagDual(const char *p1, const char *p2) {
    VCamRemoveFlag(p1);
    if (p2 && strcmp(p1, p2) != 0) VCamRemoveFlag(p2);
}

static BOOL VCamIsActive(void) {
    return (access(kVCamEnabledFlagPath, F_OK) == 0 || access(kVCamEnabledFlagPathAlt, F_OK) == 0);
}

static BOOL VCamIsPaused(void) {
    return (access(kVCamPauseFlagPath, F_OK) == 0 || access(kVCamPauseFlagPathAlt, F_OK) == 0);
}

static NSString *VCamGetExistingTempFilePath(void) {
    if ([gFileManager fileExistsAtPath:kVCamTempFile]) return kVCamTempFile;
    if ([gFileManager fileExistsAtPath:kVCamTempFileAlt]) return kVCamTempFileAlt;
    return kVCamTempFile;
}

static CGFloat VCamGetScale(void) {
    FILE *f = fopen(kVCamScaleFilePath, "r");
    if (!f) f = fopen(kVCamScaleFilePathAlt, "r");
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
    VCamWriteFlagDual(kVCamScaleFilePath, kVCamScaleFilePathAlt, buf);
}

static CGFloat VCamGetOffsetX(void) {
    FILE *f = fopen(kVCamOffsetXFilePath, "r");
    if (!f) f = fopen(kVCamOffsetXFilePathAlt, "r");
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
    if (!f) f = fopen(kVCamOffsetYFilePathAlt, "r");
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
    VCamWriteFlagDual(kVCamOffsetXFilePath, kVCamOffsetXFilePathAlt, bufX);
    VCamWriteFlagDual(kVCamOffsetYFilePath, kVCamOffsetYFilePathAlt, bufY);
}

static VTPixelTransferSessionRef VCamGetThreadTransferSession(void) {
    static __thread VTPixelTransferSessionRef threadSession = NULL;
    if (!threadSession) {
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &threadSession);
    }
    return threadSession;
}

static OSStatus VCamCopyPixelBuffer(CVPixelBufferRef source, CVPixelBufferRef target) {
    if (!source || !target) return -1;

    size_t srcW = CVPixelBufferGetWidth(source);
    size_t srcH = CVPixelBufferGetHeight(source);
    size_t dstW = CVPixelBufferGetWidth(target);
    size_t dstH = CVPixelBufferGetHeight(target);
    OSType srcFmt = CVPixelBufferGetPixelFormatType(source);
    OSType dstFmt = CVPixelBufferGetPixelFormatType(target);

    // Fast path: exact same format and dimensions
    if (srcW == dstW && srcH == dstH && srcFmt == dstFmt) {
        CVReturn retSrc = CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
        CVReturn retDst = CVPixelBufferLockBaseAddress(target, 0);
        if (retSrc == kCVReturnSuccess && retDst == kCVReturnSuccess) {
            size_t planes = CVPixelBufferIsPlanar(source) ? CVPixelBufferGetPlaneCount(source) : 1;
            for (size_t plane = 0; plane < planes; plane++) {
                void *srcBase = CVPixelBufferIsPlanar(source)
                    ? CVPixelBufferGetBaseAddressOfPlane(source, plane)
                    : CVPixelBufferGetBaseAddress(source);
                void *dstBase = CVPixelBufferIsPlanar(target)
                    ? CVPixelBufferGetBaseAddressOfPlane(target, plane)
                    : CVPixelBufferGetBaseAddress(target);
                if (!srcBase || !dstBase) continue;

                size_t srcBPR = CVPixelBufferIsPlanar(source)
                    ? CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                    : CVPixelBufferGetBytesPerRow(source);
                size_t dstBPR = CVPixelBufferIsPlanar(target)
                    ? CVPixelBufferGetBytesPerRowOfPlane(target, plane)
                    : CVPixelBufferGetBytesPerRow(target);
                size_t planeH = CVPixelBufferIsPlanar(source)
                    ? CVPixelBufferGetHeightOfPlane(source, plane)
                    : srcH;
                size_t bpr = MIN(srcBPR, dstBPR);
                for (size_t r = 0; r < planeH; r++) {
                    memcpy((uint8_t *)dstBase + r * dstBPR,
                           (uint8_t *)srcBase + r * srcBPR, bpr);
                }
            }
            CVPixelBufferUnlockBaseAddress(target, 0);
            CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
            return noErr;
        }
        if (retSrc == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
        if (retDst == kCVReturnSuccess) CVPixelBufferUnlockBaseAddress(target, 0);
    }

    // Hardware scaler via VideoToolbox (thread-local session, zero IOFence risk)
    VTPixelTransferSessionRef session = VCamGetThreadTransferSession();
    if (session) {
        return VTPixelTransferSessionTransferImage(session, source, target);
    }

    return -1;
}

static os_unfair_lock gReaderLock = OS_UNFAIR_LOCK_INIT;
static AVAsset *gAsset = nil;
static AVAssetTrack *gTrack = nil;
static AVAssetReader *gReader = nil;
static AVAssetReaderTrackOutput *gOutput = nil;
static CVPixelBufferRef gCachedPixelBuffer = NULL;
static CFTimeInterval gPlaybackStartTime = 0;
static Float64 gDuration = 0;
static float gFPS = 30.0f;
static int64_t gLastFrameIndex = -1;

static void VCamTearDownReader(void) {
    if (gReader) {
        // Safe tear down: only cancel if actively reading
        // Never cancel if status is Completed/Failed to avoid CFRelease(NULL) crash on iOS 16
        if (gReader.status == AVAssetReaderStatusReading) {
            @try {
                [gReader cancelReading];
            } @catch (__unused id ex) {}
        }
        gReader = nil;
        gOutput = nil;
    }
}

static void VCamStartReader(NSString *path) {
    VCamTearDownReader();

    if (!path || access(path.UTF8String, F_OK) != 0) return;

    if (!gAsset) {
        NSURL *url = [NSURL fileURLWithPath:path];
        gAsset = [AVAsset assetWithURL:url];
        gTrack = [[gAsset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (gAsset && gTrack) {
            gDuration = CMTimeGetSeconds(gAsset.duration);
            float f = gTrack.nominalFrameRate;
            gFPS = (f >= 10.0f && f <= 120.0f) ? f : 30.0f;
            NSLog(@"[vcamios] Asset loaded: duration=%.2fs, fps=%.1f", gDuration, gFPS);
        }
    }
    if (!gAsset || !gTrack) return;

    // Decode in standard BiPlanar Video Range (420v) at native video resolution
    NSDictionary *settings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    };

    NSError *err = nil;
    gReader = [AVAssetReader assetReaderWithAsset:gAsset error:&err];
    if (!gReader || err) {
        NSLog(@"[vcamios] Failed to create AVAssetReader: %@", err);
        gReader = nil;
        return;
    }

    gOutput = [[AVAssetReaderTrackOutput alloc] initWithTrack:gTrack outputSettings:settings];
    gOutput.alwaysCopiesSampleData = NO;
    if ([gReader canAddOutput:gOutput]) {
        [gReader addOutput:gOutput];
    }

    if (![gReader startReading]) {
        NSLog(@"[vcamios] startReading failed: %@", gReader.error);
        VCamTearDownReader();
    } else {
        gPlaybackStartTime = CACurrentMediaTime();
        gLastFrameIndex = -1;
    }
}

// Call with gReaderLock held!
static CVPixelBufferRef VCamAcquireCurrentPixelBufferLocked(void) {
    if (!VCamIsActive()) return NULL;

    NSString *tempPath = VCamGetExistingTempFilePath();
    if (access(tempPath.UTF8String, F_OK) != 0) return NULL;

    // Check if video file changed
    NSDate *modified = [[gFileManager attributesOfItemAtPath:tempPath error:nil] fileModificationDate];
    if (modified && ![modified isEqualToDate:gLastTempFileModified]) {
        gLastTempFileModified = modified;
        gAsset = nil;
        gTrack = nil;
        if (gCachedPixelBuffer) {
            CFRelease(gCachedPixelBuffer);
            gCachedPixelBuffer = NULL;
        }
        VCamStartReader(tempPath);
    }

    if (!gReader || !gOutput) {
        VCamStartReader(tempPath);
    }

    if (VCamIsPaused()) {
        return gCachedPixelBuffer;
    }

    CFTimeInterval now = CACurrentMediaTime();
    if (gPlaybackStartTime <= 0) gPlaybackStartTime = now;
    CFTimeInterval elapsed = now - gPlaybackStartTime;

    // Loop video when time reaches duration
    if (gDuration > 0.05 && elapsed >= gDuration) {
        VCamStartReader(tempPath);
        gPlaybackStartTime = now;
        elapsed = 0;
    }

    int64_t targetFrameIndex = (int64_t)(elapsed * gFPS);
    if (targetFrameIndex != gLastFrameIndex && gOutput) {
        CMSampleBufferRef sbuf = [gOutput copyNextSampleBuffer];
        if (sbuf) {
            CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sbuf);
            if (pb) {
                if (gCachedPixelBuffer) CFRelease(gCachedPixelBuffer);
                gCachedPixelBuffer = (CVPixelBufferRef)CFRetain(pb);
            }
            CFRelease(sbuf);
            gLastFrameIndex = targetFrameIndex;
        } else {
            // EOF reached: restart reader for loop
            VCamStartReader(tempPath);
            gPlaybackStartTime = now;
            if (gOutput) {
                CMSampleBufferRef loopBuf = [gOutput copyNextSampleBuffer];
                if (loopBuf) {
                    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(loopBuf);
                    if (pb) {
                        if (gCachedPixelBuffer) CFRelease(gCachedPixelBuffer);
                        gCachedPixelBuffer = (CVPixelBufferRef)CFRetain(pb);
                    }
                    CFRelease(loopBuf);
                    gLastFrameIndex = 0;
                }
            }
        }
    }

    return gCachedPixelBuffer;
}

static void (*orig_BWNodeOutput_emitSampleBuffer)(id, SEL, CMSampleBufferRef) = NULL;
static void hook_BWNodeOutput_emitSampleBuffer(id self, SEL _cmd, CMSampleBufferRef sampleBuffer) {
    if (!sampleBuffer || !VCamIsActive()) {
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }

    CVImageBufferRef camPixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!camPixelBuffer) {
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }

    size_t camW = CVPixelBufferGetWidth(camPixelBuffer);
    size_t camH = CVPixelBufferGetHeight(camPixelBuffer);
    if (camW < 100 || camH < 100) {
        orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
        return;
    }

    CVPixelBufferRef videoFrame = NULL;
    os_unfair_lock_lock(&gReaderLock);
    CVPixelBufferRef curPB = VCamAcquireCurrentPixelBufferLocked();
    if (curPB) {
        videoFrame = (CVPixelBufferRef)CFRetain(curPB);
    }
    os_unfair_lock_unlock(&gReaderLock);

    if (videoFrame) {
        VCamCopyPixelBuffer(videoFrame, camPixelBuffer);
        CFRelease(videoFrame);
    }

    orig_BWNodeOutput_emitSampleBuffer(self, _cmd, sampleBuffer);
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
    void *hCMCapture = dlopen("/System/Library/PrivateFrameworks/CMCapture.framework/CMCapture", RTLD_NOW);
    if (!hCMCapture) {
        NSLog(@"[vcamios] dlopen CMCapture failed: %s", dlerror());
        hCMCapture = dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_NOW);
    }
    NSLog(@"[vcamios] CMCapture handle = %p", hCMCapture);

    HookIfPresent("BWNodeOutput", @selector(emitSampleBuffer:),
                  (IMP)&hook_BWNodeOutput_emitSampleBuffer,
                  (IMP *)&orig_BWNodeOutput_emitSampleBuffer);

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
    [gFileManager removeItemAtPath:kVCamTempFileAlt error:nil];
    VCamRemoveFlagDual(kVCamPauseFlagPath, kVCamPauseFlagPathAlt);

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
    [gFileManager copyItemAtPath:url.path toPath:kVCamTempFileAlt error:nil];

    if ([gFileManager fileExistsAtPath:kVCamTempFile] || [gFileManager fileExistsAtPath:kVCamTempFileAlt]) {
        chmod(kVCamTempFilePath, 0666);
        chmod(kVCamTempFilePathAlt, 0666);
        VCamWriteFlagDual(kVCamEnabledFlagPath, kVCamEnabledFlagPathAlt, "1");
        NSLog(@"[vcamios] Picker saved video to %s and %s", kVCamTempFilePath, kVCamTempFilePathAlt);
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
        BOOL active = VCamIsActive();
        BOOL isPaused = VCamIsPaused();
        gVCamFloat->_btn.alpha = active ? 0.90 : 0.40;
        if (!active) {
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

    // ── 3. Bottom: 4 Action Icon Buttons (Horizontal Row) ──
    CGFloat iconW = 34, iconH = 30, iconY = 135;
    CGFloat totalIconsW = 4 * iconW + 3 * 6;
    CGFloat startIconX = (w - totalIconsW) / 2.0;

    // Icon 1: Chọn video (🎬)
    UIButton *pickBtn = [self _iconButtonWithTitle:@"🎬" x:startIconX y:iconY w:iconW h:iconH color:[UIColor whiteColor] sel:@selector(_menuSelectVideo)];
    [panel addSubview:pickBtn];

    // Icon 2: Tạm dừng / Tiếp tục (⏸️ / ▶️)
    NSString *pauseIcon = isPaused ? @"▶️" : @"⏸️";
    UIColor *pauseCol = isPaused ? [UIColor colorWithRed:0.4 green:0.95 blue:0.5 alpha:1] : [UIColor colorWithRed:1.0 green:0.85 blue:0.3 alpha:1];
    UIButton *pauseBtn = [self _iconButtonWithTitle:pauseIcon x:startIconX + iconW + 6 y:iconY w:iconW h:iconH color:pauseCol sel:@selector(_menuTogglePause)];
    [panel addSubview:pauseBtn];

    // Icon 3: Xóa video (🗑️)
    UIButton *trashBtn = [self _iconButtonWithTitle:@"🗑️" x:startIconX + (iconW + 6)*2 y:iconY w:iconW h:iconH color:[UIColor colorWithRed:1 green:0.45 blue:0.45 alpha:1] sel:@selector(_menuDisable)];
    [panel addSubview:trashBtn];

    // Icon 4: Đóng (✕)
    UIButton *closeBtn = [self _iconButtonWithTitle:@"✕" x:startIconX + (iconW + 6)*3 y:iconY w:iconW h:iconH color:[UIColor colorWithWhite:0.85 alpha:1] sel:@selector(_hideMenu)];
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
    if (VCamIsPaused()) {
        VCamRemoveFlagDual(kVCamPauseFlagPath, kVCamPauseFlagPathAlt);
    } else {
        VCamWriteFlagDual(kVCamPauseFlagPath, kVCamPauseFlagPathAlt, "1");
    }
    [self _hideMenu];
    VCamFloatRefreshButton();
}

- (void)_menuSelectVideo {
    [self _hideMenu];
    VCamSelectVideo();
}

- (void)_menuDisable {
    VCamRemoveFlagDual(kVCamEnabledFlagPath, kVCamEnabledFlagPathAlt);
    VCamRemoveFlagDual(kVCamPauseFlagPath, kVCamPauseFlagPathAlt);
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
        [VCamFloat show];
    });
}

%ctor {
    @autoreleasepool {
        gFileManager = NSFileManager.defaultManager;
        [gFileManager createDirectoryAtPath:@"/private/var/tmp"
                withIntermediateDirectories:YES attributes:nil error:nil];
        [gFileManager createDirectoryAtPath:@"/var/tmp"
                withIntermediateDirectories:YES attributes:nil error:nil];
        chmod("/private/var/tmp", 0777);
        chmod("/var/tmp", 0777);

        NSString *processName = NSProcessInfo.processInfo.processName;
        NSLog(@"[vcamios] ctor loaded in process: %@", processName);
        if ([processName isEqualToString:@"mediaserverd"]) {
            VCamInitMediaServerHooks();
        } else if ([processName isEqualToString:@"SpringBoard"]) {
            VCamInitSpringBoardHooks();
        }
    }
}
