-- 2026-09-18 · RPC หน้า Dashboard ยอดขาย (Stage 14)
--
-- โจทย์เจ้านาย 6 ข้อ: ยอดรวม · แยกแบรนด์ · รายปี/เดือน/วัน · มาจากทีมไหน/ใคร · กราฟเทียบช่วงเวลา · เลือกช่วงเอง
-- สิทธิ์: Adm + Vm (ชื่อ role จะเปลี่ยนเป็น Vw ตาม docs/specs/2026-09-18-role-vm-to-vw-plan.md)
--
-- กฎการนับยอด (ตรงกับที่ตรวจกับเจ้านายไว้):
--   • ไม่นับแบรนด์ 'ตัวแทน'        (เอกสาร ไม่ใช่งานขาย · ยอด 0 ทุกใบ)
--   • ไม่นับ payment_status='ยกเลิก' (ตีกลับ/ยกเลิกแล้ว = ไม่เป็นยอดขาย)
--   • กรอง order_no LIKE 'MOCK2512-%' ออก (ข้อมูลจำลอง)
-- ตรวจแล้ว: ผลบวกรายเดือน 9 เดือน = 106,032,958 บาท · 62,874 ใบ ตรงกับยอดรวมเป๊ะ

create or replace function public.app_sales_dashboard(
  p_token text,
  p_gran  text default 'month',          -- 'year' | 'month' | 'day'
  p_from  date default null,             -- null = คำนวณช่วงเริ่มต้นให้ตาม gran
  p_to    date default null,
  p_brand text default null,             -- null = ทุกแบรนด์ · 'HOPEFUL' · 'แบรนด์อื่นๆ'
  p_team  bigint default null            -- null = ทุกทีม · -1 = เฉพาะกลุ่มไม่มีทีม
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_uid uuid; v_role text;
  v_min date; v_max date;
  v_from date; v_to date;
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

  -- ขอบเขตข้อมูลจริงที่มี (ใช้ทั้งตั้งค่าเริ่มต้นและกันเลือกเกิน)
  select min((ordered_at at time zone 'Asia/Bangkok')::date),
         max((ordered_at at time zone 'Asia/Bangkok')::date)
    into v_min, v_max
  from public.orders o join public.brands b on b.id = o.brand_id
  where o.order_no not like 'MOCK2512-%' and b.name <> 'ตัวแทน';
  if v_min is null then
    return jsonb_build_object('authorized', true, 'ok', true, 'empty', true);
  end if;

  -- ช่วงเริ่มต้นเมื่อไม่ได้ระบุ: ปี=ทั้งช่วง · เดือน=ปีล่าสุด · วัน=เดือนล่าสุด
  v_from := coalesce(p_from, case p_gran
              when 'year'  then v_min
              when 'month' then date_trunc('year',  v_max)::date
              else              date_trunc('month', v_max)::date end);
  v_to   := coalesce(p_to, v_max);
  if v_from > v_to then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_range');
  end if;
  -- ช่วงก่อนหน้าที่ยาวเท่ากัน (ไว้เทียบ % เติบโต)
  v_span  := (v_to - v_from) + 1;
  v_pto   := v_from - 1;
  v_pfrom := v_pto - (v_span - 1);

  with src as (
    select (o.ordered_at at time zone 'Asia/Bangkok')::date  as d,
           b.name                                            as brand,
           o.total_sales                                      as amt,
           s.id                                               as seller_id,
           s.employee_code, s.name as seller_name,
           t.id as team_id, t.name as team_name
    from public.orders o
    join public.brands b on b.id = o.brand_id
    left join public.sellers s on s.id = o.seller_id
    left join public.teams   t on t.id = s.team_id
    where o.order_no not like 'MOCK2512-%'
      and b.name <> 'ตัวแทน'
      and o.payment_status <> 'ยกเลิก'
      and (p_brand is null or b.name = p_brand)
      and (p_team is null
           or (p_team = -1 and t.id is null)
           or t.id = p_team)
  ),
  cur  as (select * from src where d between v_from and v_to),
  prev as (select * from src where d between v_pfrom and v_pto),
  -- แกนเวลาตาม granularity
  bucketed as (
    select case p_gran
             when 'year'  then to_char(d,'YYYY')
             when 'month' then to_char(d,'YYYY-MM')
             else              to_char(d,'YYYY-MM-DD') end as k,
           brand, amt
    from cur
  ),
  series as (
    select k,
           sum(amt)                                          as total,
           coalesce(sum(amt) filter (where brand='HOPEFUL'),0)     as hope,
           coalesce(sum(amt) filter (where brand='แบรนด์อื่นๆ'),0) as other,
           count(*)                                          as orders
    from bucketed group by k
  ),
  teams as (
    select coalesce(team_name,'—ไม่มีทีม—') as name, team_id,
           sum(amt) total,
           coalesce(sum(amt) filter (where brand='HOPEFUL'),0) hope,
           coalesce(sum(amt) filter (where brand='แบรนด์อื่นๆ'),0) other,
           count(*) orders
    from cur group by 1,2
  ),
  people as (
    select coalesce(employee_code,'—') as code,
           coalesce(nullif(btrim(seller_name),''),'(ยังไม่มีชื่อ)') as name,
           coalesce(team_name,'—ไม่มีทีม—') as team,
           sum(amt) total,
           coalesce(sum(amt) filter (where brand='HOPEFUL'),0) hope,
           coalesce(sum(amt) filter (where brand='แบรนด์อื่นๆ'),0) other,
           count(*) orders
    from cur where seller_id is not null group by 1,2,3
  )
  select jsonb_build_object(
    'authorized', true, 'ok', true,
    'gran', p_gran,
    'from', v_from, 'to', v_to,
    'prev_from', v_pfrom, 'prev_to', v_pto,
    'bounds', jsonb_build_object('min', v_min, 'max', v_max),
    'total', jsonb_build_object(
        'amount', coalesce((select sum(amt) from cur),0),
        'orders', (select count(*) from cur)),
    'prev', jsonb_build_object(
        'amount', coalesce((select sum(amt) from prev),0),
        'orders', (select count(*) from prev)),
    'brands', coalesce((select jsonb_agg(jsonb_build_object(
        'name', brand, 'amount', a, 'orders', n) order by a desc)
      from (select brand, sum(amt) a, count(*) n from cur group by brand) x), '[]'::jsonb),
    'series', coalesce((select jsonb_agg(jsonb_build_object(
        'k', k, 'total', total, 'hope', hope, 'other', other, 'orders', orders) order by k)
      from series), '[]'::jsonb),
    'teams', coalesce((select jsonb_agg(jsonb_build_object(
        'name', name, 'team_id', team_id, 'total', total,
        'hope', hope, 'other', other, 'orders', orders) order by total desc)
      from teams), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object(
        'code', code, 'name', name, 'team', team, 'total', total,
        'hope', hope, 'other', other, 'orders', orders) order by total desc)
      from people), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $function$;

grant execute on function public.app_sales_dashboard(text,text,date,date,text,bigint)
  to anon, authenticated, service_role;

-- รายชื่อทีมสำหรับ dropdown (เบา เรียกครั้งเดียวตอนเข้าหน้า)
create or replace function public.app_sales_dashboard_teams(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare v_uid uuid; v_role text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role is null or v_role not in ('Adm','Vm','Vw') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;
  return jsonb_build_object('authorized', true, 'ok', true,
    'teams', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name)
                       from public.teams), '[]'::jsonb));
end $function$;

grant execute on function public.app_sales_dashboard_teams(text) to anon, authenticated, service_role;
