# TASK — เว็บแอป Face Advance (build ตัวจริง local)

> งานใหญ่ ข้ามหลาย session · เริ่ม 2026-08-31 · login ยังไม่ทำ (ครอบทีหลัง) · ยังไม่ deploy GitHub
> ดีไซน์ล็อกแล้ว: `webapp/design/mockup-orders-v6.html` · การตัดสินใจ: `webapp/DESIGN-DECISIONS.md`
> สัญญา API: `webapp/API-CONTRACT.md`

## สถาปัตยกรรม local
- **backend** (`webapp/backend/`) FastAPI ถือ DB URL ไว้ในเครื่อง (จาก `~/.claude/secrets.env` → `SUPABASE_DB_URL_FACEADVANCE`) · bind 127.0.0.1 เท่านั้น · key ไม่หลุดออก frontend
- **frontend** (`webapp/frontend/`) Vite + TS (vanilla) · reuse markup/CSS จาก mockup v6 · คุย backend ที่ localhost
- ตอน deploy จริงทีหลัง: สลับ data layer เป็น Supabase RPC + anon + login (สถาปัตยกรรม A)

## แบ่งงาน
- 🐝 เดซี่ (Codex): backend ทั้งหมด (`webapp/backend/`) — endpoints ตาม API-CONTRACT + เทส
- 👩 ฟรายเดย์: frontend (`webapp/frontend/`) + verify ทั้งระบบ + deploy

## Checklist
### Stage 1 — หน้าดูออเดอร์ ✅ เสร็จ + verify แล้ว (2026-08-31, ฟรายเดย์เขียนเอง)
- [x] backend: `GET /api/health`, `GET /api/orders?month=YYYY-MM`, `GET /api/months` (FastAPI, `webapp/backend/`)
- [x] frontend: scaffold Vite+TS, ฟอนต์ (IBM Plex Sans Thai + Inter), Lucide-style SVG icons, palette
- [x] frontend: top bar (โลโก้/แบรนด์/month-picker/ค้นหา/ซูม/ปุ่มนำเข้า(ยังไม่ทำงาน)/user)
- [x] frontend: 3 KPI cards + กราฟแท่งรายวัน (ฐานเท่ากัน, แท่ง=วันในเดือน, อนาคตว่าง)
- [x] frontend: ตารางออเดอร์ (เก่า→ใหม่, datecell d/M/yyyy, คอลัมน์ครบ, badge+icon, ชื่อ+โค้ด)
- [x] frontend: filter แบบ Google Sheets ทุกคอลัมน์ + chip ตัวกรอง + เรียง
- [x] frontend: ซูมในแอป (rem, จำค่า localStorage) · ค้นหา (เบอร์/ชื่อ/แทร็ค/ที่อยู่/หมายเหตุ)
- [x] **frontend: ฟีเจอร์เลือกเลขแทร็คคัดลอก** (tick กลม, max 30, แถบก๊อป+count+X+badge ครบ30, คั่นเว้นวรรค 1)
- [x] verify: เปิดจริงในเบราว์เซอร์ — ตรง mockup, tsc สะอาด, 0 console error, ก๊อป 30/คั่นเว้นวรรค/ลำดับถูก, กรอง/ค้นหา/zoom/month-picker/empty-month ผ่านหมด
### Stage 2 — นำเข้าไฟล์ (ทีหลัง)
- [ ] backend: `/api/import/preflight` + `/api/import/confirm` (พอร์ต logic จาก `database/seed/import_gosell_orders.py`)
- [ ] frontend: หน้านำเข้า (upload → pre-flight report → ยืนยัน)
### Stage 3 — login (กำลังทำ 2026-08-31) — Supabase Edge Functions + RLS (Architecture A)
> boss อนุมัติ: ทำบน Supabase เลย (เลิกใช้ Python backend) · username+password+LINE OTP · OTP ส่งเข้า **กลุ่ม LINE** `<LINE_GROUP_ID — ตั้งใน Supabase secret>` เป็น Flex+ปุ่มคัดลอก · geo: จังหวัด/เมือง(approx) + เก็บเต็มใน audit · session token 12 ชม.
> user: **Aom-pinchaya** (boss ตั้ง password เอง ผ่านสคริปต์ — ฟรายเดย์ไม่แตะ plain) · LINE token = `LINE_ACCESS_TOKEN` ใน secrets.env
- [x] migration `auth_login_system`: ตาราง `app_users`/`auth_login_tickets`/`auth_sessions`/`audit_log` + RLS + RPC (`app_auth_login`/`app_auth_verify`/`app_auth_logout`/`app_session_uid`/`get_orders`/`get_months`) + grants — เทส DB flow ครบ (login/verify/orders/logout + negative + audit)
- [x] สคริปต์ `webapp/auth/create_user.sh` + `create_user.py` (boss พิมพ์ password เอง getpass, bcrypt via pgcrypto)
- [x] Edge Function `auth` (1 ตัว dispatch login/verify/logout, verify_jwt=false) — ส่ง LINE flex เข้ากลุ่ม + geo(ipwho.is) + parseUA · เทส HTTP flow ครบ
- [x] Supabase secrets: LINE_CHANNEL_TOKEN, LINE_GROUP_ID (Management API) — LINE flex ส่งจริงเข้ากลุ่มได้ · การ์ด kilo+OTP 3xl+ปุ่มคัดลอก boss พอใจแล้ว
- [x] frontend: หน้า login+OTP · gate แอป · session localStorage · logout · เลิกใช้ Python backend/proxy · KPI/daily คำนวณที่ frontend
- [x] สร้างบัญชี **Aom-pinchaya** (ฟรายเดย์จัดการให้ตามที่ boss สั่ง, bcrypt) + verify flow เต็มผ่าน API (login→verify→session→orders 219) ✅
- [x] ลบ testuser (บัญชีทดสอบ) · ปิด Python backend + mockup server
- [ ] **boss login ครั้งแรกผ่าน UI เอง** — เข้า http://127.0.0.1:5173 กรอก Aom-pinchaya+รหัส → OTP เข้ากลุ่ม LINE → กรอก → เข้าแอป (ขั้นนี้ทำแทนไม่ได้ เพราะ OTP เข้า LINE ของ boss = หัวใจ 2FA)
### Stage 4 — deploy GitHub Pages (ทีหลัง)
- [ ] push frontend ขึ้น GitHub Pages (Edge Functions อยู่ Supabase แล้ว = ไม่ต้องทำ backend เพิ่ม)

## แจ้ง LINE ตอน build stage เสร็จ (boss confirm แล้ว)
