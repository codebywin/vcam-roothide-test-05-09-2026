//
//  VCAMPhotoManager.h
//  VCAM iOS - Still Image Manager
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAMPhotoManager : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>

+ (instancetype)sharedManager;

/// Mở thư viện ảnh để người dùng chọn ảnh tĩnh
- (void)presentPhotoPickerFromViewController:(UIViewController *)presenter;

/// Đọc file ảnh tĩnh từ đường dẫn và tạo CVPixelBufferRef 32BGRA
+ (nullable CVPixelBufferRef)createPixelBufferFromImageFile:(NSString *)path;

/// Xoay CVPixelBuffer theo góc (0, 90, 180, 270 độ)
+ (nullable CVPixelBufferRef)createRotatedPixelBuffer:(CVPixelBufferRef)src rotation:(int)rotation;

@end

NS_ASSUME_NONNULL_END
