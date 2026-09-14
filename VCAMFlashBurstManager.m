//
//  VCAMFlashBurstManager.m
//  VCAM iOS - Camera Flash Burst & Catchlight Reflection Engine
//

#import "VCAMFlashBurstManager.h"
#import "VCAMFlashLivenessManager.h"
#include <sys/stat.h>
#include <unistd.h>

static const NSTimeInterval kBurstTotalDuration = 0.45; // Tổng thời lượng chớp sáng 450ms
static const NSTimeInterval kBurstRiseDuration  = 0.09; // Thời gian bừng sáng cực nhanh 90ms
static const float kBurstPeakIntensity          = 0.85f; // Cường độ sáng đỉnh

static NSArray<NSString *> *BurstPossibleDirs(void) {
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
    for (NSString *dir in BurstPossibleDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:@"vcam_burst_time"];
        if (access([p UTF8String], F_OK) == 0) {
            return p;
        }
    }
    return nil;
}

@implementation VCAMFlashBurstManager

+ (instancetype)sharedManager {
    static VCAMFlashBurstManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMFlashBurstManager alloc] init];
    });
    return instance;
}

+ (void)triggerFlashBurst {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSString *val = [NSString stringWithFormat:@"%.4f", now];
    for (NSString *dir in BurstPossibleDirs()) {
        NSString *p = [dir stringByAppendingPathComponent:@"vcam_burst_time"];
        FILE *f = fopen([p UTF8String], "w");
        if (f) {
            fputs([val UTF8String], f);
            fclose(f);
        }
        chmod([p UTF8String], 0666);
    }
}

+ (float)currentBurstIntensity {
    static NSTimeInterval sCachedBurstTime = 0;
    static NSTimeInterval sLastFileCheckTime = 0;
    
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    
    // Nếu đang trong nhịp chớp (đã lưu cache và chưa quá 450ms) -> tính toán trực tiếp không cần đọc file
    if (sCachedBurstTime > 0 && (now - sCachedBurstTime) >= 0 && (now - sCachedBurstTime) < kBurstTotalDuration) {
        NSTimeInterval dt = now - sCachedBurstTime;
        if (dt < kBurstRiseDuration) {
            return kBurstPeakIntensity * (float)(dt / kBurstRiseDuration);
        } else {
            float p = (float)((dt - kBurstRiseDuration) / (kBurstTotalDuration - kBurstRiseDuration));
            return kBurstPeakIntensity * (1.0f - p) * (1.0f - p);
        }
    }
    
    // Kiểm tra file định kỳ (giới hạn 50ms một lần để tối ưu hóa CPU)
    if (now - sLastFileCheckTime > 0.05) {
        sLastFileCheckTime = now;
        NSString *path = FindExistingBurstPath();
        if (path) {
            FILE *f = fopen([path UTF8String], "r");
            if (f) {
                char buf[64] = {0};
                if (fgets(buf, sizeof(buf) - 1, f)) {
                    sCachedBurstTime = atof(buf);
                }
                fclose(f);
            }
        }
    }
    
    if (sCachedBurstTime > 0) {
        NSTimeInterval dt = now - sCachedBurstTime;
        if (dt >= 0 && dt < kBurstTotalDuration) {
            if (dt < kBurstRiseDuration) {
                return kBurstPeakIntensity * (float)(dt / kBurstRiseDuration);
            } else {
                float p = (float)((dt - kBurstRiseDuration) / (kBurstTotalDuration - kBurstRiseDuration));
                return kBurstPeakIntensity * (1.0f - p) * (1.0f - p);
            }
        }
    }
    
    return 0.0f;
}

+ (BOOL)isFlashBurstActive {
    return [self currentBurstIntensity] > 0.015f;
}

+ (CIImage *)applyFlashBurstToImage:(CIImage *)image size:(CGSize)size {
    if (!image || size.width <= 0 || size.height <= 0) return image;

    float baseIntensity = [self currentBurstIntensity];
    if (baseIntensity <= 0.015f) return image;

    VCAMFlashState flashState = [VCAMFlashLivenessManager currentFlashState];
    float userMultiplier = (flashState.intensity > 0.05f) ? (flashState.intensity / 0.35f) : 1.0f;
    float intensity = baseIntensity * userMultiplier;
    if (intensity > 1.0f) intensity = 1.0f;

    @try {
        // 1. Tọa độ tâm hội tụ ánh sáng (Catchlight tập trung vào vùng chữ T khuôn mặt hoặc thẻ căn cước)
        CGFloat centerX = size.width * 0.50f;
        CGFloat centerY = size.height * 0.55f;
        CGFloat innerRadius = MIN(size.width, size.height) * 0.18f; // Vùng phản quang trán, mắt, sống mũi
        CGFloat outerRadius = MAX(size.width, size.height) * 0.70f; // Vùng tỏa sáng mềm toàn khuôn hình

        // Màu trắng ngà đặc trưng của ánh đèn flash iPhone
        CIColor *centerColor = [CIColor colorWithRed:1.0f green:0.98f blue:0.95f alpha:intensity];
        CIColor *outerColor  = [CIColor colorWithRed:1.0f green:0.96f blue:0.92f alpha:intensity * 0.15f];

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
        CIImage *blended = blendFilter.outputImage;
        if (!blended) blended = image;

        // 3. Tăng nhẹ phơi sáng (Auto-Exposure Surge) trong khoảnh khắc lóe sáng
        CIFilter *exposureFilter = [CIFilter filterWithName:@"CIExposureAdjust"];
        [exposureFilter setValue:blended forKey:kCIInputImageKey];
        [exposureFilter setValue:@(intensity * 0.65f) forKey:@"inputEV"];
        CIImage *finalImg = exposureFilter.outputImage;

        return finalImg ?: blended;
    } @catch (__unused NSException *e) {
        return image;
    }
}

+ (void)checkAndAutoTriggerWithScreenRGB:(float)r g:(float)g b:(float)b {
    static float lastBrightness = 0.0f;
    static NSTimeInterval lastTriggerTime = 0;

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

