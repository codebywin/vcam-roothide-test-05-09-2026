//
//  VCAMVideoManager.m
//  VCAM iOS - Video Selection & Trimming Engine
//

#import "VCAMVideoManager.h"
#import "VCAMLicenseManager.h"
#import "VCAMTransformManager.h"
#import "VCAMSecurityGuard.h"
#import <AVFoundation/AVFoundation.h>
#import <sys/stat.h>
#import <unistd.h>

static const char *kVCamTempFileName      = "vcam_temp.mov";
static const char *kVCamTempPhotoFileName = "vcam_temp.jpg";
static const char *kVCamEnabledFlagName   = "vcam_enabled";
static const char *kVCamPauseFlagName     = "vcam_paused";

@interface VCAMVideoManager () {
    __weak UIViewController *_currentPresenter;
}
@end

@implementation VCAMVideoManager

+ (instancetype)sharedManager {
    static VCAMVideoManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMVideoManager alloc] init];
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

- (void)presentVideoPickerFromViewController:(UIViewController *)presenter {
    _currentPresenter = presenter;

    // Kiểm tra bản quyền & token bảo mật
    if (![[VCAMLicenseManager sharedManager] isLicenseValid]) {
        [[VCAMLicenseManager sharedManager] promptActivationDialogWithReason:@"Vui lòng kích hoạt mã bản quyền để chọn video!" presenter:presenter];
        return;
    }

    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.movie"];
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    picker.allowsEditing = YES; // Bật tính năng cắt video mặc định của iOS
    picker.videoMaximumDuration = 600.0; // Giới hạn tối đa 10 phút
    picker.delegate = self;

    if (@available(iOS 11.0, *)) {
        picker.videoExportPreset = AVAssetExportPresetPassthrough;
    }

    [presenter presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];

    // Lấy URL video đã cắt/chọn từ iOS trimmer
    NSURL *url = info[UIImagePickerControllerMediaURL];
    if (!url) {
        url = info[UIImagePickerControllerReferenceURL];
    }

    if (!url) {
        NSLog(@"[VCAMVideo] Không tìm thấy URL video hợp lệ!");
        [self _showToast:@"❌ Không đọc được video!" inView:_currentPresenter.view];
        return;
    }

    // Truy cập security-scoped resource an toàn trên iOS 15 & 16
    BOOL accessed = [url startAccessingSecurityScopedResource];

    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&err];

    // Reset góc xoay về 0° và tắt lật gương khi nạp video mới
    [[VCAMTransformManager sharedManager] setRotation:0];
    [[VCAMTransformManager sharedManager] setMirrorFlipped:NO];

    BOOL anySaved = NO;
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *dir in PossibleTmpDirs()) {
        NSString *destPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamTempFileName]];
        unlink([destPath UTF8String]);

        // Xóa ảnh cũ để ưu tiên video vừa chọn
        NSString *photoPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamTempPhotoFileName]];
        unlink([photoPath UTF8String]);

        BOOL saved = NO;
        if (data && data.length > 0) {
            FILE *f = fopen([destPath UTF8String], "wb");
            if (f) {
                size_t written = fwrite(data.bytes, 1, data.length, f);
                fflush(f);
                fclose(f);
                saved = (written == data.length);
            }
        }

        if (!saved) {
            [fm removeItemAtPath:destPath error:nil];
            saved = [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:destPath] error:nil];
        }

        if (!saved && url.path) {
            saved = [fm copyItemAtPath:url.path toPath:destPath error:nil];
        }

        if (saved || (access([destPath UTF8String], F_OK) == 0)) {
            chmod([destPath UTF8String], 0666);
            anySaved = YES;
        }

        // Bật cờ enabled
        NSString *enPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamEnabledFlagName]];
        [@"1" writeToFile:enPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([enPath UTF8String], 0666);

        // Tắt cờ paused
        NSString *pausePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamPauseFlagName]];
        unlink([pausePath UTF8String]);
    }

    if (accessed) {
        [url stopAccessingSecurityScopedResource];
    }

    if (anySaved) {
        NSLog(@"[VCAMVideo] Video đã được lưu thành công vào các thư mục tmp (size: %lu bytes)", (unsigned long)(data ? data.length : 0));
        [self _showToast:@"🎬 Đã chọn & cắt video thành công!" inView:_currentPresenter.view];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"kVCAMMediaChangedNotification" object:nil];
    } else {
        NSLog(@"[VCAMVideo] LỖI ghi file video: %@", err.localizedDescription);
        [self _showToast:@"❌ Lỗi lưu video vào tmp!" inView:_currentPresenter.view];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Toast

- (void)_showToast:(NSString *)msg inView:(UIView *)view {
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 240, 42)];
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
