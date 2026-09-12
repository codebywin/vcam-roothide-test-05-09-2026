# VCAM iOS (RootHide / Dopamine)

> **Virtual Camera & KYC Flash Liveness Tweak for iOS**  
> Tweak camera ảo hiệu năng cao, can thiệp khung hình tầng hệ thống `mediaserverd`, hỗ trợ điều hướng thời gian thực và mô phỏng phản xạ ánh sáng chớp màu cho bài kiểm tra eKYC.

---

## 🌟 Tính Năng Nổi Bật

### 1. Can thiệp Camera tầng hệ thống (`mediaserverd`)
- Can thiệp trực tiếp vào tiến trình điều phối camera lõi của iOS (`BWNodeOutput emitSampleBuffer:`).
- Hoạt động trên mọi ứng dụng (Camera mặc định, Safari, Messenger, Zalo, Telegram, các ứng dụng Ngân hàng, eKYC, VNeID...).
- Không cần inject dylib vào ứng dụng bên thứ 3 $\rightarrow$ **Miễn nhiễm 100% với cơ chế phát hiện Jailbreak của App**.

### 2. Pipeline xử lý đồ họa GPU Metal 60 FPS
- Khởi tạo `CIContext` chạy trực tiếp trên chip đồ họa GPU Metal của iPhone.
- Tự động chuẩn hóa tỷ lệ khung hình (`baseScaleX`, `baseScaleY`).
- Độ trễ kết xuất cực thấp ($< 1.5\text{ ms}$), không giật lag, không nóng máy.

### 3. Điều hướng & Tùy biến khung hình thời gian thực (`VCAMTransformManager`)
- **Cụm Zoom đa tầng**: Thanh trượt Zoom + 2 phím `[-]` / `[+]` hỗ trợ co nhỏ từ **0.4x** (tự động đệm viền đen chuẩn YUV) đến phóng to **2.5x**.
- **Cụm D-Pad 5 hướng**: Phím Lên, Xuống, Trái, Phải với bước nhảy tăng lên **40px** và phím Đặt lại (`●`) đưa về vị trí cân bằng 1.0x.
- **Lật gương ngang (`🪞`)**: Lật trục đối xứng video lập tức trên GPU Metal (0ms trễ), giải quyết triệt để vấn đề chữ / khuôn mặt bị đảo ngược trên Camera trước (Selfie/KYC), đồng thời tự động đồng bộ chiều điều hướng D-Pad.
- **Xoay video đa chiều**: Phím `🔄` hỗ trợ xoay vòng $0^\circ \rightarrow 90^\circ \rightarrow 180^\circ \rightarrow 270^\circ$.

### 4. Module KYC Active Flash Liveness (`VCAMFlashLivenessManager`)
- **Tự động bắt màu màn hình (`⚡`)**:
  - Quét mẫu màu sắc chủ đạo của màn hình app KYC theo chu kỳ an toàn 180ms ở tầng SpringBoard.
  - Tích hợp bộ lọc trễ cảm biến vật lý **EMA Low-Pass Filter (~60ms)**, mô phỏng phản ứng phơi sáng quang học của cảm biến camera thật.
- **Mặt nạ ánh sáng phản quang (Photometric Reflection)**:
  - Tạo vùng sáng `CIRadialGradient` tập trung ở tâm khuôn mặt và lan tỏa mềm ra các góc.
  - Hòa trộn lớp sáng chớp màu bằng bộ lọc `CISoftLightBlendMode` trên GPU Metal, giúp vượt qua các thuật toán đo phổ màu $\Delta R, \Delta G, \Delta B$ (FaceTec, Sumsub, VNPT, FPT...).
- **Chế độ kiểm thử trực quan (`🧪`)**:
  - Tự động luân chuyển chu kỳ màu (Trắng $\rightarrow$ Xanh $\rightarrow$ Đỏ $\rightarrow$ Lục $\rightarrow$ Vàng $\rightarrow$ Tím) để kiểm tra ngay trong Camera.

### 5. Giao diện điều khiển nổi (Floating HUD)
- Quả cầu nổi phong cách AssistiveTouch kéo thả tự do trên SpringBoard.
- Cụm D-Pad thiết kế đối xứng hoàn hảo 4 góc: `🔄` (Xoay 90°) - `🪞` (Lật gương) - `⚡` (KYC Flash) - `🧪` (Test chớp).
- Tự động đổi màu nền sang **ĐỎ CAM** khi video đang hoạt động (`Active Hook`).
- Tích hợp quản lý bản quyền HWID, gia hạn key và kiểm tra thời hạn sử dụng.

