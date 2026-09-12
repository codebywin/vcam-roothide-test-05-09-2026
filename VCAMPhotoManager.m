//
//  VCAMPhotoManager.m
//  VCAM iOS - Still Image Injection Engine
//

#import "VCAMPhotoManager.h"
#import "VCAMLicenseManager.h"
#import "VCAMSecurityGuard.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <sys/stat.h>
#import <unistd.h>

static const char *kVCamTempFileName    = "vcam_temp.mov";
static const char *kVCamEnabledFlagName = "vcam_enabled";
static const char *kVCamPauseFlagName   = "vcam_paused";

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
        [[VCAMLicenseManager sharedManager] promptActivationDialogWithReason:@"Vui lòng kích hoạt mã bản quyền để chọn ảnh ảo!" presenter:presenter];
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
        NSLog(@"[VCAMPhoto] Không tìm thấy ảnh hợp lệ trong kết quả picker!");
        return;
    }

    [self processImage:selectedImg presenter:_currentPresenter completion:nil];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Core Image to Video Conversion

static UIImage *NormalizeImageOrientation(UIImage *img) {
    if (img.imageOrientation == UIImageOrientationUp) return img;
    UIGraphicsBeginImageContextWithOptions(img.size, NO, img.scale);
    [img drawInRect:CGRectMake(0, 0, img.size.width, img.size.height)];
    UIImage *normalized = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return normalized ?: img;
}

static CVPixelBufferRef CreatePixelBufferFromCGImage(CGImageRef image, size_t width, size_t height) {
    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    CVPixelBufferRef pxbuffer = NULL;
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA,
                                          (__bridge CFDictionaryRef)options,
                                          &pxbuffer);
    if (status != kCVReturnSuccess || !pxbuffer) return NULL;

    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pxbuffer);

    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, width, height, 8, bytesPerRow,
                                                 rgbColorSpace,
                                                 kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(rgbColorSpace);

    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
        CGContextRelease(context);
    }
    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    return pxbuffer;
}

- (void)processImage:(UIImage *)image presenter:(nullable UIViewController *)presenter completion:(nullable void(^)(BOOL success))completion {
    // Hiển thị thông báo đang xử lý
    [self _showToast:@"🖼️ Đang nạp ảnh..." inView:presenter.view];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        UIImage *normalized = NormalizeImageOrientation(image);
        CGImageRef cgImage = normalized.CGImage;
        if (!cgImage) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _showToast:@"❌ Lỗi đọc định dạng ảnh!" inView:presenter.view];
                if (completion) completion(NO);
            });
            return;
        }

        size_t origW = CGImageGetWidth(cgImage);
        size_t origH = CGImageGetHeight(cgImage);

        // H.264 Video Codec bắt buộc kích thước chẵn
        size_t width = (origW % 2 == 0) ? origW : origW - 1;
        size_t height = (origH % 2 == 0) ? origH : origH - 1;
        if (width < 320) width = 320;
        if (height < 320) height = 320;

        // Giới hạn kích thước tối đa 1920 để mượt mà trên chip A11
        if (width > 1920 || height > 1920) {
            CGFloat factor = 1920.0f / MAX(width, height);
            width = ((size_t)(width * factor)) & ~1;
            height = ((size_t)(height * factor)) & ~1;
        }

        NSString *tmpExport = [NSTemporaryDirectory() stringByAppendingPathComponent:@"vcam_img_export.mov"];
        unlink([tmpExport UTF8String]);

        NSError *err = nil;
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:tmpExport]
                                                         fileType:AVFileTypeQuickTimeMovie
                                                            error:&err];
        if (err || !writer) {
            NSLog(@"[VCAMPhoto] Lỗi khởi tạo AVAssetWriter: %@", err);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self _showToast:@"❌ Lỗi đóng gói video!" inView:presenter.view];
                if (completion) completion(NO);
            });
            return;
        }

        NSDictionary *videoSettings = @{
            AVVideoCodecKey: AVVideoCodecTypeH264,
            AVVideoWidthKey: @(width),
            AVVideoHeightKey: @(height)
        };
        AVAssetWriterInput *writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                             outputSettings:videoSettings];
        writerInput.expectsMediaDataInRealTime = NO;

        NSDictionary *bufferAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey: @(width),
            (id)kCVPixelBufferHeightKey: @(height)
        };
        AVAssetWriterInputPixelBufferAdaptor *adaptor =
            [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput
                                                                            sourcePixelBufferAttributes:bufferAttrs];

        if (![writer canAddInput:writerInput]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO);
            });
            return;
        }
        [writer addInput:writerInput];

        if (![writer startWriting]) {
            NSLog(@"[VCAMPhoto] startWriting lỗi: %@", writer.error);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO);
            });
            return;
        }
        [writer startSessionAtSourceTime:kCMTimeZero];

        CVPixelBufferRef pxBuffer = CreatePixelBufferFromCGImage(cgImage, width, height);
        if (!pxBuffer) {
            [writer cancelWriting];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO);
            });
            return;
        }

        // Xuất 30 khung hình tĩnh (1.0 giây chuẩn ở tốc độ 30 FPS)
        int fps = 30;
        int totalFrames = 30;
        for (int i = 0; i < totalFrames; i++) {
            while (!writerInput.isReadyForMoreMediaData) {
                [NSThread sleepForTimeInterval:0.005];
            }
            CMTime framePTS = CMTimeMake(i, fps);
            [adaptor appendPixelBuffer:pxBuffer withPresentationTime:framePTS];
        }
        CVPixelBufferRelease(pxBuffer);

        [writerInput markAsFinished];
        [writer finishWritingWithCompletionHandler:^{
            if (writer.status == AVAssetWriterStatusCompleted) {
                // Đọc video đã tạo và sao chép vào toàn bộ thư mục tmp
                NSData *vidData = [NSData dataWithContentsOfFile:tmpExport];
                if (vidData && vidData.length > 0) {
                    for (NSString *dir in PossibleTmpDirs()) {
                        NSString *dest = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamTempFileName]];
                        unlink([dest UTF8String]);
                        [vidData writeToFile:dest atomically:YES];
                        chmod([dest UTF8String], 0666);

                        // Bật cờ enabled, tắt paused
                        NSString *enPath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamEnabledFlagName]];
                        [@"1" writeToFile:enPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                        chmod([enPath UTF8String], 0666);

                        NSString *pausePath = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamPauseFlagName]];
                        unlink([pausePath UTF8String]);
                    }
                    NSLog(@"[VCAMPhoto] Đã nạp video từ ảnh vào tmp: %zux%zu (size: %lu bytes)", width, height, (unsigned long)vidData.length);
                }
                unlink([tmpExport UTF8String]);

                dispatch_async(dispatch_get_main_queue(), ^{
                    [self _showToast:@"🖼️ Đã nạp ảnh thành công!" inView:presenter.view];
                    [[NSNotificationCenter defaultCenter] postNotificationName:@"kVCAMMediaChangedNotification" object:nil];
                    if (completion) completion(YES);
                });
            } else {
                NSLog(@"[VCAMPhoto] finishWriting lỗi: %@", writer.error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self _showToast:@"❌ Lỗi xử lý ảnh!" inView:presenter.view];
                    if (completion) completion(NO);
                });
            }
        }];
    });
}

- (void)_showToast:(NSString *)msg inView:(UIView *)view {
    if (!view) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 180, 40)];
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
            [UIView animateWithDuration:0.2 delay:1.0 options:0 animations:^{
                lbl.alpha = 0;
            } completion:^(BOOL fin2) {
                [lbl removeFromSuperview];
            }];
        }];
    });
}

@end
