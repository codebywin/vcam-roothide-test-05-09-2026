//
//  VCAMFlashLivenessManager.m
//  VCAM iOS - KYC Active Flash Liveness Engine
//

#import "VCAMFlashLivenessManager.h"
#import "VCAMFlashBurstManager.h"
#import <dlfcn.h>
#import <sys/stat.h>

static const char *kVCAMFlashStateFileName = "vcam_flash_state";

typedef CFTypeRef (*UICreateScreenUIImageFunc)(void);

@interface VCAMFlashLivenessManager () {
    dispatch_source_t _samplingTimer;
    dispatch_queue_t _samplingQueue;
    BOOL _isEnabled;
    BOOL _isTestMode;
    CGFloat _intensity;
    float _smoothedR;
    float _smoothedG;
    float _smoothedB;
    NSInteger _testColorIndex;
    UICreateScreenUIImageFunc _uikitCreateScreenUIImage;
}
@end

@implementation VCAMFlashLivenessManager

+ (instancetype)sharedManager {
    static VCAMFlashLivenessManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMFlashLivenessManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _intensity = 0.35f;
        _smoothedR = 1.0f;
        _smoothedG = 1.0f;
        _smoothedB = 1.0f;
        _testColorIndex = 0;
        _samplingQueue = dispatch_queue_create("com.vcam.flash.sampler", DISPATCH_QUEUE_SERIAL);

        // Load UIKit screen capture function if in SpringBoard
        void *uikitHandle = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW | RTLD_GLOBAL);
        if (uikitHandle) {
            _uikitCreateScreenUIImage = (UICreateScreenUIImageFunc)dlsym(uikitHandle, "_UICreateScreenUIImage");
        }
        if (!_uikitCreateScreenUIImage) {
            _uikitCreateScreenUIImage = (UICreateScreenUIImageFunc)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
        }

        // Tự động bật giám sát màn hình ngầm để luôn sẵn sàng bắt chớp sáng chụp ảnh
        [self startScreenColorMonitoring];
    }
    return self;
}

#pragma mark - Properties

- (BOOL)isLivenessEnabled {
    return _isEnabled;
}

- (void)setLivenessEnabled:(BOOL)enabled {
    _isEnabled = enabled;
    VCAMFlashState s = [VCAMFlashLivenessManager currentFlashState];
    s.active = enabled;
    s.testMode = _isTestMode;
    s.intensity = (float)_intensity;
    [VCAMFlashLivenessManager saveFlashState:s];
}

- (BOOL)isTestModeEnabled {
    return _isTestMode;
}

- (void)setTestModeEnabled:(BOOL)enabled {
    _isTestMode = enabled;
    if (enabled) {
        _isEnabled = YES;
    }
    VCAMFlashState s = [VCAMFlashLivenessManager currentFlashState];
    s.active = _isEnabled;
    s.testMode = enabled;
    [VCAMFlashLivenessManager saveFlashState:s];

    if (_isEnabled) {
        [self startScreenColorMonitoring];
    } else {
        [self stopScreenColorMonitoring];
    }
}

- (CGFloat)flashIntensity {
    return _intensity;
}

- (void)setFlashIntensity:(CGFloat)intensity {
    if (intensity < 0.10f) intensity = 0.10f;
    if (intensity > 0.85f) intensity = 0.85f;
    _intensity = intensity;
    VCAMFlashState s = [VCAMFlashLivenessManager currentFlashState];
    s.intensity = (float)_intensity;
    [VCAMFlashLivenessManager saveFlashState:s];
}

#pragma mark - Shared File State & IPC

static NSArray<NSString *> *PossibleTmpDirs(void) {
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

static NSString *FindExistingStatePath(void) {
    for (NSString *dir in PossibleTmpDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashStateFileName]];
        if (access([p UTF8String], F_OK) == 0) {
            return p;
        }
    }
    for (NSString *dir in PossibleTmpDirs()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            return [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashStateFileName]];
        }
    }
    return [@"/var/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashStateFileName]];
}

