//
//  VCAMTransformManager.h
//  VCAM iOS - Video Transformation & Mirroring Engine
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    CGFloat scale;          // Ti le thu phong (0.4x - 2.5x)
    CGFloat offsetX;        // Dich chuyen ngang (tren man hinh dung)
    CGFloat offsetY;        // Dich chuyen doc (tren man hinh dung)
    int rotation;           // Goc xoay: 0, 90, 180, 270 do
    BOOL isFlipped;         // Lat guong ngang (Front Camera Mirror)
    BOOL hasTransform;      // Co ap dung bien doi khong
} VCAMTransformState;

@interface VCAMTransformManager : NSObject

+ (instancetype)sharedManager;

// Thu phong (Zoom / Scale)
- (CGFloat)scale;
- (void)setScale:(CGFloat)scale;
- (void)zoomIn;
- (void)zoomOut;

// Toa do dich chuyen (Pan Offset)
- (CGFloat)offsetX;
- (CGFloat)offsetY;
- (void)setOffsetX:(CGFloat)x offsetY:(CGFloat)y;

// Dieu huong D-Pad (Buoc nhay 40px)
- (void)moveUp;
- (void)moveDown;
- (void)moveLeft;
- (void)moveRight;
- (void)reset;

// Xoay goc (Rotation)
- (int)rotation;
- (void)setRotation:(int)degrees;
- (int)rotate90;

// Lat guong ngang (Horizontal Mirror Flip)
- (BOOL)isMirrorFlipped;
- (void)setMirrorFlipped:(BOOL)flipped;
- (BOOL)toggleMirrorFlip;

// Trang thai transform thoi gian thuc (cache cho mediaserverd 60fps)
+ (VCAMTransformState)currentTransformState;

// GPU Metal Transform Pipeline (ap dung len CIImage)
+ (CIImage *)applyTransformToImage:(CIImage *)image
                           srcSize:(CGSize)srcSize
                           dstSize:(CGSize)dstSize
                             state:(VCAMTransformState)state;

@end

NS_ASSUME_NONNULL_END
