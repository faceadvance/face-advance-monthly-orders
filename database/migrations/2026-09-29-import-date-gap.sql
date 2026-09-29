-- 2026-09-29 นำเข้าออเดอร์: ตรวจวันที่ขาดช่วง
-- ถ้าไฟล์ไม่ต่อจากวันล่าสุดใน DB (มีวันที่ข้ามไป) → เว็บถามผู้นำเข้า "ต้องการข้ามวันที่ … เพราะวันนั้นไม่มีข้อมูลใช่ไหม"
--   ยืนยัน → นำเข้า + บันทึกคำตอบลง import_date_skips (ใคร/เมื่อไร/ไฟล์ช่วงไหน) + audit_log.detail.skipped_dates
--   ยกเลิก → ไม่นำเข้าอะไรเลย
-- เข้ากับเว็บรุ่นเก่า: p_confirm_skip_dates = null → ไม่บังคับ (ขึ้น DB ก่อน deploy หน้าเว็บได้)

create table if not exists public.import_date_skips (
  skip_date         date primary key,
  confirmed_by      uuid,
  confirmed_by_name text,
  confirmed_at      timestamptz not null default now(),
  file_first        date,
  file_last         date
);
alter table public.import_date_skips enable row level security;
revoke all on public.import_date_skips from anon, authenticated;

drop function if exists public.app_import_orders(text, jsonb, text);

