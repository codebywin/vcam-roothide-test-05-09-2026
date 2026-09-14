//
//  VCAMTransformManager.m
//  VCAM iOS - Video Transformation & Mirroring Engine
//

#import "VCAMTransformManager.h"
#import <sys/stat.h>
#import <unistd.h>

static const char *kVCAMScaleFileName          = "vcam_scale";
static const char *kVCAMOffsetXFileName        = "vcam_offset_x";
static const char *kVCAMOffsetYFileName        = "vcam_offset_y";
static const char *kVCAMRotationFileName       = "vcam_rotation";
static const char *kVCAMFlipHorizontalFileName = "vcam_flip_horizontal";

static const CGFloat kVCAMDpadStep = 40.0f;
static const CGFloat kVCAMMinScale = 0.40f;
static const CGFloat kVCAMMaxScale = 2.50f;
static const CGFloat kVCAMMaxOffset = 600.0f;

@implementation VCAMTransformManager

+ (instancetype)sharedManager {
    static VCAMTransformManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VCAMTransformManager alloc] init];
    });
    return instance;
}

#pragma mark - Path & File Helpers

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

static void WriteTmpFlag(const char *name, const char *val) {
    for (NSString *dir in PossibleTmpDirs()) {
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        FILE *f = fopen([path UTF8String], "w");
        if (f) {
            if (val) fputs(val, f);
            fclose(f);
        }
        chmod([path UTF8String], 0666);
    }
}

static void RemoveTmpFlag(const char *name) {
    for (NSString *dir in PossibleTmpDirs()) {
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        unlink([path UTF8String]);
    }
}

static BOOL CheckTmpFlagExists(const char *name) {
    for (NSString *dir in PossibleTmpDirs()) {
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        if (access([path UTF8String], F_OK) == 0) {
            return YES;
        }
    }
    return NO;
}

static NSString *FindTmpFilePath(const char *name) {
    static NSString *primaryDir = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSString *dir in PossibleTmpDirs()) {
            if (access([dir UTF8String], W_OK | R_OK) == 0) {
                primaryDir = dir;
                break;
            }
        }
        if (!primaryDir) primaryDir = @"/var/tmp";
    });

    NSString *directPath = [primaryDir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
    if (access([directPath UTF8String], F_OK) == 0) {
        return directPath;
    }

    for (NSString *dir in PossibleTmpDirs()) {
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithUTF8String:name]];
        if (access([path UTF8String], F_OK) == 0) {
            return path;
        }
    }
    return directPath;
}

#pragma mark - Scale / Zoom

- (CGFloat)scale {
    NSString *path = FindTmpFilePath(kVCAMScaleFileName);
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        float val = 1.0f;
        if (fscanf(f, "%f", &val) == 1) {
            fclose(f);
            if (val >= kVCAMMinScale && val <= kVCAMMaxScale) return (CGFloat)val;
        } else {
            fclose(f);
        }
    }
    return 1.0f;
}

- (void)setScale:(CGFloat)scale {
    if (scale < kVCAMMinScale) scale = kVCAMMinScale;
    if (scale > kVCAMMaxScale) scale = kVCAMMaxScale;
    char buf[32];
    snprintf(buf, sizeof(buf), "%.2f", scale);
    WriteTmpFlag(kVCAMScaleFileName, buf);
}

- (void)zoomIn {
    CGFloat s = [self scale] + 0.10f;
    [self setScale:s];
}

- (void)zoomOut {
    CGFloat s = [self scale] - 0.10f;
    [self setScale:s];
}

#pragma mark - Offsets & D-Pad

- (CGFloat)offsetX {
    NSString *path = FindTmpFilePath(kVCAMOffsetXFileName);
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        float val = 0.0f;
        if (fscanf(f, "%f", &val) == 1) {
            fclose(f);
            return (CGFloat)val;
        }
        fclose(f);
    }
    return 0.0f;
}

- (CGFloat)offsetY {
    NSString *path = FindTmpFilePath(kVCAMOffsetYFileName);
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        float val = 0.0f;
        if (fscanf(f, "%f", &val) == 1) {
            fclose(f);
            return (CGFloat)val;
        }
        fclose(f);
    }
    return 0.0f;
}

- (void)setOffsetX:(CGFloat)x offsetY:(CGFloat)y {
    if (x > kVCAMMaxOffset) x = kVCAMMaxOffset;
    if (x < -kVCAMMaxOffset) x = -kVCAMMaxOffset;
    if (y > kVCAMMaxOffset) y = kVCAMMaxOffset;
    if (y < -kVCAMMaxOffset) y = -kVCAMMaxOffset;

    char bufX[32], bufY[32];
    snprintf(bufX, sizeof(bufX), "%.1f", x);
    snprintf(bufY, sizeof(bufY), "%.1f", y);
    WriteTmpFlag(kVCAMOffsetXFileName, bufX);
    WriteTmpFlag(kVCAMOffsetYFileName, bufY);
}

- (void)moveUp {
    CGFloat x = [self offsetX];
    CGFloat y = [self offsetY] + kVCAMDpadStep;
    [self setOffsetX:x offsetY:y];
}

