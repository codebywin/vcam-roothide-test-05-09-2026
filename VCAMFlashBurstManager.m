//
//  VCAMFlashBurstManager.m
//  VCAM iOS - Camera Flash Burst & Catchlight Engine
//

#import "VCAMFlashBurstManager.h"
#import <sys/stat.h>
#import <unistd.h>

static const char *kVCAMFlashBurstFileName     = "vcam_flash_burst";
static const char *kVCAMFlashBurstModeFileName = "vcam_flash_burst_mode";
static const NSTimeInterval kVCAMBurstDuration = 0.45; // 450ms flash cycle

@implementation VCAMFlashBurstManager

+ (instancetype)sharedManager {
    static VCAMFlashBurstManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMFlashBurstManager alloc] init];
    });
    return instance;
}

#pragma mark - Temporary Directory Helpers

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

static NSString *FindExistingBurstPath(void) {
    for (NSString *dir in PossibleTmpDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashBurstFileName]];
        if (access([p UTF8String], F_OK) == 0) {
            return p;
        }
    }
    for (NSString *dir in PossibleTmpDirs()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            return [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashBurstFileName]];
        }
    }
    return [@"/var/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashBurstFileName]];
}

static NSString *FindExistingModePath(void) {
    for (NSString *dir in PossibleTmpDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashBurstModeFileName]];
        if (access([p UTF8String], F_OK) == 0) {
            return p;
        }
    }
    for (NSString *dir in PossibleTmpDirs()) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:dir]) {
            return [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashBurstModeFileName]];
        }
    }
    return [@"/var/tmp" stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashBurstModeFileName]];
}

#pragma mark - 3-Mode Management (OFF / MANUAL / AUTO)

+ (VCAMFlashBurstMode)currentBurstMode {
    static VCAMFlashBurstMode sCachedMode = VCAMFlashBurstModeAuto; // Mặc định là Tự động
    static NSTimeInterval sLastModeCheck = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    if (now - sLastModeCheck < 0.10) {
        return sCachedMode;
    }
    sLastModeCheck = now;

    NSString *path = FindExistingModePath();
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        int m = 2;
        if (fscanf(f, "%d", &m) == 1) {
            if (m >= 0 && m <= 2) {
                sCachedMode = (VCAMFlashBurstMode)m;
            }
        }
        fclose(f);
    }
    return sCachedMode;
}

+ (void)setBurstMode:(VCAMFlashBurstMode)mode {
    char buf[16];
    snprintf(buf, sizeof(buf), "%d\n", (int)mode);

    for (NSString *dir in PossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashBurstModeFileName]];
        FILE *f = fopen([filePath UTF8String], "w");
        if (f) {
            fputs(buf, f);
            fclose(f);
            chmod([filePath UTF8String], 0666);
        }
    }
}

#pragma mark - Flash Burst Trigger (IPC)

+ (void)triggerFlashBurst {
    if ([self currentBurstMode] == VCAMFlashBurstModeOff) {
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    char buf[64];
    snprintf(buf, sizeof(buf), "%.4f\n", now);

    for (NSString *dir in PossibleTmpDirs()) {
        NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCAMFlashBurstFileName]];
        FILE *f = fopen([filePath UTF8String], "w");
        if (f) {
            fputs(buf, f);
            fclose(f);
            chmod([filePath UTF8String], 0666);
        }
    }
}

+ (NSTimeInterval)_getBurstStartTime {
    static NSTimeInterval sCachedStartTime = 0;
    static NSTimeInterval sLastCheckTime = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];

    // Throttled file check: đọc file cờ tối đa 25 lần/giây (40ms) để không nghẽn luồng render
    if (now - sLastCheckTime < 0.04) {
        return sCachedStartTime;
    }
    sLastCheckTime = now;

    NSString *path = FindExistingBurstPath();
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        double val = 0.0;
        if (fscanf(f, "%lf", &val) == 1) {
            sCachedStartTime = val;
        }
        fclose(f);
    }
    return sCachedStartTime;
}

