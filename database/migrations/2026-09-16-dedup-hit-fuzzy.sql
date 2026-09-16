-- ═══════════════════════════════════════════════════════════════════════════
-- EDITH › Dedup — บอกให้ชัดว่า "ตรงกัน" กับ "คล้ายกัน" ไม่ใช่เรื่องเดียวกัน
--
-- ปัญหา : detect_customer_duplicates จับด้วย "ความคล้าย" (trigram) แต่ _dedup_vals
--         ตั้งธง hit ด้วย "ตรงเป๊ะ" เท่านั้น → 35/205 เคสไม่มีสีเลย ทั้งที่เข้าเงื่อนไขถูก
--         พนักงานจึงไม่รู้ว่าระบบจับที่จุดไหน
--
-- ⚠️ บทเรียน (2026-09-16): ลองแก้ให้ hit ครอบ "คล้าย" ด้วย → ป้ายบนจอยังเขียน
--    "🎯 ตรงกัน" (ข้อความอยู่ใน frontend) กลายเป็นยืนยันสิ่งที่ไม่จริง
--    เช่น "เอ๋" ⟷ "เอ็ม" คล้าย 0.60 แต่ป้ายบอกว่าตรงกัน → rollback ทันที
--    ➜ ต้องส่ง "ระดับความคล้าย" มาให้ frontend แยกข้อความเอง ไม่ใช่ยัดลง hit
--
-- แก้    : เพิ่มฟิลด์ `sim` ในผลลัพธ์ (ไม่แตะความหมายของ `hit`)
--            hit = ตรงเป๊ะ (ไม่สนช่องว่าง/วรรคตอน)   ← ความหมายเดิม
--            sim = คะแนนความคล้ายสูงสุดกับอีกฝั่ง ใส่มาเฉพาะเมื่อ
--                  "ไม่ตรงเป๊ะ แต่คล้ายถึงเกณฑ์ที่ตัวจับใช้" มิฉะนั้น null
--                    ชื่อ   → >= 0.60   ·   ที่อยู่ → >= 0.85   ·   เบอร์ → ไม่มี fuzzy
--
-- 🔒 BACKWARD COMPATIBLE — frontend เวอร์ชันที่ deploy อยู่ไม่รู้จัก `sim` จะข้ามไป
--    และ `hit` ยังหมายความเหมือนเดิมเป๊ะ → พฤติกรรมบนจอ "ไม่เปลี่ยน" จนกว่าจะ deploy
--    frontend ที่อ่าน `sim` (deploy frontend ก่อนหรือหลังก็ได้ ไม่พัง)
--
-- rollback: ดูท้ายไฟล์
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public._dedup_key(t text)
returns text language sql immutable set search_path to ''
as $fn$
  select lower(regexp_replace(coalesce(t,''), '[[:space:].,/()_''"|–—-]', '', 'g'))
$fn$;

create or replace function public._dedup_vals(p_cid bigint, p_other bigint, p_kind text)
returns jsonb language sql stable security definer
set search_path to 'public', 'extensions'
as $fn$
  with raw as (
    select case p_kind
        when 'name'  then customer_name
        when 'phone' then phone
        else nullif(trim(coalesce(addr_detail,'')||' '||coalesce(subdistrict,'')||' '||coalesce(district,'')||' '||coalesce(province,'')||' '||coalesce(postal_code,'')),'')
      end as v,
      addr_detail as ad
    from public.orders where customer_id = p_cid
  ),
  vals as (
    -- ยุบค่าที่ต่างแค่ช่องว่าง/วรรคตอน (แสดงตัวแทน 1 อัน)
    select distinct on (public._dedup_key(v)) v, ad
    from raw where v is not null and v <> ''
    order by public._dedup_key(v), v
  ),
  calc as (
    select vals.v, vals.ad,
      -- ตรงเป๊ะ (ความหมายเดิมของ hit)
      case p_kind
        when 'name'  then exists(select 1 from public.orders o2 where o2.customer_id=p_other
                                 and public.norm_name(o2.customer_name) = public.norm_name(vals.v))
        when 'phone' then exists(select 1 from public.orders o2 where o2.customer_id=p_other
                                 and o2.phone = vals.v)
        else exists(select 1 from public.orders o2 where o2.customer_id=p_other
                    and public._dedup_key(nullif(trim(concat_ws(' ', o2.addr_detail, o2.subdistrict, o2.district, o2.province, o2.postal_code)),''))
                      = public._dedup_key(vals.v))
      end as is_exact,
      -- ความคล้ายสูงสุดกับอีกฝั่ง (เทียบฟิลด์เดียวกับที่ตัวจับใช้)
      case p_kind
        when 'name'  then (select max(extensions.similarity(public.norm_name(o2.customer_name), public.norm_name(vals.v)))
                           from public.orders o2 where o2.customer_id=p_other)
        when 'phone' then null
        else (select max(extensions.similarity(coalesce(o2.addr_detail,''), coalesce(vals.ad,'')))
              from public.orders o2 where o2.customer_id=p_other)
      end as sim_raw
    from vals
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'v', v,
           'hit', is_exact,
           'sim', case when is_exact or sim_raw is null then null
                       when p_kind='name' and sim_raw >= 0.60 then round(sim_raw::numeric, 2)
                       when p_kind='addr' and sim_raw >= 0.85 then round(sim_raw::numeric, 2)
                       else null end
         ) order by v), '[]'::jsonb)
  from calc
$fn$;

-- ── ROLLBACK (คืนพฤติกรรมเดิม ไม่มีฟิลด์ sim) ───────────────────────────────
-- create or replace function public._dedup_vals(p_cid bigint, p_other bigint, p_kind text)
-- returns jsonb language sql stable security definer set search_path to 'public','extensions'
-- as $fn$
--   with raw as (select case p_kind when 'name' then customer_name when 'phone' then phone
--       else nullif(trim(coalesce(addr_detail,'')||' '||coalesce(subdistrict,'')||' '||coalesce(district,'')||' '||coalesce(province,'')||' '||coalesce(postal_code,'')),'') end as v
--     from public.orders where customer_id=p_cid),
--   vals as (select distinct on (regexp_replace(v,'\s','','g')) v from raw where v is not null and v<>''
--            order by regexp_replace(v,'\s','','g'), v)
--   select coalesce(jsonb_agg(jsonb_build_object('v', v, 'hit', case p_kind
--       when 'name'  then exists(select 1 from public.orders o2 where o2.customer_id=p_other and public.norm_name(o2.customer_name)=public.norm_name(vals.v))
--       when 'phone' then exists(select 1 from public.orders o2 where o2.customer_id=p_other and o2.phone=vals.v)
--       else exists(select 1 from public.orders o2 where o2.customer_id=p_other and regexp_replace(nullif(trim(coalesce(o2.addr_detail,'')||' '||coalesce(o2.subdistrict,'')||' '||coalesce(o2.district,'')||' '||coalesce(o2.province,'')||' '||coalesce(o2.postal_code,'')),''),'\s','','g')=regexp_replace(vals.v,'\s','','g'))
--     end) order by v), '[]'::jsonb) from vals
-- $fn$;
