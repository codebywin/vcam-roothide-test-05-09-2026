//
//  VCAMLicenseManager.m
//  VCAM iOS RootHide Dopamine
//
//  Hệ thống quản lý bản quyền, chống bẻ khóa & Heartbeat 60s
//

#import "VCAMLicenseManager.h"
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <sys/sysctl.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <sys/stat.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

NSString *const kVCAMLicenseStatusChangedNotification = @"kVCAMLicenseStatusChangedNotification";
NSString *const kVCAMLicenseRevokedNotification       = @"kVCAMLicenseRevokedNotification";

static const char *kVCamSharedLicensePath = "/var/mobile/Library/Preferences/com.vcamios.license.plist";
static const char *kVCamSharedHwidPath    = "/var/mobile/Library/Preferences/.vcam_device_id";
static const char *kVCamEnabledFlagPath   = "/var/tmp/vcam_enabled";
static const char *kVCamPauseFlagPath     = "/var/tmp/vcam_paused";

// Khóa muối bảo mật khớp với Cloudflare Worker SECRET_SALT
static NSString *const kSecretSalt = @"ZdgM7kzHWw8RV58TFQT7Hc7JZeG6fbEn8bHtdDg2";

// Đường dẫn máy chủ Cloudflare Worker bản quyền
static NSString *VCAMGetServerBaseURL(void) {
    static NSString *cachedUrl = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cachedUrl = [NSString stringWithFormat:@"%@://%@.%@.%@", @"https", @"vios", @"hothangtech", @"workers.dev"];
    });
    return cachedUrl;
}

#pragma mark - CHỐNG BẮT REQUEST (ANTI-SNIFF / ANTI-PROXY / SSL PINNING)

@interface VCAMSecuritySessionDelegate : NSObject <NSURLSessionDelegate>
@end

@implementation VCAMSecuritySessionDelegate

- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable credential))completionHandler {

    if (![challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }

    SecTrustRef serverTrust = challenge.protectionSpace.serverTrust;
    if (!serverTrust) {
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    // Kiểm tra chứng chỉ hệ thống bằng SecTrustEvaluateWithError
    CFErrorRef error = NULL;
    bool eval = SecTrustEvaluateWithError(serverTrust, &error);
    if (!eval) {
        NSLog(@"[VCAMSecurity] Chứng chỉ SSL không hợp lệ hoặc đang bị chặn!");
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
        return;
    }

    // QUÉT VÀ CHẶN TRIỆT ĐỂ MỌI CHỨNG CHỈ BẮT GÓI TIN (Charles, Burp, HTTP Catcher, Thor, Proxyman, Mitmproxy...)
    CFArrayRef certsArray = SecTrustCopyCertificateChain(serverTrust);
    if (certsArray) {
        NSArray *certs = (__bridge_transfer NSArray *)certsArray;
        for (id certObj in certs) {
            SecCertificateRef cert = (__bridge SecCertificateRef)certObj;
            CFStringRef summary = SecCertificateCopySubjectSummary(cert);
            NSString *certName = (__bridge_transfer NSString *)summary;
            if (certName) {
                NSString *lower = certName.lowercaseString;
                if ([lower containsString:@"charles"] ||
                    [lower containsString:@"burp"] ||
                    [lower containsString:@"portswigger"] ||
                    [lower containsString:@"fiddler"] ||
                    [lower containsString:@"mitmproxy"] ||
                    [lower containsString:@"http catcher"] ||
                    [lower containsString:@"thor"] ||
                    [lower containsString:@"stream"] ||
                    [lower containsString:@"proxyman"] ||
                    [lower containsString:@"shadowrocket"]) {
                    NSLog(@"[VCAMSecurity] CẢNH BÁO BẮT GÓI TIN: Chứng chỉ giả mạo %@! Lập tức hủy request.", certName);
                    completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
                    return;
                }
            }
        }
    }

    completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:serverTrust]);
}

@end

