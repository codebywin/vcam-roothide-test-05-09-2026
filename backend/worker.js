/**
 * VCAM iOS License Backend - Cloudflare Worker
 * Endpoint: https://vios.hothangtech.workers.dev/
 * 
 * Các tính năng nâng cao:
 * - Khóa key (Ban / Tạm ngưng) và Mở khóa key (Unban)
 * - Xóa key vĩnh viễn khỏi hệ thống
 * - Quản lý nhiều thiết bị trên 1 key (max_devices: 1, 2, 3, 5, 10... máy)
 * - Xem danh sách các thiết bị đang liên kết & gỡ từng thiết bị độc lập
 * - Ký token chống can thiệp (Anti-tamper HMAC-SHA256)
 * - Bảng điều khiển Web Admin Dashboard trực quan, tiện lợi
 */

// Fallback in-memory store if KV is not bound (cho phép test ngay lập tức)
const memoryStore = new Map();

// Helper: Ký số HMAC-SHA256 bảo mật cao
async function generateSignature(secret, payload) {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret || "default_vcam_secret_salt_2026"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(payload));
  return Array.from(new Uint8Array(signature))
    .map(b => b.toString(16).padStart(2, "0"))
    .join("");
}

// Helper: Sinh mã key ngẫu nhiên (Ví dụ: VCAM-ABCD-1234-EF56)
function generateLicenseKey(prefix = "VCAM") {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // bỏ 0, O, 1, I để tránh nhầm lẫn
  const part = (len) => {
    let res = "";
    const randVals = new Uint8Array(len);
    crypto.getRandomValues(randVals);
    for (let i = 0; i < len; i++) {
      res += chars[randVals[i] % chars.length];
    }
    return res;
  };
  return `${prefix.toUpperCase()}-${part(4)}-${part(4)}-${part(4)}`;
}

// Lớp trừu tượng quản lý Storage (Cloudflare KV + Memory fallback)
class LicenseStorage {
  constructor(kv) {
    this.kv = kv;
  }

  async get(key) {
    if (this.kv) {
      const data = await this.kv.get(`lic:${key}`, "json");
      return data;
    }
    return memoryStore.get(key) || null;
  }

  async put(key, record) {
    if (this.kv) {
      await this.kv.put(`lic:${key}`, JSON.stringify(record));
      return;
    }
    memoryStore.set(key, record);
  }

  async delete(key) {
    if (this.kv) {
      await this.kv.delete(`lic:${key}`);
      return;
    }
    memoryStore.delete(key);
  }

  async listAll() {
    if (this.kv) {
      const list = await this.kv.list({ prefix: "lic:" });
      const records = [];
      for (const item of list.keys) {
        const key = item.name.replace(/^lic:/, "");
        const record = await this.get(key);
        if (record) records.push(record);
      }
      return records;
    }
    return Array.from(memoryStore.values());
  }
}

// Tiện ích CORS — Chỉ cho phép request từ thiết bị iOS (không phải browser lạ)
function corsHeaders() {
  return {
    // API mobile không cần mở wildcard CORS
    "Access-Control-Allow-Origin": "null",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, X-VCAM-Signature, X-VCAM-Timestamp",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
  };
}

// CORS header riêng cho Admin Dashboard (cho phép browser)
function adminCorsHeaders() {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Admin-Token",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "SAMEORIGIN",
  };
}

function jsonResponse(data, status = 200, isAdmin = false) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...(isAdmin ? adminCorsHeaders() : corsHeaders()),
    },
  });
}

function checkAdminAuth(request, env) {
  // Bắt buộc phải set ADMIN_TOKEN trong Cloudflare env — không có fallback!
  const adminSecret = env.ADMIN_TOKEN;
  if (!adminSecret) return false;
  const authHeader = request.headers.get("Authorization") || "";
  const tokenHeader = request.headers.get("X-Admin-Token") || "";
  const bearerMatch = authHeader.match(/^Bearer\s+(.*)$/i);
  const token = bearerMatch ? bearerMatch[1].trim() : tokenHeader.trim();
  return token === adminSecret;
}

