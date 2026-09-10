//
//  VCAMLicenseManager.h
//  VCAM iOS RootHide Dopamine
//
//  Hệ thống quản lý bản quyền, chống bẻ khóa & Heartbeat 60s
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kVCAMLicenseStatusChangedNotification;
extern NSString *const kVCAMLicenseRevokedNotification;

@interface VCAMLicenseManager : NSObject

@property (nonatomic, readonly) BOOL isLicenseValid;
@property (nonatomic, copy, readonly, nullable) NSString *currentKey;
@property (nonatomic, copy, readonly) NSString *hwid;
@property (nonatomic, readonly) NSTimeInterval expiresAt; // 0 = Lifetime
@property (nonatomic, readonly) BOOL isChecking;

+ (instancetype)sharedManager;

/// Khởi động chu kỳ kiểm tra ngầm Heartbeat 60s
- (void)startHeartbeat;

/// Dừng chu kỳ kiểm tra ngầm
- (void)stopHeartbeat;

/// Kích hoạt bản quyền bằng mã key
- (void)activateWithKey:(NSString *)key completion:(void(^)(BOOL success, NSString *message))completion;

/// Xác thực bản quyền với máy chủ Cloudflare
- (void)verifyLicenseOnlineWithCompletion:(nullable void(^)(BOOL valid, NSString *message))completion;

/// Kiểm tra chữ ký số cục bộ (chống can thiệp offline)
- (BOOL)validateLocalSignatureOffline;

/// Lấy chuỗi mô tả thời hạn còn lại (ví dụ: "Còn 28 ngày", "Vĩnh viễn", "Hết hạn")
- (NSString *)remainingTimeString;

/// Hiển thị hộp thoại nhập Key kích hoạt trên màn hình
- (void)promptActivationDialogWithReason:(nullable NSString *)reason presenter:(nullable UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END

