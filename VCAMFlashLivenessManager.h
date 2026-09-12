//
//  VCAMFlashLivenessManager.h
//  VCAM iOS - KYC Active Flash Liveness Engine
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    float r;
    float g;
    float b;
    float intensity; // 0.0 to 1.0 (default 0.35)
    BOOL active;
    BOOL testMode;   // Test simulation mode (cycles colors)
} VCAMFlashState;

@interface VCAMFlashLivenessManager : NSObject

+ (instancetype)sharedManager;

// Bật / tắt tính năng KYC Flash Liveness
- (BOOL)isLivenessEnabled;
- (void)setLivenessEnabled:(BOOL)enabled;

// Chế độ mô phỏng kiểm thử (tự động đổi màu ngẫu nhiên để test)
- (BOOL)isTestModeEnabled;
- (void)setTestModeEnabled:(BOOL)enabled;

// Cường độ phản quang (mặc định 0.35)
- (CGFloat)flashIntensity;
- (void)setFlashIntensity:(CGFloat)intensity;

// Bắt đầu / dừng quét màu màn hình (chạy trong SpringBoard)
- (void)startScreenColorMonitoring;
- (void)stopScreenColorMonitoring;

// Đọc trạng thái ánh sáng hiện tại (dùng chung cho mediaserverd & SpringBoard)
+ (VCAMFlashState)currentFlashState;

// Ghi trạng thái ánh sáng vào file chia sẻ /var/tmp
+ (void)saveFlashState:(VCAMFlashState)state;

// Áp dụng hiệu ứng ánh sáng phản quang lên khung hình CIImage (GPU Metal trong mediaserverd)
+ (CIImage *)applyFlashLightingToImage:(CIImage *)sourceImage
                                  size:(CGSize)size
                                 state:(VCAMFlashState)state;

@end

NS_ASSUME_NONNULL_END