CREATE OR REPLACE FUNCTION public.app_import_orders(p_token text, p_rows jsonb, p_mode text, p_confirm_skip_dates date[] DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_uid uuid; v_uname text; v_role text;
  v_dupdates text; v_problems jsonb; v_warnings jsonb;
  v_ok boolean; v_error text;
  v_orders_total int; v_orders_ok int; v_items_total int; v_total_sales bigint;
  v_dates jsonb; v_new_cust int;
  v_inserted int := 0; v_new_cust_ins int := 0;
  v_flagged int := 0;
  orow record; irow record;
  v_cust bigint; v_order bigint; v_brand bigint; v_seller bigint; v_prod bigint;
  v_agent bigint;
  v_first date; v_last date; v_prev date; v_missing date[] := '{}'; v_unconf text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','OM') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden_viewer');
  end if;
  if p_mode not in ('preflight','confirm') then
    return jsonb_build_object('authorized', true, 'error', 'bad_mode');
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'ไม่มีข้อมูลในไฟล์');
  end if;

  select id into v_agent from public.brands where name = 'ตัวแทน';

  create temp table _imp_ord on commit drop as
  select (row_number() over ())::int as k,
         nullif(r->>'order_no','')                       as order_no,
         (r->>'ordered_at')::timestamptz                 as ordered_at,
         r->>'customer_name'                             as customer_name,
         r->>'phone'                                     as phone,
         r->>'addr_detail'                               as addr_detail,
         r->>'subdistrict'                               as subdistrict,
         r->>'district'                                  as district,
         r->>'province'                                  as province,
         r->>'postal_code'                               as postal_code,
         r->>'seller_code'                               as seller_code,
         r->>'carrier'                                   as carrier,
         r->>'tracking_no'                               as tracking_no,
         coalesce((r->>'total_sales')::int, 0)           as total_sales,
         r->>'payment_method'                            as payment_method,
         coalesce(r->>'payment_status','รอชำระ')          as payment_status,
         coalesce(r->>'delivery_status','กำลังส่ง')          as delivery_status,
         r->>'note'                                      as note,
         r->'items'                                      as items
  from jsonb_array_elements(p_rows) r;

  create temp table _imp_it on commit drop as
  select o.k,
         it->>'product_name'               as product_name,
         coalesce((it->>'quantity')::int,0) as quantity
  from _imp_ord o
  cross join lateral jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) it
  where coalesce((it->>'quantity')::int,0) > 0;

  create temp table _imp_brand on commit drop as
  with pb as (
    select si.k, b.id as brand_id, (b.id = v_agent) as is_agent
    from _imp_it si
    join public.products p on p.name = si.product_name
    join public.categories c on c.id = p.category_id
    join public.brands b on b.id = c.brand_id
  )
  select o.k,
         case when bool_or(coalesce(pb.is_agent,false)) then 1
              else count(distinct pb.brand_id) end as nbrand,
         case when bool_or(coalesce(pb.is_agent,false)) then v_agent
              else min(pb.brand_id) end            as brand_id
  from _imp_ord o
  left join pb on pb.k = o.k
  group by o.k;

  select string_agg(x.d::text, ', ' order by x.d) into v_dupdates
  from (select distinct (ordered_at at time zone 'Asia/Bangkok')::date d from _imp_ord) x
  where exists (
    select 1 from public.orders ord
    where ord.ordered_at >= (x.d::timestamp at time zone 'Asia/Bangkok')
      and ord.ordered_at <  ((x.d + 1)::timestamp at time zone 'Asia/Bangkok')
  );

  select coalesce(jsonb_agg(jsonb_build_object(
           'order_no', coalesce(o.order_no, 'k'||o.k),
           'reason', case when br.nbrand = 0 then 'สินค้าไม่ตรงกับระบบ'
                          else 'ปนแบรนด์ ('||br.nbrand||' แบรนด์)' end)
         order by o.k), '[]'::jsonb)
    into v_problems
  from _imp_ord o join _imp_brand br on br.k = o.k
  where br.nbrand is null or br.nbrand = 0 or br.nbrand > 1;

  select coalesce(jsonb_agg(distinct si.product_name), '[]'::jsonb) into v_warnings
  from _imp_it si
  left join public.products p on p.name = si.product_name
  where p.id is null;

  select count(*) into v_orders_total from _imp_ord;
  select count(*) into v_orders_ok from _imp_ord o join _imp_brand br on br.k=o.k
    where br.nbrand = 1;
  select count(*) into v_items_total from _imp_it;
  select coalesce(sum(total_sales),0) into v_total_sales from _imp_ord;
  select coalesce(jsonb_agg(d order by d), '[]'::jsonb) into v_dates
    from (select distinct (ordered_at at time zone 'Asia/Bangkok')::date::text d from _imp_ord) x;
  select count(*) into v_new_cust from (
    select distinct br.brand_id, o.phone
    from _imp_ord o join _imp_brand br on br.k=o.k
    where br.nbrand = 1 and o.phone is not null
  ) x
  where not exists (select 1 from public.customer_phones cp
                    where cp.brand_id = x.brand_id and cp.phone = x.phone);

  -- วันที่ขาดช่วง: ตั้งแต่วันถัดจากออเดอร์ล่าสุดก่อนไฟล์ ถึงวันสุดท้ายของไฟล์
  -- ไม่นับวันที่มีในไฟล์ · มีใน DB แล้ว · เคยยืนยันข้ามไว้แล้ว (import_date_skips) · มองย้อนไม่เกิน 366 วัน
  select min(d), max(d) into v_first, v_last
    from (select (ordered_at at time zone 'Asia/Bangkok')::date d from _imp_ord) x;
  if v_first is not null then
    select (max(ordered_at) at time zone 'Asia/Bangkok')::date into v_prev
      from public.orders where ordered_at < (v_first::timestamp at time zone 'Asia/Bangkok');
  end if;
  if v_prev is not null then
    select coalesce(array_agg(g.d order by g.d), '{}') into v_missing
    from (select gs::date d
            from generate_series(greatest(v_prev + 1, v_last - 366)::timestamp, v_last::timestamp, interval '1 day') gs) g
    where not exists (select 1 from _imp_ord o where (o.ordered_at at time zone 'Asia/Bangkok')::date = g.d)
      and not exists (select 1 from public.import_date_skips s where s.skip_date = g.d)
      and not exists (select 1 from public.orders ord
                       where ord.ordered_at >= (g.d::timestamp at time zone 'Asia/Bangkok')
                         and ord.ordered_at <  ((g.d + 1)::timestamp at time zone 'Asia/Bangkok'));
  end if;

  v_error := case when v_dupdates is not null
                  then 'วันที่ซ้ำกับที่นำเข้าแล้ว: '||v_dupdates||' — ยกเลิกทั้งไฟล์'
                  else null end;
  -- เว็บรุ่นใหม่ส่ง p_confirm_skip_dates มาเสมอตอน confirm (ไม่มีวันขาด = array ว่าง)
  -- ต้องครอบคลุมทุกวันที่ขาด ไม่งั้นไม่นำเข้าเลย · null = เว็บรุ่นเก่า (ไม่บังคับ ช่วงรอ deploy)
  if p_mode = 'confirm' and p_confirm_skip_dates is not null then
    select string_agg(to_char(m, 'DD/MM/YYYY'), ', ' order by m) into v_unconf
      from unnest(v_missing) m where not (m = any(p_confirm_skip_dates));
    if v_unconf is not null then
      v_error := coalesce(v_error || ' · ', '') || 'มีวันที่ขาดที่ยังไม่ได้ยืนยันข้าม: ' || v_unconf || ' — ยังไม่ได้นำเข้า';
    end if;
  end if;
  v_ok := (v_error is null) and (jsonb_array_length(v_problems) = 0);

  if p_mode = 'confirm' and v_ok then
    for orow in select * from _imp_ord order by k loop
      select br.brand_id into v_brand from _imp_brand br where br.k = orow.k;

      v_seller := null;
      if orow.seller_code is not null then
        select id into v_seller from public.sellers
         where employee_code = orow.seller_code order by is_active desc, id limit 1;
      end if;

      select cp.customer_id into v_cust from public.customer_phones cp
       where cp.brand_id = v_brand and cp.phone = orow.phone;
      if v_cust is null then
        insert into public.customers(brand_id) values (v_brand) returning id into v_cust;
        insert into public.customer_phones(customer_id, brand_id, phone)
          values (v_cust, v_brand, orow.phone);
        v_new_cust_ins := v_new_cust_ins + 1;
      end if;

      insert into public.orders(
        brand_id, customer_id, order_no, ordered_at, customer_name, phone,
        addr_detail, subdistrict, district, province, postal_code, seller_id,
        total_sales, payment_method, carrier, tracking_no, payment_status, delivery_status, note)
      values(
        v_brand, v_cust, orow.order_no, orow.ordered_at,
        coalesce(orow.customer_name, orow.phone), orow.phone,
        orow.addr_detail, orow.subdistrict, orow.district, orow.province, orow.postal_code, v_seller,
        orow.total_sales, orow.payment_method, orow.carrier, orow.tracking_no, orow.payment_status, orow.delivery_status, orow.note)
      returning id into v_order;
      v_inserted := v_inserted + 1;

      for irow in select * from _imp_it where k = orow.k loop
        select id into v_prod from public.products where name = irow.product_name limit 1;
        if v_prod is not null then
          insert into public.order_items(order_id, product_id, quantity)
            values (v_order, v_prod, irow.quantity) on conflict (order_id, product_id) do update set quantity = order_items.quantity + excluded.quantity;
        end if;
      end loop;
    end loop;

    -- หาลูกค้าซ้ำย้ายไปทำเบื้องหลัง (process_dedup_queue ทุก 2 นาที) — ลูกค้าใหม่เข้าคิวเองด้วย trigger บน customers
    -- เดิมเรียก detect_customer_duplicates ตรงนี้ → ข้อมูลโต (281k ออเดอร์) ใช้ 17–48 วิ เกินเพดาน 20 วิ → นำเข้าล้มทั้งไฟล์ (2026-09-29)
    v_flagged := 0;

    select username into v_uname from public.app_users where id = v_uid;
    -- บันทึกคำตอบ "ข้ามวันที่ เพราะวันนั้นไม่มีข้อมูล" (เฉพาะวันที่เซิร์ฟเวอร์คำนวณว่าขาดจริง)
    if p_confirm_skip_dates is not null and cardinality(v_missing) > 0 then
      insert into public.import_date_skips(skip_date, confirmed_by, confirmed_by_name, file_first, file_last)
      select m, v_uid, v_uname, v_first, v_last from unnest(v_missing) m
      on conflict (skip_date) do nothing;
    end if;
    insert into public.audit_log(user_id, username, event, detail)
      values (v_uid, v_uname, 'import_orders',
              jsonb_build_object('orders', v_inserted, 'items', v_items_total,
                                 'new_customers', v_new_cust_ins, 'dates', v_dates,
                                 'flagged_dupes', v_flagged,
                                 'skipped_dates', case when p_confirm_skip_dates is not null
                                                       then to_jsonb(v_missing) end));
  end if;

  return jsonb_build_object(
    'authorized', true, 'mode', p_mode, 'ok', v_ok, 'error', v_error,
    'problems', v_problems, 'warnings', v_warnings,
    'orders_total', v_orders_total, 'orders_ok', v_orders_ok,
    'items_total', v_items_total, 'total_sales', v_total_sales, 'dates', v_dates,
    'new_customers', case when p_mode='confirm' and v_ok then v_new_cust_ins else v_new_cust end,
    'inserted', case when p_mode='confirm' and v_ok then v_inserted else 0 end,
    'flagged_dupes', case when p_mode='confirm' and v_ok then v_flagged else 0 end,
    'missing_dates', to_jsonb(v_missing),
    'last_date_before', v_prev
  );
end $function$;

grant execute on function public.app_import_orders(text, jsonb, text, date[]) to anon, authenticated, service_role;
notify pgrst, 'reload schema';
