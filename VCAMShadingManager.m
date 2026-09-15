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

    @autoreleasepool {
        CIImage *currentImage = image;

        // ──────────────────────────────────────────────────────────────────────────
        // 1. ĐỔ BÓNG TẠO KHỐI 3D KHUÔN MẶT (Cached Volumetric Face Shading)
        // ──────────────────────────────────────────────────────────────────────────
        if (state.shadingEnabled && state.shadingIntensity > 0.02f) {
            @try {
                float intensity = state.shadingIntensity;

                static CIImage *sCachedGradient = nil;
                static CGSize sCachedGradientSize = {0, 0};
                static float sCachedGradientIntensity = -1.0f;

                if (!sCachedGradient ||
                    !CGSizeEqualToSize(sCachedGradientSize, size) ||
                    fabsf(sCachedGradientIntensity - intensity) > 0.01f) {

                    CGFloat centerX = size.width * 0.50f;
                    CGFloat centerY = size.height * 0.48f;
                    CGFloat baseR = MIN(size.width, size.height);
                    CGFloat innerRadius = baseR * 0.22f; // Chữ T trán, mũi, gò má trong
                    CGFloat outerRadius = baseR * 0.68f; // Viền má, thái dương, góc hàm

                    CIColor *centerColor = [CIColor colorWithRed:1.0f green:0.96f blue:0.92f alpha:intensity * 0.38f];
                    CIColor *outerColor  = [CIColor colorWithRed:0.04f green:0.04f blue:0.04f alpha:intensity * 0.55f];

                    CIFilter *radialGradient = [CIFilter filterWithName:@"CIRadialGradient"];
                    [radialGradient setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
                    [radialGradient setValue:@(innerRadius) forKey:@"inputRadius0"];
                    [radialGradient setValue:@(outerRadius) forKey:@"inputRadius1"];
                    [radialGradient setValue:centerColor forKey:@"inputColor0"];
                    [radialGradient setValue:outerColor forKey:@"inputColor1"];

                    CIImage *grad = radialGradient.outputImage;
                    if (grad) {
                        CGAffineTransform t = CGAffineTransformIdentity;
                        t = CGAffineTransformTranslate(t, centerX, centerY);
                        t = CGAffineTransformScale(t, 1.0f, 1.25f);
                        t = CGAffineTransformTranslate(t, -centerX, -centerY);
                        grad = [grad imageByApplyingTransform:t];
                        grad = [grad imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                        sCachedGradient = grad;
                        sCachedGradientSize = size;
                        sCachedGradientIntensity = intensity;
                    }
                }

                if (sCachedGradient) {
                    CIFilter *shadingBlend = [CIFilter filterWithName:@"CISoftLightBlendMode"];
                    [shadingBlend setValue:sCachedGradient forKey:kCIInputImageKey];
                    [shadingBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                    CIImage *shaded = shadingBlend.outputImage;
                    if (shaded) currentImage = shaded;
                }
            } @catch (__unused NSException *ex) {}
        }

        // ──────────────────────────────────────────────────────────────────────────
        // 2. HẠT NHIỄU CẢM BIẾN CAMERA SIÊU NHẸ (Pre-computed CMOS Sensor Grain Tile)
        // ──────────────────────────────────────────────────────────────────────────
        if (state.grainEnabled && state.grainIntensity > 0.02f) {
            @try {
                float intensity = state.grainIntensity;

                // Khởi tạo texture hạt nhiễu đơn sắc compact 256x256 một lần duy nhất trong RAM
                static CIImage *sBaseNoiseTile = nil;
                static dispatch_once_t sNoiseOnce;
                dispatch_once(&sNoiseOnce, ^{
                    const int w = 256;
                    const int h = 256;
                    uint8_t *bytes = (uint8_t *)malloc(w * h * 4);
                    if (bytes) {
                        uint32_t seed = 0x9e3779b9;
                        for (int i = 0; i < w * h; i++) {
                            seed = seed * 1664525u + 1013904223u;
                            int delta = ((int)(seed >> 24) % 65) - 32; // Dao động -32 .. +32 quanh mức 128
                            int val = 128 + delta;
                            if (val < 0) val = 0;
                            if (val > 255) val = 255;
                            bytes[i * 4 + 0] = (uint8_t)val;
                            bytes[i * 4 + 1] = (uint8_t)val;
                            bytes[i * 4 + 2] = (uint8_t)val;
                            bytes[i * 4 + 3] = 255;
                        }
                        NSData *data = [NSData dataWithBytesNoCopy:bytes length:w * h * 4 freeWhenDone:YES];
                        CIImage *rawNoise = [CIImage imageWithBitmapData:data
                                                             bytesPerRow:w * 4
                                                                    size:CGSizeMake(w, h)
                                                                  format:kCIFormatRGBA8
                                                              colorSpace:nil];
                        sBaseNoiseTile = [rawNoise imageByClampingToExtent];
                    }
                });

                // Tinh chỉnh độ tương phản hạt nhiễu (chỉ tính lại khi người dùng đổi thanh trượt)
                static CIImage *sTunedNoiseTile = nil;
                static float sLastGrainIntensity = -1.0f;
                if (!sTunedNoiseTile || fabsf(sLastGrainIntensity - intensity) > 0.01f) {
                    if (sBaseNoiseTile) {
                        CIFilter *contrastFilter = [CIFilter filterWithName:@"CIColorControls"];
                        [contrastFilter setValue:sBaseNoiseTile forKey:kCIInputImageKey];
                        [contrastFilter setValue:@(0.0f) forKey:@"inputBrightness"];
                        [contrastFilter setValue:@(intensity * 0.40f) forKey:@"inputContrast"];
                        sTunedNoiseTile = contrastFilter.outputImage;
                        sLastGrainIntensity = intensity;
                    }
                }

                if (sTunedNoiseTile) {
                    // Dịch chuyển ngẫu nhiên mỗi frame để hạt nhiễu động như cảm biến ISO thật
                    static uint32_t sFrameSeed = 0;
                    sFrameSeed = (sFrameSeed + 137) % 10000;
                    CGFloat dx = (CGFloat)(sFrameSeed % 251);
                    CGFloat dy = (CGFloat)((sFrameSeed * 7) % 257);

                    CIImage *jitteredNoise = [sTunedNoiseTile imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
                    jitteredNoise = [jitteredNoise imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                    // Hòa trộn Soft Light cực nhanh trong 1 pass Metal
                    CIFilter *grainBlend = [CIFilter filterWithName:@"CISoftLightBlendMode"];
                    [grainBlend setValue:jitteredNoise forKey:kCIInputImageKey];
                    [grainBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                    CIImage *grained = grainBlend.outputImage;
                    if (grained) currentImage = grained;
                }
            } @catch (__unused NSException *ex) {}
        }

        return currentImage;
    }
}

@end

