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
    for (NSString *dir in ShadingPossibleDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
        if (access([p UTF8String], F_OK) == 0) {
            return p;
        }
    }
    for (NSString *dir in ShadingPossibleDirs()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            return [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
        }
    }
    return [@"/var/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMShadingStateFileName]];
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
    if (now - lastReadTime < 0.15) {
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

    // ──────────────────────────────────────────────────────────────────────────
    // 1. ĐỔ BÓNG TẠO KHỐI 3D KHUÔN MẶT (3D Volumetric Face Shading)
    // ──────────────────────────────────────────────────────────────────────────
    if (state.shadingEnabled && state.shadingIntensity > 0.02f) {
        @try {
            float intensity = state.shadingIntensity;
            CGFloat centerX = size.width * 0.50f;
            CGFloat centerY = size.height * 0.48f;

            // Bán kính elip phỏng theo hình học hộp sọ khuôn mặt người
            CGFloat baseR = MIN(size.width, size.height);
            CGFloat innerRadius = baseR * 0.22f; // Vùng chữ T sáng (trán, sống mũi, gò má trong)
            CGFloat outerRadius = baseR * 0.68f; // Vùng bóng đổ sâu viền má, thái dương, góc hàm

            // Tâm sáng mềm mại (Specular sheen vùng chữ T)
            CIColor *centerColor = [CIColor colorWithRed:1.0f green:0.96f blue:0.92f alpha:intensity * 0.38f];
            // Viền ngoài tối dần tự nhiên (Ambient Occlusion & Curvature Falloff)
            CIColor *outerColor = [CIColor colorWithRed:0.04f green:0.04f blue:0.04f alpha:intensity * 0.55f];

            CIFilter *radialGradient = [CIFilter filterWithName:@"CIRadialGradient"];
            [radialGradient setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
            [radialGradient setValue:@(innerRadius) forKey:@"inputRadius0"];
            [radialGradient setValue:@(outerRadius) forKey:@"inputRadius1"];
            [radialGradient setValue:centerColor forKey:@"inputColor0"];
            [radialGradient setValue:outerColor forKey:@"inputColor1"];

            CIImage *gradientImg = radialGradient.outputImage;
            if (gradientImg) {
                // Biến đổi hình tròn thành elip thuôn dọc theo tỷ lệ khuôn mặt (1 : 1.25)
                CGAffineTransform t = CGAffineTransformIdentity;
                t = CGAffineTransformTranslate(t, centerX, centerY);
                t = CGAffineTransformScale(t, 1.0f, 1.25f);
                t = CGAffineTransformTranslate(t, -centerX, -centerY);
                gradientImg = [gradientImg imageByApplyingTransform:t];
                gradientImg = [gradientImg imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                // Pha trộn tạo khối bằng CISoftLightBlendMode
                CIFilter *shadingBlend = [CIFilter filterWithName:@"CISoftLightBlendMode"];
                [shadingBlend setValue:gradientImg forKey:kCIInputImageKey];
                [shadingBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                CIImage *shaded = shadingBlend.outputImage;
                if (shaded) currentImage = shaded;
            }
        } @catch (__unused NSException *ex) {}
    }

    // ──────────────────────────────────────────────────────────────────────────
    // 2. HẠT NHIỄU CẢM BIẾN CAMERA (Dynamic CMOS Camera Sensor Noise Grain)
    // ──────────────────────────────────────────────────────────────────────────
    if (state.grainEnabled && state.grainIntensity > 0.02f) {
        @try {
            float intensity = state.grainIntensity;

            // Bộ tạo nhiễu ngẫu nhiên thời gian thực
            CIFilter *noiseFilter = [CIFilter filterWithName:@"CIRandomGenerator"];
            CIImage *noiseImg = noiseFilter.outputImage;

            if (noiseImg) {
                // Dịch chuyển ngẫu nhiên mỗi frame để hạt nhiễu chuyển động sống động như cảm biến ISO thật
                static uint32_t sFrameSeed = 0;
                sFrameSeed = (sFrameSeed + 137) % 10000;
                CGFloat dx = (CGFloat)(sFrameSeed % 373);
                CGFloat dy = (CGFloat)((sFrameSeed * 7) % 389);
                noiseImg = [noiseImg imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];

                // Chuyển hạt nhiễu thành dạng đơn sắc (Luma/Grayscale noise) để không bị nhiễu màu loang lổ
                CIFilter *matrixFilter = [CIFilter filterWithName:@"CIColorMatrix"];
                [matrixFilter setValue:noiseImg forKey:kCIInputImageKey];
                CIVector *grayVector = [CIVector vectorWithX:0.33f Y:0.33f Z:0.33f W:0.0f];
                [matrixFilter setValue:grayVector forKey:@"inputRVector"];
                [matrixFilter setValue:grayVector forKey:@"inputGVector"];
                [matrixFilter setValue:grayVector forKey:@"inputBVector"];
                [matrixFilter setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1.0f] forKey:@"inputAVector"];
                CIImage *grayNoise = matrixFilter.outputImage;

                if (grayNoise) {
                    // Điều chỉnh độ tương phản của hạt nhiễu quanh mức trung tính 0.5
                    // Mức 0.5 trong Soft Light không làm biến đổi ảnh, các hạt sáng/tối quanh 0.5 tạo hạt nhiễu mịn
                    CIFilter *contrastFilter = [CIFilter filterWithName:@"CIColorControls"];
                    [contrastFilter setValue:grayNoise forKey:kCIInputImageKey];
                    [contrastFilter setValue:@(0.0f) forKey:@"inputBrightness"];
                    [contrastFilter setValue:@(intensity * 0.40f) forKey:@"inputContrast"];
                    CIImage *tunedNoise = contrastFilter.outputImage;

                    if (tunedNoise) {
                        tunedNoise = [tunedNoise imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                        // Hòa trộn hạt nhiễu lên khuôn mặt
                        CIFilter *grainBlend = [CIFilter filterWithName:@"CISoftLightBlendMode"];
                        [grainBlend setValue:tunedNoise forKey:kCIInputImageKey];
                        [grainBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                        CIImage *grained = grainBlend.outputImage;
                        if (grained) currentImage = grained;
                    }
                }
            }
        } @catch (__unused NSException *ex) {}
    }

    return currentImage;
}

@end