static NSURLSession *VCAMGetSecureSession(void) {
    static NSURLSession *secureSession = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        // BỎ QUA HOÀN TOÀN PROXY: Không gửi request qua Charles Proxy, Fiddler, Burp trên Wi-Fi
        config.connectionProxyDictionary = @{};
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
        config.URLCache = nil;
        config.timeoutIntervalForRequest = 10.0;
        config.timeoutIntervalForResource = 10.0;
        
        VCAMSecuritySessionDelegate *delegate = [VCAMSecuritySessionDelegate new];
        secureSession = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:nil];
    });
    return secureSession;
}

static UIWindow *VCAMGetTopWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *winScene = (UIWindowScene *)scene;
                for (UIWindow *w in winScene.windows) {
                    if (w.isKeyWindow) return w;
                }
            }
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

@interface VCAMLicenseManager () {
    dispatch_source_t _heartbeatTimer;
    uint64_t _monotonicAnchorTime;
    NSTimeInterval _serverAnchorTime;
    NSTimeInterval _lastObservedTime;
    BOOL _isLicenseValid;
    NSString *_currentKey;
    NSString *_hwid;
    NSString *_signature;
    NSTimeInterval _expiresAt;
    BOOL _isChecking;
}
@property (nonatomic, assign) BOOL isLicenseValid;
@property (nonatomic, copy, nullable) NSString *currentKey;
@property (nonatomic, copy) NSString *hwid;
@property (nonatomic, copy, nullable) NSString *signature;
@property (nonatomic, assign) NSTimeInterval expiresAt;
@property (nonatomic, assign) BOOL isChecking;
@end

@implementation VCAMLicenseManager

@synthesize isLicenseValid = _isLicenseValid;
@synthesize currentKey = _currentKey;
@synthesize hwid = _hwid;
@synthesize signature = _signature;
@synthesize expiresAt = _expiresAt;
@synthesize isChecking = _isChecking;

+ (instancetype)sharedManager {
    static VCAMLicenseManager *mgr = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mgr = [[VCAMLicenseManager alloc] init];
    });
    return mgr;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _hwid = [self loadOrCreateHWID];
        _monotonicAnchorTime = mach_continuous_time();
        _serverAnchorTime = [[NSDate date] timeIntervalSince1970];
        _lastObservedTime = _serverAnchorTime;
        [self loadSavedLicense];
        [self validateLocalSignatureOffline];
    }
    return self;
}

#pragma mark - 1. HWID Bất Biến Phần Cứng (Chống gỡ app cài lại)

