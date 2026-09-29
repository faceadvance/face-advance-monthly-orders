-- นำเข้าออเดอร์ไม่ล้มเพราะขั้นหาลูกค้าซ้ำ: ย้ายการหาลูกค้าซ้ำไปทำเบื้องหลัง (เจ้านายอนุมัติ 2026-09-29)
-- ปัญหา: app_import_orders เรียก detect_customer_duplicates ในคำขอเดียวกับการบันทึก · ข้อมูลโตเป็น 281k ออเดอร์ บน NANO
--   → ขั้นนี้ใช้ 17–48 วิ (pg_stat_statements) เกิน statement_timeout ของ anon 20 วิ → HTTP 500 · ไม่มีออเดอร์ถูกบันทึก
-- แก้: (1) app_import_orders ไม่หาลูกค้าซ้ำแล้ว (แก้บรรทัดเดียว · คีย์ flagged_dupes ยังส่ง = 0 · หน้าเว็บไม่ได้ใช้)
--      (2) trigger บน customers → ลูกค้าใหม่ทุกคน (ทุกช่องทาง รวมนำเข้าตรง DB) เข้าคิว dedup_queue
--      (3) pg_cron ทุก 2 นาที → process_dedup_queue หยิบคิวทีละชุด → detect_customer_duplicates_ids (เกณฑ์เดิมเป๊ะ) → คู่ที่เจอเข้า EDITH
-- ผลต่อผู้ใช้: นำเข้าเสร็จเร็ว · คู่ลูกค้าอาจซ้ำโผล่ใน EDITH ภายในไม่กี่นาทีแทนทันที

create table if not exists public.dedup_queue (
  customer_id bigint primary key references public.customers(id) on delete cascade,
  queued_at timestamptz not null default now()
);
alter table public.dedup_queue enable row level security;
revoke all on public.dedup_queue from anon, authenticated;

create or replace function public.enqueue_new_customer_dedup() returns trigger
 language plpgsql security definer set search_path to '' as $$
begin
  insert into public.dedup_queue(customer_id) values (new.id) on conflict do nothing;
  return null;
end $$;
drop trigger if exists customers_enqueue_dedup on public.customers;
create trigger customers_enqueue_dedup after insert on public.customers
  for each row execute function public.enqueue_new_customer_dedup();

CREATE OR REPLACE FUNCTION public.detect_customer_duplicates_ids(p_ids bigint[], p_thresh_name real DEFAULT 0.6, p_thresh_addr real DEFAULT 0.85)
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_count int;
begin
  perform extensions.set_limit(p_thresh_name);
  with newc as (
    select id from public.customers where id = any(p_ids)
  ),
  cand as (
    -- ชื่อคล้าย + ต้องอยู่จังหวัด+อำเภอเดียวกัน (กันชื่อเล่นซ้ำข้ามพื้นที่)
    select o1.brand_id, o1.customer_id nc_id, o2.customer_id cc_id, 'name'::text reason,
           max(extensions.similarity(public.norm_name(o1.customer_name), public.norm_name(o2.customer_name))) score
    from newc
    join public.orders o1 on o1.customer_id = newc.id
    join public.orders o2 on o2.brand_id = o1.brand_id and o2.customer_id <> o1.customer_id
       and o2.province is not distinct from o1.province
       and o2.district is not distinct from o1.district
    where o1.province is not null
      and public.norm_name(o1.customer_name) operator(extensions.%) public.norm_name(o2.customer_name)
    group by o1.brand_id, o1.customer_id, o2.customer_id
    union all
    -- ที่อยู่เดียวกัน (จังหวัด+อำเภอ+ตำบล+ไปรษณีย์ตรง และบ้านเลขที่คล้ายมาก)
    select o1.brand_id, o1.customer_id, o2.customer_id, 'address'::text,
           max(extensions.similarity(coalesce(o1.addr_detail,''), coalesce(o2.addr_detail,'')))
    from newc
    join public.orders o1 on o1.customer_id = newc.id
    join public.orders o2 on o2.brand_id = o1.brand_id and o2.customer_id <> o1.customer_id
       and o2.province     is not distinct from o1.province
       and o2.district     is not distinct from o1.district
       and o2.subdistrict  is not distinct from o1.subdistrict
       and o2.postal_code  is not distinct from o1.postal_code
    where o1.province is not null
      and extensions.similarity(coalesce(o1.addr_detail,''), coalesce(o2.addr_detail,'')) >= p_thresh_addr
    group by o1.brand_id, o1.customer_id, o2.customer_id
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

create or replace function public.process_dedup_queue(p_limit int default 100) returns integer
 language plpgsql security definer set search_path to '' as $$
declare v_ids bigint[]; v_n int;
begin
  select array_agg(customer_id) into v_ids
    from (select customer_id from public.dedup_queue order by queued_at limit p_limit for update skip locked) q;
  if v_ids is null then return 0; end if;
  v_n := public.detect_customer_duplicates_ids(v_ids);
  delete from public.dedup_queue where customer_id = any(v_ids);
  return v_n;
end $$;
revoke all on function public.process_dedup_queue(int) from public, anon, authenticated;
revoke all on function public.detect_customer_duplicates_ids(bigint[], real, real) from public, anon, authenticated;
revoke all on function public.enqueue_new_customer_dedup() from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public.app_import_orders(p_token text, p_rows jsonb, p_mode text)
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

  v_error := case when v_dupdates is not null
                  then 'วันที่ซ้ำกับที่นำเข้าแล้ว: '||v_dupdates||' — ยกเลิกทั้งไฟล์'
                  else null end;
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
    insert into public.audit_log(user_id, username, event, detail)
      values (v_uid, v_uname, 'import_orders',
              jsonb_build_object('orders', v_inserted, 'items', v_items_total,
                                 'new_customers', v_new_cust_ins, 'dates', v_dates,
                                 'flagged_dupes', v_flagged));
  end if;

  return jsonb_build_object(
    'authorized', true, 'mode', p_mode, 'ok', v_ok, 'error', v_error,
    'problems', v_problems, 'warnings', v_warnings,
    'orders_total', v_orders_total, 'orders_ok', v_orders_ok,
    'items_total', v_items_total, 'total_sales', v_total_sales, 'dates', v_dates,
    'new_customers', case when p_mode='confirm' and v_ok then v_new_cust_ins else v_new_cust end,
    'inserted', case when p_mode='confirm' and v_ok then v_inserted else 0 end,
    'flagged_dupes', case when p_mode='confirm' and v_ok then v_flagged else 0 end
  );
end $function$;

-- ตั้งงานเบื้องหลัง (รันครั้งเดียว · ต้องมี pg_cron: create extension if not exists pg_cron with schema pg_catalog;)
-- select cron.schedule('dedup-queue', '*/2 * * * *', $$set statement_timeout = '5min'; select public.process_dedup_queue(25);$$);
