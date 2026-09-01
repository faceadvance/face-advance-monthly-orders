# สเปก: การบันทึกติดตาม (Order Tracking) — เฟส v2

> เขียน 2026-09-01 · อนุมัติแนวทางแล้ว (เจ้านาย) · ยังไม่เริ่ม implement
> โปรเจกต์: `Face Advance Monthly orders/` · DB: Face Advance DB (`xfayguljywhjwqcuimvw`)
> สถาปัตยกรรม production: static frontend → **Supabase RPC ตรงๆ** (anon key + session token, RPC ตรวจ token ในตัว) แบบเดียวกับ `app_import_orders`

---

## 1. เป้าหมาย

เปลี่ยนหน้าออเดอร์จาก **read-only** เป็น **แก้ไข + ติดตามได้** โดยแก้แบบมีสเต็ปยืนยันทุกครั้ง และเก็บ **ไทม์ไลน์ประวัติ** (โน้ตที่พิมพ์เอง + log การเปลี่ยนสถานะอัตโนมัติ) ต่อออเดอร์ พร้อมรู้ว่า "ใครทำ เมื่อไหร่"

**สิ่งที่แก้ได้ในเฟสนี้:** สถานะจัดส่ง · สถานะชำระเงิน · เพิ่มโน้ตติดตาม
**นอกขอบเขต:** `return_arrived` (ตีกลับถึงแล้ว) — ทำเฟสถัดไป

---

## 2. โครงสร้างข้อมูล (DB)

### 2.1 ตารางใหม่ `order_tracking` (ไทม์ไลน์ append-only)

| คอลัมน์ | ชนิด | หมายเหตุ |
|---|---|---|
| `id` | bigint identity PK | |
| `order_id` | bigint FK→orders | |
| `entry_type` | text CHECK in (`note`,`delivery_change`,`payment_change`) | ชนิดรายการ |
| `note` | text nullable | เนื้อโน้ต (เมื่อ entry_type=note) |
| `old_value` | text nullable | สถานะเดิม (เมื่อ *_change) |
| `new_value` | text nullable | สถานะใหม่ (เมื่อ *_change) |
| `detail` | text nullable | เหตุผลตีกลับ/รายละเอียดปัญหา ที่แนบมากับการเปลี่ยนสถานะ |
| `created_by` | uuid FK→app_users nullable | ผู้ทำ |
| `created_by_name` | text | **snapshot** ชื่อผู้ทำ ณ เวลานั้น (กันชื่อเปลี่ยนย้อนหลัง) |
| `created_at` | timestamptz default now() | |

- **Append-only:** ไม่มี path แก้/ลบจากแอป (โน้ตและ log เป็นประวัติจริง)
- index: `(order_id, created_at desc)` เพื่อดึงไทม์ไลน์เร็ว
- RLS: เปิด (เหมือนตารางอื่น) — เขียน/อ่านผ่าน RPC SECURITY DEFINER เท่านั้น

### 2.2 เพิ่มคอลัมน์ใน `orders` (เก็บสถานะปัจจุบัน)

| คอลัมน์ | ชนิด | หมายเหตุ |
|---|---|---|
| `return_reason` | text nullable | เหตุผลตีกลับ = ตัวเลือก dropdown (categorical, เผื่อทำสถิติภายหลัง) |
| `status_detail` | text nullable | ข้อความเพิ่มเติม: "เนื่องจาก…"/"ระบุเพิ่มเติม…" ของตีกลับ **หรือ** รายละเอียดของ "มีปัญหา" |

- เปลี่ยนสถานะจัดส่ง **ออกจาก** ตีกลับ/มีปัญหา → เคลียร์ `return_reason`+`status_detail` เป็น null (และ log การเปลี่ยน)

### 2.3 เหตุผลตีกลับ (dropdown)

ค่าคงที่ 10 ตัวเลือก (เก็บเป็น label ตรงๆ ใน `return_reason`):
1. ไม่สามารถติดต่อลูกค้าได้
2. ลูกค้าไม่สะดวกรับในรอบการจัดส่ง
3. ลูกค้าไม่ได้สั่ง
4. ลูกค้ายกเลิก เนื่องจาก … *(มีช่องพิมพ์ต่อ → `status_detail`)*
5. ลูกค้าต้องการเปลี่ยนสินค้า
6. ร้านค้าส่งของผิด
7. จัดส่งนานเกินไป
8. ขนส่งบริการไม่ดี
9. ขนส่งไม่นำส่งให้ลูกค้า
10. อื่นๆ ระบุเพิ่มเติม … *(มีช่องพิมพ์ต่อ → `status_detail`)*

---

## 3. UI — แก้ inline ในตาราง

คอลัมน์ **สถานะจัดส่ง** และ **สถานะชำระ** แต่ละ badge มีไอคอน **ดินสอ ✏** (ต่างจากสามเหลี่ยมขยายแถวที่ขอบขวา)

flow:
1. กด ✏ → **popup** เลือกสถานะอื่น (เฉพาะค่าที่ CHECK อนุญาต) + ปุ่ม **ยืนยัน / ยกเลิก**
2. เลือกสถานะปกติ → กดยืนยัน → เขียน DB + สร้าง 1 รายการไทม์ไลน์ + refresh แถว
3. เลือก **ตีกลับ / มีปัญหา** → **เด้งเปิด sidebar** ให้กรอกเหตุผล (บังคับ) ก่อน แล้วบันทึกจากใน sidebar

---

## 4. UI — Sidebar

เลื่อนเข้าจากขวา · พื้นหลัง (ตาราง) มี overlay ทึบลงเล็กน้อย · **กดนอก sidebar ไม่ปิด** — ปิดได้ด้วยปุ่ม **ปิด** หรือ **ยืนยันบันทึก** เท่านั้น