- (NSString *)loadOrCreateHWID {
    // 1. Kiểm tra file HWID dùng chung của Jailbreak
    NSString *path = [NSString stringWithUTF8String:kVCamSharedHwidPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSString *savedHWID = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        savedHWID = [savedHWID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (savedHWID.length >= 16) {
            return savedHWID;
        }
    }

    // 2. Kiểm tra Dopamine Rootless prefix nếu có (/var/jb)
    NSString *rootlessPath = [@"/var/jb" stringByAppendingPathComponent:path];
    if ([[NSFileManager defaultManager] fileExistsAtPath:rootlessPath]) {
        NSString *savedHWID = [NSString stringWithContentsOfFile:rootlessPath encoding:NSUTF8StringEncoding error:nil];
        savedHWID = [savedHWID stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (savedHWID.length >= 16) {
            return savedHWID;
        }
    }

    // 3. Nếu chưa có -> Tính toán mã định danh phần cứng duy nhất
    size_t size;
    sysctlbyname("hw.model", NULL, &size, NULL, 0);
    char *model = malloc(size);
    sysctlbyname("hw.model", model, &size, NULL, 0);
    NSString *hwModel = model ? [NSString stringWithUTF8String:model] : @"iPhone";
    free(model);

    // Tạo UUID ngẫu nhiên kết hợp model
    NSString *rawSeed = [NSString stringWithFormat:@"%@-%@-%lu", hwModel, [[NSUUID UUID] UUIDString], (unsigned long)arc4random()];
    
    // Băm SHA256 để có chuỗi HWID 64 ký tự chuẩn
    const char *s = [rawSeed UTF8String];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(s, (CC_LONG)strlen(s), digest);
    NSMutableString *hwidStr = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hwidStr appendFormat:@"%02x", digest[i]];
    }

    // Lưu vào cả 2 đường dẫn với quyền 0644
    [hwidStr writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod(kVCamSharedHwidPath, 0666);

    [hwidStr writeToFile:rootlessPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    chmod([rootlessPath UTF8String], 0666);

    return hwidStr;
}

#pragma mark - 2. Quản Lý File License Lưu Trữ

- (void)loadSavedLicense {
    NSString *path = [NSString stringWithUTF8String:kVCamSharedLicensePath];
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (!dict) {
        NSString *rootlessPath = [@"/var/jb" stringByAppendingPathComponent:path];
        dict = [NSDictionary dictionaryWithContentsOfFile:rootlessPath];
    }

    if (dict) {
        _currentKey  = [dict[@"key"] copy];
        _signature   = [dict[@"signature"] copy];
        _expiresAt   = [dict[@"expires_at"] doubleValue];
    }
}

- (void)saveLicenseWithKey:(NSString *)key expiresAt:(NSTimeInterval)expires signature:(NSString *)sig {
    _currentKey = [key copy];
    _expiresAt  = expires;
    _signature  = [sig copy];

    NSDictionary *dict = @{
        @"key": key ?: @"",
        @"hwid": self.hwid ?: @"",
        @"expires_at": @(expires),
        @"signature": sig ?: @"",
        @"saved_at": @([[NSDate date] timeIntervalSince1970])
    };

    NSString *path = [NSString stringWithUTF8String:kVCamSharedLicensePath];
    [dict writeToFile:path atomically:YES];
    chmod(kVCamSharedHwidPath, 0666);

    NSString *rootlessPath = [@"/var/jb" stringByAppendingPathComponent:path];
    [dict writeToFile:rootlessPath atomically:YES];
    chmod([rootlessPath UTF8String], 0666);
}

- (void)clearSavedLicense {
    _currentKey = nil;
    _signature = nil;
    _expiresAt = 0;
    self.isLicenseValid = NO;

    unlink(kVCamSharedLicensePath);
    unlink([[@"/var/jb" stringByAppendingPathComponent:[NSString stringWithUTF8String:kVCamSharedLicensePath]] UTF8String]);
}

#pragma mark - 3. Ký Số HMAC-SHA256 & Chống Lùi Giờ (Anti-Time-Tamper)

- (BOOL)validateLocalSignatureOffline {
    if (!self.currentKey || self.currentKey.length == 0 || !self.signature || self.signature.length == 0) {
        self.isLicenseValid = NO;
        return NO;
    }

    // Kiểm tra chữ ký số toán học
    NSString *payload = [NSString stringWithFormat:@"%@|%@|%.0f", self.currentKey, self.hwid, self.expiresAt];
    const char *cKey  = [kSecretSalt cStringUsingEncoding:NSUTF8StringEncoding];
    const char *cData = [payload cStringUsingEncoding:NSUTF8StringEncoding];

    unsigned char cHMAC[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), cHMAC);

    NSMutableString *expectedSig = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [expectedSig appendFormat:@"%02x", cHMAC[i]];
    }

    if (![expectedSig isEqualToString:self.signature]) {
        NSLog(@"[VCAMLicense] Chữ ký số không khớp! Có dấu hiệu can thiệp.");
        self.isLicenseValid = NO;
        return NO;
    }

    // Chống lùi giờ: Đo thời gian thực bằng Monotonic Uptime kết hợp giờ Server
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    uint64_t nowTicks = mach_continuous_time();
    uint64_t elapsedNanos = (nowTicks - _monotonicAnchorTime) * info.numer / info.denom;
    NSTimeInterval elapsedSecs = (double)elapsedNanos / 1e9;

    NSTimeInterval currentRealTime = _serverAnchorTime + elapsedSecs;

    // Bẫy chỉnh lùi giờ hệ thống
    NSTimeInterval systemNow = [[NSDate date] timeIntervalSince1970];
    if (systemNow < _lastObservedTime - 300.0) {
        NSLog(@"[VCAMLicense] Phát hiện người dùng chỉnh lùi đồng hồ hệ thống!");
        // Bắt buộc kiểm tra online, tạm thời khóa
        self.isLicenseValid = NO;
        return NO;
    }
    _lastObservedTime = systemNow;

    // Kiểm tra hạn sử dụng
    if (self.expiresAt > 0 && currentRealTime > (self.expiresAt / 1000.0)) {
        NSLog(@"[VCAMLicense] Bản quyền đã hết hạn sử dụng.");
        self.isLicenseValid = NO;
        return NO;
    }

    self.isLicenseValid = YES;
    return YES;
}

