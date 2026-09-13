//
//  VCAMPhotoManager.h
//  VCAM iOS - Still Image Manager
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAMPhotoManager : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>

+ (instancetype)sharedManager;

/// Mở thư viện ảnh để người dùng chọn ảnh tĩnh
- (void)presentPhotoPickerFromViewController:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
