//
//  VCAMFlashBurstManager.h
//  VCAM iOS - Camera Flash Burst & Catchlight Engine
//

#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAMFlashBurstManager : NSObject

+ (instancetype)sharedManager;

/// Kích hoạt 1 cú chớp sáng Flash Burst chân thực (450ms)
+ (void)triggerFlashBurst;

/// Kiểm tra xem hiện tại có đang trong nhịp chớp Flash hay không (trong mediaserverd)
+ (BOOL)isFlashBurstActive;

/// Cường độ sáng tức thời hiện tại (0.0 -> 0.80 -> 0.0 theo đường cong quang học thực tế)
+ (float)currentBurstIntensity;

/// Áp dụng hiệu ứng chớp sáng và điểm phản quang Catchlight bằng Metal GPU
+ (CIImage *)applyFlashBurstToImage:(CIImage *)image size:(CGSize)size;

/// Tự động phát hiện khi màn hình chớp trắng chụp ảnh (> 82% độ sáng) và kích hoạt (cooldown 3s)
+ (void)checkAndAutoTriggerWithScreenRGB:(float)r g:(float)g b:(float)b;

@end

NS_ASSUME_NONNULL_END
