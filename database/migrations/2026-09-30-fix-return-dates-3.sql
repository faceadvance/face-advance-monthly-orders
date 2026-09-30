-- 2026-09-30 09:54 แก้วันที่ตีกลับพิมพ์ผิด 3 รายการ (id 3881 ปีผิด · 6495/6240 วัน-เดือนสลับ) · เจ้านายสั่ง
-- backup _bak_retdate_20260930 · รัน: psql -v commit=1 -f (ไม่ใส่ = rollback)
\set ON_ERROR_STOP 1
set lock_timeout='3s'; set statement_timeout='10s';
begin;
create temp table _fix(id bigint primary key, old_d date, new_d date, why text);
insert into _fix values
 (3881, '2023-03-05', '2024-03-05', 'ปีพิมพ์ผิด (สั่ง 2024-03-02)'),
 (6495, '2023-12-01', '2023-01-12', 'วัน/เดือนสลับ (สั่ง 2023-01-02)'),
 (6240, '2023-09-02', '2023-02-09', 'วัน/เดือนสลับ (สั่ง 2023-02-04)');
-- ยาม: ค่าปัจจุบันต้องตรงที่ตรวจไว้ทุกแถว
do $$ declare n int; begin
  select count(*) into n from _fix f join public.recon_returns r on r.id=f.id
   where (r.recorded_at at time zone 'Asia/Bangkok')::date = f.old_d;
  if n <> 3 then raise exception 'ค่าปัจจุบันไม่ตรงที่ตรวจไว้ (ตรง % จาก 3)', n; end if;
end $$;
create table public._bak_retdate_20260930 as
  select r.id, r.tracking_out, r.recorded_at old_recorded_at from public.recon_returns r join _fix f on f.id=r.id;
revoke all on public._bak_retdate_20260930 from anon, authenticated;
-- เปลี่ยนเฉพาะวันที่ · เวลาของวันตามเวลาไทยคงเดิม
update public.recon_returns r
   set recorded_at = (f.new_d + (r.recorded_at at time zone 'Asia/Bangkok')::time) at time zone 'Asia/Bangkok'
  from _fix f where f.id=r.id;
select r.id, f.old_d, (r.recorded_at at time zone 'Asia/Bangkok')::date new_d,
       (o.ordered_at at time zone 'Asia/Bangkok')::date ordered,
       (r.recorded_at at time zone 'Asia/Bangkok')::date - (o.ordered_at at time zone 'Asia/Bangkok')::date days_after
  from public.recon_returns r join _fix f on f.id=r.id
  join public.orders o on btrim(o.tracking_no)=btrim(r.tracking_out) order by r.id;
\if :{?commit}
commit;
\else
rollback;
\endif