+ (VCAMFlashState)currentFlashState {
    static VCAMFlashState cachedState = {1.0f, 1.0f, 1.0f, 0.35f, NO, NO};
    static NSTimeInterval lastReadTime = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastReadTime < 0.05) { // 50ms throttle cache
        return cachedState;
    }
    lastReadTime = now;

    NSString *path = FindExistingStatePath();
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        int act = 0, test = 0;
        float r = 1.0f, g = 1.0f, b = 1.0f, inten = 0.35f;
        if (fscanf(f, "%d %d %f %f %f %f", &act, &test, &r, &g, &b, &inten) >= 5) {
            cachedState.active = (act != 0);
            cachedState.testMode = (test != 0);
            cachedState.r = r;
            cachedState.g = g;
            cachedState.b = b;
            cachedState.intensity = (inten > 0.01f) ? inten : 0.35f;
        }
        fclose(f);
    }
    return cachedState;
}

+ (void)saveFlashState:(VCAMFlashState)state {
    char buf[128];
    snprintf(buf, sizeof(buf), "%d %d %.3f %.3f %.3f %.2f\n",
             state.active ? 1 : 0,
             state.testMode ? 1 : 0,
             state.r, state.g, state.b,
             state.intensity);

    for (NSString *dir in PossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashStateFileName]];
        FILE *f = fopen([filePath UTF8String], "w");
        if (f) {
            fputs(buf, f);
            fclose(f);
            chmod([filePath UTF8String], 0666);
        }
    }
}

#pragma mark - Screen Color Sampler (SpringBoard)

static void ComputeAverageRGB(CGImageRef cgImage, float *outR, float *outG, float *outB) {
    if (!cgImage) return;
    unsigned char pixel[4] = {255, 255, 255, 255};
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return;

    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, colorSpace,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
        CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), cgImage);
        CGContextRelease(context);
        *outR = (float)pixel[0] / 255.0f;
        *outG = (float)pixel[1] / 255.0f;
        *outB = (float)pixel[2] / 255.0f;
    }
    CGColorSpaceRelease(colorSpace);
}

- (void)startScreenColorMonitoring {
    if (_samplingTimer) return;

    _samplingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _samplingQueue);
    // Safe timer interval: 180ms (~5.5 fps, lightweight, perfectly catches 250-500ms KYC color flashes)
    dispatch_source_set_timer(_samplingTimer, DISPATCH_TIME_NOW, 180 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_samplingTimer, ^{
        [weakSelf _sampleTick];
    });
    dispatch_resume(_samplingTimer);
}

- (void)stopScreenColorMonitoring {
    if (_samplingTimer) {
        dispatch_source_cancel(_samplingTimer);
        _samplingTimer = nil;
    }
}

