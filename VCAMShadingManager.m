//
//  VCAMShadingManager.m
//  VCAM iOS - 3D Volumetric Face Shading & Camera Sensor Noise Engine
//

#import "VCAMShadingManager.h"
#import <sys/stat.h>
#import <unistd.h>

static const char *kVCAMShadingStateFileName = "vcam_shading_state";

static NSArray<NSString *> *ShadingPossibleDirs(void) {
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

static NSString *FindExistingShadingStatePath(void) {
    static NSString *cachedPath = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSString *dir in ShadingPossibleDirs()) {
            NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
            if (access([p UTF8String], F_OK) == 0) {
                cachedPath = p;
                break;
            }
        }
        if (!cachedPath) {
            for (NSString *dir in ShadingPossibleDirs()) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) {
                    cachedPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
                    break;
                }
            }
        }
        if (!cachedPath) {
            cachedPath = [@"/var/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
        }
    });
    return cachedPath;
}

@interface VCAMShadingManager () {
    BOOL _shadingEnabled;
    BOOL _grainEnabled;
    CGFloat _shadingIntensity;
    CGFloat _grainIntensity;
}
@end

@implementation VCAMShadingManager

+ (instancetype)sharedManager {
    static VCAMShadingManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMShadingManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        VCAMShadingState s = [VCAMShadingManager currentShadingState];
        _shadingEnabled = s.shadingEnabled;
        _grainEnabled = s.grainEnabled;
        _shadingIntensity = s.shadingIntensity;
        _grainIntensity = s.grainIntensity;
    }
    return self;
}

#pragma mark - Properties

- (BOOL)isShadingEnabled {
    return _shadingEnabled;
}

- (void)setShadingEnabled:(BOOL)shadingEnabled {
    _shadingEnabled = shadingEnabled;
    [self _persistState];
}

- (BOOL)isGrainEnabled {
    return _grainEnabled;
}

- (void)setGrainEnabled:(BOOL)grainEnabled {
    _grainEnabled = grainEnabled;
    [self _persistState];
}

- (CGFloat)shadingIntensity {
    return _shadingIntensity;
}

- (void)setShadingIntensity:(CGFloat)shadingIntensity {
    if (shadingIntensity < 0.05f) shadingIntensity = 0.05f;
    if (shadingIntensity > 1.0f) shadingIntensity = 1.0f;
    _shadingIntensity = shadingIntensity;
    [self _persistState];
}

- (CGFloat)grainIntensity {
    return _grainIntensity;
}

- (void)setGrainIntensity:(CGFloat)grainIntensity {
    if (grainIntensity < 0.02f) grainIntensity = 0.02f;
    if (grainIntensity > 0.80f) grainIntensity = 0.80f;
    _grainIntensity = grainIntensity;
    [self _persistState];
}

- (void)_persistState {
    VCAMShadingState s;
    s.shadingEnabled = _shadingEnabled;
    s.grainEnabled = _grainEnabled;
    s.shadingIntensity = (float)_shadingIntensity;
    s.grainIntensity = (float)_grainIntensity;
    [VCAMShadingManager saveShadingState:s];
}

#pragma mark - Shared State IPC

+ (VCAMShadingState)currentShadingState {
    static VCAMShadingState cachedState = {YES, YES, 0.45f, 0.28f};
    static NSTimeInterval lastReadTime = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastReadTime < 0.25) {
        return cachedState;
    }
    lastReadTime = now;

    NSString *path = FindExistingShadingStatePath();
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        int sEn = 1, gEn = 1;
        float sInt = 0.45f, gInt = 0.28f;
        if (fscanf(f, "%d %d %f %f", &sEn, &gEn, &sInt, &gInt) >= 2) {
            cachedState.shadingEnabled = (sEn != 0);
            cachedState.grainEnabled = (gEn != 0);
            cachedState.shadingIntensity = (sInt > 0.01f) ? sInt : 0.45f;
            cachedState.grainIntensity = (gInt > 0.01f) ? gInt : 0.28f;
        }
        fclose(f);
    }
    return cachedState;
}

+ (void)saveShadingState:(VCAMShadingState)state {
    char buf[128];
    snprintf(buf, sizeof(buf), "%d %d %.2f %.2f\n",
             state.shadingEnabled ? 1 : 0,
             state.grainEnabled ? 1 : 0,
             state.shadingIntensity,
             state.grainIntensity);

    for (NSString *dir in ShadingPossibleDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
        FILE *f = fopen([filePath UTF8String], "w");
        if (f) {
            fputs(buf, f);
            fclose(f);
            chmod([filePath UTF8String], 0666);
        }
    }
}