#pragma mark - 4. Heartbeat 60 Giây (Kiểm Tra Ngầm Định Kỳ)

- (void)startHeartbeat {
    if (_heartbeatTimer) return;

    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    
    // Cài đặt chu kỳ đúng 60 giây
    dispatch_source_set_timer(_heartbeatTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), // Lần đầu sau 5s
                              60 * NSEC_PER_SEC,                                  // Lặp lại mỗi 60s
                              1 * NSEC_PER_SEC);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_heartbeatTimer, ^{
        [weakSelf verifyLicenseOnlineWithCompletion:nil];
    });

    dispatch_resume(_heartbeatTimer);
    NSLog(@"[VCAMLicense] Đã khởi động Heartbeat 60 giây!");
}

- (void)stopHeartbeat {
    if (_heartbeatTimer) {
        dispatch_source_cancel(_heartbeatTimer);
        _heartbeatTimer = nil;
    }
}

#pragma mark - 5. Gọi API Cloudflare (Kích Hoạt & Xác Thực)

- (void)activateWithKey:(NSString *)key completion:(void(^)(BOOL success, NSString *message))completion {
    key = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].uppercaseString;
    if (key.length == 0) {
        if (completion) completion(NO, @"Vui lòng nhập mã key!");
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/api/activate", VCAMGetServerBaseURL()];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10.0;

    NSDictionary *body = @{
        @"key": key,
        @"hwid": self.hwid ?: @"",
        @"device_name": [UIDevice currentDevice].name ?: @"iPhone"
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    req.HTTPBody = bodyData;

    // Ký số Request chống làm giả và Replay Attack
    NSTimeInterval nowTs = [[NSDate date] timeIntervalSince1970];
    NSString *tsStr = [NSString stringWithFormat:@"%.0f", nowTs];
    NSString *signRaw = [NSString stringWithFormat:@"%@|%@", [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding], tsStr];
    const char *cKey  = [kSecretSalt cStringUsingEncoding:NSUTF8StringEncoding];
    const char *cData = [signRaw cStringUsingEncoding:NSUTF8StringEncoding];
    unsigned char cHMAC[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), cHMAC);
    NSMutableString *reqSig = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [reqSig appendFormat:@"%02x", cHMAC[i]];
    }
    [req setValue:tsStr forHTTPHeaderField:@"X-VCAM-Timestamp"];
    [req setValue:reqSig forHTTPHeaderField:@"X-VCAM-Signature"];

    self.isChecking = YES;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [VCAMGetSecureSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.isChecking = NO;
            if (err) {
                if (completion) completion(NO, [NSString stringWithFormat:@"Lỗi kết nối máy chủ: %@", err.localizedDescription]);
                return;
            }

            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSHTTPURLResponse *httpRes = (NSHTTPURLResponse *)res;

            if (httpRes.statusCode == 200 && [json[@"success"] boolValue]) {
                NSTimeInterval expires = [json[@"expires_at"] doubleValue];
                NSString *sig = json[@"signature"];
                
                [strongSelf saveLicenseWithKey:key expiresAt:expires signature:sig];
                strongSelf.isLicenseValid = YES;
                
                // Cập nhật mốc giờ chuẩn từ Cloudflare
                strongSelf->_serverAnchorTime = [[NSDate date] timeIntervalSince1970];
                strongSelf->_monotonicAnchorTime = mach_continuous_time();

                [[NSNotificationCenter defaultCenter] postNotificationName:kVCAMLicenseStatusChangedNotification object:nil];
                if (completion) completion(YES, json[@"message"] ?: @"Kích hoạt thành công!");
            } else {
                NSString *errMsg = json[@"error"] ?: @"Mã key không hợp lệ hoặc đã hết hạn!";
                if (completion) completion(NO, errMsg);
            }
        });
    }];
    [task resume];
}

