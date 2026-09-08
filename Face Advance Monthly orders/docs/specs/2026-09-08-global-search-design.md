# หน้า "ค้นหา" (Global Search) — Design

> Stage 9c · 2026-09-08 · หน้าที่ 5 ของระบบ MO · utility ค้นหาออเดอร์/ตีกลับข้ามรอบเดือน

## เป้าหมาย
ค้นหาออเดอร์/ตีกลับได้ทั้งระบบ (ข้ามขอบเขตรอบเดือน) จาก 4 ฟิลด์ · แสดงผลได้ 2 มุมมอง · เคารพสิทธิ์ทีม

## 1. การเข้าถึง
- ทุก role ที่ดูข้อมูลได้: **Adm / OM / Vm / RT+ / RTs**
- ผลลัพธ์กรองตามสิทธิ์แต่ละคน: Adm/Vm/RT+/all_teams → ทุกทีม · RTs → ทีมตัวเอง (`app_user_teams`) · OM → ทุกออเดอร์ (ไม่ผูกทีม)
- เพิ่มใน `pages.ts` เป็น page `search` · ROLE_PAGES ทุก role · ไอคอนแว่นขยาย

## 2. ช่องค้นหา
- ค้น **4 ฟิลด์เท่านั้น**: `phone` · `customer_name` · `address`(concat addr_detail+ตำบล+อำเภอ+จังหวัด+ไปรษณีย์) · `tracking_no`(แทร็คส่งออก)
- match แบบ `ilike '%q%'` (case-insensitive) · ขั้นต่ำ 2 ตัวอักษร · debounce ~300ms
- คีย์ลัด `/` โฟกัส · `Esc` ล้าง · Enter ยิงทันที
- **ค้นล่าสุด** (recent · localStorage) กดซ้ำได้

## 3. สองมุมมอง (toggle · ค้นครั้งเดียว สลับ view)
| มุมมอง | dataset | คอลัมน์ |
|---|---|---|
| **แบบออเดอร์** | ทุกออเดอร์ที่ match (ทุกสถานะ) · ไม่มีเดือน | เหมือนหน้า order |
| **แบบหักยอดตีกลับ** | ออเดอร์ที่ match ที่เป็น "ตีกลับ" (มี recon_returns) · **ทุกใบ ทั้งหักยอด+ไม่หักยอด** | เหมือนโหมดหักยอด + คอลัมน์ **"รอบเดือน"** (หักยอดในรอบไหน) + badge "ไม่หักยอด" |
- **ไม่มีการ์ด/ตัวเลือกเดือน** · มีแถบ "พบ X รายการ · ค้นด้วย '...' (ตรงกับ เบอร์/ชื่อ/ที่อยู่/แทร็ค)"
- **ไฮไลต์คำที่ match** ในผลลัพธ์ · **ป้ายบอกฟิลด์ที่ตรง**
- **จัดกลุ่มตามลูกค้า** เมื่อผลมาจากเบอร์/ชื่อ (1 ลูกค้าหลายออเดอร์) → หัวกลุ่ม ชื่อ+จำนวน (optional เฟสปรับ)

## 4. คลิกผล → drawer รายละเอียด (read-only · อยู่ในหน้าค้นหา)
- เปิดแผงข้างขวา: ข้อมูลออเดอร์ (ลูกค้า/เบอร์/ที่อยู่/สินค้า/ยอด/ขนส่ง/แทร็ค) + สถานะ (จัดส่ง/ชำระ) + ข้อมูลตีกลับ (ผลตรวจ/วันตีกลับถึง/หักยอด/รอบ) + **timeline** (ผ่าน `app_get_order_tracking`)
- **read-only** (ดูอย่างเดียว — ไม่แก้ในหน้าค้นหา) · ปิด drawer กลับผลค้นหา

## 5. Backend
- RPC ใหม่ `app_search_orders(p_token text, p_query text, p_view text)` (SECURITY DEFINER)
  - gate: role in (Adm,OM,Vm,RT+,RTs) · v_all/v_teams scope เหมือน app_returns_list
  - guard: `length(btrim(q)) < 2` → คืน `{ok:true, rows:[], too_short:true}`
  - match 4 ฟิลด์ · คืน `matched_fields` ต่อแถว (badge) · limit 300 + count
  - `p_view='order'` → ออเดอร์ที่ match (คอลัมน์แบบ order)
  - `p_view='deduct'` → ออเดอร์ที่ match ที่ delivery='ตีกลับ' หรือมี recon_returns · +cycle label (หักยอดรอบไหน · จาก recorded_at 26–25) + no_deduct
- ใช้ `app_get_order_tracking` เดิมสำหรับ drawer timeline

## 6. แผน slice
1. **DB:** `app_search_orders` + verify (rollback · ทุก role/scope · match แต่ละฟิลด์ · too_short)
2. **FE:** หน้า `search.ts` (input+debounce+recent · toggle 2 view · ตาราง reuse คอลัมน์ order/deduct · badge+highlight · drawer read-only) · api.ts + main.ts + pages.ts + ไอคอน
3. verify E2E ทุก role · deploy พร้อม EDITH

## หมายเหตุ
- ค้นข้ามรอบเดือน = ไม่มี month scope · แต่ scope ทีม/สิทธิ์ยังบังคับ
- reuse ลอจิก/คอลัมน์จาก returns_list.ts + main.ts ให้ตรงกัน (ชื่อ/ความกว้าง/badge)
