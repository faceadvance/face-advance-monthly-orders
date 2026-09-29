-- 2026-09-29 หาลูกค้าซ้ำเบื้องหลังเร็วขึ้น (ขั้นที่ 2 ต่อจาก 2026-09-29-import-dedup-async.sql)
-- สาเหตุที่ช้า: join orders × orders ด้วย `is not distinct from` → ใช้ index (brand,province,district,subdistrict,postal_code) ไม่ได้
--   → สแกน orders ทั้งตาราง (281k) ทุกครั้ง + เรียก norm_name ซ้ำทุกแถว · ชุด 25 ลูกค้าใช้ 17–34 วิ
-- แก้: (1) ดึงกลุ่มพื้นที่ของลูกค้าใหม่ก่อน แล้ว join ด้วย = ให้ใช้ index ได้ (ช่องว่างแยกทางเล็ก)
--      (2) คิด norm_name ครั้งเดียวต่อชื่อไม่ซ้ำ ไม่ใช่ทุกคู่แถว
-- เกณฑ์เหมือนเดิมทุกอย่าง (ชื่อ ≥ 0.6 แบรนด์+จังหวัด+อำเภอเดียวกัน · ที่อยู่ ≥ 0.85 ตำบล+ไปรษณีย์เดียวกัน)
-- ทดสอบกับข้อมูลจริง (อ่านอย่างเดียว): คู่ที่ระบบเดิมเคยเจอ 8/8 เจอครบ คะแนนเท่ากันทุกคู่
--   8 ลูกค้า 7.9 วิ → 0.15 วิ · 25 ลูกค้าล่าสุด 1.7 วิ → 0.26 วิ (แบบเดิม 3 ลูกค้า 14.2 วิ)

CREATE OR REPLACE FUNCTION public.detect_customer_duplicates_ids(p_ids bigint[], p_thresh_name real DEFAULT 0.6, p_thresh_addr real DEFAULT 0.85)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_count int;
begin
  perform extensions.set_limit(p_thresh_name);
  with n as (
    select distinct o.brand_id, o.customer_id, o.province, o.district, o.subdistrict, o.postal_code,
           public.norm_name(o.customer_name) nn, coalesce(o.addr_detail,'') ad
      from public.orders o
     where o.customer_id = any(p_ids) and o.province is not null
  ),
  nd as (select distinct brand_id, customer_id, province, district, nn from n),
  kn as (select distinct brand_id, province, district from n),
  -- แยก 2 ทาง: อำเภอมีค่า → เทียบด้วย = (ใช้ index brand+province+district ได้) · อำเภอว่าง → is not distinct (น้อยมาก)
  pool as (
    select o2.brand_id, o2.customer_id, o2.province, o2.district, o2.customer_name
      from kn join public.orders o2
        on o2.brand_id = kn.brand_id and o2.province = kn.province and o2.district = kn.district
    union
    select o2.brand_id, o2.customer_id, o2.province, o2.district, o2.customer_name
      from kn join public.orders o2
        on o2.brand_id = kn.brand_id and o2.province = kn.province and o2.district is null
     where kn.district is null
  ),
  pn as (select p.brand_id, p.customer_id, p.province, p.district, public.norm_name(p.customer_name) nn from pool p),
  ka as (select distinct brand_id, province, district, subdistrict, postal_code from n),
  -- เหมือนกัน: ที่อยู่ครบ 3 ช่อง → = ใช้ index เต็ม · มีช่องว่าง → is not distinct (น้อยมาก)
  apool as (
    select o2.brand_id, o2.customer_id, o2.province, o2.district, o2.subdistrict, o2.postal_code,
           coalesce(o2.addr_detail,'') ad
      from ka join public.orders o2
        on o2.brand_id = ka.brand_id and o2.province = ka.province and o2.district = ka.district
       and o2.subdistrict = ka.subdistrict and o2.postal_code = ka.postal_code
    union
    select o2.brand_id, o2.customer_id, o2.province, o2.district, o2.subdistrict, o2.postal_code,
           coalesce(o2.addr_detail,'') ad
      from ka join public.orders o2
        on o2.brand_id = ka.brand_id and o2.province = ka.province
       and o2.district    is not distinct from ka.district
       and o2.subdistrict is not distinct from ka.subdistrict
       and o2.postal_code is not distinct from ka.postal_code
     where ka.district is null or ka.subdistrict is null or ka.postal_code is null
  ),
  cand as (
    select a.brand_id, a.customer_id nc_id, p.customer_id cc_id, 'name'::text reason,
           max(extensions.similarity(a.nn, p.nn)) score
      from nd a join pn p
        on p.brand_id = a.brand_id and p.province = a.province
       and p.district is not distinct from a.district and p.customer_id <> a.customer_id
     where a.nn operator(extensions.%) p.nn
     group by 1, 2, 3
    union all
    select a.brand_id, a.customer_id, p.customer_id, 'address'::text,
           max(extensions.similarity(a.ad, p.ad))
      from n a join apool p
        on p.brand_id = a.brand_id and p.province = a.province
       and p.district    is not distinct from a.district
       and p.subdistrict is not distinct from a.subdistrict
       and p.postal_code is not distinct from a.postal_code
       and p.customer_id <> a.customer_id
     where extensions.similarity(a.ad, p.ad) >= p_thresh_addr
     group by 1, 2, 3
  )

  insert into public.customer_review (brand_id, new_customer_id, candidate_customer_id, reason, score)
  select distinct on (least(m.nc_id, m.cc_id), greatest(m.nc_id, m.cc_id))
         m.brand_id, m.nc_id, m.cc_id, m.reason, round(m.score::numeric, 3)
  from cand m
  where not exists (
    select 1 from public.customer_review r
    where least(r.new_customer_id, r.candidate_customer_id) = least(m.nc_id, m.cc_id)
      and greatest(r.new_customer_id, r.candidate_customer_id) = greatest(m.nc_id, m.cc_id)
  )
  order by least(m.nc_id, m.cc_id), greatest(m.nc_id, m.cc_id), m.score desc
  on conflict (new_customer_id, candidate_customer_id) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end $function$;

-- เร็วขึ้นแล้ว → เพิ่มชุดละ 25 → 200 ลูกค้า (ทุก 2 นาที) ให้คิวหมดไวหลังนำเข้าไฟล์ใหญ่
select cron.alter_job(j.jobid, command := 'set statement_timeout = ''5min''; select public.process_dedup_queue(200);')
  from cron.job j where j.jobname = 'dedup-queue';