- (void)moveDown {
    CGFloat x = [self offsetX];
    CGFloat y = [self offsetY] - kVCAMDpadStep;
    [self setOffsetX:x offsetY:y];
}

- (void)moveLeft {
    CGFloat x = [self offsetX] - kVCAMDpadStep;
    CGFloat y = [self offsetY];
    [self setOffsetX:x offsetY:y];
}

- (void)moveRight {
    CGFloat x = [self offsetX] + kVCAMDpadStep;
    CGFloat y = [self offsetY];
    [self setOffsetX:x offsetY:y];
}

- (void)reset {
    [self setOffsetX:0.0f offsetY:0.0f];
    [self setScale:1.0f];
}

#pragma mark - Rotation

- (int)rotation {
    NSString *path = FindTmpFilePath(kVCAMRotationFileName);
    FILE *f = fopen([path UTF8String], "r");
    if (f) {
        int val = 0;
        if (fscanf(f, "%d", &val) == 1) {
            fclose(f);
            return ((val % 360) + 360) % 360;
        }
        fclose(f);
    }
    return 0;
}

- (void)setRotation:(int)degrees {
    char buf[16];
    snprintf(buf, sizeof(buf), "%d", ((degrees % 360) + 360) % 360);
    WriteTmpFlag(kVCAMRotationFileName, buf);
}

- (int)rotate90 {
    int cur = [self rotation];
    int next = (cur + 90) % 360;
    [self setRotation:next];
    return next;
}

#pragma mark - Mirror Flip (🪞)

- (BOOL)isMirrorFlipped {
    return CheckTmpFlagExists(kVCAMFlipHorizontalFileName);
}

- (void)setMirrorFlipped:(BOOL)flipped {
    if (flipped) {
        WriteTmpFlag(kVCAMFlipHorizontalFileName, "1");
    } else {
        RemoveTmpFlag(kVCAMFlipHorizontalFileName);
    }
}

- (BOOL)toggleMirrorFlip {
    BOOL cur = [self isMirrorFlipped];
    BOOL next = !cur;
    [self setMirrorFlipped:next];
    return next;
}

#pragma mark - Realtime State Cache

+ (VCAMTransformState)currentTransformState {
    static VCAMTransformState cachedState = {1.0f, 0.0f, 0.0f, 0, NO, NO};
    static NSTimeInterval lastRead = 0;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - lastRead < 0.50) { // Cache 500ms giam tai I/O trong render loop mediaserverd
        return cachedState;
    }
    lastRead = now;

    VCAMTransformManager *mgr = [VCAMTransformManager sharedManager];
    cachedState.scale = [mgr scale];
    cachedState.offsetX = [mgr offsetX];
    cachedState.offsetY = [mgr offsetY];
    cachedState.rotation = [mgr rotation];
    cachedState.isFlipped = [mgr isMirrorFlipped];
    cachedState.hasTransform = (fabs(cachedState.scale - 1.0f) > 0.01f ||
                                fabs(cachedState.offsetX) > 0.1f ||
                                fabs(cachedState.offsetY) > 0.1f ||
                                cachedState.isFlipped ||
                                cachedState.rotation != 0);
    return cachedState;
}

#pragma mark - GPU Metal Transform Pipeline

+ (CIImage *)applyTransformToImage:(CIImage *)image
                           srcSize:(CGSize)srcSize
                           dstSize:(CGSize)dstSize
                             state:(VCAMTransformState)state {
    if (!image || srcSize.width <= 0 || srcSize.height <= 0 || dstSize.width <= 0 || dstSize.height <= 0) {
        return image;
    }

    CGFloat scale = state.scale;
    if (scale < kVCAMMinScale) scale = kVCAMMinScale;
    if (scale > kVCAMMaxScale) scale = kVCAMMaxScale;

    CGFloat baseScaleX = dstSize.width / srcSize.width;
    CGFloat baseScaleY = dstSize.height / srcSize.height;

    // Lat guong ngang tren man hinh portrait (truc Y cua sensor = truc ngang man hinh)
    if (state.isFlipped) {
        baseScaleY = -baseScaleY;
    }

    CGFloat finalScaleX = baseScaleX * scale;
    CGFloat finalScaleY = baseScaleY * scale;

    // 1. Dua tam anh goc ve goc toa do (0, 0)
    CGAffineTransform t = CGAffineTransformMakeTranslation(-srcSize.width / 2.0f, -srcSize.height / 2.0f);

    // 2. Thu phong ti le va lat guong
    t = CGAffineTransformConcat(t, CGAffineTransformMakeScale(finalScaleX, finalScaleY));

    // 3. Tinh tien theo truc cam bien (da duoc can chinh theo huong cam portrait):
    // Truc X cam bien = Len / Xuong tren man hinh
    // Truc Y cam bien = Trai / Phai tren man hinh
    CGFloat tx = dstSize.width / 2.0f - state.offsetY;
    CGFloat ty = dstSize.height / 2.0f + state.offsetX;
    t = CGAffineTransformConcat(t, CGAffineTransformMakeTranslation(tx, ty));

    return [image imageByApplyingTransform:t];
}

@end

