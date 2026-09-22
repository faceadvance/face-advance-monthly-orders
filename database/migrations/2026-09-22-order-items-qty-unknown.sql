-- 2026-09-22 · order_items.quantity: ยอมรับ 0 = "ไม่ทราบจำนวน"
--
-- เจ้านายเคาะ: ไฟล์ย้อนหลังปี 2025 เดือน ก.ย./ต.ค. เขียนจำนวนสินค้าเป็น '-' อ่านไม่ได้ 2,493 แถว
--   (3,814 บรรทัดสินค้า · ยอดขายรวม 3,708,566 บาท)
--   "ถ้าจำนวนสินค้าไม่สามารถระบุได้ เราใส่เป็น 0 หรือ ไม่มีข้อมูล ได้ไหม? รู้แค่ว่าสั่งอะไร
--    แต่จำนวนเท่าไหร่ไม่รู้ ได้ไม่เป็นไร"
--
-- 🔴 ทำไมใช้ 0 ไม่ใช่ NULL:
--    มี 10 ฟังก์ชันที่ต่อสตริง `ชื่อสินค้า || ' ×' || quantity` — get_orders · app_search_orders ·
--    app_returns_list · app_lookup_return_tracking · app_edith_error_detail · app_edith_recon_detail ·
--    app_edith_conflict_detail · app_edith_noseller_detail · app_import_orders · app_save_returns
--    ต่อสตริงกับ NULL ใน Postgres ได้ NULL แล้ว string_agg จะทิ้งทั้งบรรทัด
--    → บรรทัดสินค้าหายไปจากหน้าออเดอร์/ค้นหา/ตีกลับ/ปุ่มคัดลอก แบบไม่มีอะไรบอก
--    (บทเรียนนี้เกิดจริงแล้ววันนี้: app_edith_set_seller เขียน detail หายทั้งช่อง เพราะชื่อเซลเป็น NULL)
--
-- ✅ 0 เป็นเครื่องหมายที่บอกตัวเองได้: CHECK เดิมห้าม 0 มาตลอด และข้อมูลที่มีอยู่ต่ำสุด = 1
--    ฉะนั้นทุกแถวที่เป็น 0 แปลว่า "มาจากนำเข้าย้อนหลังที่ไฟล์ไม่มีจำนวน" เท่านั้น
--    ตามรอยได้ตลอดด้วย: select * from order_items where quantity = 0
--
-- ⚠️ ผลข้างเคียงที่ยอมรับ: ใครรวมจำนวนสินค้าเพื่อดู "ขายไปกี่ชิ้น" จะได้ตัวเลขต่ำกว่าจริง
--    ยอดขาย/การเงินไม่กระทบ เพราะเก็บที่ orders.total_sales ไม่ได้คำนวณจากจำนวน
--    งานที่ต้องทำต่อ (ตอนนำเข้าจริง): ให้ 10 ฟังก์ชันแสดง '×?' แทน '×0'

alter table public.order_items drop constraint if exists order_items_quantity_chk;
alter table public.order_items add constraint order_items_quantity_chk check (quantity >= 0);

comment on column public.order_items.quantity is
  '0 = ไม่ทราบจำนวน (นำเข้าย้อนหลังจากไฟล์ที่เขียนจำนวนเป็น ''-'' เช่น ก.ย./ต.ค. 2025) — ค่าปกติเริ่มที่ 1';