+ (BOOL)isFlashBurstActive {
    if ([self currentBurstMode] == VCAMFlashBurstModeOff) {
        return NO;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval start = [self _getBurstStartTime];
    NSTimeInterval elapsed = now - start;
    return (elapsed >= 0.0 && elapsed < kVCAMBurstDuration);
}

+ (float)currentBurstIntensity {
    if ([self currentBurstMode] == VCAMFlashBurstModeOff) {
        return 0.0f;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval start = [self _getBurstStartTime];
    NSTimeInterval elapsed = now - start;

    if (elapsed < 0.0 || elapsed >= kVCAMBurstDuration) {
        return 0.0f;
    }

    // ── Đường cong quang học chớp Flash chân thực (450ms cycle) ──
    // Giai đoạn 1: Attack nhanh bừng sáng (0 -> 70ms: vọt lên 100%)
    if (elapsed <= 0.07) {
        return (float)(elapsed / 0.07);
    }

    // Giai đoạn 2: Giữ đỉnh sáng rực rỡ (70ms -> 160ms: từ 1.0 -> 0.85)
    if (elapsed <= 0.16) {
        float peakProgress = (float)((elapsed - 0.07) / 0.09);
        return 1.0f - (peakProgress * 0.15f);
    }

    // Giai đoạn 3: Suy hao dịu dần mềm mại (Decay: 160ms -> 450ms)
    float decayProgress = (float)((elapsed - 0.16) / (kVCAMBurstDuration - 0.16));
    float factor = 1.0f - decayProgress;
    return 0.85f * (factor * factor); // Quadratic decay
}

#pragma mark - Metal GPU Flash & Specular Catchlight Shader

+ (CIImage *)applyFlashBurstToImage:(CIImage *)image size:(CGSize)size {
    if (!image || size.width <= 0 || size.height <= 0) return image;

    float intensity = [self currentBurstIntensity];
    if (intensity <= 0.02f) return image;

    @try {
        CIImage *result = image;

        // 1. Tăng phơi sáng tổng thể rõ rệt (Camera Flash EV Surge): +0.0 -> +1.35 EV
        // Giúp toàn bộ khung hình bừng sáng chân thực như đèn flash camera iPhone thật
        CIFilter *exposureFilter = [CIFilter filterWithName:@"CIExposureAdjust"];
        [exposureFilter setValue:result forKey:kCIInputImageKey];
        [exposureFilter setValue:@(intensity * 1.35f) forKey:@"inputEV"];
        CIImage *exposed = exposureFilter.outputImage;
        if (exposed) result = exposed;

        // 2. Điểm phản quang Catchlight & quầng sáng hội tụ ở vùng khuôn mặt
        CGFloat centerX = size.width * 0.50f;
        CGFloat centerY = size.height * 0.55f;
        CGFloat innerRadius = MIN(size.width, size.height) * 0.18f; // Vùng phản quang trán, mắt, sống mũi
        CGFloat outerRadius = MAX(size.width, size.height) * 0.70f; // Vùng tỏa sáng mềm toàn khuôn hình

        // Màu trắng ánh vàng nhẹ đặc trưng của Retina Flash
        CIColor *centerColor = [CIColor colorWithRed:1.0f green:0.98f blue:0.94f alpha:intensity * 0.75f];
        CIColor *outerColor  = [CIColor colorWithRed:1.0f green:0.97f blue:0.90f alpha:0.0f];

        CIFilter *radialGradient = [CIFilter filterWithName:@"CIRadialGradient"];
        [radialGradient setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
        [radialGradient setValue:@(innerRadius) forKey:@"inputRadius0"];
        [radialGradient setValue:@(outerRadius) forKey:@"inputRadius1"];
        [radialGradient setValue:centerColor forKey:@"inputColor0"];
        [radialGradient setValue:outerColor forKey:@"inputColor1"];

        CIImage *lightGradient = [radialGradient.outputImage imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];
        if (lightGradient) {
            // Hòa trộn quang học bằng CIScreenBlendMode tạo độ phản quang tự nhiên tuyệt đẹp
            CIFilter *blendFilter = [CIFilter filterWithName:@"CIScreenBlendMode"];
            [blendFilter setValue:lightGradient forKey:kCIInputImageKey];
            [blendFilter setValue:result forKey:kCIInputBackgroundImageKey];
            CIImage *blended = blendFilter.outputImage;
            if (blended) result = blended;
        }

        return result;
    } @catch (NSException *ex) {
        return image;
    }
}

#pragma mark - Auto Screen Flash Detection

+ (void)checkAndAutoTriggerWithScreenRGB:(float)r g:(float)g b:(float)b {
    // Chỉ hoạt động khi đang ở chế độ TỰ ĐỘNG (Auto)
    if ([self currentBurstMode] != VCAMFlashBurstModeAuto) {
        return;
    }

    static NSTimeInterval lastTriggerTime = 0;
    static float lastBrightness = 0.5f;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    float currentBrightness = (r + g + b) / 3.0f;
    float delta = currentBrightness - lastBrightness;

    // Điều kiện chớp tự động nhạy và chính xác cho KYC:
    // 1. Màn hình lóe sáng đột biến (tăng vọt > 10% và độ sáng hiện tại > 48%)
    // 2. Hoặc màn hình cực sáng trắng (> 70%)
    if ((delta > 0.10f && currentBrightness > 0.48f) || currentBrightness > 0.70f) {
        if (now - lastTriggerTime > 2.0) { // Cooldown 2 giây chống lặp
            lastTriggerTime = now;
            [self triggerFlashBurst];
        }
    }

    // Làm mượt độ sáng theo dõi
    lastBrightness = lastBrightness * 0.40f + currentBrightness * 0.60f;
}

@end
