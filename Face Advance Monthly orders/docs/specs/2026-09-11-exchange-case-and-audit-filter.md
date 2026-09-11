# Spec: เคสแลกเปลี่ยนสินค้า (COD จ่ายแล้ว + ของกลับมา) + Audit log filter

วันที่ 2026-09-11 · โปรเจกต์ Face Advance Monthly orders (ระบบ MO) · สถานะ: อนุมัติแล้ว

## ปัญหา
ออเดอร์ COD ที่ส่งสำเร็จ+รับเงินแล้ว แต่ลูกค้าส่งของกลับมา "เปลี่ยน" (แลกเปลี่ยน) →
มีทั้ง recon_cod + recon_returns → reconcile ตี `recon_conflict=true` → EDITH มีให้เลือกแค่
**ลบ COD** หรือ **ลบตีกลับ** ซึ่งไม่ตรงเคสนี้ (เงินควรเก็บไว้ + มีของกลับมาจริง)

## หลักการที่ตกลง
- **ของที่ส่งไปแทน = ออเดอร์ใหม่แยกต่างหาก** (นอกขอบเขต spec นี้)
- ออเดอร์เดิม (เคสแลกเปลี่ยน) = `ส่งสำเร็จ + ชำระแล้ว + ถึงแล้ว` · นับเป็น **ยอดขายสำเร็จ**
- **ไม่ auto** — ทุกเคส COD+ตีกลับ ต้องเข้า EDITH ให้คนตรวจ + เลือกเอง (reconcile ไม่แก้)

## A. เคสแลกเปลี่ยน

### A1. reconcile_order — ไม่แก้
COD+ตีกลับ → conflict เข้า EDITH เหมือนเดิม (คนตัดสินเอง)

### A2. EDITH (recon detail) — edith.ts `reconResolver`
- **โชว์ "ลงตีกลับแบบไหน"** ในการ์ด "รายการตีกลับถึง": `หักยอด` / `ไม่หักยอด` (จาก `ret.no_deduct` ที่ RPC ส่งมาแล้ว)
- **เพิ่มปุ่มที่ 3: "ปรับเป็นถึงแล้ว (แลกเปลี่ยน)"** → เรียก RPC `app_edith_exchange`

### A3. RPC ใหม่ `app_edith_exchange(p_token, p_order_id)`
- auth: role Adm · SECURITY DEFINER · grant anon
- ตั้ง `recon_returns.no_deduct = true` (record ตีกลับของ tracking นี้)
- ตั้ง order: `delivery_status='ส่งสำเร็จ'`, `payment_status='ชำระแล้ว'`, `return_arrived=true`, `recon_conflict=false`
- log order_tracking: delivery_change/payment_change (เฉพาะที่เปลี่ยน) + note "แลกเปลี่ยน: เก็บเงิน + รับของคืน (ไม่หักยอด)"
- audit_log event `edith_exchange`
- **ไม่ลบ record ใดๆ** (เก็บทั้ง COD + ตีกลับ)

### A4. KPI — main.ts
ยอดตีกลับถึงแล้ว (`returned_amount`) เปลี่ยนจาก `return_arrived` เป็น
**`return_arrived && delivery_status==='ตีกลับ'`** (ทั้ง kpi + daily)
→ เคสแลกเปลี่ยน (delivery=ส่งสำเร็จ) หลุดออกจากยอดตีกลับเอง
→ **ค่าปัจจุบันไม่เปลี่ยน** (วันนี้ return_arrived มากับ delivery=ตีกลับ เสมอ)

## B. Audit log filter (EDITH) — edith.ts + app_edith_log
- เพิ่มตัวเลือกช่วงเวลา **"กำหนดเอง (from–to)"** (คง preset 1ชม./วันนี้/7วัน/ทั้งหมด ไว้)
- backend `app_edith_log` เพิ่มรับพารามิเตอร์ `to` (มี `from` แล้ว)
- User filter คงไว้ (มีอยู่แล้ว)

## ไฟล์ที่แตะ
- DB: RPC ใหม่ `app_edith_exchange` · แก้ `app_edith_log` (รับ `to`)
- `edith.ts`: reconResolver (โชว์ type + ปุ่ม 3) · log filter (custom range)
- `main.ts`: KPI 1 บรรทัด (kpi + daily)
- `api.ts`: `edithExchange()` · `fetchEdithLog` เพิ่ม `to`

## เทส (local)
- แลกเปลี่ยนบนข้อมูลเทส (ไม่แตะข้อมูลจริง): กดปุ่ม → ออเดอร์เป็น ส่งสำเร็จ+ชำระแล้ว+ถึงแล้ว + no_deduct + conflict หาย + log ครบ
- KPI: เคสแลกเปลี่ยนไม่โผล่ในยอดตีกลับ · ค่าเดิมไม่เปลี่ยน
- Audit log: เลือกช่วง from–to เอง + เลือก user → กรองถูก

## Non-goals
- ไม่สร้าง/ผูกออเดอร์ใหม่ (ของที่ส่งแทน) · ไม่ auto-resolve · ไม่แตะ reconcile logic
