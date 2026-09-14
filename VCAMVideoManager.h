//
//  VCAMVideoManager.h
//  VCAM iOS - Video Selection & Trimming Engine
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface VCAMVideoManager : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>

+ (instancetype)sharedManager;

/// Mở thư viện video với giao diện cắt video mặc định của iOS (allowsEditing = YES)
- (void)presentVideoPickerFromViewController:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END

