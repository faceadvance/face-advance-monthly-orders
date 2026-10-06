-- 2026-10-06 เติมเลขแทร็กที่หายตอนนำเข้าออเดอร์วันที่ 3/10 · 36 รายการ · เจ้านายสั่ง
-- ที่มา: ~/Downloads/Export Orders 2026-10-06 043911.xlsx (GoSell 2026-10-03 · 245 ออเดอร์ · ตรงกันแล้ว 209 · ขาดแทร็ก 36 · ขัดแย้ง 0)
-- เติมเฉพาะ tracking_no ที่ว่าง (ไม่ทับค่าที่มี · carrier ตรงกันอยู่แล้ว · ไม่แตะช่องอื่น)
-- ตรวจก่อนแล้ว: เลขไม่ซ้ำกับออเดอร์อื่น · ไม่มีเงิน COD/พัสดุตีกลับค้างรอเลขเหล่านี้
-- backup _bak_trackfix_20261006 · รัน: psql -v commit=1 -f (ไม่ใส่ = rollback)
\set ON_ERROR_STOP 1
set lock_timeout='3s'; set statement_timeout='10s';
begin;
create temp table _fix(order_id bigint primary key, order_no text not null, tracking text not null);
insert into _fix values
 (311450, 'OD261003188431', 'GOSH06475939B6'),
 (311451, 'OD261003188430', 'GOSH0647595897'),
 (311452, 'OD261003188429', 'GOSH0647595720'),
 (311453, 'OD261003188428', 'GOSH064759567A'),
 (311454, 'OD261003188427', 'GOSH06475945D0'),
 (311455, 'OD261003188426', 'GOSH0647594913'),
 (311456, 'OD261003188425', 'GOSH06475917F5'),
 (311457, 'OD261003188424', 'GOSH0647595530'),
 (311458, 'OD261003188423', 'GOSH064759511A'),
 (311459, 'OD261003188422', 'GOSH0647594169'),
 (311460, 'OD261003188421', 'GOSH06475950AE'),
 (311461, 'OD261003188420', 'GOSH064759435F'),
 (311462, 'OD261003188419', 'GOSH0647595376'),
 (311463, 'OD261003188418', 'GOSH064759361B'),
 (311464, 'OD261003188417', 'GOSH06475954E2'),
 (311465, 'OD261003188416', 'GOSH0647593766'),
 (311466, 'OD261003188415', 'GOSH06475952D9'),
 (311467, 'OD261003188414', 'GOSH0647593821'),
 (311468, 'OD261003188413', 'GOSH0647591262'),
 (311469, 'OD261003188412', 'GOSH064759326F'),
 (311470, 'OD261003188411', 'GOSH064759186C'),
 (311471, 'OD261003188410', 'GOSH0647592895'),
 (311472, 'OD261003188409', 'GOSH0647591376'),
 (311473, 'OD261003188408', 'GOSH0647593175'),
 (311474, 'OD261003188407', 'GOSH06475921D8'),
 (311475, 'OD261003188406', 'GOSH064759300B'),
 (311476, 'OD261003188405', 'GOSH06475922A0'),
 (311477, 'OD261003188404', 'GOSH0647593489'),
 (311478, 'OD261003188403', 'GOSH06475916BB'),
 (311479, 'OD261003188402', 'GOSH06475935FB'),
 (311480, 'OD261003188401', 'GOSH064759144E'),
 (311481, 'OD261003188400', 'GOSH06475933BD'),
 (311482, 'OD261003188399', 'GOSH064759113C'),
 (311483, 'OD261003188398', 'GOSH06475920BD'),
 (311484, 'OD261003188397', 'GOSH0647592468'),
 (311536, 'OD261003188345', 'WA195615472TH');
-- ยาม: ทุกแถวต้องยังว่างอยู่ เลขออเดอร์ตรง และเลขแทร็กไม่ซ้ำกับออเดอร์อื่น
do $$ declare n int; d int; begin
  select count(*) into n from _fix f join public.orders o on o.id=f.order_id
   where o.order_no=f.order_no and coalesce(btrim(o.tracking_no),'')='';
  if n <> 36 then raise exception 'ค่าปัจจุบันไม่ตรงที่ตรวจไว้ (ว่างอยู่ % จาก 36)', n; end if;
  select count(*) into d from public.orders o join _fix f on btrim(o.tracking_no)=f.tracking;
  if d <> 0 then raise exception 'เลขแทร็กซ้ำกับออเดอร์อื่น % รายการ', d; end if;
end $$;
create table public._bak_trackfix_20261006 as
  select o.id, o.order_no, o.tracking_no old_tracking_no, o.updated_at old_updated_at from public.orders o join _fix f on f.order_id=o.id;
revoke all on public._bak_trackfix_20261006 from anon, authenticated;
update public.orders o set tracking_no=f.tracking, updated_at=now()
  from _fix f where f.order_id=o.id and coalesce(btrim(o.tracking_no),'')='';
select count(*) filled from public.orders o join _fix f on f.order_id=o.id where o.tracking_no=f.tracking;
\if :{?commit}
commit;
\else
rollback;
\endif