- (void)_sampleTick {
    // Chỉ lấy mẫu khi VCAM đang bật thay thế camera
    static BOOL sHasEnabled = NO;
    static NSTimeInterval sLastFlagCheck = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - sLastFlagCheck > 0.5) {
        sLastFlagCheck = now;
        sHasEnabled = (access("/var/tmp/vcam_enabled", F_OK) == 0 ||
                       access("/rootfs/private/var/tmp/vcam_enabled", F_OK) == 0 ||
                       access("/private/var/tmp/vcam_enabled", F_OK) == 0);
    }
    if (!sHasEnabled) return;

    if (_isTestMode && _isEnabled) {
        // Test Simulation: Cycle through common eKYC flash colors every 500ms (0% memory overhead)
        static const float testPalette[6][3] = {
            {1.00f, 1.00f, 1.00f}, // Sáng trắng
            {0.20f, 0.75f, 1.00f}, // Xanh lam (Cyan/Blue)
            {1.00f, 0.25f, 0.25f}, // Đỏ (Red)
            {0.30f, 0.95f, 0.35f}, // Xanh lục (Green)
            {1.00f, 0.90f, 0.20f}, // Vàng (Yellow)
            {0.90f, 0.30f, 0.90f}  // Tím hồng (Magenta)
        };

        static NSTimeInterval lastCycleTime = 0;
        if (now - lastCycleTime > 0.50) {
            lastCycleTime = now;
            _testColorIndex = (_testColorIndex + 1) % 6;
        }

        float targetR = testPalette[_testColorIndex][0];
        float targetG = testPalette[_testColorIndex][1];
        float targetB = testPalette[_testColorIndex][2];

        // Exponential Moving Average (EMA) smoothing
        _smoothedR = _smoothedR * 0.40f + targetR * 0.60f;
        _smoothedG = _smoothedG * 0.40f + targetG * 0.60f;
        _smoothedB = _smoothedB * 0.40f + targetB * 0.60f;

        VCAMFlashState s;
        s.active = YES;
        s.testMode = YES;
        s.r = _smoothedR;
        s.g = _smoothedG;
        s.b = _smoothedB;
        s.intensity = (float)_intensity;
        [VCAMFlashLivenessManager saveFlashState:s];
        return;
    }

    // Normal Auto-Detection: Sample actual screen color in real time with strict autorelease
    if (_uikitCreateScreenUIImage) {
        @autoreleasepool {
            CFTypeRef rawImg = _uikitCreateScreenUIImage();
            if (rawImg) {
                // CFBridgingRelease transfers ownership to ARC, ensuring immediate deallocation
                UIImage *screenImg = CFBridgingRelease(rawImg);
                CGImageRef cg = screenImg.CGImage;
                if (cg) {
                    float sampleR = 1.0f, sampleG = 1.0f, sampleB = 1.0f;
                    ComputeAverageRGB(cg, &sampleR, &sampleG, &sampleB);

                    // 1. LUÔN TỰ ĐỘNG BẮT CHỚP SÁNG CHỤP ẢNH (Auto Screen Flash on Capture)
                    [VCAMFlashBurstManager checkAndAutoTriggerWithScreenRGB:sampleR g:sampleG b:sampleB];

                    // 2. Nếu người dùng bật thêm nút ⚡ (KYC Flash) thì hắt thêm màu phản quang
                    if (_isEnabled) {
                        _smoothedR = _smoothedR * 0.35f + sampleR * 0.65f;
                        _smoothedG = _smoothedG * 0.35f + sampleG * 0.65f;
                        _smoothedB = _smoothedB * 0.35f + sampleB * 0.65f;

                        VCAMFlashState s;
                        s.active = YES;
                        s.testMode = NO;
                        s.r = _smoothedR;
                        s.g = _smoothedG;
                        s.b = _smoothedB;
                        s.intensity = (float)_intensity;
                        [VCAMFlashLivenessManager saveFlashState:s];
                    }
                }
            }
        }
    }
}

#pragma mark - CoreImage Photometric Lighting Engine (Metal GPU)

+ (CIImage *)applyFlashLightingToImage:(CIImage *)sourceImage
                                  size:(CGSize)size
                                 state:(VCAMFlashState)state {
    if (!sourceImage || !state.active || state.intensity <= 0.01f) {
        return sourceImage;
    }

    @try {
        float r = state.r;
        float g = state.g;
        float b = state.b;
        float intensity = state.intensity;
        if (intensity < 0.05f) intensity = 0.05f;
        if (intensity > 0.85f) intensity = 0.85f;

        // 1. Calculate lighting geometry: Soft spotlight concentrated on the face center
        CGFloat centerX = size.width / 2.0f;
        CGFloat centerY = size.height / 2.0f;
        CGFloat innerRadius = MIN(size.width, size.height) * 0.22f;
        CGFloat outerRadius = MAX(size.width, size.height) * 0.72f;

        CIColor *centerColor = [CIColor colorWithRed:r green:g blue:b alpha:intensity];
        CIColor *outerColor = [CIColor colorWithRed:r green:g blue:b alpha:intensity * 0.12f];

        CIFilter *radialGradient = [CIFilter filterWithName:@"CIRadialGradient"];
        [radialGradient setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
        [radialGradient setValue:@(innerRadius) forKey:@"inputRadius0"];
        [radialGradient setValue:@(outerRadius) forKey:@"inputRadius1"];
        [radialGradient setValue:centerColor forKey:@"inputColor0"];
        [radialGradient setValue:outerColor forKey:@"inputColor1"];

        CIImage *lightGradient = [radialGradient.outputImage imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];
        if (!lightGradient) return sourceImage;

        // 2. Blend lighting onto video frame via Soft Light (photometric screen reflection)
        CIFilter *blendFilter = [CIFilter filterWithName:@"CISoftLightBlendMode"];
        [blendFilter setValue:lightGradient forKey:kCIInputImageKey];
        [blendFilter setValue:sourceImage forKey:kCIInputBackgroundImageKey];
        CIImage *output = blendFilter.outputImage;

        return output ?: sourceImage;
    } @catch (NSException *ex) {
        NSLog(@"[VCAMFlashLivenessManager] Lighting error: %@", ex);
        return sourceImage;
    }
}

@end

