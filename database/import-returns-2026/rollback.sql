-- ย้อนการนำเข้าตีกลับย้อนหลัง 2026-09-17 14:42 (ให้กลับไปเหมือนก่อนนำเข้าทุกอย่าง)
-- ยังไม่ได้รัน · รันเมื่อเจ้านายสั่งเท่านั้น
--
-- คืนอะไร: บันทึกตีกลับ 1,785 แถว · สถานะออเดอร์ 1,785 ใบ (จาก _bak_ret_hist_20260917)
--          · timeline ที่ระบบเขียนตอนนำเข้า (1,738 payment_change + 1 delivery_change + 47 note)
-- ไม่แตะ:  ลอจิก reconcile_order / app_edith_issues / app_edith_confirm_return
--          (ถ้าจะย้อนลอจิกด้วย ต้องรัน migration เวอร์ชันเดิม — บอกได้ ฟรายเดย์เตรียมให้)

begin;
set local statement_timeout = 0;
set local app.skip_reconcile = '1';   -- ห้าม trigger แก้สถานะตอนลบ เพราะเราคืนจาก backup เอง

-- 1) ลบ timeline ที่เกิดจากการนำเข้า (ล็อกด้วยเวลา transaction เดียวเป๊ะๆ)
delete from public.order_tracking t
where t.created_by_name = 'ระบบ'
  and t.created_at = '2026-09-17 14:42:16.546181+07'::timestamptz
  and t.order_id in (select order_id from public._bak_ret_hist_20260917);

-- 2) ลบบันทึกตีกลับที่นำเข้า
delete from public.recon_returns r
where r.created_by is null
  and r.recorded_at < '2026-09-01'
  and btrim(r.tracking_out) in (select tracking_out from public._bak_ret_hist_20260917);

-- 3) คืนสถานะออเดอร์จาก backup
update public.orders o set
  delivery_status = b.delivery_status,
  payment_status  = b.payment_status,
  return_arrived  = b.return_arrived,
  return_reason   = b.return_reason,
  recon_conflict  = b.recon_conflict,
  updated_at      = b.updated_at
from public._bak_ret_hist_20260917 b
where o.id = b.order_id;

-- 4) ตรวจก่อน commit — ต้องได้ 0 ทั้งคู่
do $$
declare v_left int; v_diff int;
begin
  select count(*) into v_left from public.recon_returns
   where created_by is null and recorded_at < '2026-09-01';
  select count(*) into v_diff from public._bak_ret_hist_20260917 b join public.orders o on o.id=b.order_id
   where (o.delivery_status, o.payment_status, o.return_arrived, coalesce(o.return_reason,''), o.recon_conflict)
      is distinct from
         (b.delivery_status, b.payment_status, b.return_arrived, coalesce(b.return_reason,''), b.recon_conflict);
  raise notice 'บันทึกตีกลับย้อนหลังที่เหลือ: % (ต้องเป็น 0) · ออเดอร์ที่ยังไม่ตรง backup: % (ต้องเป็น 0)', v_left, v_diff;
  if v_left <> 0 or v_diff <> 0 then
    raise exception 'ย้อนไม่ครบ — ยกเลิก transaction';
  end if;
end $$;

commit;
