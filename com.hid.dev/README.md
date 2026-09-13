# HideDeveloperMode (`com.hid.dev`)

Tweak iOS 16 chuyên dụng ẩn và giả lập **Chế độ nhà phát triển (Developer Mode = OFF)** cho các ứng dụng ngân hàng và tài chính (ACB ONE, Techcombank, VNeID, v.v.).

## 🚀 Tính Năng
1. **Hook AMFI APIs (`libamfi` & `libSystem`)**:
   - `amfi_get_developer_mode_status` -> return `0`
   - `amfi_developer_mode_status` -> return `0`
   - `amfi_developer_mode_enabled` -> return `0`
2. **Hook CFPreferences & NSUserDefaults**:
   - Chặn các truy vấn đọc key `com.apple.security.developer-mode`, `DeveloperModeStatus`, `developer-mode-status`.
3. **Hook NSFileManager**:
   - Chặn các hàm kiểm tra sự tồn tại của file cấu hình Developer Mode (`com.apple.security.developer-mode.plist`).
4. **An toàn tuyệt đối**:
   - Tự động bỏ qua `SpringBoard`, `backboardd`, `mediaserverd` để không ảnh hưởng đến jailbreak và tweak camera.

## 📱 Cài Đặt
Cài đặt file `.deb` qua **Sileo** hoặc **Filza**, sau đó Respring lại thiết bị.
Mở app ngân hàng (ACB ONE) và đăng nhập bình thường!
