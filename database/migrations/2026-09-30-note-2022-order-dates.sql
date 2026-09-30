-- 2026-09-30 12:01 ใส่โน้ตออเดอร์ปี 2022 ที่เงินเข้าก่อนวันสั่ง 3,095 รายการ (เจ้านายสั่ง) · ไม่เปลี่ยนวันสั่ง · backup _bak_note2022_20260930
-- รายการ oid+จำนวนวัน สร้างจากการตรวจทั้งระบบ (ไฟล์ tsv ไม่เก็บใน repo — ยามในสคริปต์ตรวจเงื่อนไขซ้ำทุกแถว)
\set ON_ERROR_STOP 1
set lock_timeout='3s'; set statement_timeout='60s';
begin;
create temp table n(oid bigint primary key, gap int);
\copy n from '/tmp/audit/note2022.tsv'
do $$ declare c int; m int; begin
  select count(*) into c from n;
  -- ยาม: ต้องเป็นออเดอร์ปี 2022 ที่ยังมีเงินเข้าก่อนวันสั่งจริงทุกรายการ และยังไม่เคยใส่โน้ตนี้
  select count(*) into m from n join public.orders o on o.id=n.oid
   where extract(year from o.ordered_at at time zone 'Asia/Bangkok') = 2022
     and coalesce(o.note,'') not like '%วันสั่งจากไฟล์ย้อนหลังอาจคลาดเคลื่อน%'
     and exists (select 1 from public.recon_cod_payments c where btrim(c.tracking_out)=btrim(o.tracking_no) and c.recorded_at < o.ordered_at);
  if m <> c then raise exception 'ไม่ตรง: รายการ % · ผ่านเงื่อนไข %', c, m; end if;
end $$;
create table public._bak_note2022_20260930 as select o.id, o.note old_note from n join public.orders o on o.id=n.oid;
revoke all on public._bak_note2022_20260930 from anon, authenticated;
update public.orders o set note = coalesce(nullif(btrim(o.note),'') || ' · ', '')
       || 'ข้อมูลย้อนหลัง: วันสั่งจากไฟล์ย้อนหลังอาจคลาดเคลื่อน (เงินเข้าก่อนวันสั่ง ' || n.gap || ' วัน)'
  from n where o.id=n.oid;
select 'backup' chk, count(*) from public._bak_note2022_20260930;
select 'noted' chk, count(*) from public.orders where note like '%วันสั่งจากไฟล์ย้อนหลังอาจคลาดเคลื่อน%';
select 'ตัวอย่าง' chk, o.order_no, o.note from n join public.orders o on o.id=n.oid order by n.gap desc limit 2;
\if :{?commit}
commit;
\else
rollback;
\endif
