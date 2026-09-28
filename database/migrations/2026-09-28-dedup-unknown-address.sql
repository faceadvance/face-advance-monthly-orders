-- EDITH ลูกค้าอาจซ้ำ: "ไม่ทราบที่อยู่" (ข้อมูลย้อนหลังที่ไม่มีที่อยู่) ไม่นับเป็นที่อยู่ตรงกัน/คล้ายกัน
-- เจ้านายสั่ง 2026-09-28: "กรณี ไม่ทราบที่อยู่ ไม่ต้องให้คะแนน ไม่ใช่เกณฑ์ที่เอามาคิด"
-- ต้นเรื่อง: ออเดอร์ย้อนหลัง 2022–2024 ใส่ addr_detail = 'ไม่ทราบที่อยู่' → สองลูกค้าที่มีค่านี้ถูกโชว์ "🎯 ตรงกัน" ผิด
-- ขอบเขต: เฉพาะป้าย hit/sim ในหน้ารวมลูกค้า (_dedup_vals) · ตัวหาลูกค้าซ้ำ (detect_customer_duplicates) ไม่เกี่ยว เพราะข้าม province ว่างอยู่แล้ว
CREATE OR REPLACE FUNCTION public._dedup_vals(p_cid bigint, p_other bigint, p_kind text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
        else vals.ad is distinct from 'ไม่ทราบที่อยู่'   -- ข้อมูลเก่าไม่มีที่อยู่ → ไม่ใช่เกณฑ์ (เจ้านายสั่ง 2026-09-28)
             and exists(select 1 from public.orders o2 where o2.customer_id=p_other
                    and public._dedup_key(nullif(trim(concat_ws(' ', o2.addr_detail, o2.subdistrict, o2.district, o2.province, o2.postal_code)),''))
                      = public._dedup_key(vals.v))
      end as is_exact,
      -- ความคล้ายสูงสุดกับอีกฝั่ง (เทียบฟิลด์เดียวกับที่ตัวจับใช้)
      case p_kind
        when 'name'  then (select max(extensions.similarity(public.norm_name(o2.customer_name), public.norm_name(vals.v)))
                           from public.orders o2 where o2.customer_id=p_other)
        when 'phone' then null
        else (select max(extensions.similarity(coalesce(o2.addr_detail,''), coalesce(vals.ad,'')))
              from public.orders o2 where o2.customer_id=p_other
               and vals.ad is distinct from 'ไม่ทราบที่อยู่' and o2.addr_detail is distinct from 'ไม่ทราบที่อยู่')
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
$function$;
