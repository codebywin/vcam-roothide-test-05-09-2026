//
//  VCAMVideoManager.h
//  VCAM iOS - Video Selection & Trimming Engine
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAMVideoManager : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>

+ (instancetype)sharedManager;

/// Mở thư viện chọn video trực tiếp (không cắt video)
- (void)presentVideoPickerFromViewController:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END

