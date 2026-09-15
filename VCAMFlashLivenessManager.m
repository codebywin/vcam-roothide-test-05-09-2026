//
//  VCAMFlashLivenessManager.m
//  VCAM iOS - KYC Active Flash Liveness Engine
//

#import "VCAMFlashLivenessManager.h"
#import "VCAMFlashBurstManager.h"
#import <dlfcn.h>
#import <sys/stat.h>

static const char *kVCAMFlashStateFileName = "vcam_flash_state";

#if defined(__cplusplus)
extern "C" {
#endif
UIImage *_UICreateScreenUIImage(void) __attribute__((weak_import));
#if defined(__cplusplus)
}
#endif

typedef UIImage *(*UICreateScreenUIImageFunc)(void);

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
    int _consecutiveCaptureFailures;
    NSTimeInterval _monitorStartTime;
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
        _consecutiveCaptureFailures = 0;
        _samplingQueue = dispatch_queue_create("com.vcam.flash.sampler", DISPATCH_QUEUE_SERIAL);

        // Safe resolution of screen capture function for SpringBoard (iOS 15 / 16 / Dopamine / RootHide)
        if (_UICreateScreenUIImage != NULL) {
            _uikitCreateScreenUIImage = _UICreateScreenUIImage;
        } else {
            void *handle = dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW | RTLD_GLOBAL);
            if (!handle) handle = dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW | RTLD_GLOBAL);
            if (!handle) handle = dlopen(NULL, RTLD_GLOBAL);
            if (handle) {
                _uikitCreateScreenUIImage = (UICreateScreenUIImageFunc)dlsym(handle, "_UICreateScreenUIImage");
            }
            if (!_uikitCreateScreenUIImage) {
                _uikitCreateScreenUIImage = (UICreateScreenUIImageFunc)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
            }
        }

        _isEnabled = NO;
        _isTestMode = NO;
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

    if (enabled) {
        [self startScreenColorMonitoring];
    } else {
        [self stopScreenColorMonitoring];
    }
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
    if (now - lastReadTime < 0.08) { // 80ms throttle cache for high responsiveness to fast 250ms eKYC flashes
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

/// Các dải màu nhận diện KYC Flash
typedef enum {
    BIN_NONE = -1,
    BIN_RED = 0,
    BIN_GREEN,
    BIN_BLUE,
    BIN_YELLOW,
    BIN_CYAN,
    BIN_MAGENTA,
    BIN_COUNT
} KYCColorBinType;

typedef struct {
    float sumR;
    float sumG;
    float sumB;
    float totalWeight;
    int pixelCount;
} KYCColorBin;

static const char *kBinNames[BIN_COUNT] = {
    "ĐỎ (Red)",
    "XANH LỤC (Green)",
    "XANH LAM (Blue)",
    "VÀNG (Yellow)",
    "CYAN (Xanh ngọc)",
    "TÍM (Magenta)"
};

/// Thuật toán trích xuất dải màu bão hòa chủ đạo (Dominant Chroma Bin Voting)
/// Quét lưới 24x24 (576 điểm ảnh), loại trừ 100% giao diện tweak, phân loại cụm màu áp đảo
static void ComputeDominantScreenRGB(CGImageRef cgImage, float *outR, float *outG, float *outB, float *outSat, NSString **outColorName, int *outVotedCount, float *outVotedWeight) {
    if (!cgImage) return;

    const int sampleW = 24;
    const int sampleH = 24;
    uint32_t pixels[sampleW * sampleH] = {0};

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return;

    CGContextRef context = CGBitmapContextCreate(pixels, sampleW, sampleH, 8, sampleW * 4, colorSpace,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (context) {
        CGContextSetInterpolationQuality(context, kCGInterpolationLow);
        CGContextDrawImage(context, CGRectMake(0, 0, sampleW, sampleH), cgImage);
        CGContextRelease(context);

        KYCColorBin bins[BIN_COUNT] = {0};
        float totalR = 0, totalG = 0, totalB = 0;
        int validSampledCount = 0;

        for (int y = 0; y < sampleH; y++) {
            float normY = (float)y / (float)sampleH;

            for (int x = 0; x < sampleW; x++) {
                float normX = (float)x / (float)sampleW;

                // 1. Loại trừ 100% vùng giao diện của chính tweak (Floating Button & Control Panel)
                if (VCamIsScreenPointInTweakUI(normX, normY)) {
                    continue;
                }

                uint32_t p = pixels[y * sampleW + x];
                float r = (float)(p & 0xFF) / 255.0f;
                float g = (float)((p >> 8) & 0xFF) / 255.0f;
                float b = (float)((p >> 16) & 0xFF) / 255.0f;

                totalR += r;
                totalG += g;
                totalB += b;
                validSampledCount++;

                float maxVal = MAX(r, MAX(g, b));
                float minVal = MIN(r, MIN(g, b));
                float delta = maxVal - minVal;

                // Bỏ qua các điểm ảnh tối hoặc xám/trắng/trung tính (da mặt bình thường, nền xám/đen)
                // Ngưỡng bão hòa delta >= 0.16f
                if (maxVal < 0.18f || delta < 0.16f) {
                    continue;
                }

                // Trọng số bão hòa bình phương: điểm ảnh càng rực màu thì tiếng nói càng áp đảo
                float weight = delta * delta * maxVal;
                // Vùng viền màn hình (nơi app eKYC hay chớp màu) được tăng 30% trọng số
                if (y < 5 || y > 18 || x < 5 || x > 18) {
                    weight *= 1.30f;
                }

                // Phân loại dải màu (Chroma Bin Classification)
                KYCColorBinType binIdx = BIN_NONE;

                if (r > 0.40f && r > g * 1.30f && r > b * 1.30f) {
                    binIdx = BIN_RED; // ĐỎ
                } else if (g > 0.35f && g > r * 1.20f && g > b * 1.15f) {
                    binIdx = BIN_GREEN; // XANH LỤC
                } else if (b > 0.38f && b > r * 1.25f && b > g * 1.05f) {
                    binIdx = BIN_BLUE; // XANH LAM
                } else if (g > 0.35f && b > 0.35f && (g + b) > 2.0f * r && fabsf(g - b) < 0.25f) {
                    binIdx = BIN_CYAN; // CYAN (Xanh ngọc)
                } else if (r > 0.50f && g > 0.42f && b < 0.32f && (r + g) > 2.2f * b) {
                    binIdx = BIN_YELLOW; // VÀNG
                } else if (r > 0.45f && b > 0.45f && g < 0.35f) {
                    binIdx = BIN_MAGENTA; // TÍM
                }

                if (binIdx != BIN_NONE) {
                    bins[binIdx].sumR += r * weight;
                    bins[binIdx].sumG += g * weight;
                    bins[binIdx].sumB += b * weight;
                    bins[binIdx].totalWeight += weight;
                    bins[binIdx].pixelCount++;
                }
            }
        }

        // Tìm bin màu áp đảo (Dominant Bin)
        KYCColorBinType bestBin = BIN_NONE;
        float maxWeight = 0.0f;
        for (int k = 0; k < BIN_COUNT; k++) {
            if (bins[k].totalWeight > maxWeight) {
                maxWeight = bins[k].totalWeight;
                bestBin = (KYCColorBinType)k;
            }
        }

        // Ngưỡng xác nhận KYC Flash: cần ít nhất 6 điểm ảnh bão hòa cao và tổng trọng số > 1.2
        if (bestBin != BIN_NONE && bins[bestBin].pixelCount >= 6 && maxWeight > 1.2f) {
            float avgR = bins[bestBin].sumR / bins[bestBin].totalWeight;
            float avgG = bins[bestBin].sumG / bins[bestBin].totalWeight;
            float avgB = bins[bestBin].sumB / bins[bestBin].totalWeight;

            // Tăng cường độ rực màu (Boost Saturation) để phản chiếu lên da mặt rõ nét nhất
            float maxC = MAX(avgR, MAX(avgG, avgB));
            if (maxC > 0.01f) {
                avgR /= maxC;
                avgG /= maxC;
                avgB /= maxC;
            }

            float minC = MIN(avgR, MIN(avgG, avgB));
            float sat = maxC - minC;

            if (outSat) *outSat = sat;
            *outR = avgR;
            *outG = avgG;
            *outB = avgB;
            if (outColorName) *outColorName = [NSString stringWithUTF8String:kBinNames[bestBin]];
            if (outVotedCount) *outVotedCount = bins[bestBin].pixelCount;
            if (outVotedWeight) *outVotedWeight = maxWeight;
        } else {
            // Không có chớp màu đặc biệt (màn hình trung tính, camera preview bình thường)
            if (outSat) *outSat = 0.0f;
            if (validSampledCount > 0) {
                *outR = totalR / validSampledCount;
                *outG = totalG / validSampledCount;
                *outB = totalB / validSampledCount;
            } else {
                *outR = 1.0f; *outG = 1.0f; *outB = 1.0f;
            }
            if (outColorName) *outColorName = @"Trắng/Trung tính";
            if (outVotedCount) *outVotedCount = 0;
            if (outVotedWeight) *outVotedWeight = 0.0f;
        }
    }
    CGColorSpaceRelease(colorSpace);
}

- (void)startScreenColorMonitoring {
    if (_samplingTimer) return;

    _monitorStartTime = [NSDate timeIntervalSinceReferenceDate];
    _samplingTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _samplingQueue);
    // Tần số quét 250ms (~4 FPS), nhẹ, an toàn tuyệt đối và bắt trúng 100% các nhịp chớp màu 400-800ms của eKYC
    dispatch_source_set_timer(_samplingTimer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 25 * NSEC_PER_MSEC);

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
    if (!_isEnabled) return;

    // Tự động tắt sau 90 giây để bảo vệ pin và chống chạy ngầm kéo dài
    if ([NSDate timeIntervalSinceReferenceDate] - _monitorStartTime > 90.0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setLivenessEnabled:NO];
        });
        return;
    }

    if (_isTestMode) {
        // Chế độ test mô phỏng: đảo 6 màu tuần hoàn mỗi 450ms
        static const float testPalette[6][3] = {
            {1.00f, 1.00f, 1.00f}, // Sáng trắng
            {0.20f, 0.75f, 1.00f}, // Xanh lam (Cyan/Blue)
            {1.00f, 0.25f, 0.25f}, // Đỏ (Red)
            {0.30f, 0.95f, 0.35f}, // Xanh lục (Green)
            {1.00f, 0.90f, 0.20f}, // Vàng (Yellow)
            {0.90f, 0.30f, 0.90f}  // Tím hồng (Magenta)
        };

        static NSTimeInterval lastCycleTime = 0;
        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - lastCycleTime > 0.45) {
            lastCycleTime = now;
            _testColorIndex = (_testColorIndex + 1) % 6;
        }

        float targetR = testPalette[_testColorIndex][0];
        float targetG = testPalette[_testColorIndex][1];
        float targetB = testPalette[_testColorIndex][2];

        // Lọc trễ quang học EMA mượt mà
        _smoothedR = _smoothedR * 0.35f + targetR * 0.65f;
        _smoothedG = _smoothedG * 0.35f + targetG * 0.65f;
        _smoothedB = _smoothedB * 0.35f + targetB * 0.65f;

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

    // Tự động quét màu màn hình app eKYC theo thời gian thực
    BOOL capturedSuccess = NO;
    if (_uikitCreateScreenUIImage) {
        @autoreleasepool {
            @try {
                void *rawImg = (void *)_uikitCreateScreenUIImage();
                if (rawImg) {
                    UIImage *screenImg = (__bridge_transfer UIImage *)rawImg;
                    if (screenImg && screenImg.CGImage) {
                        capturedSuccess = YES;
                        _consecutiveCaptureFailures = 0;

                        float sampleR = 1.0f, sampleG = 1.0f, sampleB = 1.0f;
                        float saturation = 0.0f;
                        NSString *detectedColorName = @"Trắng/Trung tính";
                        int votedCount = 0;
                        float votedWeight = 0.0f;

                        ComputeDominantScreenRGB(screenImg.CGImage, &sampleR, &sampleG, &sampleB, &saturation, &detectedColorName, &votedCount, &votedWeight);

                        // Tự động kích hoạt phản quang nếu màn hình chớp sáng trắng chụp ảnh
                        [VCAMFlashBurstManager checkAndAutoTriggerWithScreenRGB:sampleR g:sampleG b:sampleB];

                        // Sensor Latency Simulation (Bộ lọc trễ cảm biến quang học EMA)
                        // Nếu là màu chớp rực rỡ (sat > 0.20): phản ứng cực nhanh (85% giá trị mới, trễ < 80ms)
                        // Nếu trở về bình thường: làm mượt chuyển cảnh (60% giá trị mới)
                        if (saturation > 0.20f) {
                            _smoothedR = _smoothedR * 0.15f + sampleR * 0.85f;
                            _smoothedG = _smoothedG * 0.15f + sampleG * 0.85f;
                            _smoothedB = _smoothedB * 0.15f + sampleB * 0.85f;
                        } else {
                            _smoothedR = _smoothedR * 0.40f + sampleR * 0.60f;
                            _smoothedG = _smoothedG * 0.40f + sampleG * 0.60f;
                            _smoothedB = _smoothedB * 0.40f + sampleB * 0.60f;
                        }

                        VCAMFlashState s;
                        s.active = YES;
                        s.testMode = NO;
                        s.r = _smoothedR;
                        s.g = _smoothedG;
                        s.b = _smoothedB;
                        s.intensity = (float)_intensity;
                        [VCAMFlashLivenessManager saveFlashState:s];

                        // Ghi log vào /var/tmp/vcam_flash.log và /rootfs/private/var/tmp/vcam_flash.log
                        static NSTimeInterval lastLogTime = 0;
                        NSTimeInterval nowLog = [NSDate timeIntervalSinceReferenceDate];
                        if (nowLog - lastLogTime > 0.35) {
                            lastLogTime = nowLog;
                            NSString *logMsg = [NSString stringWithFormat:@"[KYC Flash] %@ [voted: %d px, w=%.1f] | SampleRGB=(%.2f, %.2f, %.2f) Sat=%.2f | OutputRGB=(%.2f, %.2f, %.2f)\n",
                                                detectedColorName, votedCount, votedWeight, sampleR, sampleG, sampleB, saturation, _smoothedR, _smoothedG, _smoothedB];
                            for (NSString *dir in PossibleTmpDirs()) {
                                NSString *logPath = [dir stringByAppendingPathComponent:@"vcam_flash.log"];
                                FILE *lf = fopen([logPath UTF8String], "a");
                                if (lf) {
                                    fputs([logMsg UTF8String], lf);
                                    fclose(lf);
                                    chmod([logPath UTF8String], 0666);
                                }
                            }
                        }
                    }
                }
            } @catch (__unused NSException *ex) {
                capturedSuccess = NO;
            }
        }
    }

    // Cơ chế thông minh dự phòng: Nếu hệ điều hành / app chặn đọc màn hình (> 1.5s liên tiếp)
    if (!capturedSuccess) {
        _consecutiveCaptureFailures++;
        if (_consecutiveCaptureFailures > 15) {
            // Tự động luân chuyển dải màu KYC để đảm bảo luôn có phản quang trên da mặt
            static const float fallbackPalette[6][3] = {
                {1.00f, 1.00f, 1.00f}, // Sáng trắng
                {0.20f, 0.75f, 1.00f}, // Xanh lam
                {1.00f, 0.25f, 0.25f}, // Đỏ
                {0.30f, 0.95f, 0.35f}, // Xanh lục
                {1.00f, 0.90f, 0.20f}, // Vàng
                {0.90f, 0.30f, 0.90f}  // Tím hồng
            };

            static NSTimeInterval lastFallbackCycle = 0;
            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            if (now - lastFallbackCycle > 0.45) {
                lastFallbackCycle = now;
                _testColorIndex = (_testColorIndex + 1) % 6;
            }

            float targetR = fallbackPalette[_testColorIndex][0];
            float targetG = fallbackPalette[_testColorIndex][1];
            float targetB = fallbackPalette[_testColorIndex][2];

            _smoothedR = _smoothedR * 0.35f + targetR * 0.65f;
            _smoothedG = _smoothedG * 0.35f + targetG * 0.65f;
            _smoothedB = _smoothedB * 0.35f + targetB * 0.65f;

            VCAMFlashState s;
            s.active = YES;
            s.testMode = YES;
            s.r = _smoothedR;
            s.g = _smoothedG;
            s.b = _smoothedB;
            s.intensity = (float)_intensity;
            [VCAMFlashLivenessManager saveFlashState:s];

            static NSTimeInterval lastWarnLog = 0;
            if (now - lastWarnLog > 2.0) {
                lastWarnLog = now;
                FILE *lf = fopen("/var/tmp/vcam_flash.log", "a");
                if (lf) {
                    fputs("[KYC Flash Dự Phòng] Chụp màn hình bị chặn bảo mật. Đang tự động đảo dải màu KYC chuẩn.\n", lf);
                    fclose(lf);
                    chmod("/var/tmp/vcam_flash.log", 0666);
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