### 4.1 ส่วนแสดงข้อมูล (อ่านอย่างเดียว)
- ออเดอร์: วันที่ · เบอร์โทร · ชื่อลูกค้า · ที่อยู่ (เต็ม) · รายการสินค้า · ช่องทางชำระ · ยอดขาย · ขนส่ง · เลขแทร็ก · โน้ตเดิม
- **ผู้ขาย:** `sellers.employee_code` (รหัส) + `sellers.name` (ชื่อ) — ถ้า `seller_id` เป็น null → "ไม่ระบุ"
- **สถานะปัจจุบัน + ข้อมูลเพิ่มเติม:** delivery_status, payment_status, และ return_reason/status_detail ถ้ามี
- **ไทม์ไลน์ประวัติติดตาม** (ดูข้อ 5)

### 4.2 ส่วนแก้ไขได้
- **สถานะจัดส่ง** (dropdown ค่าที่อนุญาต)
  - = ตีกลับ → โผล่ dropdown เหตุผล 10 ตัวเลือก **(บังคับ)** · ตัวเลือกที่ 4/10 โผล่ช่องพิมพ์ต่อ
  - = มีปัญหา → โผล่ช่องกรอกรายละเอียด **(บังคับ)**
- **สถานะชำระ** (dropdown ค่าที่อนุญาต)
- **ช่องเพิ่มโน้ตติดตามใหม่** (textarea)
- ปุ่ม **ปิด** (ไม่บันทึก) / **ยืนยันบันทึก** (บันทึกสถานะ+โน้ตพร้อมกัน atomic)

> กรอกเฉยๆ ไม่เกิดการบันทึก — ต้องกดยืนยันเท่านั้น

---

## 5. ไทม์ไลน์

- รวมโน้ต + log เปลี่ยนสถานะ เรียง **ใหม่→เก่า**
- รูปแบบแต่ละรายการ:
  ```
  1/9/2026 - 14:30  ·  <ชื่อผู้ทำ>
  <เนื้อหาขึ้นบรรทัดใหม่>
  ```
  - note → เนื้อหา = ข้อความโน้ต
  - delivery_change/payment_change → เนื้อหา = "สถานะจัดส่ง: ส่งแล้ว → ตีกลับ (เหตุผล: …)"
- append-only (แก้/ลบไม่ได้)

---

## 6. Backend (RPC — SECURITY DEFINER, ตรวจ session token ในตัว)

### `app_save_order_tracking(p_token, p_order_id, p_delivery_status, p_payment_status, p_return_reason, p_status_detail, p_note)`
บันทึกการแก้แบบ **atomic** ในทรานแซกชันเดียว:
1. ตรวจ token → ได้ user (id, display_name); ไม่ผ่าน → `{authorized:false}`
2. โหลดออเดอร์ปัจจุบัน; ไม่พบ → error
3. เทียบ diff:
   - delivery เปลี่ยน → validate ค่าตาม CHECK · ถ้าใหม่=ตีกลับ → **บังคับ** return_reason (ไม่มี → error) · ถ้าใหม่=มีปัญหา → **บังคับ** status_detail · ถ้าเปลี่ยนออกจากตีกลับ/มีปัญหา → เคลียร์ reason/detail · insert `delivery_change`
   - payment เปลี่ยน → validate · insert `payment_change`
   - note ไม่ว่าง → insert `note`
4. update `orders` (สถานะ + return_reason + status_detail + updated_at)
5. เขียน `audit_log` (security) 1 รายการ event=`order_tracking_save`
6. คืนออเดอร์ที่อัปเดต + ไทม์ไลน์ล่าสุด

> ฝั่ง server **บังคับเหตุผลเอง** ไม่เชื่อ UI อย่างเดียว (กันเรียก RPC ตรง)

### `app_get_order_tracking(p_token, p_order_id)`
คืนไทม์ไลน์ของออเดอร์ (lazy — ดึงตอนเปิด sidebar เท่านั้น ไม่โหลดพร้อม 1008 แถว)

### แก้ `get_orders`
เพิ่มใน payload ต่อออเดอร์: `seller_code`, `seller_name`, `return_reason`, `status_detail`
(ไม่รวมไทม์ไลน์ — โหลด lazy)

---

## 7. กันพัง (defensive)

- server บังคับ return_reason (ตีกลับ) / status_detail (มีปัญหา) — reject ถ้าขาด
- validate ค่าสถานะตาม CHECK ก่อนเขียน (กันค่านอกชุด)
- เปลี่ยนออกจากตีกลับ/มีปัญหา → ล้าง reason/detail + log
- `created_by_name` เก็บ snapshot กันชื่อผู้ใช้เปลี่ยนย้อนหลัง
- token หมดอายุ/ผิด → `{authorized:false}` (frontend เด้ง lock เหมือนเดิม)
- โน้ตว่าง/ช่องว่างล้วน → ไม่สร้าง entry note
- เปิด sidebar ออเดอร์ที่ถูกลบ/ไม่พบ → error ชัด ไม่พังเงียบ
- ยืนยันโดยไม่มีอะไรเปลี่ยน (ไม่ diff, ไม่โน้ต) → no-op ไม่สร้าง entry ขยะ

---

## 8. นอกขอบเขตเฟสนี้
- `return_arrived` (ตีกลับถึงแล้ว) — เฟสถัดไป
- แก้ฟิลด์อื่น (ขนส่ง/เลขแทร็ก/ที่อยู่/ชื่อ) — ยังไม่ทำ
- แก้/ลบโน้ตย้อนหลัง — ตั้งใจไม่ทำ (append-only)
