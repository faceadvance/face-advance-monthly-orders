# สถานะชำระ "บางส่วน" — Implementation Plan

> ทำตามสเปก `2026-09-23-partial-payment-design.md` (เจ้านายเคาะแล้ว) · ฟรายเดย์ลงมือเอง (inline) · checkbox ติดตามงาน

**Goal:** เพิ่มสถานะชำระ `บางส่วน` + ช่องยอดที่รับจริง ให้เคสได้เงินไม่เต็ม (เช่น เงินเคลมขนส่ง) ไม่ถูกระบบตั้งเป็น `error`

**Architecture:** DB เป็นตัวตัดสิน — CHECK + trigger กันข้อมูลไม่สอดคล้อง, `reconcile_order` / `app_import_cod_payments` รู้จักบางส่วน, ทุกที่ที่นับเงินนับบางส่วน = ชำระแล้ว · หน้าเว็บ: ตัวช่วยกลาง `src/payment.ts` + sidebar + กล่องยืนยันตอนนำเข้า COD

**Tech Stack:** Postgres (Supabase) plpgsql · TypeScript + Vite · node:test

## กติกา (จากสเปก)
1. `บางส่วน` ใช้ได้เฉพาะ `delivery_status = มีปัญหา` · ต้องมี `paid_amount` > 0 และ < `total_sales`
2. นับเงินเหมือน `ชำระแล้ว` เต็มจำนวนทุกที่ (แดชบอร์ด · การ์ด · หน้าค้นหา)
3. `paid_amount` โชว์เฉพาะ sidebar ตอนสถานะเป็นบางส่วน · ไม่โชว์ในตาราง
4. โอนเงิน: คนกรอกยอดเองตอนตั้งบางส่วน · COD: แก้สถานะมือไม่ได้เหมือนเดิม ระบบใส่ให้ตอนบันทึก/นำเข้าเงินเข้า
5. นำเข้า COD: `ได้รับจาก = ทำเคลม` และยอด < ยอดขาย → ต้องยืนยัน · **ไม่ยืนยัน = ไม่บันทึกอะไรเลยทั้งไฟล์** (บันทึกมือก็เหมือนกัน) · ขนส่ง/ระบบ ยอดไม่ตรง → error เหมือนเดิม

## ไฟล์
- Create: `database/migrations/2026-09-24-partial-payment.sql`
- Create: `frontend/src/payment.ts` · `frontend/tests/payment.test.ts`
- Modify: `frontend/src/util.ts` (badge) · `frontend/src/main.ts` (PAYMENT_STATUSES · การ์ด · sidebar · นำเข้า COD · บันทึก COD มือ) · `frontend/src/api.ts` (paid_amount · p_confirm_partial · partials) · `frontend/src/types.ts` · `frontend/src/search.ts` (การ์ด)

---

### Task 1: DB migration (เข้ากันได้กับเว็บตัวเก่า — ขึ้นก่อนหน้าเว็บได้)
- [x] `orders.paid_amount numeric(12,2)` + CHECK `payment_status` เพิ่ม `บางส่วน` + CHECK `orders_paid_amount_chk`:
  `(payment_status = 'บางส่วน') = (paid_amount is not null) and (paid_amount is null or (paid_amount > 0 and paid_amount < total_sales))`
