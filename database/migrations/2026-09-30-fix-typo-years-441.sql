-- 2026-09-30 แก้วันที่พิมพ์ผิดจากไฟล์นำเข้าย้อนหลัง 2022–2024 (ปี 3034/1967/2004/2014 → 2024) · เจ้านายสั่ง + รันเอง
-- recon_returns 5 · recon_cod_payments 436 · backup _bak_datefix_20260929 · รัน: psql -v commit=1 -f (ไม่ใส่ = rollback)
-- ย้อนกลับ: update ... set recorded_at = b.old_recorded_at from _bak_datefix_20260929 b where b.tbl=... and b.id=...

\set ON_ERROR_STOP 1
set lock_timeout='3s'; set statement_timeout='20s';
begin;
create table public._bak_datefix_20260929 as
  select 'recon_returns'::text tbl, id, recorded_at old_recorded_at from public.recon_returns
   where recorded_at >= now() + interval '1 day' or recorded_at < '2022-01-01'
  union all
  select 'recon_cod_payments', id, recorded_at from public.recon_cod_payments
   where recorded_at >= now() + interval '1 day' or recorded_at < '2022-01-01';
revoke all on public._bak_datefix_20260929 from anon, authenticated;
do $$ declare r int; c int; begin
  select count(*) filter (where tbl='recon_returns'), count(*) filter (where tbl='recon_cod_payments') into r, c from public._bak_datefix_20260929;
  if r <> 5 or c <> 436 then raise exception 'จำนวนไม่ตรงที่ตรวจไว้: returns=% cod=%', r, c; end if;
end $$;
-- เปลี่ยนเฉพาะปี → 2024 (เดือน/วัน/เวลาตามเวลาไทยคงเดิม)
update public.recon_returns t
   set recorded_at = ((t.recorded_at at time zone 'Asia/Bangkok')
                      + make_interval(years => 2024 - extract(year from t.recorded_at at time zone 'Asia/Bangkok')::int))
                     at time zone 'Asia/Bangkok'
  from public._bak_datefix_20260929 b where b.tbl='recon_returns' and b.id=t.id;
update public.recon_cod_payments t
   set recorded_at = ((t.recorded_at at time zone 'Asia/Bangkok')
                      + make_interval(years => 2024 - extract(year from t.recorded_at at time zone 'Asia/Bangkok')::int))
                     at time zone 'Asia/Bangkok'
  from public._bak_datefix_20260929 b where b.tbl='recon_cod_payments' and b.id=t.id;
-- ตรวจหลังแก้
select b.tbl, to_char(b.old_recorded_at at time zone 'Asia/Bangkok','YYYY-MM-DD') old, to_char(coalesce(r.recorded_at,c.recorded_at) at time zone 'Asia/Bangkok','YYYY-MM-DD') new, count(*)
  from public._bak_datefix_20260929 b
  left join public.recon_returns r on b.tbl='recon_returns' and r.id=b.id
  left join public.recon_cod_payments c on b.tbl='recon_cod_payments' and c.id=b.id
 group by 1,2,3 order by 1,2;
-- ต้องไม่เหลือวันที่ผิดปกติ + วันรับเงิน/ตีกลับต้องไม่ก่อนวันสั่ง
select (select count(*) from public.recon_returns where recorded_at >= now()+interval '1 day' or recorded_at < '2022-01-01')
     + (select count(*) from public.recon_cod_payments where recorded_at >= now()+interval '1 day' or recorded_at < '2022-01-01') as still_bad,
       (select count(*) from public._bak_datefix_20260929 b
          join public.recon_returns r on b.tbl='recon_returns' and r.id=b.id
          join public.orders o on btrim(o.tracking_no)=btrim(r.tracking_out) where r.recorded_at < o.ordered_at)
     + (select count(*) from public._bak_datefix_20260929 b
          join public.recon_cod_payments c on b.tbl='recon_cod_payments' and c.id=b.id
          join public.orders o on btrim(o.tracking_no)=btrim(c.tracking_out) where c.recorded_at < o.ordered_at) as before_order;
\if :{?commit}
commit;
\else
rollback;
\endif
