-- รันหลังนำเข้าไฟล์ออเดอร์ 7/10 และ 8/10 เสร็จ (คู่กับ 2026-10-08-sellers-c205-c213-c203.sql — เก็บในเครื่อง ไม่ขึ้น repo เพราะมีชื่อพนักงาน)
-- เจ้านายเลือกเปลี่ยนรหัส C205/C213 เป็นคนใหม่ทันที (2026-10-08 22:05) ก่อนนำเข้าออเดอร์ 7–8/10
-- → ออเดอร์ที่ลงวันก่อน 9/10 แต่ไปผูกกับคนใหม่ = ของคนเดิม: C205 ใหม่(84)→C205 เดิม(46) · C213 ใหม่(85)→C213 เดิม(54)
-- รัน: psql -v commit=1 -f (ไม่ใส่ = rollback · ดูจำนวนก่อนได้)
\set ON_ERROR_STOP 1
begin;

do $$ begin
  if (select count(*) from public.sellers where (id, employee_code, is_active) in ((46, 'C205', false), (54, 'C213', false),
                                                                          (84, 'C205', true), (85, 'C213', true))) <> 4
  then raise exception 'id ผู้ขายไม่ตรงกับที่บันทึกไว้ — ยกเลิก'; end if;
end $$;

create temp table moved as
select o.id, o.order_no, o.seller_id from_seller, case o.seller_id when 84 then 46 when 85 then 54 end to_seller
  from public.orders o
 where o.seller_id in (84, 85) and o.ordered_at < '2026-10-09 00:00:00+07';

update public.orders o set seller_id = m.to_seller from moved m where o.id = m.id;

insert into public.audit_log (user_id, username, event, detail)
select null, 'friday', 'datafix_sellers', jsonb_build_object(
  'reason', 'ออเดอร์ก่อน 9/10 ที่ผูกกับรหัส C205/C213 คนใหม่ → คืนให้คนเดิม (แถวที่ปิดแล้ว)', 'orders', count(*),
  'order_nos', coalesce(jsonb_agg(order_no), '[]'::jsonb))
  from moved;

select from_seller, to_seller, count(*) from moved group by 1, 2 order by 1;

\if :{?commit}
commit;
\else
rollback;
\endif