// Rate Limiter đơn giản dùng KV (max 15 request / 60 giây / IP)
async function checkRateLimit(env, ip, action) {
  if (!env.VCAM_LICENSES) return true; // Bỏ qua nếu không có KV
  const key = `rl:${action}:${ip}`;
  const now = Math.floor(Date.now() / 1000);
  const windowSec = 60;
  const maxRequests = 15;
  try {
    const raw = await env.VCAM_LICENSES.get(key);
    if (raw) {
      const data = JSON.parse(raw);
      if (now - data.start < windowSec) {
        if (data.count >= maxRequests) return false; // Vượt giới hạn
        await env.VCAM_LICENSES.put(key, JSON.stringify({ start: data.start, count: data.count + 1 }), { expirationTtl: windowSec });
      } else {
        await env.VCAM_LICENSES.put(key, JSON.stringify({ start: now, count: 1 }), { expirationTtl: windowSec });
      }
    } else {
      await env.VCAM_LICENSES.put(key, JSON.stringify({ start: now, count: 1 }), { expirationTtl: windowSec });
    }
  } catch (_) { /* Ignore KV errors */ }
  return true;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;
    const method = request.method.toUpperCase();

    // CORS preflight
    if (method === "OPTIONS") {
      const isAdminPath = path.startsWith("/api/admin") || path === "/admin";
      return new Response(null, { status: 204, headers: isAdminPath ? adminCorsHeaders() : corsHeaders() });
    }

    // 1. Root Health Check (không cần SECRET_SALT)
    if (path === "/" || path === "/api/health") {
      return jsonResponse({
        service: "VCAM iOS License Server",
        status: "online",
        time: new Date().toISOString(),
        kv_bound: !!env.VCAM_LICENSES,
        version: "2.0.0 (Multi-device, Lock/Unlock & Revoke)"
      }, 200, true);
    }

    // 2. Web Admin Dashboard — không cần SECRET_SALT (chỉ trả HTML)
    if (path === "/admin") {
      return new Response(renderAdminHTML(), {
        headers: { "Content-Type": "text/html; charset=utf-8", ...adminCorsHeaders() },
      });
    }

    // === Kiểm tra cấu hình bắt buộc cho các API routes ===
    const secretSalt = env.SECRET_SALT;
    if (!secretSalt) {
      return new Response(JSON.stringify({ error: "Server misconfigured: SECRET_SALT not set in environment" }), {
        status: 500, headers: { "Content-Type": "application/json" }
      });
    }

    const storage = new LicenseStorage(env.VCAM_LICENSES);

    // ==========================================
    // CLIENT APIS
    // ==========================================

    // POST /api/activate
    // Body: { "key": "VCAM-...", "hwid": "...", "device_name"?: "..." }
    if (path === "/api/activate" && method === "POST") {
      // Rate limit: tối đa 15 lần activate / IP / phút
      const clientIP = request.headers.get("CF-Connecting-IP") || "unknown";
      const allowed = await checkRateLimit(env, clientIP, "activate");
      if (!allowed) {
        return jsonResponse({ error: "Quá nhiều yêu cầu! Vui lòng thử lại sau 60 giây." }, 429);
      }

      try {
        const body = await request.json();
        const key = (body.key || "").trim().toUpperCase();
        const hwid = (body.hwid || "").trim();
        const deviceName = (body.device_name || "iPhone").trim();

        if (!key || !hwid) {
          return jsonResponse({ error: "Thiếu mã kích hoạt (key) hoặc định danh máy (hwid)!" }, 400);
        }

        const record = await storage.get(key);
        if (!record) {
          return jsonResponse({ error: "Mã kích hoạt không tồn tại hoặc đã bị xóa!" }, 404);
        }

        // Kiểm tra trạng thái KHÓA KEY (BANNED / LOCKED)
        if (record.status === "banned") {
          return jsonResponse({
            error: "Mã key này đã bị KHÓA bởi Quản trị viên! Vui lòng liên hệ Admin để được hỗ trợ.",
            code: "KEY_BANNED"
          }, 403);
        }

        const now = Date.now();

        // Đảm bảo tương thích cấu trúc mảng devices (nhiều thiết bị)
        if (!Array.isArray(record.devices)) {
          record.devices = [];
          if (record.hwid) {
            record.devices.push({
              hwid: record.hwid,
              device_name: "Thiết bị chính",
              activated_at: record.activated_at || now,
              last_seen_at: now
            });
          }
        }

        const maxDevices = Math.max(record.max_devices || 1, 1);
        let existingDevice = record.devices.find(d => d.hwid === hwid);

        // Kích hoạt lần đầu cho key chưa dùng
        if (record.status === "unactivated") {
          record.status = "active";
          record.activated_at = now;
          if (record.duration_days > 0) {
            record.expires_at = now + record.duration_days * 86400 * 1000;
          } else {
            record.expires_at = 0; // Vĩnh viễn (Lifetime)
          }
        }

        // Kiểm tra hết hạn thời gian
        if (record.expires_at > 0 && now > record.expires_at) {
          record.status = "expired";
          await storage.put(key, record);
          return jsonResponse({
            error: "Mã key đã hết hạn sử dụng! Vui lòng gia hạn thêm.",
            code: "EXPIRED",
            expires_at: record.expires_at
          }, 403);
        }

        // Kiểm tra thiết bị
        if (existingDevice) {
          existingDevice.last_seen_at = now;
          if (deviceName) existingDevice.device_name = deviceName;
        } else {
          // Thiết bị mới -> Kiểm tra giới hạn số lượng thiết bị (max_devices)
          if (record.devices.length >= maxDevices) {
            return jsonResponse({
              error: `Key này đã đạt giới hạn tối đa ${maxDevices} thiết bị (${record.devices.length}/${maxDevices} máy). Vui lòng nhờ Admin gỡ máy cũ để thêm máy mới.`,
              code: "MAX_DEVICES_REACHED",
              max_devices: maxDevices,
              current_devices: record.devices.length
            }, 403);
          }

          // Cho phép thêm thiết bị mới vào danh sách
          record.devices.push({
            hwid: hwid,
            device_name: deviceName,
            activated_at: now,
            last_seen_at: now
          });
        }

        record.last_check_at = now;
        await storage.put(key, record);

        // Ký số bảo mật: HMAC(secret, key + hwid + expires_at)
        const signPayload = `${key}|${hwid}|${record.expires_at}`;
        const signature = await generateSignature(secretSalt, signPayload);

        return jsonResponse({
          success: true,
          message: "Kích hoạt thành công!",
          key: record.key,
          hwid: hwid,
          max_devices: maxDevices,
          devices_count: record.devices.length,
          expires_at: record.expires_at,
          duration_days: record.duration_days,
          signature: signature,
          token: `${signPayload}|${signature}`
        });
      } catch (err) {
        return jsonResponse({ error: "Dữ liệu gửi lên không hợp lệ: " + err.message }, 400);
      }
    }

    // POST /api/verify
    // Body: { "key": "...", "hwid": "...", "signature": "...", "expires_at": 123456 }
    if (path === "/api/verify" && method === "POST") {
      // Rate limit: tối đa 15 lần verify / IP / phút
      const clientIP = request.headers.get("CF-Connecting-IP") || "unknown";
      const allowed = await checkRateLimit(env, clientIP, "verify");
      if (!allowed) {
        return jsonResponse({ valid: false, error: "Quá nhiều yêu cầu! Vui lòng thử lại sau 60 giây." }, 429);
      }

      try {
        const body = await request.json();
        const key = (body.key || "").trim().toUpperCase();
        const hwid = (body.hwid || "").trim();
        const expires_at = Number(body.expires_at ?? 0);
        const signature = (body.signature || "").trim();

        if (!key || !hwid || !signature) {
          return jsonResponse({ valid: false, error: "Thiếu thông tin xác thực!" }, 400);
        }

        // Bước 1: Xác minh chữ ký số toán học
        const signPayload = `${key}|${hwid}|${expires_at}`;
        const expectedSig = await generateSignature(secretSalt, signPayload);

        if (signature !== expectedSig) {
          return jsonResponse({ valid: false, error: "Chữ ký số không hợp lệ (Bị can thiệp)!" }, 403);
        }

        // Bước 2: Kiểm tra hết hạn
        const now = Date.now();
        if (expires_at > 0 && now > expires_at) {
          return jsonResponse({ valid: false, error: "Key đã hết hạn sử dụng!", code: "EXPIRED" }, 403);
        }

        // Bước 3: Kiểm tra trạng thái trực tuyến trên cơ sở dữ liệu
        const record = await storage.get(key);
        if (!record) {
          return jsonResponse({ valid: false, error: "Mã key đã bị xóa khỏi hệ thống!" }, 403);
        }

        if (record.status === "banned") {
          return jsonResponse({ valid: false, error: "Mã key đã bị khóa bởi Quản trị viên!", code: "KEY_BANNED" }, 403);
        }

        const devices = Array.isArray(record.devices) ? record.devices : (record.hwid ? [{ hwid: record.hwid }] : []);
        const isDeviceAllowed = devices.some(d => d.hwid === hwid);

        if (!isDeviceAllowed) {
          return jsonResponse({ valid: false, error: "Thiết bị này đã bị gỡ liên kết khỏi key!", code: "DEVICE_UNBOUND" }, 403);
        }

        return jsonResponse({
          valid: true,
          expires_at: record.expires_at,
          remaining_seconds: record.expires_at > 0 ? Math.max(0, Math.floor((record.expires_at - now) / 1000)) : -1
        });
      } catch (err) {
        return jsonResponse({ valid: false, error: err.message }, 400);
      }
    }

    // ==========================================
    // ADMIN APIS (Cần Admin Token xác thực)
    // ==========================================

    if (path.startsWith("/api/admin/")) {
      if (!env.ADMIN_TOKEN) {
        return jsonResponse({ error: "Server misconfigured: ADMIN_TOKEN not set in environment" }, 500, true);
      }
      if (!checkAdminAuth(request, env)) {
        return jsonResponse({ error: "Không có quyền truy cập (Sai Admin Token)!" }, 401, true);
      }

      // POST /api/admin/create-key
      // Body: { count: 1, duration_days: 30, max_devices: 1, note: "Khách 1", prefix: "VCAM" }
      if (path === "/api/admin/create-key" && method === "POST") {
        const body = await request.json().catch(() => ({}));
        const count = Math.min(Math.max(parseInt(body.count) || 1, 1), 50);
        const durationDays = parseInt(body.duration_days ?? 30);
        const maxDevices = Math.max(parseInt(body.max_devices) || 1, 1);
        const note = (body.note || "").trim();
        const prefix = (body.prefix || "VCAM").trim().replace(/[^A-Za-z0-9]/g, "");

        const createdKeys = [];
        const now = Date.now();

        for (let i = 0; i < count; i++) {
          const keyString = generateLicenseKey(prefix);
          const record = {
            key: keyString,
            status: "unactivated",
            duration_days: durationDays,
            max_devices: maxDevices,
            devices: [],
            created_at: now,
            activated_at: null,
            expires_at: null,
            note: note,
            last_check_at: null
          };
          await storage.put(keyString, record);
          createdKeys.push(record);
        }

        return jsonResponse({
          success: true,
          count: createdKeys.length,
          keys: createdKeys
        });
      }

      // GET /api/admin/keys
      if (path === "/api/admin/keys" && method === "GET") {
        const list = await storage.listAll();
        // Sắp xếp key mới nhất lên đầu
        list.sort((a, b) => (b.created_at || 0) - (a.created_at || 0));
        return jsonResponse({
          total: list.length,
          keys: list
        });
      }

      // POST /api/admin/toggle-ban (KHÓA / MỞ KHÓA KEY)
      // Body: { key: "VCAM-..." }
      if (path === "/api/admin/toggle-ban" && method === "POST") {
        const body = await request.json().catch(() => ({}));
        const key = (body.key || "").trim().toUpperCase();
        const record = await storage.get(key);
        if (!record) {
          return jsonResponse({ error: "Không tìm thấy key!" }, 404);
        }

        if (record.status === "banned") {
          // Mở khóa key: phục hồi về active hoặc unactivated
          const now = Date.now();
          if (!record.activated_at) {
            record.status = "unactivated";
          } else if (record.expires_at > 0 && now > record.expires_at) {
            record.status = "expired";
          } else {
            record.status = "active";
          }
          await storage.put(key, record);
          return jsonResponse({ success: true, message: `Đã mở khóa (Kích hoạt lại) cho key ${key}!`, record });
        } else {
          // Khóa key ngay lập tức
          record.status = "banned";
          await storage.put(key, record);
          return jsonResponse({ success: true, message: `Đã KHÓA thành công key ${key}!`, record });
        }
      }

      // POST /api/admin/reset-hwid (RESET TOÀN BỘ THIẾT BỊ HOẶC 1 THIẾT BỊ CỤ THỂ)
      // Body: { key: "VCAM-...", hwid?: "..." }
      if (path === "/api/admin/reset-hwid" && method === "POST") {
        const body = await request.json().catch(() => ({}));
        const key = (body.key || "").trim().toUpperCase();
        const specificHwid = (body.hwid || "").trim();

        const record = await storage.get(key);
        if (!record) {
          return jsonResponse({ error: "Không tìm thấy key!" }, 404);
        }

        if (!Array.isArray(record.devices)) {
          record.devices = [];
        }

        if (specificHwid) {
          // Xóa một thiết bị cụ thể
          record.devices = record.devices.filter(d => d.hwid !== specificHwid);
          await storage.put(key, record);
          return jsonResponse({
            success: true,
            message: `Đã gỡ thiết bị ${specificHwid.substring(0, 8)}... khỏi key ${key}!`,
            record
          });
        } else {
          // Reset toàn bộ thiết bị
          record.devices = [];
          record.hwid = null;
          await storage.put(key, record);
          return jsonResponse({
            success: true,
            message: `Đã reset toàn bộ danh sách thiết bị cho key ${key}!`,
            record
          });
        }
      }

      // POST /api/admin/delete-key (XÓA VĨNH VIỄN KEY)
      // Body: { key: "VCAM-..." }
      if (path === "/api/admin/delete-key" && method === "POST") {
        const body = await request.json().catch(() => ({}));
        const key = (body.key || "").trim().toUpperCase();
        await storage.delete(key);
        return jsonResponse({ success: true, message: `Đã xóa vĩnh viễn key ${key} khỏi hệ thống!` });
      }
    }

    return jsonResponse({ error: "Endpoint không tồn tại" }, 404);
  }
};

