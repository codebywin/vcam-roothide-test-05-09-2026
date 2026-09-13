//
//  VCAMPhotoManager.m
//  VCAM iOS - Still Image Manager
//

#import "VCAMPhotoManager.h"
#import "VCAMLicenseManager.h"
#import <sys/stat.h>
#import <unistd.h>

static const char *kVCamTempFileName      = "vcam_temp.mov";
static const char *kVCamTempPhotoFileName = "vcam_temp.jpg";
static const char *kVCamEnabledFlagName   = "vcam_enabled";
static const char *kVCamPauseFlagName     = "vcam_paused";

@interface VCAMPhotoManager () {
    __weak UIViewController *_currentPresenter;
}
@end

@implementation VCAMPhotoManager

+ (instancetype)sharedManager {
    static VCAMPhotoManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMPhotoManager alloc] init];
    });
    return instance;
}

static NSArray<NSString *> *PossibleTmpDirs(void) {
    static NSArray<NSString *> *dirs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray *list = [NSMutableArray array];
        if ([[NSFileManager defaultManager] fileExistsAtPath:@"/rootfs/private/var/tmp"]) {
            [list addObject:@"/rootfs/private/var/tmp"];
        }
        [list addObject:@"/var/tmp"];
        [list addObject:@"/private/var/tmp"];
        dirs = [list copy];
    });
    return dirs;
}

- (void)presentPhotoPickerFromViewController:(UIViewController *)presenter {
    _currentPresenter = presenter;

    if (![[VCAMLicenseManager sharedManager] isLicenseValid]) {
        [[VCAMLicenseManager sharedManager] promptActivationDialogWithReason:@"Vui lòng kích hoạt mã bản quyền để chọn ảnh!" presenter:presenter];
        return;
    }

    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.image"];
    picker.allowsEditing = NO;
    picker.delegate = self;

    [presenter presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIImagePickerControllerDelegate

static UIImage *NormalizeImageOrientation(UIImage *img) {
    if (!img) return nil;
    if (img.imageOrientation == UIImageOrientationUp) return img;
    UIGraphicsBeginImageContextWithOptions(img.size, NO, img.scale);
    [img drawInRect:CGRectMake(0, 0, img.size.width, img.size.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: img;
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    UIImage *selectedImg = info[UIImagePickerControllerOriginalImage];
    if (!selectedImg) {
        NSURL *imgURL = info[UIImagePickerControllerImageURL];
        if (imgURL) {
            NSData *d = [NSData dataWithContentsOfURL:imgURL];
            selectedImg = [UIImage imageWithData:d];
        }
    }

    if (!selectedImg) {
        NSLog(@"[VCAMPhoto] Không tìm thấy ảnh hợp lệ!");
        [self _showToast:@"❌ Không đọc được ảnh!" inView:_currentPresenter.view];
        return;
    }

    // Chuẩn hóa góc xoay thẳng đứng theo EXIF
    UIImage *normalized = NormalizeImageOrientation(selectedImg);

    // Chuyển thành dữ liệu JPEG chất lượng cao 95%
    NSData *jpegData = UIImageJPEGRepresentation(normalized, 0.95);
    if (!jpegData || jpegData.length == 0) {
        NSLog(@"[VCAMPhoto] Không thể nén JPEG từ ảnh đã chọn!");
        [self _showToast:@"❌ Lỗi xử lý ảnh!" inView:_currentPresenter.view];
        return;
    }

    // Lưu vào toàn bộ các thư mục tmp
    BOOL savedAny = NO;
    for (NSString *dir in PossibleTmpDirs()) {
        // 1. Xóa video cũ để ưu tiên ảnh tĩnh
        NSString *movPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamTempFileName]];
        unlink([movPath UTF8String]);

        // 2. Ghi file ảnh tĩnh
        NSString *photoPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamTempPhotoFileName]];
        unlink([photoPath UTF8String]);
        BOOL ok = [jpegData writeToFile:photoPath atomically:YES];
        if (ok) {
            chmod([photoPath UTF8String], 0666);
            savedAny = YES;
        }

        // 3. Bật cờ enabled
        NSString *enPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamEnabledFlagName]];
        [@"1" writeToFile:enPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([enPath UTF8String], 0666);

        // 4. Tắt cờ paused
        NSString *pausePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamPauseFlagName]];
        unlink([pausePath UTF8String]);
    }

    if (savedAny) {
        NSLog(@"[VCAMPhoto] Đã lưu ảnh thành công vào tmp (size: %lu bytes)", (unsigned long)jpegData.length);
        [self _showToast:@"🖼️ Đã chọn ảnh thành công!" inView:_currentPresenter.view];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"kVCAMMediaChangedNotification" object:nil];
    } else {
        [self _showToast:@"❌ Lỗi ghi file ảnh vào tmp!" inView:_currentPresenter.view];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)_showToast:(NSString *)msg inView:(UIView *)view {
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 190, 40)];
        lbl.center = CGPointMake(view.bounds.size.width / 2, view.bounds.size.height * 0.35);
        lbl.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];
        lbl.textColor = [UIColor whiteColor];
        lbl.textAlignment = NSTextAlignmentCenter;
        lbl.font = [UIFont boldSystemFontOfSize:14];
        lbl.text = msg;
        lbl.layer.cornerRadius = 10;
        lbl.layer.masksToBounds = YES;
        lbl.alpha = 0;
        [view addSubview:lbl];
        [UIView animateWithDuration:0.2 animations:^{
            lbl.alpha = 1.0;
        } completion:^(BOOL fin1) {
            [UIView animateWithDuration:0.2 delay:1.2 options:0 animations:^{
                lbl.alpha = 0;
            } completion:^(BOOL fin2) {
                [lbl removeFromSuperview];
            }];
        }];
    });
}

@end
