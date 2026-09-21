-- 2026-09-18 · ปรับ RPC หน้ายอดขายให้เป็น "การ์ดสรุป" ตามที่เจ้านายเคาะใหม่
--
-- เจ้านายโละของเดิม (กราฟเทียบช่วง + รายทีม/รายคน) แล้วขอแค่ 4 การ์ด:
--   1. ยอดรวม (แยก ชำระแล้ว / รอชำระ)
--   2. ยอดแยกตามแบรนด์
--   3. ยอดตีกลับ
--   4. จำนวนออเดอร์ — ทั้งหมด / ส่งสำเร็จ / ตีกลับ
--
-- 🔴 ต่างจากรอบก่อน: เดิมตัด payment_status='ยกเลิก' ออกทั้งหมด
--    ตอนนี้ต้องนับใบยกเลิก/ตีกลับด้วย (เป็นตัวเลขที่เจ้านายขอ) → เปลี่ยนวิธีคิดเป็น
--    "เอาทุกใบมา แล้วแยกถังตามสถานะ" ไม่ตัดออกตั้งแต่ต้น
--
-- นิยามที่ใช้ (ตรวจกับข้อมูลจริง 2026-09-18):
--   ยอดขาย        = ใบที่ payment_status in ('ชำระแล้ว','รอชำระ')   → 105,633,481 (62,761 ใบ)
--   ยอดตีกลับ      = ใบที่ delivery_status = 'ตีกลับ'                → 2,870,654  (1,918 ใบ)
--   ส่งสำเร็จ       = ใบที่ delivery_status = 'ส่งสำเร็จ'
--   ไม่นับแบรนด์ 'ตัวแทน' · กรอง order_no LIKE 'MOCK2512-%' ออก (ข้อมูลจำลอง)
--   'ไม่ใช่งานขาย' (68 ใบ ยอด 0) ไม่นับเป็นยอดขาย แต่ยังนับใน "ออเดอร์ทั้งหมด"

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
           o.payment_status as pay, o.delivery_status as dlv
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
  -- ยอดขาย = ชำระแล้ว + รอชำระ (ไม่รวมยกเลิก / ไม่ใช่งานขาย)
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
      from brands), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $function$;

grant execute on function public.app_sales_dashboard(text,text,date,date,text,bigint)
  to anon, authenticated, service_role;
