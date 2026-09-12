//
//  VCAMPhotoManager.h
//  VCAM iOS - Still Image Injection Engine
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAMPhotoManager : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>

+ (instancetype)sharedManager;

/// Mở thư viện ảnh để người dùng chọn ảnh tĩnh
- (void)presentPhotoPickerFromViewController:(UIViewController *)presenter;

/// Xử lý chuyển đổi ảnh đã chọn thành luồng video ảo độ nét cao
- (void)processImage:(UIImage *)image presenter:(nullable UIViewController *)presenter completion:(nullable void(^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END

