# Hướng Dẫn Hệ Thống Quản Lý Bản Quyền VCAM iOS (Cloudflare Workers)

Endpoint: `https://vios.hothangtech.workers.dev/`  
Giao diện quản trị Web Admin: `https://vios.hothangtech.workers.dev/admin`

---

## 🌟 Các Tính Năng Đã Tích Hợp Đầy Đủ

1. **🔒 Khóa Key (Ban/Lock) & Mở Khóa (Unlock):**
   - 1-Click khóa key ngay trên Web: Ngay lập tức từ chối mọi yêu cầu kích hoạt và xác thực từ tweak trên iPhone (`code: KEY_BANNED`).
   - Mở khóa lại bất cứ lúc nào mà không làm mất thời hạn hay dữ liệu của khách.

2. **🗑️ Xóa Key Vĩnh Viễn:**
   - Xóa bỏ hoàn toàn mã key khỏi cơ sở dữ liệu Cloudflare KV.

3. **📱 Quản Lý Nhiều Thiết Bị Trên 1 Key (Multi-Device):**
   - Khi tạo key, bạn có thể chọn số lượng máy tối đa được dùng: **1, 2, 3, 5 hoặc 10 thiết bị** (hoặc tùy chỉnh).
   - Danh sách thiết bị (`devices`) lưu rõ HWID, tên máy (`iPhone...`), thời điểm kích hoạt và lần kết nối gần nhất.
   - **Gỡ từng máy lẻ:** Khách đổi 1 máy trong nhóm, admin chỉ cần bấm **⚙️ Máy** -> chọn đúng máy cũ bấm **Gỡ Máy**, các máy khác vẫn hoạt động bình thường!
   - **Gỡ toàn bộ máy:** 1-click đưa key về trạng thái trống thiết bị để cấp lại.

4. **🛡️ Chữ Ký Số Chống Dịch Ngược (Anti-Tamper HMAC-SHA256):**
   - Server ký số token bằng thuật toán mã hóa `HMAC-SHA256` kết hợp khóa muối bí mật (`SECRET_SALT`).
   - Hacker/User can thiệp vào máy iPhone (sửa file plist, chỉnh sửa ngày giờ hệ thống) đều sẽ bị từ chối vì chữ ký số không khớp.

---

## 🚀 Hướng Dẫn Triển Khai Lên Cloudflare Trong 1 Phút

### Bước 1: Dán code vào Worker
1. Truy cập [Cloudflare Dashboard](https://dash.cloudflare.com/) -> **Workers & Pages**.
2. Chọn worker **`vios`** (hoặc tạo worker mới tên `vios`).
3. Bấm **Edit Code** (hoặc Quick Edit).
4. Mở file [worker.js](file:///c:/Users/admin/Desktop/codebywin/vcam-roothide-test-05-09-2026/backend/worker.js), copy toàn bộ nội dung và dán đè vào khung soạn thảo của Cloudflare.
5. Bấm nút **Deploy** ở góc trên cùng bên phải.

### Bước 2: Tạo KV Storage (Lưu trữ dữ liệu vĩnh viễn)
1. Trong Cloudflare Dashboard, vào menu bên trái: **Workers & Pages** -> **KV**.
2. Bấm **Create a namespace** -> Đặt tên: `VCAM_LICENSES` -> Bấm **Add**.
3. Quay lại trang cài đặt Worker `vios`:
   - Vào tab **Settings** -> **Variables and Secrets**.
   - Cuộn xuống mục **KV Namespace Bindings** -> Bấm **Add binding**.
   - **Variable name**: Nhập chính xác `VCAM_LICENSES`
   - **KV namespace**: Chọn namespace `VCAM_LICENSES` vừa tạo.
   - Bấm **Save and deploy**.

### Bước 3: Cấu hình biến bí mật (Tùy chọn)
Trong mục **Settings** -> **Variables and Secrets** -> **Environment Variables**:
- `ADMIN_TOKEN`: Mật khẩu đăng nhập trang Web Admin (Mặc định nếu chưa đặt là `vcam_admin_secret_2026`).
- `SECRET_SALT`: Mã bí mật để ký token (Mặc định nếu chưa đặt là `vcam_super_secure_salt_key_05_09_2026`).

---

## 🖥️ Hướng Dẫn Sử Dụng Trang Web Admin

Truy cập: 👉 **`https://vios.hothangtech.workers.dev/admin`**

1. **Đăng nhập:** Nhập `ADMIN_TOKEN` của bạn.
2. **Tạo Key:**
   - **Thời hạn:** 1 ngày (test), 7 ngày, 30 ngày, 90 ngày, 365 ngày hoặc Vĩnh viễn.
   - **Số lượng máy được dùng:** 1 máy, 2 máy, 3 máy, 5 máy hoặc 10 máy.
   - **Số lượng key:** Tạo từ 1 đến 50 key cùng một lúc.
   - **Ghi chú:** Tên Facebook, Zalo hoặc ghi chú khách hàng.
   - Bấm **⚡ Tạo Key Ngay**.
3. **Thao tác nhanh trên danh sách:**
   - **Bấm vào mã Key:** Tự động copy mã vào clipboard để gửi khách.
   - **🔒 Khóa Key / 🔓 Mở Khóa:** Chặn hoặc bỏ chặn ngay tức thì.
   - **⚙️ Máy (X/X máy):** Bấm vào để xem danh sách HWID đang dùng key này và gỡ từng máy hoặc gỡ toàn bộ.
   - **🗑️ Xóa:** Xóa vĩnh viễn key khỏi cơ sở dữ liệu.

