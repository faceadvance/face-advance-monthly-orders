# Design — MO Auth: LINE OTP รายบุคคล + role + session + OTP-fail alert

วันที่: 2026-09-02 · แตะ auth production (ระวังไม่ให้ล็อกอินเดิมพัง)

## เป้าหมาย
1. OTP ส่งเข้า **LINE รายบุคคล** (`line_user_id` ของ user) แทนกลุ่ม
2. **role** editor/viewer — viewer ดูอย่างเดียว (เปิด sidebar/แก้/นำเข้าไม่ได้ + บล็อก server)
3. บัญชี **friday** session **24 ชม.** (ทั้ง TTL และ idle)
4. ใส่ **OTP ผิด ≥2 หลัก หรือ ผิด ≥2 ครั้ง → แจ้งเตือนเข้ากลุ่ม LINE ทุกครั้ง (flex)** (กันสุ่มเดา)
5. เอาข้อความ "ยืนยันตัวตน 2 ชั้นด้วย OTP ผ่าน LINE" ออกจากหน้า login

## DB
### app_users +คอลัมน์
- `line_user_id text` · `role text not null default 'editor'` (editor|viewer)
- `session_hours int not null default 12` · `idle_minutes int not null default 30`

### auth_login_tickets +คอลัมน์
- `otp text` — เก็บ OTP ตัวจริง (ephemeral 5 นาที) เพื่อนับหลักที่ต่างตอน verify (คง `otp_hash` ไว้ใช้ match)

### RPC
- `app_auth_login` → เก็บ otp plain ใน ticket · **คืน `line_user_id`** เพิ่ม
- `app_auth_verify` →
  - สำเร็จ: `expires_at = now() + session_hours ชม.` (ตาม user) · **คืน `role`** เพิ่ม
  - ผิด: นับหลักต่าง vs `otp` (6 หลัก) + นับครั้งที่ผิด (attempts+1) → ถ้า **หลักต่าง ≥2 หรือ ครั้งที่ผิด ≥2** คืน `alert:true` + `wrong_digits` + `attempt_no` + `username` (Edge ส่ง flex เข้ากลุ่มทุกครั้ง)
- `app_session_uid` → ใช้ `idle_minutes` ของ user แทน 30 คงที่ (join app_users)
- `get_orders` → คืน `role` เพิ่ม (ให้ frontend รู้ role ตอน reload)
- `app_save_order_tracking` (+ RPC นำเข้าในอนาคต) → **reject ถ้า role=viewer** (กันเลี่ยง UI)

## Edge Function `auth`
- `doLogin`: push OTP flex → **`line_user_id`** (จาก login response) · ถ้าว่าง → fallback `LINE_GROUP`
- `doVerify`: ถ้า response มี `alert` → push **security flex → `LINE_GROUP`** (username, ip, device, เวลา, จำนวนหลักผิด)

## Frontend
- เก็บ `role` (จาก verify ตอนล็อกอิน + จาก get_orders ตอน reload)
- **viewer:** ซ่อน/ปิดดินสอแก้สถานะ · คลิกอัพเดต/แถว = เตือน "ไม่มีสิทธิ์แก้ไขข้อมูล" (ไม่เปิด sidebar) · ปุ่มนำเข้าปิด/เตือน
- editor: เหมือนเดิม

## บัญชี (line_user_id = Ub9df…d901 ทั้ง 3, ชั่วคราวสำหรับ aom/plug)
| username | role | session_hours | idle_minutes | password |
|---|---|---|---|---|
| aom-pinchaya | editor | 12 | 30 | (เดิม ไม่แตะ) |
| friday | editor | 24 | 1440 | 65164416 (bcrypt) |
| plug | viewer | 12 | 30 | 65164416 (bcrypt) |

## Verify (tx/rollback + revert)
- login → OTP push เข้า LINE รายบุคคล (ทดสอบจริงกับ id เจ้านาย)
- OTP ผิด 1 หลัก = ไม่เตือน · ผิด 2+ หลัก = เตือนกลุ่ม
- viewer: เปิด sidebar ไม่ได้ (UI เตือน) + save RPC reject
- friday: expires_at = +24ชม. · idle 24ชม.
- ล็อกอินเดิม (aom) ยังทำงานปกติ
