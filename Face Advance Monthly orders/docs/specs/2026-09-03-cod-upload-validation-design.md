# COD Upload + ตรวจสอบก่อนนำเข้า — Design (2026-09-03)

ต่อจาก reconciliation (`2026-09-02-reconciliation-cod-returns-design.md`). อนุมัติโดย boss 2026-09-03.

## เป้าหมาย
พนักงานอัปโหลดไฟล์ "COD รับเงินแล้ว" (.xlsx ตาม template) → ระบบตรวจสอบเข้ม → นำเข้า `recon_cod_payments`
→ reconcile อัปเดตสถานะชำระของออเดอร์อัตโนมัติ (ตรงยอด = ชำระแล้ว, ไม่ตรง = error)

## UI (modal นำเข้า COD)
- **ช่องอัปโหลดไฟล์ = พระเอก** — drop zone ใหญ่บนสุด
- **template (ดาวน์โหลด / Google Sheets) = แถบรองเล็ก** อยู่ล่าง ("ครั้งแรกโหลดไปกรอก")
- **คลิกนอก modal = ไม่ปิด** (กันข้อมูลที่ตรวจแล้วหาย)

## Parser (frontend `import.ts` → `parseCodWorkbook`)
อ่าน 4 คอลัมน์: หมายเลขพัสดุ / จำนวนเงิน / ได้รับจาก / หมายเหตุ ·
header ไม่ตรง template = throw (ไม่ให้ไปต่อ) · ตัดแถวว่าง + แถวตัวอย่าง (`EX...` / "ตัวอย่าง")

## Validation (RPC `app_import_cod_payments`, 2 เฟส preflight/confirm)
Guard: `app_session_uid` + **role = editor** (viewer โดน `forbidden_viewer`)

🔴 **บล็อกทั้งไฟล์** (problems — ถ้ามีข้อใดข้อหนึ่ง confirm ไม่ได้ ต้องแก้ไฟล์อัปใหม่):
1. แถวไม่มีเลขแทร็ค
2. เลขแทร็คซ้ำกันเองในไฟล์
3. เลขแทร็คมีในระบบ COD แล้ว (บันทึกซ้ำ)
4. เลขแทร็คไม่พบในออเดอร์เลย
5. เลขแทร็คตรงกับออเดอร์ที่ **ไม่ใช่ COD** (โอนเงิน) → "ในฐานข้อมูล ออเดอร์นี้ชำระแบบโอนเงิน โปรดตรวจสอบไฟล์"
6. ค่า "ได้รับจาก" ไม่อยู่ใน (ขนส่ง/ระบบ/ทำเคลม)

🟡 **เตือน ไม่บล็อก** (mismatches): `amount` ≠ `orders.total_sales` (รวมยอดว่าง = ถือว่าไม่ตรง)
→ คืน list {tracking, order_no, order_id, order_amount, received_amount, fixable} ·
พนักงานเลือกแก้ทีละรายการ (`p_fix_trackings`) หรือไม่แก้

## Confirm flow
กด "ยืนยันนำเข้า" → **ด่านแนบไฟล์หลักฐาน (บังคับ)** → อัปโหลด Storage (ก้อน 2) → ได้ path →
RPC confirm(`p_source` = path, `p_fix_trackings`):
1. `p_source` ว่าง → `no_evidence` (นำเข้าไม่สำเร็จ)
2. แก้ยอด: ออเดอร์ใน `p_fix_trackings` → `total_sales = received_amount`
3. insert `recon_cod_payments` (source=path, created_by) → trigger reconcile ต่อแถว
4. reconcile เทียบ amount vs total_sales → **ตรง = ชำระแล้ว · ไม่ตรง = error**

## Backend เปลี่ยน
- `orders_payment_status_chk` + `'error'`
- `reconcile_order`: branch COD → ดึง `recon_cod_payments.amount` เทียบ `total_sales` → ชำระแล้ว/error (เดิม set ชำระแล้วเสมอ)
- ใหม่: `app_import_cod_payments(p_token, p_rows, p_mode, p_fix_trackings, p_source)`

## Frontend เปลี่ยน
- `util.ts` `paymentBadge`: + `'error'` → {cls:'w', icon:'i-alert'} · `paymentStatusLabel('error')='Error'`
- `api.ts`: `importCodPayments(...)` + type
- `main.ts`: `showCodImport` (จัดใหม่), `handleCodFile`, `showCodPreview`, ด่านหลักฐาน, `doCodConfirm`; modal no-close-outside

## ลำดับสร้าง
- **ก้อน 1**: UI reorg + parser + preflight + preview + confirm(logic แก้ยอด/insert/status) + reconcile + constraint + badge — verify ครบ (tx/rollback + browser)
- **ก้อน 2**: ด่านหลักฐาน (Supabase Storage bucket `cod-evidence` + Edge Function `cod-upload` ตรวจ session, service role)

## สมมติฐาน
- ยอดเทียบ = `orders.total_sales` · 1 tracking = 1 order (ถ้าซ้ำเลือก id ต่ำสุด) · amount numeric เทียบ `round()` กับ total_sales int

## สถานะ: เสร็จทั้ง 2 ก้อน + verify แล้ว (2026-09-03) — ยังไม่ commit/deploy
- Backend live บน prod: constraint +error · reconcile_order (round เทียบยอด) · RPC `app_import_cod_payments` · bucket `cod-evidence` · Edge Function `cod-upload` (v1, verify_jwt=false)
- Frontend (uncommitted): import.ts `parseCodWorkbook` · api.ts `importCodPayments`/`uploadCodEvidence` · util.ts badge+label `error` · main.ts UI reorg + preview + fix toggle + ด่านหลักฐาน + modal no-close-outside
- verify: tx/rollback (preflight ทุกเคส · confirm match→ชำระแล้ว/mismatch→error/fix→ชำระแล้ว · no_evidence/viewer/bad_token) + browser E2E จริง (อัปโหลด→หลักฐาน→นำเข้า→badge Error ในตาราง) แล้วเคลียร์ DB
- ⚠️ ค้าง: ไฟล์ทดสอบ 2 ไฟล์ใน bucket `cod-evidence` (ลบผ่าน Storage API ไม่ได้เพราะ service key ถูก gate) — ลบผ่าน dashboard ได้

## Fix 2026-09-03 (หลัง boss เทส): หลักฐานชื่อไทย/ทุกชนิด
- **บั๊ก**: อัปโหลดไฟล์ชื่อภาษาไทย → storage `InvalidKey` (key ห้ามมีอักษรไทย) · เดิม `safeName` เก็บ ก-๙ ไว้ → พัง (png ascii เลยผ่าน)
- **แก้**: EdgeFn `cod-upload` v2 — `safeName` เป็น ASCII-only (ตัดไทย/อักขระเสี่ยง เหลือ [A-Za-z0-9._-], ว่าง→"file") · content-type fallback octet-stream
- **boss request**: รับหลักฐานทุกชนิด → ถอด mime allowlist ทั้ง EdgeFn และ bucket (`allowed_mime_types=null`) · FE ถอด accept · เช็คแค่ไม่ว่าง + ≤10MB · verify: xlsx ชื่อไทยอัปโหลดผ่าน 200
