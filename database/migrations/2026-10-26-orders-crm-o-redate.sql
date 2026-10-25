-- 2026-10-26 แก้วันที่สั่งซื้อออเดอร์พนักงาน CRM ให้เป็นเวลาสั่งจริงจากระบบ CRM V5 Order Management · เจ้านายสั่ง
-- ที่มา: ไฟล์ GoSell ลงวันที่สั่งซื้อ = เวลาที่ CRM V5 export ไป GoSell (ไม่ใช่เวลาที่ลูกค้าสั่ง)
--   เช่น นำเข้า 26/10 01:40 ได้วันที่ 24–26 แต่ 70 รายการของวันที่ 26 จริงๆ สั่งวันที่ 24
-- เลข CRM-O-<n> ในหมายเหตุ = orders.id ในฐาน CRM V5 · เวลาสั่งจริง = created_at
--   ก. ออเดอร์ที่มีเลข CRM-O อยู่แล้ว → ตั้ง ordered_at = created_at
--   ข. ออเดอร์ก่อนหน้าที่ยังไม่มีเลข → จับคู่ด้วย เบอร์ + เวลา export (±30 นาที)
--      หรือ (กรณี CRM export ซ้ำทีหลัง) เบอร์+รหัสเซล+ยอด ตรง และเวลา MO อยู่ระหว่าง created−10 นาที ถึง exported+2 ชม.
--      เลือกคู่ที่ดีที่สุดที่ตรงกันทั้งสองฝั่งเท่านั้น → เติมเลข CRM-O ในหมายเหตุ + ตั้ง ordered_at
-- ข้อมูล CRM V5 ดึงเป็น CSV เก็บในเครื่อง (มีเบอร์ลูกค้า ไม่ขึ้น repo): database/datafix-local/2026-10-26-crm-o/
-- รัน: cd โฟลเดอร์ข้อมูล (มี crm-v5-orders.csv) แล้ว psql [-v exp_a=N -v exp_b=M -v commit=1] -f <ไฟล์นี้> → สำรองค่าเดิมลง backup-supabase.csv
-- Render (ก.ค.): เพิ่ม -v render=1 + ไฟล์ used-crm-ids.csv (crm id ที่ใช้ในฐานหลักแล้ว) → จำกัด ordered_at < 1 ส.ค. · สำรองลง backup-render.csv
-- ไม่ใส่ commit = rollback · ใส่ commit ต้องใส่ exp_a/exp_b ให้ตรงกับที่ dry-run เห็น ไม่งั้นยกเลิก
\set ON_ERROR_STOP 1
set statement_timeout = '300s';
begin;

create temp table crm(id bigint primary key, employee_id text, amount numeric, phone text, status text, created_at timestamptz, exported_at timestamptz);
\copy crm from 'crm-v5-orders.csv' csv header

create temp table used(id bigint primary key);
\if :{?render}
\copy used from 'used-crm-ids.csv' csv header
\endif

create temp table mo as
select o.id, o.ordered_at, regexp_replace(coalesce(o.phone, ''), '\D', '', 'g') phone, o.total_sales, o.note, s.employee_code,
       (regexp_match(o.note, 'CRM-O-(\d+)'))[1]::bigint crm_id
  from public.orders o left join public.sellers s on s.id = o.seller_id
\if :{?render}
 where o.ordered_at < '2026-08-01 00:00+07'
\endif
;
create index on mo(phone);

-- ก. มีเลขแล้ว
create temp table fix_a as
select m.id mo_id, c.id crm_id, date_trunc('second', c.created_at) new_at
  from mo m join crm c on c.id = m.crm_id
 where m.ordered_at <> date_trunc('second', c.created_at);

-- ข. ยังไม่มีเลข
create temp table cand as
select c.id crm_id, m.id mo_id, 1 tier,
       (c.employee_id = m.employee_code)::int + (c.amount = m.total_sales)::int score,
       abs(extract(epoch from m.ordered_at - c.exported_at)) dist
  from crm c join mo m on m.phone = c.phone and m.crm_id is null
 where not exists (select 1 from mo t where t.crm_id = c.id) and not exists (select 1 from used u where u.id = c.id)
   and m.ordered_at between c.exported_at - interval '30 min' and c.exported_at + interval '30 min'
union all
select c.id, m.id, 2, 2, abs(extract(epoch from m.ordered_at - c.created_at))
  from crm c join mo m on m.phone = c.phone and m.crm_id is null and c.employee_id = m.employee_code and c.amount = m.total_sales
 where not exists (select 1 from mo t where t.crm_id = c.id) and not exists (select 1 from used u where u.id = c.id)
   and m.ordered_at between c.created_at - interval '10 min' and c.exported_at + interval '2 hour';

create temp table fix_b as
with d as (select distinct on (crm_id, mo_id) * from cand order by crm_id, mo_id, tier, score desc, dist),
     r as (select *, row_number() over (partition by crm_id order by tier, score desc, dist) rc,
                     row_number() over (partition by mo_id  order by tier, score desc, dist) rm from d)
