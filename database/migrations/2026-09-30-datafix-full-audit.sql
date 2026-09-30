-- 2026-09-30 11:4x แก้ข้อมูลจากการตรวจทั้งระบบ (เจ้านายสั่ง + รันเอง) · backup _bak_datafix_20260930 (44,608 แถว)
-- ก) COD 2026 วันรับเงินจริง 43,238 + วันพิมพ์ผิดในไฟล์ 2023–2025 1,351 (รายการ: 2026-09-30-datafix-cod-dates.tsv = id, วันเดิม, วันใหม่, ชนิด)
-- ข) วันตีกลับ 3 · ค) 'ยังไม่ได้รับ' 12 ใส่โน้ต · ง) ค่าชดเชยขนส่ง 2 → รับเงินเคลม
-- รัน: แก้ path \set ON_ERROR_STOP 1
set lock_timeout='3s'; set statement_timeout='120s';
begin;
create table public._bak_datafix_20260930 (tbl text, id bigint, col text, old_val text);
revoke all on public._bak_datafix_20260930 from anon, authenticated;

-- ===== ก) เงินเข้า COD: วันรับเงินจริง 2026 (43,238) + วันพิมพ์ผิดในไฟล์ 2023–2025 (1,351) =====
create temp table cf(id bigint primary key, old_d date, new_d date, kind text);
\copy cf from '/tmp/audit/cod_fix.tsv'
do $$ declare n int; m int; begin
  select count(*) into n from cf;
  select count(*) into m from cf join public.recon_cod_payments c on c.id=cf.id
   where (c.recorded_at at time zone 'Asia/Bangkok')::date = cf.old_d;
  if n <> 44589 or m <> n then raise exception 'COD: รายการ % · ค่าเดิมตรง %', n, m; end if;
end $$;
insert into public._bak_datafix_20260930 select 'recon_cod_payments', c.id, 'recorded_at', c.recorded_at::text
  from cf join public.recon_cod_payments c on c.id=cf.id;
update public.recon_cod_payments c set recorded_at = cf.new_d::timestamp at time zone 'Asia/Bangkok' from cf where cf.id=c.id;

-- ===== ข) วันตีกลับ: เดือนพิมพ์ผิด 2 · "ยังไม่ได้รับ" ที่อยู่ก่อนวันสั่ง 1 → วันสั่ง =====
create temp table rf(id bigint primary key, old_d date, new_d date, why text);
insert into rf values (5881,'2023-02-18','2023-10-18','เดือนพิมพ์ผิด 02→10 (แถวก่อนหน้า 18/10/2023)'),
                      (6089,'2023-06-25','2023-08-25','เดือนพิมพ์ผิด 06→08 (แถวก่อนหน้า 23/08/2023)'),
                      (5891,'2023-02-23','2023-02-25','ไฟล์เขียน "ยังไม่ได้รับ" · ใช้วันสั่งแทนวันจากแถวข้างเคียง');
do $$ declare m int; begin
  select count(*) into m from rf join public.recon_returns r on r.id=rf.id where (r.recorded_at at time zone 'Asia/Bangkok')::date = rf.old_d;
  if m <> 3 then raise exception 'ตีกลับ: ค่าเดิมตรง % จาก 3', m; end if;
end $$;
insert into public._bak_datafix_20260930 select 'recon_returns', r.id, 'recorded_at', r.recorded_at::text from rf join public.recon_returns r on r.id=rf.id;
update public.recon_returns r set recorded_at = rf.new_d::timestamp at time zone 'Asia/Bangkok' from rf where rf.id=r.id;

-- ===== ค) "ยังไม่ได้รับ" 12 รายการ: คงถึงแล้ว + โน้ตบอกที่มา =====
create temp table nr as select r.id rid, o.id oid from public.recon_returns r join public.orders o on btrim(o.tracking_no)=btrim(r.tracking_out)
  where r.id in (5811,5816,5820,5823,5824,5827,5830,5831,5841,5890,5891,5897);
do $$ begin if (select count(*) from nr) <> 12 then raise exception 'ยังไม่ได้รับ: ไม่ครบ 12'; end if; end $$;
insert into public._bak_datafix_20260930 select 'orders', o.id, 'note', o.note from nr join public.orders o on o.id=nr.oid;
update public.orders o set note = coalesce(nullif(btrim(o.note),'') || ' · ', '') || 'ข้อมูลย้อนหลัง: ไฟล์บันทึกตีกลับเขียนว่า "ยังไม่ได้รับ" · ไม่มีวันที่ตีกลับถึงจริง'
  from nr where o.id=nr.oid;
insert into public.order_tracking(order_id, entry_type, note, created_by_name)
  select oid, 'note', 'แก้ข้อมูลย้อนหลัง 2026-09-30: ไฟล์ตีกลับเขียนว่า "ยังไม่ได้รับ" → คงสถานะตีกลับถึงแล้ว + ใส่โน้ต', 'ระบบ (แก้ข้อมูลย้อนหลัง)' from nr;

