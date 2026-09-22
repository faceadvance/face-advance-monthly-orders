-- 2026-09-22 · หน้ายอดขาย: เพิ่ม "ยอดแยกตามฝ่าย" (แอดมิน / CRM)
--
-- เจ้านายขอ: "แยกยอดขายทีม แอดมิน กับ CRM ด้วย"
-- ต่อยอดจาก 2026-09-18-sales-dashboard-cards.sql — เพิ่มก้อน `depts` ในผลลัพธ์ อย่างอื่นคงเดิมทุกตัว
--
-- ฝ่ายมาจาก sellers.department (ตรวจกับข้อมูลจริง 2026-09-22):
--   admin  33 คน / 4 ทีม      → "แอดมิน"
--   crm    40 คน / 4 ทีม      → "CRM"
--   อื่นๆ    1 คน · ไม่มีทีม     ┐
--   ออเดอร์ที่ seller_id ว่าง 33 ใบ ┘ → รวมเป็น "อื่นๆ" เพื่อให้ผลบวก 3 ฝ่าย = ยอดรวมเป๊ะ
--   🔴 ห้ามตัด "อื่นๆ" ออก ไม่งั้นการ์ดจะบวกไม่ครบแล้วเจ้านายจับได้ว่าตัวเลขเพี้ยน
--
-- นิยามเดิมทั้งหมด: ยอดขาย = payment_status in ('ชำระแล้ว','รอชำระ') · ตีกลับ = delivery_status='ตีกลับ'
--                  ไม่นับแบรนด์ 'ตัวแทน' · กรอง order_no LIKE 'MOCK2512-%' ออก

