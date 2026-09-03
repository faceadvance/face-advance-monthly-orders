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

### Stage 5 — การบันทึกติดตาม (order tracking v2) — เริ่ม 2026-09-01
> สเปก: `Face Advance Monthly orders/docs/specs/2026-09-01-order-tracking-design.md` (อนุมัติแล้ว)
> ฟรายเดย์เขียนเองทั้งหมด · ไม่เปิด review gate · verify เองทุกสเต็ป
- [x] DB: ตาราง `order_tracking` (append-only) + index (order_id, created_at desc) + RLS — verify ผ่าน
- [x] DB: `orders` เพิ่มคอลัมน์ `return_reason`, `status_detail`
- [x] DB: RPC `app_save_order_tracking` (atomic: diff สถานะ+โน้ต, บังคับเหตุผล server-side, log timeline+audit) — verify negatives+happy+clear-on-exit ผ่านใน tx/rollback
- [x] DB: RPC `app_get_order_tracking` (ดึงไทม์ไลน์ lazy)
- [x] DB: แก้ `get_orders` เพิ่ม seller_code, seller_name, return_reason, status_detail
- [x] FE: types.ts + api.ts (ฟิลด์ใหม่ + saveOrderTracking + getOrderTracking)
- [x] FE: inline edit — ดินสอ ✏ บน badge จัดส่ง/ชำระ → popup เลือก → ยืนยัน (ตีกลับ/มีปัญหา → เด้ง sidebar + เลื่อนไปการ์ดแก้ไข)
- [x] FE: คอลัมน์ "อัพเดต" (sticky ขวา) + ปุ่มเปิด sidebar
- [x] FE: sidebar — การ์ดข้อมูล(กริด+ยอดขายสีตามสถานะ+เบอร์มีขีด+KEXลิงก์) · บันทึกติดตาม(โน้ต+ประวัติ) · แก้ไขสถานะ(chip+เหตุผล) · ประวัติเปลี่ยนสถานะ(พับได้) · scroll indicator · ขอบมนซ้าย · ปิด widget+footer มี popup เตือนถ้าแก้ไข · ปุ่มยืนยัน disable อัจฉริยะ
- [x] FE fix: ยอดขายเฉลี่ยต่อวัน หารด้วยวันที่มีข้อมูล (เดิมหาร 31 ผิด)
- [x] verify: เปิดจริงในเบราว์เซอร์ครบ flow + เจ้านายลองเอง หลายรอบ · revert ข้อมูลเทสสะอาด
- [x] deploy: push ขึ้น GitHub (2026-09-01)

### Stage 5.1 — ชิปคำแนะนำ "รายละเอียดปัญหา" + autocomplete — เสร็จ+deploy (2026-09-02)
> สเปก: `Face Advance Monthly orders/docs/specs/2026-09-02-detail-presets-design.md` · commit 35b8891
- [x] DB: ตาราง `tracking_detail_presets` (default catalog) + RPC `app_get_detail_presets` · default 5 คำ
- [x] FE: ชิปคำที่เคยใช้ (default=DB, คำใหม่+ลำดับ+ลบ=localStorage เฉพาะเครื่อง) · กดชิป/ลาก/ลบ(เฉพาะ local)
- [x] FE: ปุ่มลูกศร ‹ › เลื่อนทีละชิป (โผล่เมื่อล้น) · autocomplete แบบ Sheets (ghost+Enter รับ+เลือกชิป)
- [x] FE fix: badge ชิดขวา + ดินสอเรียงตรงเป็นคอลัมน์
- [x] verify: เปิดจริงในเบราว์เซอร์ครบทุกเคส · revert order 219 สะอาด · deploy ผ่าน (Actions success)

### Stage 6 — Auth: LINE OTP รายบุคคล + role + session + OTP-fail alert — เสร็จ (2026-09-02)
> สเปก: `Face Advance Monthly orders/docs/specs/2026-09-02-auth-lineotp-roles-design.md`
- [x] DB: app_users +line_user_id/role/session_hours/idle_minutes · auth_login_tickets +otp
- [x] RPC: login(คืน line_id) · verify(session ต่อ user + role + alert ผิด≥2หลัก/≥2ครั้ง) · session_uid(idle ต่อ user) · get_orders(role) · save(reject viewer) — verify tx/rollback ผ่าน
- [x] Edge Function `auth` v4: OTP push รายบุคคล (fallback กลุ่ม) + flex เตือนกลุ่มเมื่อ OTP ผิด
- [x] FE: viewer gating (เตือน "ไม่มีสิทธิ์แก้ไขข้อมูล" + บล็อก sidebar/นำเข้า) · เก็บ role · ลบข้อความ 2FA หน้า login
- [x] บัญชี: aom(line_id) · friday(editor 24h/1440m) · plug(viewer) — bcrypt
- [ ] **boss ทดสอบล็อกอินจริง** (OTP เข้า LINE รายบุคคล) — หลัง deploy · ต้องแอดบอทเป็นเพื่อนก่อน

### Stage 7 — Reconciliation (COD รับเงิน + ตีกลับถึงแล้ว) — backend live · FE ยังไม่ deploy (2026-09-03)
> สเปก: `Face Advance Monthly orders/docs/specs/2026-09-02-reconciliation-cod-returns-design.md` · รายละเอียดใน HANDOFF.md
- [x] DB: ตาราง recon_returns/recon_cod_payments + orders.recon_conflict + reconcile engine & triggers (2 ทาง) + COD payment lock (server) + get_orders recon fields — verify tx/rollback ผ่าน
- [x] FE (uncommitted): COD payment ไม่มีไอคอน(กันที่ว่าง) · ถึงแล้วเขียว · ขัดแย้ง=สามเหลี่ยมทึบ+ไฮไลต์ · หมายเหตุ toggle · modal เมนู 2 ประเภท — verify เบราว์เซอร์ครบ
- [x] **COD Excel upload + ตรวจก่อนนำเข้า** — เสร็จ+verify (2026-09-03) · template + Google Sheet · block(ซ้ำ/ไม่พบ/โอนเงิน/แทร็คว่าง/ได้รับจากผิด) · ยอดไม่ตรง→เลือกแก้/error · ด่านหลักฐาน(Storage+EdgeFn cod-upload) · badge error · สเปก `docs/specs/2026-09-03-cod-upload-validation-design.md`
- [ ] **ตีกลับถึงแล้ว** = กรอง+บันทึกผ่านระบบ (เฟสถัดๆ)
- [ ] deploy FE Stage 7 + COD เมื่อ boss สั่ง (+ ลบไฟล์ทดสอบใน bucket cod-evidence)

## แจ้ง LINE ตอน build stage เสร็จ (boss confirm แล้ว)
