-- นำเข้าบันทึกตีกลับย้อนหลัง ม.ค.–ส.ค. 2026 · 1,785 แถว จาก public._stg_ret_final
-- ต้องรัน build_final.sql และ migrations/2026-09-17-recon-paid-conflict.sql มาก่อน
--
-- ให้ trigger reconcile ทำงานตามปกติ (ไม่ set app.skip_reconcile) เพราะเราต้องการผลข้างเคียงครบ:
--   • ตีกลับ + รอชำระ        → delivery=ตีกลับ · payment=ยกเลิก · return_arrived=true
--   • ตีกลับ + รับเงินแล้ว    → recon_conflict=true (เข้า EDITH ให้คนตัดสิน)
-- recorded_at = วันที่ของถึงบริษัท → รอบค่าคอมย้อนหลังคิดถูกต้อง (ตัดวันที่ 26)

begin;
set local statement_timeout = 0;

-- ═══ backup สถานะออเดอร์ "ก่อน" นำเข้า (rollback ได้) ═══
drop table if exists public._bak_ret_hist_20260917;
create table public._bak_ret_hist_20260917 as
select o.id as order_id, o.order_no, o.delivery_status, o.payment_status,
       o.return_arrived, o.return_reason, o.recon_conflict, o.updated_at,
       f.src_row, f.tracking_out
from public._stg_ret_final f
join public.orders o on btrim(o.tracking_no) = f.tracking_out;

-- ═══ นำเข้า ═══
insert into public.recon_returns
  (tracking_out, tracking_return, inspection_result, damage_detail, no_deduct, photo_url, recorded_at)
select f.tracking_out, f.tracking_return, f.inspection_result, f.damage_detail,
       f.no_deduct, f.photo_url, f.recorded_at
from public._stg_ret_final f
order by f.recorded_at, f.src_row;

commit;
