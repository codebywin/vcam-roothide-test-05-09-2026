//
//  VCAMShadingManager.h
//  VCAM iOS - 3D Volumetric Face Shading & Camera Sensor Noise Engine
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    BOOL shadingEnabled;
    BOOL grainEnabled;
    float shadingIntensity; // 0.10 - 1.00 (Default: 0.45)
    float grainIntensity;   // 0.05 - 0.80 (Default: 0.28)
} VCAMShadingState;

@interface VCAMShadingManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, assign, getter=isShadingEnabled, setter=setShadingEnabled:) BOOL shadingEnabled;
@property (nonatomic, assign, getter=isGrainEnabled, setter=setGrainEnabled:) BOOL grainEnabled;
@property (nonatomic, assign) CGFloat shadingIntensity;
@property (nonatomic, assign) CGFloat grainIntensity;

- (void)setShadingEnabled:(BOOL)shadingEnabled;
- (void)setGrainEnabled:(BOOL)grainEnabled;
- (BOOL)isShadingEnabled;
- (BOOL)isGrainEnabled;

+ (VCAMShadingState)currentShadingState;
+ (void)saveShadingState:(VCAMShadingState)state;

/// Áp dụng đổ bóng tạo khối 3D và hạt nhiễu cảm biến ISO thời gian thực bằng GPU Metal
+ (CIImage *)apply3DShadingAndGrainToImage:(CIImage *)image
                                     size:(CGSize)size
                                    state:(VCAMShadingState)state;

@end

NS_ASSUME_NONNULL_END
