//
//  VCAMFlashBurstManager.m
//  VCAM iOS - Camera Flash Burst & Catchlight Engine
//

#import "VCAMFlashBurstManager.h"
#import <sys/stat.h>
#import <unistd.h>

static const char *kVCAMFlashBurstFileName = "vcam_flash_burst";
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

#pragma mark - Flash Burst Trigger (IPC)

+ (void)triggerFlashBurst {
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
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval start = [self _getBurstStartTime];
    NSTimeInterval elapsed = now - start;
    return (elapsed >= 0.0 && elapsed < kVCAMBurstDuration);
}

+ (float)currentBurstIntensity {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval start = [self _getBurstStartTime];
    NSTimeInterval elapsed = now - start;

    if (elapsed < 0.0 || elapsed >= kVCAMBurstDuration) {
        return 0.0f;
    }

    // ── Đường cong quang học chớp Flash chân thực (Optical Flash Curve) ──
    // Giai đoạn 1: Lóe sáng bùng nổ cực nhanh (Attack: 0 -> 100ms)
    if (elapsed <= 0.10) {
        float progress = (float)(elapsed / 0.10);
        return progress * 0.82f; // Bừng sáng cực đại 82%
    }

    // Giai đoạn 2: Tự động dịu dần mềm mại (Decay Ease-Out: 100ms -> 450ms)
    float decayProgress = (float)((elapsed - 0.10) / (kVCAMBurstDuration - 0.10));
    float factor = 1.0f - (decayProgress * decayProgress); // Quadratic ease-out
    return 0.82f * MAX(0.0f, factor);
}

#pragma mark - Metal GPU Flash & Specular Catchlight Shader

+ (CIImage *)applyFlashBurstToImage:(CIImage *)image size:(CGSize)size {
    if (!image || size.width <= 0 || size.height <= 0) return image;

    float intensity = [self currentBurstIntensity];
    if (intensity <= 0.015f) return image;

    @try {
        // 1. Tọa độ tâm hội tụ ánh sáng (Catchlight tập trung vào vùng chữ T khuôn mặt)
        CGFloat centerX = size.width * 0.50f;
        CGFloat centerY = size.height * 0.55f;
        CGFloat innerRadius = MIN(size.width, size.height) * 0.16f; // Vùng phản quang trán, mắt, sống mũi
        CGFloat outerRadius = MAX(size.width, size.height) * 0.68f; // Vùng tỏa sáng mềm toàn khuôn hình

        // Màu trắng ấm đặc trưng của màn hình Retina Flash iPhone
        CIColor *centerColor = [CIColor colorWithRed:1.0f green:0.98f blue:0.95f alpha:intensity];
        CIColor *outerColor  = [CIColor colorWithRed:1.0f green:0.97f blue:0.92f alpha:intensity * 0.15f];

        CIFilter *radialGradient = [CIFilter filterWithName:@"CIRadialGradient"];
        [radialGradient setValue:[CIVector vectorWithX:centerX Y:centerY] forKey:@"inputCenter"];
        [radialGradient setValue:@(innerRadius) forKey:@"inputRadius0"];
        [radialGradient setValue:@(outerRadius) forKey:@"inputRadius1"];
        [radialGradient setValue:centerColor forKey:@"inputColor0"];
        [radialGradient setValue:outerColor forKey:@"inputColor1"];

        CIImage *lightGradient = [radialGradient.outputImage imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];
        if (!lightGradient) return image;

        // 2. Pha trộn phản quang tự nhiên lên khuôn mặt bằng CISoftLightBlendMode
        CIFilter *blendFilter = [CIFilter filterWithName:@"CISoftLightBlendMode"];
        [blendFilter setValue:lightGradient forKey:kCIInputImageKey];
        [blendFilter setValue:image forKey:kCIInputBackgroundImageKey];
        CIImage *blended = blendFilter.outputImage ?: image;

        // 3. Tăng phơi sáng tổng thể nhẹ (Auto-Exposure Surge) trong khoảnh khắc lóe sáng cực đại
        if (intensity > 0.40f) {
            CIFilter *exposureFilter = [CIFilter filterWithName:@"CIExposureAdjust"];
            [exposureFilter setValue:blended forKey:kCIInputImageKey];
            [exposureFilter setValue:@(intensity * 0.55f) forKey:@"inputEV"];
            CIImage *exposed = exposureFilter.outputImage;
            if (exposed) return exposed;
        }

        return blended;
    } @catch (NSException *ex) {
        return image;
    }
}

#pragma mark - Auto Screen Flash Detection

+ (void)checkAndAutoTriggerWithScreenRGB:(float)r g:(float)g b:(float)b {
    static NSTimeInterval lastTriggerTime = 0;
    static float lastBrightness = 0.5f;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    float currentBrightness = (r + g + b) / 3.0f;

    // Điều kiện chớp tự động: Màn hình sáng trắng (> 78%) và tăng vọt > 18% so với nhịp trước
    if (currentBrightness > 0.78f && (currentBrightness - lastBrightness) > 0.18f) {
        // Cooldown 2.5 giây để chống kích hoạt trùng lặp
        if (now - lastTriggerTime > 2.5) {
            lastTriggerTime = now;
            [self triggerFlashBurst];
        }
    }

    lastBrightness = currentBrightness;
}

@end

