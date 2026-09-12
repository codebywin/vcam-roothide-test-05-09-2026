//
//  VCAMObfuscation.h
//  VCAM iOS Build-Time Symbol Obfuscation Header
//
//  File này tự động map tất cả tên Class, Method và Symbol sang mã băm ngẫu nhiên
//  khi biên dịch. Mã nguồn gốc của bạn vẫn giữ nguyên 100% sạch đẹp!
//

#ifndef VCAM_OBFUSCATION_H
#define VCAM_OBFUSCATION_H

// 1. Mã hóa tên các Class
#define VCAMLicenseManager              _0x8f192b
#define VCAMSecuritySessionDelegate     _0x4c291a
#define VCamFloatWindow                 _0x9183ca
#define VCamFloat                       _0x33b1e7
#define VCamPickerDelegate              _0x77d20f
#define VCAMPhotoManager                _0x11e47a

// 2. Mã hóa các hàm kiểm tra bản quyền & kích hoạt
#define isLicenseValid                  _0xa8f102
#define currentKey                      _0x2b4e91
#define hwid                            _0x11c7e9
#define expiresAt                       _0x5b31f8
#define _isLicenseValid                 _0x_iv_lic
#define _currentKey                     _0x_iv_ckey
#define _hwid                           _0x_iv_hwid
#define _signature                      _0x_iv_sig
#define _expiresAt                      _0x_iv_exp
#define _isChecking                     _0x_iv_chk
#define startHeartbeat                  _0x99a12c
#define stopHeartbeat                   _0x82f41c
#define activateWithKey                 _0x17a02c
#define verifyLicenseOnlineWithCompletion _0x4e3182
#define validateLocalSignatureOffline   _0x66c891
#define remainingTimeString             _0x33e8b1
#define promptActivationDialogWithReason _0x55d01e
#define promptActivationDialogWithKeyPrefilled _0x77b420
#define showBannedAlert                 _0x99c431
#define loadOrCreateHWID                _0x12d90e
#define loadSavedLicense                _0x34a182
#define saveLicenseWithKey              _0x78b201
#define clearSavedLicense               _0x56a912

// 3. Mã hóa các action trên menu Dock
#define _menuShowLicense                _0x22d810
#define _menuSelectVideo                _0x44f192
#define _menuSelectPhoto                _0x55a82e
#define _menuTogglePause                _0x88c12a
#define _menuDisable                    _0x99e341

// 4. Mã hóa các hàm chọn & xử lý ảnh
#define presentPhotoPickerFromViewController _0x77c92b
#define processImage                    _0x33d19f

// 4. Mã hóa các biến tĩnh và hàm C nội bộ
#define VCAMGetServerBaseURL            _0x_gsb_2026
#define VCAMGetSecureSession            _0x_gss_2026
#define VCAMGetTopWindow                _0x_gtw_2026

// 5. Mã hóa Security Guard & Anti-Bypass
#define VCAMSecurityGuard               _0x3e179a
#define VCAMVerifyProcessAuthorization  _0x9b20e1
#define VCAMCheckBinaryIntegrity        _0x5c41f7
#define VCAMGetDecryptedSecretSalt      _0x7a30b4
#define VCAMGetSharedDeviceHWID         _0x1e88f2
#define issueAuthorizationTokenWithKey  _0x66f120
#define revokeAuthorizationToken        _0x88c401
#define isTokenValid                    _0x22b79c

#endif /* VCAM_OBFUSCATION_H */

