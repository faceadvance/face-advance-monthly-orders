-- เพิ่มบันทึกตีกลับที่ไม่มีในไฟล์: HIST2602-00215 · แทร็ค 7028021315042626
-- ของกลับมาแล้วแต่ไม่มีบันทึก · วันที่อ้างจากหมายเหตุในออเดอร์เอง: "น้องไอซ์แจ้งว่ากลับมาแล้วครับ วันที่ 20/2"
--
-- ทำไมต้องเข้าทาง DB ไม่ใช่หน้าเว็บ:
--   1. app_save_returns บังคับ photo_url (ต้องเป็น http · ห้ามซ้ำกับที่เคยใช้) — รายการนี้ไม่มีรูป
--   2. app_save_returns ไม่รับวันที่ → recorded_at = now() → รอบค่าคอมจะไปตกเดือนปัจจุบัน ไม่ใช่ ก.พ.
--
-- ⚠️ เปลี่ยน :nodeduct ก่อนรัน (false = หักยอด · true = ไม่หักยอด)

begin;

drop table if exists public._bak_ret_one_20260917;
create table public._bak_ret_one_20260917 as
select o.id as order_id, o.order_no, o.delivery_status, o.payment_status,
       o.return_arrived, o.return_reason, o.recon_conflict, o.updated_at
from public.orders o where btrim(o.tracking_no) = '7028021315042626';

insert into public.recon_returns
  (tracking_out, tracking_return, inspection_result, damage_detail, no_deduct, photo_url, recorded_at)
values
  ('7028021315042626',
   '7028021315042626',                 -- ไม่มีเลขแทร็คตีกลับ → ใช้เลขส่งออก (แบบเดียวกับชีต F)
   'สินค้าครบ ไม่เสียหาย',                 -- ไม่มีผลตรวจ → ตามกฎเดิมของเจ้านาย (ผลตรวจว่าง = ครบ ไม่เสียหาย)
   null,                               -- CHECK ไม่บังคับเมื่อผลตรวจ = ครบ ไม่เสียหาย
   :nodeduct,
   null,                               -- ไม่มีรูป → EDITH แสดง "— ไม่มีรูป"
   '2026-02-20 00:00+07'::timestamptz  -- รอบค่าคอม ก.พ. 2026 (วันที่ 20 < 26)
  );

-- ที่มาของข้อมูลต้องตามได้ เพราะไม่มีรูป/แทร็คตีกลับเป็นหลักฐาน
insert into public.order_tracking(order_id, entry_type, note, created_by_name)
select o.id, 'note',
       'นำเข้าย้อนหลัง: ไม่มีบันทึกตีกลับในไฟล์ · อ้างวันที่ 20/2/2026 จากหมายเหตุในออเดอร์ · ไม่มีรูป/เลขแทร็คตีกลับ',
       'ระบบ'
from public.orders o where btrim(o.tracking_no) = '7028021315042626';

-- ตรวจผลก่อน commit
do $$
declare o record;
begin
  select delivery_status, payment_status, return_arrived into o
  from public.orders where btrim(tracking_no) = '7028021315042626';
  raise notice 'หลังนำเข้า: จัดส่ง=% · ชำระ=% · ถึงแล้ว=%', o.delivery_status, o.payment_status, o.return_arrived;
  if o.delivery_status <> 'ตีกลับ' or o.payment_status <> 'ยกเลิก' or not o.return_arrived then
    raise exception 'ผลไม่เป็นไปตามที่คาด — ยกเลิก';
  end if;
end $$;

commit;
