#!/bin/bash
set -e
MO="$1"; YMM="$2"
set -a; . ~/.claude/secrets.env >/dev/null 2>&1; set +a
P(){ psql "$SUPABASE_DB_URL_FACEADVANCE" -v ON_ERROR_STOP=1 -q -A -t "$@"; }
echo "════════ $MO ($YMM) ════════"
python3 /tmp/hist/transform.py "$MO"
P -c "truncate public._stg_hist" -c "\copy public._stg_hist(mo,src_row,order_no,ordered_at,customer_name,phone,addr_detail,subdistrict,district,province,postal_code,seller_code,carrier,tracking_no,total_sales,payment_method,payment_status,delivery_status,note,return_reason,status_detail,brand_name,items) from '/tmp/hist/$YMM.tsv'" >/dev/null
# ---- gate: ต้องผ่านทุกข้อ ไม่ผ่าน = หยุด ----
GATE=$(P -c "
select string_agg(msg,' · ') from (
 select 'seller ไม่พบ: '||string_agg(distinct s.seller_code,',') msg from public._stg_hist s
   left join public.sellers e on e.employee_code=s.seller_code where s.seller_code is not null and e.id is null
 union all select 'สินค้าไม่พบ: '||string_agg(distinct it->>'name',',') from public._stg_hist s
   cross join lateral jsonb_array_elements(s.items) it left join public.products p on p.name=it->>'name' where p.id is null
 union all select 'brand ไม่พบ: '||string_agg(distinct s.brand_name,',') from public._stg_hist s
   left join public.brands b on b.name=s.brand_name where b.id is null
 union all select 'phone ผิดกฎ: '||count(*) from public._stg_hist where phone !~ '^[0-9]{8,15}\$' having count(*)>0
 union all select 'zip ผิดกฎ: '||count(*) from public._stg_hist where postal_code !~ '^[0-9]{5}\$' having count(*)>0
 union all select 'order_no ชน: '||count(*) from public._stg_hist s join public.orders o on o.order_no=s.order_no having count(*)>0
 union all select 'trk ชน DB: '||count(*) from public._stg_hist s join public.orders o on btrim(o.tracking_no)=btrim(s.tracking_no) where s.tracking_no is not null having count(*)>0
 union all select 'แบรนด์ไม่ตรงสินค้าจริง: '||count(*) from (
   select s.k from public._stg_hist s cross join lateral jsonb_array_elements(s.items) it
   join public.products p on p.name=it->>'name' join public.categories c on c.id=p.category_id
   join public.brands b on b.id=c.brand_id group by s.k, s.brand_name
   having (s.brand_name<>'ตัวแทน' and bool_or(b.name='ตัวแทน'))
      or (s.brand_name='ตัวแทน' and not bool_or(b.name='ตัวแทน'))
      or (not bool_or(b.name='ตัวแทน') and count(distinct b.name) > 1)
      or (not bool_or(b.name='ตัวแทน') and s.brand_name <> min(b.name))) z having count(*)>0
) q where msg is not null;")
if [ -n "$GATE" ]; then echo "🔴 GATE ไม่ผ่าน: $GATE"; exit 1; fi
echo "  gate ✅"
P << SQL >/dev/null
set statement_timeout = 0;
begin;
with need as (select distinct b.id brand_id, s.phone from public._stg_hist s join public.brands b on b.name=s.brand_name
   where not exists(select 1 from public.customer_phones cp where cp.brand_id=b.id and cp.phone=s.phone)),
 ins as (insert into public.customers(brand_id) select brand_id from need returning id, brand_id),
 pair as (select n.brand_id,n.phone,i.id customer_id from
   (select *, row_number() over (partition by brand_id order by phone) rn from need) n
   join (select *, row_number() over (partition by brand_id order by id) rn from ins) i on i.brand_id=n.brand_id and i.rn=n.rn),
 ph as (insert into public.customer_phones(customer_id,brand_id,phone) select customer_id,brand_id,phone from pair returning customer_id)
insert into public._bak_hist_import(batch,kind,id) select 'HIST$YMM','customer',customer_id from ph;
with ins as (insert into public.orders(brand_id,customer_id,order_no,ordered_at,customer_name,phone,
    addr_detail,subdistrict,district,province,postal_code,seller_id,total_sales,payment_method,
    carrier,tracking_no,payment_status,delivery_status,note,return_reason,status_detail)
  select b.id,cp.customer_id,s.order_no,s.ordered_at,s.customer_name,s.phone,s.addr_detail,s.subdistrict,
    s.district,s.province,s.postal_code,e.id,s.total_sales,s.payment_method,s.carrier,s.tracking_no,
    s.payment_status,s.delivery_status,s.note,s.return_reason,s.status_detail
  from public._stg_hist s join public.brands b on b.name=s.brand_name
  join public.customer_phones cp on cp.brand_id=b.id and cp.phone=s.phone
  left join public.sellers e on e.employee_code=s.seller_code order by s.k returning id, order_no)
update public._stg_hist s set dst_order_id=i.id from ins i where i.order_no=s.order_no;
insert into public.order_items(order_id,product_id,quantity)
select s.dst_order_id,p.id,sum((it->>'qty')::int) from public._stg_hist s
cross join lateral jsonb_array_elements(s.items) it join public.products p on p.name=it->>'name'
group by s.dst_order_id,p.id
on conflict (order_id,product_id) do update set quantity=order_items.quantity+excluded.quantity;
insert into public._bak_hist_import(batch,kind,id) select 'HIST$YMM','order',dst_order_id from public._stg_hist where dst_order_id is not null;
commit;
SQL
P -c "
select '  ✅ นำเข้า '||count(*)||' ออเดอร์ · '||to_char(sum(total_sales),'FM999,999,999')||' บาท'
  from public.orders where order_no like 'HIST$YMM-%'
union all select '  ตรวจ: dst ว่าง='||(select count(*) from public._stg_hist where dst_order_id is null)
  ||' · ฟิลด์ผิด='||(select count(*) from public.orders o join public._stg_hist s on s.dst_order_id=o.id
     where o.ordered_at<>s.ordered_at or o.customer_name<>s.customer_name or o.phone<>s.phone
       or o.total_sales<>s.total_sales or coalesce(o.tracking_no,'~')<>coalesce(s.tracking_no,'~')
       or o.delivery_status<>s.delivery_status or o.payment_status<>s.payment_status)
  ||' · ลูกค้าผูกผิด='||(select count(*) from public.orders o join public.customers c on c.id=o.customer_id
     join public._stg_hist s on s.dst_order_id=o.id where c.brand_id<>o.brand_id)
  ||' · qty='||case when (select sum((it->>'qty')::int) from public._stg_hist s cross join lateral jsonb_array_elements(s.items) it)
     = (select sum(oi.quantity) from public.order_items oi join public.orders o on o.id=oi.order_id where o.order_no like 'HIST$YMM-%')
     then 'ตรง' else 'ไม่ตรง' end;"