// ==========================================
// EMBEDDED WEB ADMIN DASHBOARD (HTML/CSS/JS)
// ==========================================
function renderAdminHTML() {
  return `<!DOCTYPE html>
<html lang="vi">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Quản Trị Bản Quyền VCAM iOS</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #0A0E1A;
      --card-bg: rgba(19, 26, 43, 0.85);
      --card-border: rgba(255, 255, 255, 0.08);
      --accent: #3B82F6;
      --accent-hover: #2563EB;
      --accent-glow: rgba(59, 130, 246, 0.35);
      --text: #F3F4F6;
      --text-muted: #9CA3AF;
      --success: #10B981;
      --warning: #F59E0B;
      --danger: #EF4444;
      --purple: #8B5CF6;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Plus Jakarta Sans', sans-serif; }
    body {
      background-color: var(--bg);
      color: var(--text);
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      background-image: radial-gradient(circle at 15% 15%, rgba(59, 130, 246, 0.12) 0%, transparent 40%),
                        radial-gradient(circle at 85% 85%, rgba(139, 92, 246, 0.10) 0%, transparent 40%);
    }
    .container { max-width: 1280px; margin: 0 auto; padding: 24px 20px; width: 100%; flex: 1; }
    header {
      display: flex; justify-content: space-between; align-items: center;
      margin-bottom: 26px; padding-bottom: 16px; border-bottom: 1px solid var(--card-border);
      flex-wrap: wrap; gap: 16px;
    }
    .brand { display: flex; align-items: center; gap: 12px; }
    .brand-icon {
      width: 44px; height: 44px; border-radius: 12px;
      background: linear-gradient(135deg, #3B82F6, #8B5CF6);
      display: flex; align-items: center; justify-content: center; font-size: 22px; font-weight: 800;
      box-shadow: 0 4px 14px var(--accent-glow);
    }
    .brand h1 { font-size: 21px; font-weight: 700; letter-spacing: -0.5px; }
    .brand p { font-size: 13px; color: var(--text-muted); }
    
    .btn {
      display: inline-flex; align-items: center; justify-content: center; gap: 6px;
      padding: 9px 16px; border-radius: 10px; font-weight: 600; font-size: 13px;
      cursor: pointer; transition: all 0.2s; border: none; outline: none;
    }
    .btn-primary {
      background: var(--accent); color: white;
      box-shadow: 0 4px 12px var(--accent-glow);
    }
    .btn-primary:hover { background: var(--accent-hover); transform: translateY(-1px); }
    .btn-secondary { background: rgba(255,255,255,0.08); color: var(--text); border: 1px solid var(--card-border); }
    .btn-secondary:hover { background: rgba(255,255,255,0.14); }
    .btn-warning { background: rgba(245, 158, 11, 0.15); color: #FBBF24; border: 1px solid rgba(245, 158, 11, 0.3); }
    .btn-warning:hover { background: rgba(245, 158, 11, 0.3); }
    .btn-danger { background: rgba(239, 68, 68, 0.15); color: #FCA5A5; border: 1px solid rgba(239, 68, 68, 0.3); }
    .btn-danger:hover { background: rgba(239, 68, 68, 0.3); }
    .btn-sm { padding: 5px 10px; font-size: 12px; border-radius: 8px; }

    .grid-stats {
      display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 14px;
      margin-bottom: 24px;
    }
    .stat-card {
      background: var(--card-bg); border: 1px solid var(--card-border);
      border-radius: 16px; padding: 16px 20px; backdrop-filter: blur(12px);
    }
    .stat-label { font-size: 12px; color: var(--text-muted); margin-bottom: 4px; text-transform: uppercase; font-weight: 600; }
    .stat-value { font-size: 26px; font-weight: 800; color: var(--text); }

    .card {
      background: var(--card-bg); border: 1px solid var(--card-border);
      border-radius: 18px; padding: 22px 24px; backdrop-filter: blur(12px);
      margin-bottom: 24px; box-shadow: 0 10px 30px rgba(0,0,0,0.25);
    }
    .card-title { font-size: 16px; font-weight: 700; margin-bottom: 16px; display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 10px; }
    
    .form-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 14px; margin-bottom: 16px; }
    .form-group { display: flex; flex-direction: column; gap: 6px; }
    .form-group label { font-size: 12px; font-weight: 600; color: var(--text-muted); }
    .form-control {
      background: rgba(15, 23, 42, 0.6); border: 1px solid var(--card-border);
      color: var(--text); padding: 9px 12px; border-radius: 10px; font-size: 13px;
      outline: none; transition: border 0.2s;
    }
    .form-control:focus { border-color: var(--accent); }

    .table-container { overflow-x: auto; margin-top: 10px; border-radius: 12px; border: 1px solid var(--card-border); }
    table { width: 100%; border-collapse: collapse; text-align: left; font-size: 13px; }
    th {
      background: rgba(15, 23, 42, 0.85); color: var(--text-muted); font-weight: 600;
      padding: 12px 14px; border-bottom: 1px solid var(--card-border); white-space: nowrap; font-size: 12px;
    }
    td { padding: 12px 14px; border-bottom: 1px solid rgba(255,255,255,0.04); vertical-align: middle; }
    tr:hover td { background: rgba(255,255,255,0.02); }

    .badge {
      display: inline-flex; align-items: center; padding: 4px 9px; border-radius: 999px;
      font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px;
    }
    .badge-active { background: rgba(16, 185, 129, 0.15); color: #34D399; border: 1px solid rgba(16, 185, 129, 0.3); }
    .badge-unactivated { background: rgba(59, 130, 246, 0.15); color: #60A5FA; border: 1px solid rgba(59, 130, 246, 0.3); }
    .badge-expired { background: rgba(245, 158, 11, 0.15); color: #FBBF24; border: 1px solid rgba(245, 158, 11, 0.3); }
    .badge-banned { background: rgba(239, 68, 68, 0.2); color: #F87171; border: 1px solid rgba(239, 68, 68, 0.4); }

    .key-box {
      font-family: monospace; font-size: 13px; font-weight: 700; color: #93C5FD;
      background: rgba(30, 58, 138, 0.3); padding: 4px 8px; border-radius: 6px;
      cursor: pointer; display: inline-flex; align-items: center; gap: 5px;
    }
    .key-box:hover { background: rgba(30, 58, 138, 0.6); }

    .device-pill {
      background: rgba(139, 92, 246, 0.15); color: #C4B5FD; border: 1px solid rgba(139, 92, 246, 0.3);
      padding: 3px 8px; border-radius: 8px; font-size: 11px; font-weight: 600; cursor: pointer;
      display: inline-flex; align-items: center; gap: 4px;
    }
    .device-pill:hover { background: rgba(139, 92, 246, 0.3); }

    /* MODAL */
    .modal-overlay {
      position: fixed; inset: 0; background: rgba(0,0,0,0.8); backdrop-filter: blur(8px);
      display: flex; align-items: center; justify-content: center; z-index: 1000;
    }
    .modal-box {
      background: #141B2D; border: 1px solid var(--card-border); border-radius: 20px;
      padding: 28px; max-width: 500px; width: 92%; box-shadow: 0 20px 50px rgba(0,0,0,0.6);
    }
    .toast {
      position: fixed; bottom: 24px; right: 24px; background: #1E293B; color: white;
      padding: 12px 20px; border-radius: 12px; border: 1px solid var(--card-border);
      box-shadow: 0 10px 25px rgba(0,0,0,0.4); font-size: 13px; z-index: 2000;
      display: none; animation: slideUp 0.3s ease;
    }
    @keyframes slideUp { from { transform: translateY(20px); opacity: 0; } to { transform: translateY(0); opacity: 1; } }
  </style>
</head>
<body>
  <!-- AUTH MODAL -->
  <div id="authModal" class="modal-overlay">
    <div class="modal-box" style="text-align: center;">
      <div style="font-size: 40px; margin-bottom: 10px;">🔐</div>
      <h2 style="font-size: 19px; font-weight: 700; margin-bottom: 6px;">Đăng Nhập Quản Trị</h2>
      <p style="font-size: 13px; color: var(--text-muted); margin-bottom: 18px;">Nhập ADMIN_TOKEN để vào bảng điều khiển</p>
      <input type="password" id="adminTokenInput" class="form-control" placeholder="Nhập ADMIN_TOKEN..." style="width: 100%; margin-bottom: 14px; text-align: center; font-size: 14px;">
      <button class="btn btn-primary" onclick="loginAdmin()" style="width: 100%;">Truy Cập</button>
    </div>
  </div>

  <!-- DEVICE MANAGEMENT MODAL -->
  <div id="deviceModal" class="modal-overlay" style="display: none;">
    <div class="modal-box">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
        <h3 style="font-size: 16px; font-weight: 700;">📱 Quản Lý Thiết Bị Liên Kết</h3>
        <button onclick="closeDeviceModal()" style="background:none; border:none; color:var(--text-muted); font-size:20px; cursor:pointer;">✕</button>
      </div>
      <p style="font-size: 13px; color: var(--text-muted); margin-bottom: 14px;" id="modalKeySubtitle"></p>
      <div id="deviceListContainer" style="max-height: 280px; overflow-y: auto; margin-bottom: 18px; display: flex; flex-direction: column; gap: 8px;">
      </div>
      <div style="display: flex; justify-content: space-between; gap: 10px;">
        <button class="btn btn-danger btn-sm" id="btnResetAllDevices" onclick="resetAllDevicesModal()">⚠️ Gỡ Toàn Bộ Máy</button>
        <button class="btn btn-secondary btn-sm" onclick="closeDeviceModal()">Đóng</button>
      </div>
    </div>
  </div>

  <div class="container" id="mainContent" style="display:none;">
    <header>
      <div class="brand">
        <div class="brand-icon">📹</div>
        <div>
          <h1>VCAM iOS License Manager</h1>
          <p>Quản lý khóa key, xóa key, nhiều thiết bị & chống dịch ngược</p>
        </div>
      </div>
      <div style="display: flex; gap: 10px;">
        <button class="btn btn-secondary btn-sm" onclick="loadKeys()">🔄 Làm Mới</button>
        <button class="btn btn-secondary btn-sm" onclick="logout()">Thoát</button>
      </div>
    </header>

    <!-- STATS -->
    <div class="grid-stats">
      <div class="stat-card">
        <div class="stat-label">Tổng Số Key</div>
        <div class="stat-value" id="statTotal">0</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Đang Hoạt Động</div>
        <div class="stat-value" style="color: #34D399;" id="statActive">0</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Chưa Kích Hoạt</div>
        <div class="stat-value" style="color: #60A5FA;" id="statUnused">0</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Đã Hết Hạn</div>
        <div class="stat-value" style="color: #FBBF24;" id="statExpired">0</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Bị Khóa (Banned)</div>
        <div class="stat-value" style="color: #F87171;" id="statBanned">0</div>
      </div>
    </div>

    <!-- CREATE KEYS -->
    <div class="card">
      <div class="card-title">
        <span>⚡ Tạo Mã Key Mới</span>
      </div>
      <div class="form-row">
        <div class="form-group">
          <label>Thời Hạn</label>
          <select id="keyDuration" class="form-control">
            <option value="1">1 Ngày (Dùng thử)</option>
            <option value="7">7 Ngày (1 Tuần)</option>
            <option value="30" selected>30 Ngày (1 Tháng)</option>
            <option value="90">90 Ngày (3 Tháng)</option>
            <option value="365">365 Ngày (1 Năm)</option>
            <option value="0">Vĩnh Viễn (Lifetime)</option>
          </select>
        </div>
        <div class="form-group">
          <label>Số Lượng Máy Được Dùng (Max Devices)</label>
          <select id="keyMaxDevices" class="form-control">
            <option value="1" selected>1 Thiết Bị</option>
            <option value="2">2 Thiết Bị</option>
            <option value="3">3 Thiết Bị</option>
            <option value="5">5 Thiết Bị</option>
            <option value="10">10 Thiết Bị</option>
          </select>
        </div>
        <div class="form-group">
          <label>Số Lượng Mã Cần Tạo</label>
          <input type="number" id="keyCount" class="form-control" value="1" min="1" max="50">
        </div>
        <div class="form-group">
          <label>Tiền Tố (Prefix)</label>
          <input type="text" id="keyPrefix" class="form-control" value="VCAM" placeholder="VCAM">
        </div>
        <div class="form-group" style="grid-column: span 2;">
          <label>Ghi Chú / Tên Khách</label>
          <input type="text" id="keyNote" class="form-control" placeholder="Ví dụ: Khách Zalo 09xx / Facebook...">
        </div>
      </div>
      <button class="btn btn-primary" onclick="createKey()">⚡ Tạo Key Ngay</button>
    </div>

    <!-- KEY LIST -->
    <div class="card">
      <div class="card-title">
        <span>📋 Danh Sách Key Hệ Thống</span>
        <input type="text" id="searchInput" class="form-control" placeholder="🔍 Tìm key, HWID, ghi chú..." style="max-width: 280px; font-size: 13px;" oninput="filterKeys()">
      </div>
      <div class="table-container">
        <table>
          <thead>
            <tr>
              <th>Mã Key</th>
              <th>Trạng Thái</th>
              <th>Thời Hạn</th>
              <th>Số Máy / HWID</th>
              <th>Ghi Chú</th>
              <th>Ngày Tạo</th>
              <th style="text-align: right;">Hành Động Quản Trị</th>
            </tr>
          </thead>
          <tbody id="keysTableBody">
            <tr>
              <td colspan="7" style="text-align:center; color: var(--text-muted); padding: 30px;">Đang tải dữ liệu...</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>

  <div id="toast" class="toast"></div>

  <script>
    let allKeys = [];
    let currentSelectedKey = null;

    function showToast(msg) {
      const t = document.getElementById('toast');
      t.innerText = msg;
      t.style.display = 'block';
      setTimeout(() => { t.style.display = 'none'; }, 3000);
    }

    function getToken() {
      return localStorage.getItem('vcam_admin_token') || '';
    }

    function loginAdmin() {
      const t = document.getElementById('adminTokenInput').value.trim();
      if (!t) return alert('Vui lòng nhập ADMIN_TOKEN!');
      localStorage.setItem('vcam_admin_token', t);
      checkAuthAndLoad();
    }

    function logout() {
      localStorage.removeItem('vcam_admin_token');
      location.reload();
    }

    async function checkAuthAndLoad() {
      const token = getToken();
      if (!token) {
        document.getElementById('authModal').style.display = 'flex';
        document.getElementById('mainContent').style.display = 'none';
        return;
      }
      document.getElementById('authModal').style.display = 'none';
      document.getElementById('mainContent').style.display = 'block';
      await loadKeys();
    }

    async function apiRequest(endpoint, options = {}) {
      options.headers = {
        ...(options.headers || {}),
        'Authorization': 'Bearer ' + getToken(),
        'Content-Type': 'application/json'
      };
      const res = await fetch(endpoint, options);
      if (res.status === 401) {
        alert('Sai ADMIN_TOKEN hoặc token hết hạn!');
        logout();
        throw new Error('Unauthorized');
      }
      return res.json();
    }

    async function loadKeys() {
      try {
        const data = await apiRequest('/api/admin/keys');
        allKeys = data.keys || [];
        updateStats();
        renderTable(allKeys);
      } catch (e) {
        console.error(e);
      }
    }

    function updateStats() {
      const now = Date.now();
      let total = allKeys.length;
      let active = 0, unused = 0, expired = 0, banned = 0;
      allKeys.forEach(k => {
        if (k.status === 'banned') banned++;
        else if (k.status === 'unactivated') unused++;
        else if (k.expires_at > 0 && now > k.expires_at) expired++;
        else if (k.status === 'active') active++;
      });
      document.getElementById('statTotal').innerText = total;
      document.getElementById('statActive').innerText = active;
      document.getElementById('statUnused').innerText = unused;
      document.getElementById('statExpired').innerText = expired;
      document.getElementById('statBanned').innerText = banned;
    }

    function renderTable(keys) {
      const tbody = document.getElementById('keysTableBody');
      if (keys.length === 0) {
        tbody.innerHTML = '<tr><td colspan="7" style="text-align:center; color: var(--text-muted); padding: 30px;">Không có mã key nào</td></tr>';
        return;
      }
      const now = Date.now();
      tbody.innerHTML = keys.map(k => {
        let statusBadge = '';
        if (k.status === 'banned') {
          statusBadge = '<span class="badge badge-banned">⛔ Đã Khóa</span>';
        } else if (k.status === 'unactivated') {
          statusBadge = '<span class="badge badge-unactivated">Chưa kích hoạt</span>';
        } else if (k.expires_at > 0 && now > k.expires_at) {
          statusBadge = '<span class="badge badge-expired">Đã hết hạn</span>';
        } else {
          statusBadge = '<span class="badge badge-active">Hoạt động</span>';
        }

        const durationText = k.duration_days === 0 ? 'Vĩnh viễn' : (k.duration_days + ' ngày');
        let expiryText = 'Chưa kích hoạt';
        if (k.expires_at === 0) expiryText = 'Vĩnh viễn';
        else if (k.expires_at > 0) {
          const daysLeft = Math.ceil((k.expires_at - now) / 86400000);
          expiryText = new Date(k.expires_at).toLocaleDateString('vi-VN') + ' (' + (daysLeft > 0 ? ('còn ' + daysLeft + ' ngày') : 'hết hạn') + ')';
        }

        const maxDev = k.max_devices || 1;
        const devices = Array.isArray(k.devices) ? k.devices : (k.hwid ? [{ hwid: k.hwid }] : []);
        const devCount = devices.length;
        const devBadge = '<span class="device-pill" onclick="openDeviceModal(\\'' + k.key + '\\')">📱 ' + devCount + '/' + maxDev + ' máy</span>';

        const isBanned = k.status === 'banned';
        const lockBtn = isBanned 
          ? '<button class="btn btn-secondary btn-sm" style="margin-right: 4px;" onclick="toggleBan(\\'' + k.key + '\\')">🔓 Mở Khóa</button>'
          : '<button class="btn btn-warning btn-sm" style="margin-right: 4px;" onclick="toggleBan(\\'' + k.key + '\\')">🔒 Khóa Key</button>';

        return '<tr>' +
          '<td><span class="key-box" onclick="copyText(\\'' + k.key + '\\')">' + k.key + ' 📋</span></td>' +
          '<td>' + statusBadge + '</td>' +
          '<td>' + durationText + '<br><small style="color:var(--text-muted);">' + expiryText + '</small></td>' +
          '<td>' + devBadge + '</td>' +
          '<td>' + (k.note || '-') + '</td>' +
          '<td>' + (k.created_at ? new Date(k.created_at).toLocaleDateString('vi-VN') : '-') + '</td>' +
          '<td style="text-align: right; white-space: nowrap;">' +
            lockBtn +
            '<button class="btn btn-secondary btn-sm" style="margin-right: 4px;" onclick="openDeviceModal(\\'' + k.key + '\\')">⚙️ Máy</button>' +
            '<button class="btn btn-danger btn-sm" onclick="deleteKey(\\'' + k.key + '\\')">🗑️ Xóa</button>' +
          '</td>' +
        '</tr>';
      }).join('');
    }

    function filterKeys() {
      const q = document.getElementById('searchInput').value.toLowerCase();
      const filtered = allKeys.filter(k => 
        k.key.toLowerCase().includes(q) ||
        (k.note && k.note.toLowerCase().includes(q)) ||
        (k.devices && k.devices.some(d => d.hwid && d.hwid.toLowerCase().includes(q))) ||
        (k.hwid && k.hwid.toLowerCase().includes(q))
      );
      renderTable(filtered);
    }

    function copyText(txt) {
      navigator.clipboard.writeText(txt);
      showToast('Đã sao chép mã: ' + txt);
    }

    async function createKey() {
      const duration = parseInt(document.getElementById('keyDuration').value);
      const maxDevices = parseInt(document.getElementById('keyMaxDevices').value) || 1;
      const count = parseInt(document.getElementById('keyCount').value) || 1;
      const prefix = document.getElementById('keyPrefix').value.trim() || 'VCAM';
      const note = document.getElementById('keyNote').value.trim();

      try {
        const res = await apiRequest('/api/admin/create-key', {
          method: 'POST',
          body: JSON.stringify({ duration_days: duration, max_devices: maxDevices, count, prefix, note })
        });
        showToast('Đã tạo thành công ' + res.count + ' mã key!');
        document.getElementById('keyNote').value = '';
        await loadKeys();
      } catch (e) {
        alert('Lỗi tạo key: ' + e.message);
      }
    }

    async function toggleBan(key) {
      const k = allKeys.find(x => x.key === key);
      const actionText = (k && k.status === 'banned') ? 'MỞ KHÓA' : 'KHÓA';
      if (!confirm('Bạn có chắc muốn ' + actionText + ' key ' + key + '?')) return;
      try {
        const res = await apiRequest('/api/admin/toggle-ban', {
          method: 'POST',
          body: JSON.stringify({ key })
        });
        showToast(res.message);
        await loadKeys();
      } catch (e) {
        alert('Lỗi: ' + e.message);
      }
    }

    async function deleteKey(key) {
      if (!confirm('⚠️ CẢNH BÁO: Bạn có chắc muốn XÓA VĨNH VIỄN key ' + key + ' khỏi cơ sở dữ liệu?')) return;
      try {
        await apiRequest('/api/admin/delete-key', {
          method: 'POST',
          body: JSON.stringify({ key })
        });
        showToast('Đã xóa vĩnh viễn key ' + key);
        await loadKeys();
      } catch (e) {
        alert('Lỗi: ' + e.message);
      }
    }

    // DEVICE MODAL HANDLERS
    function openDeviceModal(key) {
      const k = allKeys.find(x => x.key === key);
      if (!k) return;
      currentSelectedKey = k;
      document.getElementById('modalKeySubtitle').innerText = 'Mã key: ' + k.key + ' (Tối đa: ' + (k.max_devices || 1) + ' thiết bị)';
      
      const container = document.getElementById('deviceListContainer');
      const devices = Array.isArray(k.devices) ? k.devices : (k.hwid ? [{ hwid: k.hwid, device_name: 'Thiết bị chính' }] : []);

      if (devices.length === 0) {
        container.innerHTML = '<div style="text-align:center; padding:20px; color:var(--text-muted); font-size:13px;">Chưa có thiết bị nào kích hoạt key này</div>';
      } else {
        container.innerHTML = devices.map((d, index) => {
          const hwidShort = d.hwid ? (d.hwid.substring(0, 18) + '...') : 'Không rõ HWID';
          const lastSeen = d.last_seen_at ? new Date(d.last_seen_at).toLocaleString('vi-VN') : 'Mới kích hoạt';
          return '<div style="background: rgba(15,23,42,0.6); padding: 10px 12px; border-radius: 10px; border: 1px solid var(--card-border); display: flex; justify-content: space-between; align-items: center;">' +
            '<div>' +
              '<div style="font-weight: 600; font-size: 13px;">' + (d.device_name || ('Máy #' + (index + 1))) + '</div>' +
              '<div style="font-family: monospace; font-size: 11px; color: #93C5FD;">' + hwidShort + '</div>' +
              '<div style="font-size: 11px; color: var(--text-muted);">Lần cuối: ' + lastSeen + '</div>' +
            '</div>' +
            '<button class="btn btn-danger btn-sm" onclick="removeDevice(\\'' + k.key + '\\', \\'' + d.hwid + '\\')">Gỡ Máy</button>' +
          '</div>';
        }).join('');
      }

      document.getElementById('deviceModal').style.display = 'flex';
    }

    function closeDeviceModal() {
      document.getElementById('deviceModal').style.display = 'none';
      currentSelectedKey = null;
    }

    async function removeDevice(key, hwid) {
      if (!confirm('Gỡ thiết bị này khỏi key? Máy này sẽ không dùng được nữa trừ khi được kích hoạt lại.')) return;
      try {
        const res = await apiRequest('/api/admin/reset-hwid', {
          method: 'POST',
          body: JSON.stringify({ key, hwid })
        });
        showToast(res.message);
        await loadKeys();
        openDeviceModal(key);
      } catch (e) {
        alert('Lỗi: ' + e.message);
      }
    }

    async function resetAllDevicesModal() {
      if (!currentSelectedKey) return;
      if (!confirm('Bạn có chắc muốn GỠ TOÀN BỘ thiết bị khỏi key ' + currentSelectedKey.key + '?')) return;
      try {
        const res = await apiRequest('/api/admin/reset-hwid', {
          method: 'POST',
          body: JSON.stringify({ key: currentSelectedKey.key })
        });
        showToast(res.message);
        await loadKeys();
        closeDeviceModal();
      } catch (e) {
        alert('Lỗi: ' + e.message);
      }
    }

    checkAuthAndLoad();
  </script>
</body>
</html>`;
}