- [x] trigger `orders_clear_paid_amount` (BEFORE UPDATE): `payment_status <> 'บางส่วน'` → `paid_amount := null` — ทุกฟังก์ชันที่เปลี่ยนสถานะชำระ (EDITH/revert/exchange ฯลฯ) ไม่ต้องไล่แก้ทีละตัว
- [x] `is_paid_status(text)` = `in ('ชำระแล้ว','บางส่วน')` (immutable parallel safe)
- [x] `app_sales_dashboard`: `pay in ('ชำระแล้ว','รอชำระ')` → เพิ่ม `บางส่วน` · `pay = 'ชำระแล้ว'` → `pay in ('ชำระแล้ว','บางส่วน')` (แทนข้อความใน body เดิม แล้วนับว่าแทนครบ)
- [x] `get_orders`: เพิ่ม `'paid_amount', o.paid_amount`
- [x] `app_save_order_tracking`: เพิ่ม `p_paid_amount numeric default null` (ลบตัวเก่า 7 พารามิเตอร์) · valid เพิ่ม `บางส่วน` · error ใหม่ `partial_needs_problem` · `bad_paid_amount` · timeline `payment_change.detail` = `รับจริง ฿X จาก ฿Y`
- [x] `reconcile_order`: ขัดแย้งตีกลับนับ `บางส่วน` = จ่ายแล้ว · COD: ยอดตรง → ชำระแล้ว · `บางส่วน` + เงินเข้าล่าสุดเป็น `ทำเคลม` และ < ยอดขาย → คงบางส่วน (paid_amount = ยอดนั้น) · อื่นๆ → error
- [x] `app_import_cod_payments`: เพิ่ม `p_confirm_partial boolean default false` (ลบตัวเก่า) · คืน `partials` · confirm ที่มี partials แต่ไม่ยืนยัน → `ok:false, error:'partial_unconfirmed'` ไม่บันทึกอะไร · ยืนยัน → ออเดอร์นั้น `บางส่วน / มีปัญหา / paid_amount / status_detail 'รับเงินเคลมแล้ว ไม่เต็มจำนวน'` + timeline · คืน `partial` นับจำนวน
- [x] `revert_recon_effects`: baseline สาย COD รวม `บางส่วน`
- [x] **เทส (rollback ทั้งก้อน · ใช้ออเดอร์ MOCK2024 เท่านั้น):** CHECK กันบางส่วนไม่มียอด/ยอด ≥ ยอดขาย · trigger ล้างยอดเมื่อเปลี่ยนสถานะ · reconcile คงบางส่วนเมื่อเงินเคลมน้อยกว่า · ขนส่งยอดไม่ตรง → error · ขัดแย้งตีกลับ
- [x] เรียก RPC แบบเดิม (ไม่ส่งพารามิเตอร์ใหม่) ยังได้

### Task 2: `src/payment.ts` + เทส
- [x] `isPaidStatus(s)` · `PARTIAL = "บางส่วน"` · `validatePartial(amount, total)` → `null` = ผ่าน / ข้อความ error · `partialLabel(paid, total)` = `รับจริง ฿2,000 จาก ฿2,490`
- [x] เทส: ค่าว่าง/0/ติดลบ/เท่ายอด/มากกว่ายอด/ทศนิยม · isPaidStatus ครบทุกสถานะ

### Task 3: badge + การ์ด + หน้าค้นหา
- [x] `paymentBadge("บางส่วน")` → `{cls:"g", icon:"i-coin"}` (เช็คว่ามีไอคอนใน sprite)
- [x] `main.ts` การ์ด KPI + สียอดใน sidebar ใช้ `isPaidStatus` · `search.ts` การ์ดยอดชำระแล้วใช้ `isPaidStatus`

### Task 4: sidebar (โอนเงิน + แสดงผล)
- [x] `PAYMENT_STATUSES` เพิ่ม `บางส่วน` (หลัง ชำระแล้ว)
- [x] เลือกบางส่วน → โชว์ช่อง "ยอดที่รับจริง" (บังคับ · validatePartial) + ถ้าสถานะจัดส่งไม่ใช่มีปัญหา โชว์คำเตือนและปิดปุ่มบันทึก
- [x] การ์ดข้อมูลออเดอร์: สถานะเป็นบางส่วน → แถว "ยอดที่รับจริง ฿X จาก ฿Y"
- [x] COD ล็อก: badge บางส่วน + โน้ต "COD — รับเงินบางส่วน ฿X"
- [x] ส่ง `paid_amount` ไปกับ saveOrderTracking · อัปเดต `o.paid_amount` หลังบันทึก

### Task 5: นำเข้า COD (ไฟล์ + บันทึกมือ)
- [x] preview: มี partials → กล่องสรุปรายการ (แทร็ค · ยอดขาย · ได้รับ)
- [x] กดนำเข้า + มี partials → ถาม "ยืนยันชำระบางส่วน N รายการใช่ไหม" · ใช่ → confirm พร้อม `p_confirm_partial` · ไม่ → **ยกเลิกทั้งไฟล์** ไม่เรียก confirm
- [x] บันทึกมือ: confirm แล้วได้ `partial_unconfirmed` → ถามแบบเดียวกัน · ใช่ → ส่งใหม่พร้อมยืนยัน · ไม่ → เตือน "ยังไม่ได้บันทึกอะไร"

### Task 6: ตรวจ + deploy
- [x] `npm test` · `tsc` · `build` · หน้าทดสอบในเครื่อง (mock RPC) ถ่ายภาพ sidebar + กล่องยืนยัน
- [x] migration ขึ้น DB ก่อน (09:45) → deploy หน้าเว็บ 11:58 → ตรวจบันเดิล · CHANGELOG
