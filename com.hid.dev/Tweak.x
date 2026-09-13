//
//  Tweak.x - com.hid.dev (HideDeveloperMode)
//  Tương thích iOS 16.0 - 16.7.x (RootHide Dopamine / Rootless)
//  Đánh lừa các app ngân hàng (ACB, Techcombank, VNeID...) rằng Developer Mode đã TẮT (0)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>
#import <CoreFoundation/CoreFoundation.h>

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ============================================================================
// 1. C Hooks: AMFI (Apple Mobile File Integrity) Developer Mode APIs
// ============================================================================

// int amfi_get_developer_mode_status(void);
static int (*orig_amfi_get_developer_mode_status)(void) = NULL;
static int fake_amfi_get_developer_mode_status(void) {
    return 0; // Luôn trả về 0 (Chế độ nhà phát triển: ĐÃ TẮT)
}

// int amfi_developer_mode_status(void);
static int (*orig_amfi_developer_mode_status)(void) = NULL;
static int fake_amfi_developer_mode_status(void) {
    return 0;
}

// int amfi_developer_mode_enabled(void);
static int (*orig_amfi_developer_mode_enabled)(void) = NULL;
static int fake_amfi_developer_mode_enabled(void) {
    return 0;
}

// ============================================================================
// 2. C Hooks: CoreFoundation Preferences (CFPreferences)
// ============================================================================

static CFPropertyListRef (*orig_CFPreferencesCopyAppValue)(CFStringRef key, CFStringRef applicationID) = NULL;
static CFPropertyListRef fake_CFPreferencesCopyAppValue(CFStringRef key, CFStringRef applicationID) {
    if (applicationID && CFStringCompare(applicationID, CFSTR("com.apple.security.developer-mode"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
        return (CFPropertyListRef)kCFBooleanFalse;
    }
    if (key && (CFStringCompare(key, CFSTR("DeveloperModeStatus"), kCFCompareCaseInsensitive) == kCFCompareEqualTo ||
                CFStringCompare(key, CFSTR("developer-mode-status"), kCFCompareCaseInsensitive) == kCFCompareEqualTo)) {
        return (CFPropertyListRef)kCFBooleanFalse;
    }
    return orig_CFPreferencesCopyAppValue ? orig_CFPreferencesCopyAppValue(key, applicationID) : NULL;
}

static Boolean (*orig_CFPreferencesGetAppBooleanValue)(CFStringRef key, CFStringRef applicationID, Boolean *keyExistsAndHasValidFormat) = NULL;
static Boolean fake_CFPreferencesGetAppBooleanValue(CFStringRef key, CFStringRef applicationID, Boolean *keyExistsAndHasValidFormat) {
    if (applicationID && CFStringCompare(applicationID, CFSTR("com.apple.security.developer-mode"), kCFCompareCaseInsensitive) == kCFCompareEqualTo) {
        if (keyExistsAndHasValidFormat) *keyExistsAndHasValidFormat = true;
        return false;
    }
    if (key && (CFStringCompare(key, CFSTR("DeveloperModeStatus"), kCFCompareCaseInsensitive) == kCFCompareEqualTo ||
                CFStringCompare(key, CFSTR("developer-mode-status"), kCFCompareCaseInsensitive) == kCFCompareEqualTo)) {
        if (keyExistsAndHasValidFormat) *keyExistsAndHasValidFormat = true;
        return false;
    }
    return orig_CFPreferencesGetAppBooleanValue ? orig_CFPreferencesGetAppBooleanValue(key, applicationID, keyExistsAndHasValidFormat) : false;
}

// ============================================================================
// 3. Objective-C Hooks: NSFileManager (Chống quét file plist developer-mode)
// ============================================================================

%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (path && [path containsString:@"com.apple.security.developer-mode"]) {
        return NO;
    }
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (path && [path containsString:@"com.apple.security.developer-mode"]) {
        if (isDirectory) *isDirectory = NO;
        return NO;
    }
    return %orig;
}

%end

// ============================================================================
// 4. Objective-C Hooks: NSUserDefaults (Chống đọc qua NSUserDefaults)
// ============================================================================

%hook NSUserDefaults

- (id)objectForKey:(NSString *)defaultName {
    if (defaultName && ([defaultName localizedCaseInsensitiveContainsString:@"developer-mode"] ||
                        [defaultName localizedCaseInsensitiveContainsString:@"DeveloperModeStatus"])) {
        return @(NO);
    }
    return %orig;
}

- (BOOL)boolForKey:(NSString *)defaultName {
    if (defaultName && ([defaultName localizedCaseInsensitiveContainsString:@"developer-mode"] ||
                        [defaultName localizedCaseInsensitiveContainsString:@"DeveloperModeStatus"])) {
        return NO;
    }
    return %orig;
}

%end

// ============================================================================
// 5. Constructor khởi tạo an toàn
// ============================================================================

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        // Bỏ qua các tiến trình cốt lõi của iOS để không ảnh hưởng hệ thống
        if (!bundleID || 
            [bundleID hasPrefix:@"com.apple.springboard"] ||
            [bundleID hasPrefix:@"com.apple.backboardd"] ||
            [bundleID hasPrefix:@"com.apple.mediaserverd"]) {
            return;
        }

        // 1. Hook AMFI APIs trong libSystem & libamfi
        void *libamfi = dlopen("/usr/lib/libamfi.dylib", RTLD_NOW | RTLD_GLOBAL);
        if (!libamfi) {
            libamfi = dlopen("/System/Library/PrivateFrameworks/AppleMobileFileIntegrity.framework/AppleMobileFileIntegrity", RTLD_NOW | RTLD_GLOBAL);
        }

        void *sym1 = dlsym(RTLD_DEFAULT, "amfi_get_developer_mode_status");
        if (!sym1 && libamfi) sym1 = dlsym(libamfi, "amfi_get_developer_mode_status");
        if (sym1) {
            MSHookFunction(sym1, (void *)&fake_amfi_get_developer_mode_status, (void **)&orig_amfi_get_developer_mode_status);
        }

        void *sym2 = dlsym(RTLD_DEFAULT, "amfi_developer_mode_status");
        if (!sym2 && libamfi) sym2 = dlsym(libamfi, "amfi_developer_mode_status");
        if (sym2) {
            MSHookFunction(sym2, (void *)&fake_amfi_developer_mode_status, (void **)&orig_amfi_developer_mode_status);
        }

        void *sym3 = dlsym(RTLD_DEFAULT, "amfi_developer_mode_enabled");
        if (!sym3 && libamfi) sym3 = dlsym(libamfi, "amfi_developer_mode_enabled");
        if (sym3) {
            MSHookFunction(sym3, (void *)&fake_amfi_developer_mode_enabled, (void **)&orig_amfi_developer_mode_enabled);
        }

        // 2. Hook CFPreferences
        void *symPref = dlsym(RTLD_DEFAULT, "CFPreferencesCopyAppValue");
        if (symPref) {
            MSHookFunction(symPref, (void *)&fake_CFPreferencesCopyAppValue, (void **)&orig_CFPreferencesCopyAppValue);
        }

        void *symPrefBool = dlsym(RTLD_DEFAULT, "CFPreferencesGetAppBooleanValue");
        if (symPrefBool) {
            MSHookFunction(symPrefBool, (void *)&fake_CFPreferencesGetAppBooleanValue, (void **)&orig_CFPreferencesGetAppBooleanValue);
        }
    }
}