#pragma mark - CoreImage Metal Processing Pipeline

+ (CIImage *)apply3DShadingAndGrainToImage:(CIImage *)image
                                     size:(CGSize)size
                                    state:(VCAMShadingState)state {
    if (!image || size.width <= 0 || size.height <= 0) return image;
    if (!state.shadingEnabled && !state.grainEnabled) return image;

    CIImage *currentImage = image;

    // === DIAGNOSTIC TEST: Tint màu XANH LÁ mạnh để xác nhận CIContext pipeline đang chạy ===
    // Nếu video có màu xanh lá rõ ràng → pipeline OK, shading đang được áp dụng
    // Ghi log ra nhiều đường dẫn khác nhau
    static NSTimeInterval lastLog = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastLog > 2.0) {
        lastLog = now;
        const char *logPaths[] = {
            "/rootfs/private/var/tmp/vcam_shading.log",
            "/var/tmp/vcam_shading.log",
            "/private/var/tmp/vcam_shading.log",
            "/var/mobile/vcam_shading.log",
            NULL
        };
        for (int pi = 0; logPaths[pi]; pi++) {
            FILE *f = fopen(logPaths[pi], "a");
            if (f) {
                fprintf(f, "[Shading] CALLED Shading=%d (%.2f) Grain=%d (%.2f) Size=%.0fx%.0f\n",
                        state.shadingEnabled, state.shadingIntensity,
                        state.grainEnabled, state.grainIntensity,
                        size.width, size.height);
                fclose(f);
                chmod(logPaths[pi], 0666);
                break; // Ghi được 1 đường dẫn là đủ
            }
        }
    }


    // ──────────────────────────────────────────────────────────────────────────
    // 1. ĐỔ BÓNG KIỂU ÁNH ĐÈN CHIẾU (Studio Center-Light Effect)
    //    - Vùng sáng ở tâm màn hình (Screen blend = chỉ làm sáng, không tối)
    //    - Mép ngoài tối tự nhiên như bóng đổ
    // ──────────────────────────────────────────────────────────────────────────
    if (state.shadingEnabled && state.shadingIntensity > 0.02f) {
        @try {
            float intensity = state.shadingIntensity;
            CGFloat centerX = size.width  * 0.50f;
            CGFloat centerY = size.height * 0.50f; // Đúng tâm màn hình
            CGFloat baseR   = MIN(size.width, size.height);

            // ── LAYER 1: Vùng sáng tâm (đèn chiếu từ phía trước) ──
            // innerColor: trắng ấm bán trong suốt → Screen blend chỉ làm sáng
            // outerColor: trong suốt → không ảnh hưởng mép
            {
                CIColor *lightCenter = [CIColor colorWithRed:1.0f green:0.97f blue:0.90f
                                                       alpha:intensity * 0.38f];
                CIColor *lightEdge   = [CIColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.0f];

                CIFilter *lightGrad = [CIFilter filterWithName:@"CIRadialGradient"];
                [lightGrad setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
                [lightGrad setValue:@(baseR * 0.15f) forKey:@"inputRadius0"]; // Vùng sáng đều
                [lightGrad setValue:@(baseR * 0.60f) forKey:@"inputRadius1"]; // Fade ra
                [lightGrad setValue:lightCenter forKey:@"inputColor0"];
                [lightGrad setValue:lightEdge   forKey:@"inputColor1"];

                CIImage *lightImg = lightGrad.outputImage;
                if (lightImg) {
                    lightImg = [lightImg imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];
                    // Screen blend = chỉ làm sáng, pixel tối hơn không thay đổi
                    CIFilter *screenBlend = [CIFilter filterWithName:@"CIScreenBlendMode"];
                    [screenBlend setValue:lightImg    forKey:kCIInputImageKey];
                    [screenBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                    CIImage *lit = screenBlend.outputImage;
                    if (lit) currentImage = lit;
                }
            }

            // ── LAYER 2: Vignette tối mép ngoài (bóng xung quanh) ──
            // Tạo cảm giác ánh sáng tập trung vào tâm, viền ngoài rơi vào bóng tối nhẹ
            {
                CIColor *shadowCenter = [CIColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.0f];
                CIColor *shadowEdge   = [CIColor colorWithRed:0.0f green:0.0f blue:0.0f
                                                        alpha:intensity * 0.28f];

                CIFilter *shadowGrad = [CIFilter filterWithName:@"CIRadialGradient"];
                [shadowGrad setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
                [shadowGrad setValue:@(baseR * 0.40f) forKey:@"inputRadius0"]; // Vùng tâm không tối
                [shadowGrad setValue:@(baseR * 0.75f) forKey:@"inputRadius1"]; // Fade tối ra mép
                [shadowGrad setValue:shadowCenter forKey:@"inputColor0"];
                [shadowGrad setValue:shadowEdge   forKey:@"inputColor1"];

                CIImage *shadowImg = shadowGrad.outputImage;
                if (shadowImg) {
                    // Elip dọc theo tỷ lệ mặt người
                    CGAffineTransform t = CGAffineTransformIdentity;
                    t = CGAffineTransformTranslate(t, centerX, centerY);
                    t = CGAffineTransformScale(t, 1.0f, 1.20f);
                    t = CGAffineTransformTranslate(t, -centerX, -centerY);
                    shadowImg = [shadowImg imageByApplyingTransform:t];
                    shadowImg = [shadowImg imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                    CIFilter *overBlend = [CIFilter filterWithName:@"CISourceOverCompositing"];
                    [overBlend setValue:shadowImg   forKey:kCIInputImageKey];
                    [overBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                    CIImage *shaded = overBlend.outputImage;
                    if (shaded) currentImage = shaded;
                }
            }
        } @catch (__unused NSException *ex) {}
    }

    // ──────────────────────────────────────────────────────────────────────────
    // 2. HẠT NHIỄU LI TI NHƯ ISO NOISE (Ultra-Fine Sensor Grain)
    // ──────────────────────────────────────────────────────────────────────────
    if (state.grainEnabled && state.grainIntensity > 0.02f) {
        @try {
            float intensity = state.grainIntensity;

            // Tile nhỏ 64×64 → hạt li ti hơn 4× so với 256×256
            static NSData  *sNoiseData     = nil;
            static CIImage *sBaseNoiseTile = nil;
            static dispatch_once_t sNoiseOnce;
            dispatch_once(&sNoiseOnce, ^{
                const int w = 64, h = 64;
                uint8_t *bytes = (uint8_t *)malloc(w * h * 4);
                if (bytes) {
                    uint32_t seed = 0xdeadbeef;
                    for (int i = 0; i < w * h; i++) {
                        seed = seed * 1664525u + 1013904223u;
                        uint8_t val = (uint8_t)(seed >> 24);
                        bytes[i*4+0] = val;
                        bytes[i*4+1] = val;
                        bytes[i*4+2] = val;
                        bytes[i*4+3] = 255;
                    }
                    sNoiseData = [NSData dataWithBytesNoCopy:bytes length:w*h*4 freeWhenDone:YES];
                    CIImage *rawNoise = [CIImage imageWithBitmapData:sNoiseData
                                                         bytesPerRow:w * 4
                                                                size:CGSizeMake(w, h)
                                                              format:kCIFormatRGBA8
                                                          colorSpace:nil];
                    sBaseNoiseTile = [rawNoise imageByClampingToExtent];
                }
            });

            if (sBaseNoiseTile) {
                // Contrast rất thấp: hạt cực nhạt, chỉ thấy khi nhìn kỹ
                CIFilter *contrastFilter = [CIFilter filterWithName:@"CIColorControls"];
                [contrastFilter setValue:sBaseNoiseTile forKey:kCIInputImageKey];
                [contrastFilter setValue:@(0.0f) forKey:@"inputBrightness"];
                [contrastFilter setValue:@(0.05f + intensity * 0.18f) forKey:@"inputContrast"];
                CIImage *tunedNoise = contrastFilter.outputImage;

                if (tunedNoise) {
                    // Jitter mỗi frame để hạt nhiễu động như cảm biến thật
                    static uint32_t sFrameSeed = 0;
                    sFrameSeed = (sFrameSeed + 137) % 10000;
                    CGFloat dx = (CGFloat)(sFrameSeed % 61);
                    CGFloat dy = (CGFloat)((sFrameSeed * 7) % 61);

                    CIImage *jitteredNoise = [tunedNoise imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
                    jitteredNoise = [jitteredNoise imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                    // Soft Light blend — hạt hoà vào ảnh tự nhiên
                    CIFilter *grainBlend = [CIFilter filterWithName:@"CISoftLightBlendMode"];
                    [grainBlend setValue:jitteredNoise forKey:kCIInputImageKey];
                    [grainBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                    CIImage *grained = grainBlend.outputImage;
                    if (grained) currentImage = grained;
                }
            }
        } @catch (__unused NSException *ex) {}
    }


    return currentImage;
}

@end

