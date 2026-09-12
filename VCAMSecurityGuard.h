//
//  VCAMSecurityGuard.h
//  VCAM iOS - Multi-Layer Security Guard & Anti-Bypass Engine
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Kiểm tra chữ ký số ủy quyền thời gian thực (chạy trực tiếp trong mediaserverd và SpringBoard)
/// Sử dụng liên kết C trực tiếp để chống triệt để các tweak hook runtime như ElleKit / Frida.
BOOL VCAMVerifyProcessAuthorization(void);

/// Kiểm tra tính toàn vẹn mã máy ARM64 của dylib trong bộ nhớ (phát hiện binary patch MOV W0, #1 / RET)
BOOL VCAMCheckBinaryIntegrity(void);

/// Lấy chuỗi Secret Salt an toàn (đã được giải mã XOR động trong stack RAM)
NSString *VCAMGetDecryptedSecretSalt(void);

/// Lấy mã định danh phần cứng HWID dùng chung
NSString *VCAMGetSharedDeviceHWID(void);

#ifdef __cplusplus
}
#endif

@interface VCAMSecurityGuard : NSObject

+ (instancetype)sharedGuard;

/// Cấp phát và ký số token bản quyền vào file an toàn (/var/tmp/.vcam_token)
+ (void)issueAuthorizationTokenWithKey:(NSString *)key expiresAt:(NSTimeInterval)expiresAt hwid:(NSString *)hwid;

/// Thu hồi và tiêu hủy toàn bộ token bản quyền
+ (void)revokeAuthorizationToken;

/// Kiểm tra trạng thái token hiện tại (tầng Objective-C)
- (BOOL)isTokenValid;

@end

NS_ASSUME_NONNULL_END