- (void)verifyLicenseOnlineWithCompletion:(nullable void(^)(BOOL valid, NSString *message))completion {
    if (!self.currentKey || self.currentKey.length == 0 || !self.signature) {
        self.isLicenseValid = NO;
        if (completion) completion(NO, @"Chưa kích hoạt key");
        return;
    }

    NSString *urlStr = [NSString stringWithFormat:@"%@/api/verify", VCAMGetServerBaseURL()];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 8.0;

    NSDictionary *body = @{
        @"key": self.currentKey,
        @"hwid": self.hwid ?: @"",
        @"expires_at": @(self.expiresAt),
        @"signature": self.signature ?: @""
    };
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    req.HTTPBody = bodyData;

    // Ký số Request chống làm giả và Replay Attack
    NSTimeInterval nowTs = [[NSDate date] timeIntervalSince1970];
    NSString *tsStr = [NSString stringWithFormat:@"%.0f", nowTs];
    NSString *signRaw = [NSString stringWithFormat:@"%@|%@", [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding], tsStr];
    const char *cKey  = [kSecretSalt cStringUsingEncoding:NSUTF8StringEncoding];
    const char *cData = [signRaw cStringUsingEncoding:NSUTF8StringEncoding];
    unsigned char cHMAC[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, cKey, strlen(cKey), cData, strlen(cData), cHMAC);
    NSMutableString *reqSig = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [reqSig appendFormat:@"%02x", cHMAC[i]];
    }
    [req setValue:tsStr forHTTPHeaderField:@"X-VCAM-Timestamp"];
    [req setValue:reqSig forHTTPHeaderField:@"X-VCAM-Signature"];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [VCAMGetSecureSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err) {
            // Nếu mất mạng tạm thời, vẫn kiểm tra hợp lệ bằng chữ ký số offline
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL localValid = [weakSelf validateLocalSignatureOffline];
                if (completion) completion(localValid, @"Đang chạy chế độ offline");
            });
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSHTTPURLResponse *httpRes = (NSHTTPURLResponse *)res;

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (httpRes.statusCode == 200 && [json[@"valid"] boolValue]) {
                strongSelf.isLicenseValid = YES;
                strongSelf->_serverAnchorTime = [[NSDate date] timeIntervalSince1970];
                strongSelf->_monotonicAnchorTime = mach_continuous_time();
                if (completion) completion(YES, @"Bản quyền hợp lệ");
            } else {
                // SERVER ĐÃ KHÓA / XÓA HOẶC GỠ THIẾT BỊ NÀY -> CHẶN NGAY LẬP TỨC!
                NSLog(@"[VCAMLicense] SERVER ĐÃ KHÓA/HỦY KEY: %@", json[@"error"]);
                strongSelf.isLicenseValid = NO;
                
                // Tắt ngay cờ replace camera
                unlink(kVCamEnabledFlagPath);
                unlink(kVCamPauseFlagPath);

                // Phát thông báo ngắt video ảo
                [[NSNotificationCenter defaultCenter] postNotificationName:kVCAMLicenseRevokedNotification object:json[@"error"]];
                [[NSNotificationCenter defaultCenter] postNotificationName:kVCAMLicenseStatusChangedNotification object:nil];

                // Hiển thị cảnh báo đỏ trên màn hình
                NSString *reason = json[@"error"] ?: @"Mã bản quyền của bạn đã bị KHÓA hoặc THU HỒI bởi Quản trị viên!";
                [strongSelf showBannedAlert:reason];

                if (completion) completion(NO, reason);
            }
        });
    }];
    [task resume];
}

