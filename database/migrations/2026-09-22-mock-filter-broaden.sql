-- 2026-09-22 · ขยายตัวกรองข้อมูลจำลองจาก 'MOCK2512-%' → 'MOCK%'
--
-- เหตุผล: เจ้านายสั่งให้สร้างข้อมูลจำลองปี 2024 ไว้ทดสอบ (ห้ามทดสอบกับข้อมูลจริง)
--   ถ้าตัวกรองยังเจาะจง MOCK2512- ข้อมูลจำลองชุดใหม่จะหลุดเข้าไปปนในรายงานทันที
-- ปลอดภัย: เลขออเดอร์จริงทุกรูปแบบไม่ได้ขึ้นต้นด้วย MOCK
--   (HIST26MM- · HIST25MM- · OD26MMDD...) → LIKE 'MOCK%' จับได้เฉพาะของจำลอง

-- ---------- app_sales_dashboard (แทนที่ 2 จุด) ----------
CREATE OR REPLACE FUNCTION public.app_sales_dashboard(p_token text, p_gran text DEFAULT 'month'::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_brand text DEFAULT NULL::text, p_team bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
  where o.order_no not like 'MOCK%' and b.name <> 'ตัวแทน';
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
    where o.order_no not like 'MOCK%'
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

-- ---------- app_edith_issues (แทนที่ 2 จุด) ----------
CREATE OR REPLACE FUNCTION public.app_edith_issues(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_uid uuid; v_role text; v_issues jsonb; v_counts jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;

  with issues as (
    select 'error'::text as type, o.id as ref,
      coalesce(nullif(btrim(o.tracking_no),''), o.order_no, 'ออเดอร์ #'||o.id) as key,
      'high'::text as severity,
      coalesce((select max(t.created_at) from public.order_tracking t
                where t.order_id=o.id and t.entry_type='payment_change' and t.new_value='error'),
               o.updated_at) as opened_at,
      'COD ยอดไม่ตรง: รับ '||coalesce(cod.amount::text,'—')||' ≠ ออเดอร์ '||o.total_sales as summary,
      jsonb_build_object('delta', coalesce(cod.amount,0)-o.total_sales, 'cod', cod.amount, 'order_total', o.total_sales) as extra
    from public.orders o
    left join lateral (select amount from public.recon_cod_payments c
                       where btrim(c.tracking_out)=btrim(coalesce(o.tracking_no,'')) order by id desc limit 1) cod on true
    where o.payment_status='error'
    union all
    select 'conflict', rc.id, rc.tracking_out, 'high', rc.created_at,
      'บันทึกตีกลับชนกัน '||jsonb_array_length(rc.submissions)||' เวอร์ชัน',
      jsonb_build_object('versions', jsonb_array_length(rc.submissions))
    from public.return_conflicts rc where rc.status='pending'
    union all
    select 'recon', o.id, coalesce(nullif(btrim(o.tracking_no),''), o.order_no, 'ออเดอร์ #'||o.id), 'high',
      coalesce((select max(t.created_at) from public.order_tracking t
                where t.order_id=o.id and t.entry_type='note' and t.note ilike '%ขัดแย้ง%'), o.updated_at),
      -- ไม่มีรายการ COD → อย่าบอกว่ามี
      case when exists(select 1 from public.recon_cod_payments c
                       where btrim(c.tracking_out)=btrim(coalesce(o.tracking_no,'')))
           then 'ขัดแย้ง: มีทั้งรายการ COD และตีกลับถึง'
           else 'ขัดแย้ง: ชำระแล้ว ('||coalesce(nullif(btrim(o.payment_method),''),'ไม่ระบุวิธี')||') แต่ตีกลับถึง'
      end, '{}'::jsonb
    from public.orders o where coalesce(o.recon_conflict,false)
    union all
    select 'dedup', v.id, coalesce(v.new_name, v.cand_name, 'ลูกค้า #'||v.id), 'low', v.created_at,
      'ลูกค้าอาจซ้ำ ('||v.reason||' · '||round(v.score,2)||')',
      jsonb_build_object('brand', v.brand, 'score', v.score, 'keep', v.new_customer_id, 'dup', v.candidate_customer_id)
    from public.v_pending_customer_review v
    union all
    -- ออเดอร์ที่ไม่มีพนักงานขาย (เจ้านายสั่ง 2026-09-22)
    -- กันแบรนด์ 'ตัวแทน' ออก: 196/229 ใบเป็นเอกสาร ยอด 0 ซึ่งไม่ควรมีเซลอยู่แล้ว
    -- กัน seller_waived (ยืนยันแล้วว่าไม่มีเซล) และข้อมูลจำลองออก
    select 'noseller', o.id,
      coalesce(nullif(btrim(o.order_no),''), 'ออเดอร์ #'||o.id), 'low', o.ordered_at,
      'ไม่มีพนักงานขาย · '||b.name||' · '||to_char(o.total_sales,'FM999,999,999')||' บาท',
      jsonb_build_object('brand', b.name, 'total', o.total_sales,
        'code_in_name', (select m[1] from regexp_match(coalesce(o.customer_name,''), '([A-Za-z]{1,4}[0-9]{1,4})\s*$') m))
    from public.orders o join public.brands b on b.id = o.brand_id
    where o.seller_id is null and not coalesce(o.seller_waived,false)
      and b.name <> 'ตัวแทน' and o.order_no not like 'MOCK%'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'type', type, 'ref', ref, 'key', key, 'severity', severity, 'opened_at', opened_at,
           'age_minutes', greatest(0, (extract(epoch from (now()-opened_at))/60)::int),
           'summary', summary, 'extra', extra) order by opened_at asc), '[]'::jsonb)
    into v_issues from issues;

  select jsonb_build_object(
    'error',    (select count(*) from public.orders where payment_status='error'),
    'conflict', (select count(*) from public.return_conflicts where status='pending'),
    'recon',    (select count(*) from public.orders where coalesce(recon_conflict,false)),
    'dedup',    (select count(*) from public.v_pending_customer_review),
    'noseller', (select count(*) from public.orders o join public.brands b on b.id=o.brand_id
                 where o.seller_id is null and not coalesce(o.seller_waived,false)
                   and b.name <> 'ตัวแทน' and o.order_no not like 'MOCK%'),
    'total',    jsonb_array_length(v_issues)
  ) into v_counts;
  return jsonb_build_object('authorized', true, 'ok', true, 'issues', v_issues, 'counts', v_counts);
end $function$;