create or replace function public.app_sales_dashboard(
  p_token text,
  p_gran  text default 'month',
  p_from  date default null,
  p_to    date default null,
  p_brand text default null,
  p_team  bigint default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_uid uuid; v_role text;
  v_min date; v_max date; v_from date; v_to date;
  v_span int; v_pfrom date; v_pto date;
  v_out jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role is null or v_role not in ('Adm','Vm','Vw') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;
  if p_gran not in ('year','month','day') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_gran');
  end if;

  select min((ordered_at at time zone 'Asia/Bangkok')::date),
         max((ordered_at at time zone 'Asia/Bangkok')::date)
    into v_min, v_max
  from public.orders o join public.brands b on b.id = o.brand_id
  where o.order_no not like 'MOCK2512-%' and b.name <> 'ตัวแทน';
  if v_min is null then
    return jsonb_build_object('authorized', true, 'ok', true, 'empty', true);
  end if;

  v_from := coalesce(p_from, case p_gran
              when 'year'  then v_min
              when 'month' then date_trunc('year',  v_max)::date
              else              date_trunc('month', v_max)::date end);
  v_to   := coalesce(p_to, v_max);
  if v_from > v_to then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_range');
  end if;
  v_span  := (v_to - v_from) + 1;
  v_pto   := v_from - 1;
  v_pfrom := v_pto - (v_span - 1);

  with src as (
    select (o.ordered_at at time zone 'Asia/Bangkok')::date as d,
           b.name as brand, o.total_sales as amt,
           o.payment_status as pay, o.delivery_status as dlv,
           -- ฝ่าย: ค่าที่ไม่ใช่ admin/crm และออเดอร์ที่ไม่มีเซล รวมเป็น "อื่นๆ"
           case s.department when 'admin' then 'แอดมิน' when 'crm' then 'CRM' else 'อื่นๆ' end as dept
    from public.orders o
    join public.brands b on b.id = o.brand_id
    left join public.sellers s on s.id = o.seller_id
    left join public.teams   t on t.id = s.team_id
    where o.order_no not like 'MOCK2512-%'
      and b.name <> 'ตัวแทน'
      and (p_brand is null or b.name = p_brand)
      and (p_team is null or (p_team = -1 and t.id is null) or t.id = p_team)
  ),
  cur  as (select * from src where d between v_from and v_to),
  prev as (select * from src where d between v_pfrom and v_pto),
  agg as (
    select
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','รอชำระ')),0)       as sales,
      coalesce(sum(amt) filter (where pay = 'ชำระแล้ว'),0)                   as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)                     as waiting,
      coalesce(sum(amt) filter (where dlv = 'ตีกลับ'),0)                     as ret_amt,
      count(*)                                                               as n_all,
      count(*) filter (where dlv = 'ส่งสำเร็จ')                              as n_done,
      count(*) filter (where dlv = 'ตีกลับ')                                 as n_ret,
      count(*) filter (where pay in ('ชำระแล้ว','รอชำระ'))                   as n_sales,
      count(*) filter (where pay = 'ชำระแล้ว')                               as n_paid,
      count(*) filter (where pay = 'รอชำระ')                                 as n_waiting
    from cur
  ),
  pagg as (
    select coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','รอชำระ')),0) as sales,
           count(*) filter (where pay in ('ชำระแล้ว','รอชำระ'))             as n_sales
    from prev
  ),
  brands as (
    select brand,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','รอชำระ')),0) as sales,
      coalesce(sum(amt) filter (where pay = 'ชำระแล้ว'),0)             as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)               as waiting,
      coalesce(sum(amt) filter (where dlv = 'ตีกลับ'),0)               as ret_amt,
      count(*) filter (where pay in ('ชำระแล้ว','รอชำระ'))             as n_sales,
      count(*) filter (where dlv = 'ตีกลับ')                           as n_ret
    from cur group by brand
  ),
  depts as (
    select dept,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','รอชำระ')),0) as sales,
      coalesce(sum(amt) filter (where pay = 'ชำระแล้ว'),0)             as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)               as waiting,
      coalesce(sum(amt) filter (where dlv = 'ตีกลับ'),0)               as ret_amt,
      count(*) filter (where pay in ('ชำระแล้ว','รอชำระ'))             as n_sales,
      count(*) filter (where dlv = 'ตีกลับ')                           as n_ret
    from cur group by dept
  ),
  -- ฝ่าย × แบรนด์ (เจ้านายขอเพิ่ม 2026-09-22): แอดมิน/CRM ขายแบรนด์ไหนไปเท่าไหร่
  dept_brands as (
    select dept, brand,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','รอชำระ')),0) as sales,
      coalesce(sum(amt) filter (where pay = 'ชำระแล้ว'),0)             as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)               as waiting,
      count(*) filter (where pay in ('ชำระแล้ว','รอชำระ'))             as n_sales
    from cur group by dept, brand
  )
  select jsonb_build_object(
    'authorized', true, 'ok', true,
    'gran', p_gran, 'from', v_from, 'to', v_to,
    'prev_from', v_pfrom, 'prev_to', v_pto,
    'bounds', jsonb_build_object('min', v_min, 'max', v_max),
    'sales', jsonb_build_object(
        'total', (select sales from agg), 'paid', (select paid from agg), 'waiting', (select waiting from agg),
        'orders', (select n_sales from agg), 'orders_paid', (select n_paid from agg), 'orders_waiting', (select n_waiting from agg)),
    'prev', jsonb_build_object('total', (select sales from pagg), 'orders', (select n_sales from pagg)),
    'returns', jsonb_build_object('amount', (select ret_amt from agg), 'orders', (select n_ret from agg)),
    'counts', jsonb_build_object(
        'all', (select n_all from agg), 'done', (select n_done from agg), 'returned', (select n_ret from agg)),
    'brands', coalesce((select jsonb_agg(jsonb_build_object(
        'name', brand, 'sales', sales, 'paid', paid, 'waiting', waiting,
        'ret_amount', ret_amt, 'orders', n_sales, 'ret_orders', n_ret) order by sales desc)
      from brands), '[]'::jsonb),
    -- เรียงคงที่ แอดมิน → CRM → อื่นๆ (ไม่เรียงตามยอด เพื่อให้ตำแหน่งในการ์ดไม่สลับไปมาเวลาเปลี่ยนช่วง)
    'depts', coalesce((select jsonb_agg(jsonb_build_object(
        'name', dept, 'sales', sales, 'paid', paid, 'waiting', waiting,
        'ret_amount', ret_amt, 'orders', n_sales, 'ret_orders', n_ret)
        order by case dept when 'แอดมิน' then 1 when 'CRM' then 2 else 3 end)
      from depts), '[]'::jsonb),
    'dept_brands', coalesce((select jsonb_agg(jsonb_build_object(
        'dept', dept, 'brand', brand, 'sales', sales, 'paid', paid,
        'waiting', waiting, 'orders', n_sales)
        order by case dept when 'แอดมิน' then 1 when 'CRM' then 2 else 3 end, sales desc)
      from dept_brands), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $function$;

grant execute on function public.app_sales_dashboard(text,text,date,date,text,bigint)
  to anon, authenticated, service_role;