select r.mo_id, r.crm_id, r.tier, r.score, date_trunc('second', c.created_at) new_at
  from r join crm c on c.id = r.crm_id where rc = 1 and rm = 1;

select 'ก. มีเลขแล้ว ต้องแก้เวลา' what, count(*) n from fix_a
union all select 'ข. เติมเลข+แก้เวลา', count(*) from fix_b
union all select '   ข. tier1 เซล/ยอดไม่ตรงอย่างใดอย่างหนึ่ง', count(*) from fix_b where score < 2;

do $$ begin
  if exists (select 1 from fix_a a join fix_b b on b.mo_id = a.mo_id) then raise exception 'ออเดอร์ซ้ำระหว่าง ก. กับ ข.'; end if;
  if (select count(*) from (select crm_id from fix_b group by 1 having count(*) > 1) x) > 0 then raise exception 'crm id ซ้ำใน ข.'; end if;
  if exists (select 1 from fix_b b join mo m on m.id = b.mo_id where m.crm_id is not null) then raise exception 'ข. ไปทับออเดอร์ที่มีเลขแล้ว'; end if;
end $$;

\if :{?commit}
create temp table exp as select :exp_a::int a, :exp_b::int b;  -- psql ไม่แทนค่าตัวแปรใน $$ จึงพักไว้ในตาราง
do $$ begin
  if (select count(*) from fix_a) <> (select a from exp) or (select count(*) from fix_b) <> (select b from exp)
  then raise exception 'จำนวนไม่ตรงกับที่ dry-run ไว้ (ก.=% ข.=%) — ยกเลิก', (select count(*) from fix_a), (select count(*) from fix_b); end if;
end $$;
\endif

-- สำรองค่าเดิมไว้ย้อนกลับ (id, ordered_at เดิม, note เดิม)
\if :{?render}
\copy (select o.id, o.ordered_at, o.note, f.crm_id, f.k from public.orders o join (select mo_id, crm_id, 'a' k from fix_a union all select mo_id, crm_id, 'b' from fix_b) f on f.mo_id = o.id order by o.id) to 'backup-render.csv' csv header
\else
\copy (select o.id, o.ordered_at, o.note, f.crm_id, f.k from public.orders o join (select mo_id, crm_id, 'a' k from fix_a union all select mo_id, crm_id, 'b' from fix_b) f on f.mo_id = o.id order by o.id) to 'backup-supabase.csv' csv header
\endif

update public.orders o set ordered_at = a.new_at from fix_a a where o.id = a.mo_id;
update public.orders o set ordered_at = b.new_at,
       note = case when coalesce(btrim(o.note), '') = '' then 'CRM-O-' || b.crm_id else o.note || '-CRM-O-' || b.crm_id end
  from fix_b b where o.id = b.mo_id;

insert into public.audit_log (user_id, username, event, detail)
select null, 'friday', 'datafix_orders', jsonb_build_object(
  'reason', 'วันที่สั่งซื้อออเดอร์ CRM = เวลาสั่งจริงใน CRM V5 (เดิมเป็นเวลา export ไป GoSell) · เติมเลข CRM-O ย้อนหลัง (เจ้านายสั่ง 2026-10-26)',
  'db', case when :{?render} then 'render' else 'supabase' end,
  'redated_tagged', (select count(*) from fix_a), 'tagged_and_redated', (select count(*) from fix_b),
  'month_moves', (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (
     select to_char(m.ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM') || '→' || to_char(f.new_at at time zone 'Asia/Bangkok', 'YYYY-MM') k, count(*) n
       from (select mo_id, new_at from fix_a union all select mo_id, new_at from fix_b) f join mo m on m.id = f.mo_id
      where to_char(m.ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM') <> to_char(f.new_at at time zone 'Asia/Bangkok', 'YYYY-MM') group by 1) x));

-- ตรวจหลังแก้
select 'เหลือออเดอร์มีเลขแต่เวลาไม่ตรง CRM' chk, count(*) n
  from public.orders o join crm c on c.id = (regexp_match(o.note, 'CRM-O-(\d+)'))[1]::bigint
 where o.ordered_at <> date_trunc('second', c.created_at)
\if :{?render}
   and o.ordered_at < '2026-08-01 00:00+07'
\endif
union all
select 'เลข CRM-O ซ้ำกันในหลายออเดอร์', count(*) from (
  select (regexp_match(note, 'CRM-O-(\d+)'))[1] k from public.orders where note ~ 'CRM-O-'
\if :{?render}
     and ordered_at < '2026-08-01 00:00+07'
\endif
  group by 1 having count(*) > 1) x;

select (ordered_at at time zone 'Asia/Bangkok')::date d, count(*) n, count(*) filter (where note ~ 'CRM-O-') crm
  from public.orders where ordered_at >= '2026-10-22 00:00+07' group by 1 order by 1;

\if :{?commit}
commit;
\else
rollback;
\endif