-- ===== ง) ไม่ใช่ตีกลับ: ได้ค่าชดเชยพัสดุหาย/เสียหาย 2 รายการ → รับเงินเคลม (แบบเดียวกับเคสเคลมเดิม) =====
create temp table cl as
select r.id rid, o.id oid, btrim(r.tracking_out) trk, o.total_sales amt, (r.recorded_at at time zone 'Asia/Bangkok')::date rec,
       case r.id when 5862 then 'พัสดุสูญหายเคลมได้เงินแล้ว' else 'ปิดงานมีปัญหาจ่ายค่าชดเชยพัสดุเสียหาย/สูญหายแล้ว' end src_text
  from public.recon_returns r join public.orders o on btrim(o.tracking_no)=btrim(r.tracking_out) where r.id in (5862,6652);
do $$ begin
  if (select count(*) from cl) <> 2 then raise exception 'เคลม: ไม่ครบ 2'; end if;
  if exists (select 1 from cl join public.recon_cod_payments c on btrim(c.tracking_out)=cl.trk) then raise exception 'เคลม: มีเงินเข้าอยู่แล้ว'; end if;
end $$;
insert into public._bak_datafix_20260930 select 'recon_returns', r.id, 'row', to_jsonb(r)::text from cl join public.recon_returns r on r.id=cl.rid;
insert into public._bak_datafix_20260930 select 'orders', o.id, 'row', to_jsonb(o)::text from cl join public.orders o on o.id=cl.oid;
delete from public.recon_returns where id in (select rid from cl);          -- trigger ถอนผลตีกลับ + บันทึกไทม์ไลน์ให้เอง
set local app.skip_reconcile = '1';
insert into public.recon_cod_payments(tracking_out, amount, received_from, note, source, recorded_at)
  select trk, amt, 'ทำเคลม', 'ข้อมูลย้อนหลัง: ' || src_text || ' · ไม่ทราบยอดเคลมจริง ใช้ยอดขาย · วันที่จากไฟล์ตีกลับ',
         'hist:แก้ข้อมูล 2026-09-30 (ค่าชดเชยจากขนส่ง)', rec::timestamp at time zone 'Asia/Bangkok' from cl;
update public.orders o set delivery_status='มีปัญหา', payment_status='ชำระแล้ว', status_detail='รับเงินเคลมแล้ว',
       return_arrived=false, return_reason=null, recon_conflict=false,
       note = coalesce(nullif(btrim(o.note),'') || ' · ', '') || 'ข้อมูลย้อนหลัง: ' || cl.src_text || ' (เดิมนำเข้าเป็นตีกลับ)'
  from cl where o.id=cl.oid;
insert into public.order_tracking(order_id, entry_type, note, created_by_name)
  select oid, 'note', 'แก้ข้อมูลย้อนหลัง 2026-09-30: ไฟล์เขียนว่า "' || src_text || '" → ไม่ใช่ตีกลับ · เปลี่ยนเป็นรับเงินเคลม (มีปัญหา/ชำระแล้ว)', 'ระบบ (แก้ข้อมูลย้อนหลัง)' from cl;

-- ===== ตรวจหลังแก้ =====
select 'backup' chk, tbl, col, count(*) from public._bak_datafix_20260930 group by 2,3 order by 2,3;
select 'COD ที่แก้ แล้วยังก่อนวันสั่ง' chk, count(*) from cf join public.recon_cod_payments c on c.id=cf.id
  join public.orders o on btrim(o.tracking_no)=regexp_replace(btrim(c.tracking_out),'-B$','') where c.recorded_at < date_trunc('day', o.ordered_at at time zone 'Asia/Bangkok') at time zone 'Asia/Bangkok';
select 'COD 2026 ยังเป็น 17 ก.ย.' chk, count(*) from public.recon_cod_payments where source like 'hist:COD 2026%' and (recorded_at at time zone 'Asia/Bangkok')::date = '2026-09-17';
select 'ตีกลับ' chk, r.id, (r.recorded_at at time zone 'Asia/Bangkok')::date rec, (o.ordered_at at time zone 'Asia/Bangkok')::date ord from rf join public.recon_returns r on r.id=rf.id join public.orders o on btrim(o.tracking_no)=btrim(r.tracking_out) order by 2;
select 'เคลม' chk, o.order_no, o.delivery_status, o.payment_status, o.status_detail, o.return_arrived, o.recon_conflict, c.amount, c.received_from, (c.recorded_at at time zone 'Asia/Bangkok')::date
  from cl join public.orders o on o.id=cl.oid join public.recon_cod_payments c on btrim(c.tracking_out)=cl.trk;
select 'ยังไม่ได้รับ มีโน้ต' chk, count(*) from nr join public.orders o on o.id=nr.oid where o.note like '%ยังไม่ได้รับ%';
\if :{?commit}
commit;
\else
rollback;
\endif