#pragma mark - 6. Giao Diện Thông Báo & Hộp Thoại Nhập Key

- (void)showBannedAlert:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = VCAMGetTopWindow();
        UIViewController *rootVC = window.rootViewController;
        while (rootVC.presentedViewController) {
            rootVC = rootVC.presentedViewController;
        }
        if (!rootVC) return;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"⛔ BẢN QUYỀN BỊ KHÓA"
                                                                       message:reason
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Đã hiểu" style:UIAlertActionStyleDestructive handler:nil]];
        [rootVC presentViewController:alert animated:YES completion:nil];
    });
}

- (NSString *)remainingTimeString {
    if (!self.isLicenseValid) return @"Chưa kích hoạt";
    if (self.expiresAt == 0) return @"Vĩnh viễn (Lifetime)";

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval diff = (self.expiresAt / 1000.0) - now;
    if (diff <= 0) return @"Đã hết hạn";

    int days = (int)ceil(diff / 86400.0);
    return [NSString stringWithFormat:@"Còn %d ngày", days];
}

- (void)promptActivationDialogWithReason:(nullable NSString *)reason presenter:(nullable UIViewController *)presenter {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *targetVC = presenter;
        if (!targetVC) {
            UIWindow *window = VCAMGetTopWindow();
            targetVC = window.rootViewController;
            while (targetVC.presentedViewController) {
                targetVC = targetVC.presentedViewController;
            }
        }
        if (!targetVC) return;

        NSString *title = @"🔐 Kích Hoạt VCAM iOS";
        NSString *msg = reason ?: [NSString stringWithFormat:@"Mã máy (HWID):\n%@\n\nVui lòng nhập mã key để tiếp tục sử dụng:", [self.hwid substringToIndex:MIN(16, self.hwid.length)]];

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];

        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
            textField.placeholder = @"VCAM-XXXX-XXXX-XXXX";
            textField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
            textField.autocorrectionType = UITextAutocorrectionTypeNo;
            textField.text = self.currentKey ?: @"";
        }];

        // Nút Dán từ clipboard
        [alert addAction:[UIAlertAction actionWithTitle:@"📋 Dán mã" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *pasteStr = [UIPasteboard generalPasteboard].string;
            if (pasteStr.length > 0) {
                [self promptActivationDialogWithKeyPrefilled:pasteStr presenter:targetVC];
            }
        }]];

        // Nút Kích hoạt
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"⚡ Kích Hoạt" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            UITextField *tf = alert.textFields.firstObject;
            NSString *key = tf.text;
            [weakSelf activateWithKey:key completion:^(BOOL success, NSString *message) {
                UIAlertController *resultAlert = [UIAlertController alertControllerWithTitle:success ? @"🎉 Thành Công" : @"❌ Thất Bại"
                                                                                     message:message
                                                                              preferredStyle:UIAlertControllerStyleAlert];
                [resultAlert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
                [targetVC presentViewController:resultAlert animated:YES completion:nil];
            }];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];

        [targetVC presentViewController:alert animated:YES completion:nil];
    });
}

- (void)promptActivationDialogWithKeyPrefilled:(NSString *)prefilledKey presenter:(UIViewController *)presenter {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🔐 Kích Hoạt VCAM iOS"
                                                                   message:@"Mã đã được dán từ bộ nhớ tạm:"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.text = prefilledKey;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"⚡ Kích Hoạt Ngay" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UITextField *tf = alert.textFields.firstObject;
        [weakSelf activateWithKey:tf.text completion:^(BOOL success, NSString *message) {
            UIAlertController *res = [UIAlertController alertControllerWithTitle:success ? @"🎉 Thành Công" : @"❌ Thất Bại"
                                                                         message:message
                                                                  preferredStyle:UIAlertControllerStyleAlert];
            [res addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
            [presenter presentViewController:res animated:YES completion:nil];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end