### 6. Module Bảo Vệ Đa Tầng Chống Bypass (`VCAMSecurityGuard`)
- **Khóa cứng tầng `mediaserverd`**: Thẩm định token chữ ký số HMAC-SHA256 trực tiếp trước khi cho phép chèn khung hình camera. Chống hoàn toàn hành vi tự tạo file kích hoạt lậu (`/var/tmp/vcam_enabled`) bằng Filza/SSH.
- **Chống Hook Objective-C**: Hàm C `VCAMVerifyProcessAuthorization()` gọi trực tiếp, không thông qua `objc_msgSend`, miễn nhiễm với các công cụ hook runtime (ElleKit, Frida, Cycript).
- **Mã hóa XOR chuỗi Secret Salt**: Khóa bí mật ký số được mã hóa XOR trong mã máy, chống trích xuất bằng lệnh `strings`.
- **Phát hiện can thiệp nhị phân (Anti-Patching)**: Tự động kiểm tra mã máy ARM64 trong RAM để phát hiện các mẫu patch như `MOV W0, #1` hay `RET`.

---

## 📁 Cấu Trúc Dự Án

```
├── Makefile                    # Kịch bản biên dịch Theos (Rootless / Roothide arm64e)
├── control                     # Thông tin gói Debian (.deb v1.1.8)
├── vcamios.plist               # Filter inject vào com.apple.mediaserverd & com.apple.springboard
├── Tweak.x                     # Core hook camera (mediaserverd) & Giao diện HUD (SpringBoard)
├── VCAMSecurityGuard.h         # Header module bảo vệ đa tầng & Chống bypass camera
├── VCAMSecurityGuard.m         # Xử lý token chữ ký số, XOR decrypt, Anti-Hook & Anti-Patch
├── VCAMTransformManager.h      # Header module biến đổi video, D-Pad & Lật gương ngang
├── VCAMTransformManager.m      # Xử lý ma trận biến đổi GPU Metal, cache 60fps & đồng bộ D-Pad
├── VCAMFlashLivenessManager.h  # Header module KYC Flash Liveness
├── VCAMFlashLivenessManager.m  # Xử lý quét màu màn hình & Render ánh sáng GPU Metal
├── VCAMLicenseManager.h        # Header quản lý bản quyền HWID
├── VCAMLicenseManager.m        # Xử lý kích hoạt, kiểm tra hạn dùng & lưu trữ Keychain
├── VCAMObfuscation.h           # File map băm symbol chống dịch ngược
└── README.md                   # Tài liệu hướng dẫn dự án
```

---

## ⚙️ Yêu Cầu Hệ Thống

- **Thiết bị hỗ trợ**: iPhone / iPad chạy chip A11 trở lên (đã kiểm thử hoàn hảo trên iPhone 8).
- **Hệ điều hành**: iOS 15.0 – iOS 16.7.x (hỗ trợ mở rộng iOS 17+).
- **Môi trường Jailbreak**: RootHide Dopamine, Dopamine, Palera1n (hỗ trợ ElleKit hoặc MobileSubstrate $\ge 0.9.5000$).

---

## 🛠️ Hướng Dẫn Biên Dịch & Cài Đặt

### 1. Biên dịch qua Theos
```bash
export THEOS_PACKAGE_SCHEME=rootless
make clean
make package FINALPACKAGE=1
```

### 2. Cài đặt lên thiết bị
Sao chép file `.deb` vào thiết bị và cài đặt qua Terminal / SSH:
```bash
dpkg -i com.la.winday_1.1.6_iphoneos-arm64e.deb
ln -sf /usr/lib/DynamicPatches/AutoPatches.dylib /Library/MobileSubstrate/DynamicLibraries/vcamios.dylib.roothidepatch
killall -9 SpringBoard mediaserverd Camera
```

---

## 📖 Hướng Dẫn Sử Dụng Nhanh

1. **Chọn video**:
   - Chạm vào nút tròn nổi trên màn hình $\rightarrow$ Chọn biểu tượng `🎬` $\rightarrow$ Chọn video chân dung trong thư viện ảnh.
2. **Căn chỉnh vị trí & Zoom**:
   - Dùng thanh trượt hoặc phím `[-]` / `[+]` để chỉnh độ to nhỏ.
   - Dùng 4 mũi tên `▲ ▼ ◀ ▶` để đưa khuôn mặt vào giữa khung hình.
   - Bấm nút `●` ở tâm nếu muốn đưa về mặc định (1.0x).
3. **Sử dụng KYC Flash Liveness**:
   - Nhấn nút **`⚡`** (bên trái nút `▼`) khi bước vào bài kiểm tra quét mặt chớp màu của ứng dụng ngân hàng / eKYC.
   - Nhấn nút **`🧪`** (bên phải nút `▼`) nếu muốn xem trước hiệu ứng tự đổi màu thử nghiệm trong Camera.

