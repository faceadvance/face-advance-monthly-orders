# Design — MO Reconciliation: COD รับเงิน + ตีกลับถึงแล้ว (จับคู่แทร็ค → อัปเดตสถานะอัตโนมัติ)

วันที่: 2026-09-02 · แตะ orders + auto payment/delivery — ระวังชนกัน

## แนวคิด
มีตาราง "รายการกระทบยอด" (reconcile) 2 ชุด · เมื่อ **เลขแทร็คส่งออกของออเดอร์** ตรงกับแทร็คในตาราง → ระบบอัปเดตสถานะออเดอร์อัตโนมัติ + log

## ตาราง reconcile
### A. `recon_returns` (ตีกลับถึงแล้ว)
`วันที่บันทึก(recorded_at) · เลขแทร็คส่งออก(tracking_out) · เลขแทร็คตีกลับ(tracking_return) · ผลการตรวจสอบ(inspection_result)`
- inspection_result (4): `สินค้าครบ ไม่เสียหาย` / `สินค้าเสียหาย` / `สินค้าไม่ครบ` / `สินค้าไม่ครบและเสียหาย`
- 🔵 **อัปโหลดรายการตีกลับ = เฟสหน้า** (เฟสนี้ทำแค่ตาราง + reconcile engine · ใส่ข้อมูลทดสอบด้วยมือ)

### B. `recon_cod_payments` (COD รับเงินแล้ว)
คอลัมน์: `วันที่(recorded_at) · หมายเลขพัสดุ(tracking_out) · จำนวนเงิน(amount) · ได้รับจาก(received_from) · หมายเหตุ(note) · ที่มา(source)`
- **received_from** (3 ตัวเลือก): `ขนส่ง` / `ระบบ` / `ทำเคลม` — เป็น dropdown ในชีต (per แถว)
- **ที่มาของค่าตอน import:**
  - จากชีต Excel (per แถว): หมายเลขพัสดุ, จำนวนเงิน, ได้รับจาก, หมายเหตุ · (วันที่ optional)
  - จากหน้าอัปโหลด (ทั้ง batch): **ที่มา(source)** ใส่ครั้งเดียว ใช้กับทุกแถว
  - **วันที่** = auto (= เวลาอัปโหลด) ถ้าชีตไม่มี
- อัปโหลด Excel → preflight วิเคราะห์ (แมตช์แทร็ค/ไม่พบ/ซ้ำ/amount) — รายละเอียด validation คุยตอนทำ upload UI

ทั้งคู่: `id, tracking_out (index), created_by, created_at`

## กฎ reconcile (idempotent, แมตช์ด้วย tracking_out = orders.tracking_no)
สำหรับออเดอร์หนึ่ง (COD = payment_method='เก็บเงินปลายทาง'):
1. **แมตช์ทั้ง returns และ cod_payments (ซ้ำ)** → `recon_conflict=true` · **ไม่เปลี่ยน payment อัตโนมัติ** · log 'recon_conflict' · โชว์ ⚠️ ในตารางให้คนตรวจ+แก้มือ
2. **แมตช์ returns อย่างเดียว** → `delivery_status='ตีกลับ'` + `return_arrived=true` + `payment_status='ยกเลิก'` + เก็บ inspection_result · log ระบบ 'recon_return_arrived'
3. **แมตช์ cod_payments อย่างเดียว** (และเป็น COD) → `payment_status='ชำระแล้ว'` · log ระบบ 'recon_cod_paid'
4. ไม่แมตช์ → ไม่ทำอะไร

**แมตช์ 2 ทาง:** รัน reconcile เมื่อ (ก) เพิ่มรายการ reconcile · (ข) นำเข้าออเดอร์ใหม่ (Stage 2)

## COD payment ล็อกแก้มือ (เพิ่มจากเฟสนี้)
- ออเดอร์ COD: **payment แก้มือไม่ได้** — เฉพาะระบบ (reconcile) เปลี่ยน · UI ปิด chip/ดินสอ payment (เตือน) + **บล็อกฝั่ง server** (app_save_order_tracking reject ถ้าจะเปลี่ยน payment ของ COD ด้วยมือ)
- โอนเงิน: payment แก้มือได้ตามเดิม · delivery แก้มือได้ทั้งคู่

## orders +คอลัมน์
- `recon_conflict boolean default false` (ธงขัดแย้ง)
- (แสดง "ตีกลับถึงแล้ว" จาก return_arrived · inspection จาก join recon_returns)

## get_orders
- คืน `return_arrived` (มีแล้ว) + `inspection_result` (join) + `recon_conflict`

## Frontend
- คอลัมน์/แบดจ์ "ตีกลับถึงแล้ว" + ผลการตรวจสอบ · ⚠️ ขัดแย้ง สำหรับ recon_conflict
- COD: payment แก้ไม่ได้ (เตือน "สถานะชำระของ COD ระบบจัดการอัตโนมัติ")
- COD upload UI (เฟสนี้ · รายละเอียดคุยทีหลัง)

## ยังไม่ทำ / เฟสหน้า
- อัปโหลดรายการ **ตีกลับ** (return upload) = เฟสหน้า
- auto-revert เมื่อลบรายการ reconcile · ตรวจ amount vs total_sales

## จุดเสี่ยง (กันบั๊ก)
- normalize tracking (ตัดช่องว่าง) · กันแทร็คว่าง/ซ้ำ · reconcile idempotent (รันซ้ำไม่พัง)
- delivery='ตีกลับ' จาก reconcile: return_reason ตั้งค่าระบบ (เช่น 'ตีกลับถึงแล้ว (ระบบ)') — เลี่ยง constraint/แสดงผลเพี้ยน
- conflict: ไม่แตะ payment เดิม รอ manual
