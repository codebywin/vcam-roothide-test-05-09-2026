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
    // 1. HIỆU ỨNG ÁNH ĐÈN PIN CHIẾU VÀO MẶT (Flashlight Beam & Deep Falloff Shadow)
    //    - Chùm sáng đèn pin rọi mạnh trực diện vào trung tâm khuôn mặt (Screen blend, sáng rõ nét)
    //    - Rìa ngoài chùm đèn chìm vào bóng tối sâu (Deep perimeter shadow falloff)
    // ──────────────────────────────────────────────────────────────────────────
    if (state.shadingEnabled && state.shadingIntensity > 0.02f) {
        @try {
            float intensity = state.shadingIntensity;
            CGFloat centerX = size.width  * 0.50f;
            CGFloat centerY = size.height * 0.48f; // Tâm rọi ngay sống mũi / giữa mặt
            CGFloat baseR   = MIN(size.width, size.height);

            // ── LỚP 1: Chùm sáng đèn pin rọi tâm (Flashlight Core Beam) ──
            // Vùng giữa sáng rực rõ nét như có cây đèn pin chiếu thẳng vào mặt
            {
                CIColor *lightCenter = [CIColor colorWithRed:1.0f green:0.98f blue:0.92f
                                                       alpha:intensity * 0.68f];
                CIColor *lightEdge   = [CIColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.0f];

                CIFilter *lightGrad = [CIFilter filterWithName:@"CIRadialGradient"];
                [lightGrad setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
                [lightGrad setValue:@(baseR * 0.08f) forKey:@"inputRadius0"]; // Tâm rọi mạnh
                [lightGrad setValue:@(baseR * 0.52f) forKey:@"inputRadius1"]; // Bán kính chùm đèn pin
                [lightGrad setValue:lightCenter forKey:@"inputColor0"];
                [lightGrad setValue:lightEdge   forKey:@"inputColor1"];

                CIImage *lightImg = lightGrad.outputImage;
                if (lightImg) {
                    // Elip dọc 1.0 x 1.25 ôm trọn khuôn mặt giống khung oval
                    CGAffineTransform t = CGAffineTransformIdentity;
                    t = CGAffineTransformTranslate(t, centerX, centerY);
                    t = CGAffineTransformScale(t, 1.0f, 1.25f);
                    t = CGAffineTransformTranslate(t, -centerX, -centerY);
                    lightImg = [lightImg imageByApplyingTransform:t];
                    lightImg = [lightImg imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                    CIFilter *screenBlend = [CIFilter filterWithName:@"CIScreenBlendMode"];
                    [screenBlend setValue:lightImg    forKey:kCIInputImageKey];
                    [screenBlend setValue:currentImage forKey:kCIInputBackgroundImageKey];
                    CIImage *lit = screenBlend.outputImage;
                    if (lit) currentImage = lit;
                }
            }

            // ── LỚP 2: Đổ bóng sâu ngoài viền chùm đèn (Deep Flashlight Falloff Shadow) ──
            // Bên ngoài chùm đèn pin đổ bóng tối rõ rệt, làm nổi bật khuôn mặt ở giữa
            {
                CIColor *shadowCenter = [CIColor colorWithRed:0.0f green:0.0f blue:0.0f alpha:0.0f];
                CIColor *shadowEdge   = [CIColor colorWithRed:0.01f green:0.01f blue:0.02f
                                                        alpha:intensity * 0.58f];

                CIFilter *shadowGrad = [CIFilter filterWithName:@"CIRadialGradient"];
                [shadowGrad setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
                [shadowGrad setValue:@(baseR * 0.22f) forKey:@"inputRadius0"]; // Vùng trong chùm đèn không bị tối
                [shadowGrad setValue:@(baseR * 0.65f) forKey:@"inputRadius1"]; // Ra ngoài viền đổ bóng tối sâu
                [shadowGrad setValue:shadowCenter forKey:@"inputColor0"];
                [shadowGrad setValue:shadowEdge   forKey:@"inputColor1"];

                CIImage *shadowImg = shadowGrad.outputImage;
                if (shadowImg) {
                    // Cùng tỉ lệ elip 1.0 x 1.25 ôm trọn khuôn mặt
                    CGAffineTransform t = CGAffineTransformIdentity;
                    t = CGAffineTransformTranslate(t, centerX, centerY);
                    t = CGAffineTransformScale(t, 1.0f, 1.25f);
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
    // 2. HẠT NHIỄU CẢM BIẾN LI TI THƯA (Sparse 1px CMOS Sensor Grain)
    // ──────────────────────────────────────────────────────────────────────────
    if (state.grainEnabled && state.grainIntensity > 0.02f) {
        @try {
            float intensity = state.grainIntensity;

            // Texture nhiễu hạt 256x256 rải hạt rất thưa (chỉ ~3.5% pixel có hạt)
            static NSData  *sNoiseData     = nil;
            static CIImage *sBaseNoiseTile = nil;
            static dispatch_once_t sNoiseOnce;
            dispatch_once(&sNoiseOnce, ^{
                const int w = 256, h = 256;
                uint8_t *bytes = (uint8_t *)malloc(w * h * 4);
                if (bytes) {
                    uint32_t seed = 0x1337cafe;
                    for (int i = 0; i < w * h; i++) {
                        seed = seed * 1664525u + 1013904223u;
                        uint32_t r = seed >> 16;
                        uint8_t byteVal = 128; // Mặc định 128: trung tính tuyệt đối (không làm mờ/ảnh hưởng ảnh gốc)

                        // Giảm số hạt lại, rải thưa ~3.5% pixel xuất hiện đốm li ti
                        if ((r % 1000) < 35) {
                            if ((r & 1) == 0) {
                                // Hạt sáng li ti (specular highlight / hot pixel)
                                byteVal = (uint8_t)(128 + 40 + ((r >> 8) % 65)); // 168..233
                            } else {
                                // Hạt tối li ti
                                byteVal = (uint8_t)(128 - 30 - ((r >> 8) % 40)); // 58..98
                            }
                        }

                        bytes[i*4+0] = byteVal;
                        bytes[i*4+1] = byteVal;
                        bytes[i*4+2] = byteVal;
                        bytes[i*4+3] = 255;
                    }
                    sNoiseData = [NSData dataWithBytesNoCopy:bytes length:w*h*4 freeWhenDone:YES];
                    CIImage *rawNoise = [CIImage imageWithBitmapData:sNoiseData
                                                         bytesPerRow:w * 4
                                                                size:CGSizeMake(w, h)
                                                              format:kCIFormatRGBA8
                                                          colorSpace:nil];
                    // Dùng CIAffineTile để lặp texture 256x256 trải đều toàn màn hình
                    CIFilter *tileFilter = [CIFilter filterWithName:@"CIAffineTile"];
                    [tileFilter setValue:rawNoise forKey:kCIInputImageKey];
                    sBaseNoiseTile = tileFilter.outputImage;
                }
            });

            if (sBaseNoiseTile) {
                // Điều chỉnh độ rõ nét của hạt nhiễu theo slider intensity
                CIFilter *contrastFilter = [CIFilter filterWithName:@"CIColorControls"];
                [contrastFilter setValue:sBaseNoiseTile forKey:kCIInputImageKey];
                [contrastFilter setValue:@(0.0f) forKey:@"inputBrightness"];
                [contrastFilter setValue:@(0.30f + intensity * 1.05f) forKey:@"inputContrast"];
                CIImage *tunedNoise = contrastFilter.outputImage;

                if (tunedNoise) {
                    // Dịch chuyển ngẫu nhiên mỗi frame để hạt nhiễu động chân thực
                    static uint32_t sFrameSeed = 0;
                    sFrameSeed = (sFrameSeed + 97) % 100000;
                    CGFloat dx = (CGFloat)(sFrameSeed % 251);
                    CGFloat dy = (CGFloat)((sFrameSeed * 23) % 251);

                    CIImage *jitteredNoise = [tunedNoise imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
                    jitteredNoise = [jitteredNoise imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];

                    // Soft Light blend: pixel 128 giữ nguyên ảnh gốc, đốm sáng/tối tạo hạt li ti thưa
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

