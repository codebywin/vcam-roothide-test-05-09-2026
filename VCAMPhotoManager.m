//
//  VCAMPhotoManager.m
//  VCAM iOS - Still Image Manager
//

#import "VCAMPhotoManager.h"
#import "VCAMLicenseManager.h"
#import "VCAMTransformManager.h"
#import <ImageIO/ImageIO.h>
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

    // 1. Reset góc xoay về 0° mặc định và lật gương về NO theo yêu cầu của user
    [[VCAMTransformManager sharedManager] setRotation:0];
    [[VCAMTransformManager sharedManager] setMirrorFlipped:NO];

    // 2. Lưu vào toàn bộ các thư mục tmp
    BOOL savedAny = NO;
    for (NSString *dir in PossibleTmpDirs()) {
        // Xóa video cũ để ưu tiên ảnh tĩnh
        NSString *movPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamTempFileName]];
        unlink([movPath UTF8String]);

        // Ghi file ảnh tĩnh
        NSString *photoPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamTempPhotoFileName]];
        unlink([photoPath UTF8String]);
        BOOL ok = [jpegData writeToFile:photoPath atomically:YES];
        if (ok) {
            chmod([photoPath UTF8String], 0666);
            savedAny = YES;
        }

        // Bật cờ enabled
        NSString *enPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamEnabledFlagName]];
        [@"1" writeToFile:enPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([enPath UTF8String], 0666);

        // Tắt cờ paused
        NSString *pausePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamPauseFlagName]];
        unlink([pausePath UTF8String]);
    }

    if (savedAny) {
        NSLog(@"[VCAMPhoto] Đã lưu ảnh thành công vào tmp (size: %lu bytes), rotation reset về 0°", (unsigned long)jpegData.length);
        [self _showToast:@"🖼️ Đã chọn ảnh (0° dọc)!" inView:_currentPresenter.view];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"kVCAMMediaChangedNotification" object:nil];
    } else {
        [self _showToast:@"❌ Lỗi ghi file ảnh vào tmp!" inView:_currentPresenter.view];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Pixel Buffer & Rotation Engine

+ (CVPixelBufferRef)createPixelBufferFromImageFile:(NSString *)path {
    if (!path || access([path UTF8String], R_OK) != 0) return NULL;

    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return NULL;

    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!cgImage) return NULL;

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) {
        CGImageRelease(cgImage);
        return NULL;
    }

    if (width % 2 != 0) width--;
    if (height % 2 != 0) height--;

    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef pxbuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)options,
                                          &pxbuffer);
    if (status != kCVReturnSuccess || !pxbuffer) {
        CGImageRelease(cgImage);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pxbuffer);
    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, width, height, 8, bytesPerRow,
                                                 rgbColorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(rgbColorSpace);

    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    CGImageRelease(cgImage);
    return pxbuffer;
}

+ (CVPixelBufferRef)createRotatedPixelBuffer:(CVPixelBufferRef)src rotation:(int)rotation {
    if (!src) return NULL;
    int rot = ((rotation % 360) + 360) % 360;

    size_t srcW = CVPixelBufferGetWidth(src);
    size_t srcH = CVPixelBufferGetHeight(src);
    size_t dstW = (rot == 90 || rot == 270) ? srcH : srcW;
    size_t dstH = (rot == 90 || rot == 270) ? srcW : srcH;
    OSType fmt = CVPixelBufferGetPixelFormatType(src);

    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferRef dst = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, dstW, dstH, fmt,
                                          (__bridge CFDictionaryRef)options, &dst);
    if (status != kCVReturnSuccess || !dst) {
        CFRetain(src);
        return src;
    }

    CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(dst, 0);

    uint8_t *srcBase = (uint8_t *)CVPixelBufferGetBaseAddress(src);
    uint8_t *dstBase = (uint8_t *)CVPixelBufferGetBaseAddress(dst);
    size_t srcBPR = CVPixelBufferGetBytesPerRow(src);
    size_t dstBPR = CVPixelBufferGetBytesPerRow(dst);

    if (rot == 0) {
        size_t bpr = MIN(srcBPR, dstBPR);
        for (size_t y = 0; y < srcH; y++) {
            memcpy(dstBase + y * dstBPR, srcBase + y * srcBPR, bpr);
        }
    } else if (rot == 90) {
        for (size_t dy = 0; dy < dstH; dy++) {
            uint32_t *dRow = (uint32_t *)(dstBase + dy * dstBPR);
            size_t sx = dy;
            for (size_t dx = 0; dx < dstW; dx++) {
                size_t sy = srcH - 1 - dx;
                dRow[dx] = ((uint32_t *)(srcBase + sy * srcBPR))[sx];
            }
        }
    } else if (rot == 180) {
        for (size_t dy = 0; dy < dstH; dy++) {
            uint32_t *dRow = (uint32_t *)(dstBase + dy * dstBPR);
            size_t sy = srcH - 1 - dy;
            for (size_t dx = 0; dx < dstW; dx++) {
                dRow[dx] = ((uint32_t *)(srcBase + sy * srcBPR))[srcW - 1 - dx];
            }
        }
    } else if (rot == 270) {
        for (size_t dy = 0; dy < dstH; dy++) {
            uint32_t *dRow = (uint32_t *)(dstBase + dy * dstBPR);
            for (size_t dx = 0; dx < dstW; dx++) {
                size_t sy = dx;
                size_t sx = srcW - 1 - dy;
                dRow[dx] = ((uint32_t *)(srcBase + sy * srcBPR))[sx];
            }
        }
    }

    CVPixelBufferUnlockBaseAddress(dst, 0);
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    return dst;
}

#pragma mark - Toast

- (void)_showToast:(NSString *)msg inView:(UIView *)view {
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 200, 40)];
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
