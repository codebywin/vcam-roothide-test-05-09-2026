//
//  VCAMFlashBurstManager.h
//  VCAM iOS - Camera Flash Burst & Catchlight Engine
//

#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VCAMFlashBurstMode) {
    VCAMFlashBurstModeOff    = 0, // Tắt hẳn: Không chớp thủ công và không tự động
    VCAMFlashBurstModeManual = 1, // Thủ công: Chỉ chớp khi bấm nút 📸
    VCAMFlashBurstModeAuto   = 2  // Tự động: Tự bắt chớp khi màn hình chụp ảnh + chớp khi bấm 📸
};

@interface VCAMFlashBurstManager : NSObject

+ (instancetype)sharedManager;

/// Lấy chế độ Flash Burst hiện tại
+ (VCAMFlashBurstMode)currentBurstMode;

/// Đặt chế độ Flash Burst mới
+ (void)setBurstMode:(VCAMFlashBurstMode)mode;

/// Kích hoạt 1 cú chớp sáng Flash Burst chân thực (450ms)
+ (void)triggerFlashBurst;

/// Kiểm tra xem hiện tại có đang trong nhịp chớp Flash hay không (trong mediaserverd)
+ (BOOL)isFlashBurstActive;

/// Cường độ sáng tức thời hiện tại (0.0 -> 1.0 -> 0.0 theo đường cong quang học thực tế)
+ (float)currentBurstIntensity;

/// Áp dụng hiệu ứng chớp sáng và điểm phản quang Catchlight bằng Metal GPU
+ (CIImage *)applyFlashBurstToImage:(CIImage *)image size:(CGSize)size;

/// Tự động phát hiện khi màn hình chớp trắng chụp ảnh và kích hoạt (cooldown 2s)
+ (void)checkAndAutoTriggerWithScreenRGB:(float)r g:(float)g b:(float)b;

@end

NS_ASSUME_NONNULL_END
