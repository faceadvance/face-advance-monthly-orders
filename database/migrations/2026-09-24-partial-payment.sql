-- สถานะชำระ "บางส่วน" (สเปก Face Advance Monthly orders/docs/specs/2026-09-23-partial-payment-design.md · เคาะ 2026-09-23)
-- เข้ากันได้กับเว็บตัวเก่า: พารามิเตอร์ใหม่ทุกตัวมีค่าเริ่มต้น → ขึ้น DB ก่อนหน้าเว็บได้

-- 1) คอลัมน์ + CHECK
alter table public.orders add column if not exists paid_amount numeric(12,2);
alter table public.orders drop constraint if exists orders_payment_status_chk;
alter table public.orders add constraint orders_payment_status_chk
  check (payment_status = any (array['รอชำระ','ชำระแล้ว','บางส่วน','ยกเลิก','error','ไม่ใช่งานขาย']));
alter table public.orders drop constraint if exists orders_paid_amount_chk;
alter table public.orders add constraint orders_paid_amount_chk
  check ((payment_status = 'บางส่วน') = (paid_amount is not null)
         and (paid_amount is null or (paid_amount > 0 and paid_amount < total_sales)));
comment on column public.orders.paid_amount is 'ยอดที่รับจริง — มีค่าเฉพาะสถานะชำระ "บางส่วน" (ได้เงินไม่เต็ม เช่น เงินเคลมขนส่ง) · นับยอดขาย/ชำระแล้วเต็ม total_sales';

-- 2) เปลี่ยนสถานะชำระออกจากบางส่วน → ล้างยอดที่รับจริงให้เอง (ทุกฟังก์ชันที่ตั้งสถานะชำระไม่ต้องไล่แก้)
create or replace function public.orders_clear_paid_amount() returns trigger language plpgsql as $$
begin
  if new.payment_status is distinct from 'บางส่วน' then new.paid_amount := null; end if;
  return new;
end $$;
drop trigger if exists orders_clear_paid_amount on public.orders;
create trigger orders_clear_paid_amount before insert or update of payment_status, paid_amount on public.orders
  for each row execute function public.orders_clear_paid_amount();

-- 3) ตัวช่วยกลาง: สถานะไหนนับเป็น "จ่ายแล้ว"
create or replace function public.is_paid_status(p text) returns boolean language sql immutable parallel safe
  as $$ select p in ('ชำระแล้ว','บางส่วน') $$;

-- 4) แดชบอร์ด: บางส่วน = ชำระแล้วเต็มจำนวน
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
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ')),0)       as sales,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน')),0)                   as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)                     as waiting,
      coalesce(sum(amt) filter (where dlv = 'ตีกลับ'),0)                     as ret_amt,
      count(*)                                                               as n_all,
      count(*) filter (where dlv = 'ส่งสำเร็จ')                              as n_done,
      count(*) filter (where dlv = 'ตีกลับ')                                 as n_ret,
      count(*) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ'))                   as n_sales,
      count(*) filter (where pay in ('ชำระแล้ว','บางส่วน'))                               as n_paid,
      count(*) filter (where pay = 'รอชำระ')                                 as n_waiting
    from cur
  ),
  pagg as (
    select coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ')),0) as sales,
           count(*) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ'))             as n_sales
    from prev
  ),
  brands as (
    select brand,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ')),0) as sales,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน')),0)             as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)               as waiting,
      coalesce(sum(amt) filter (where dlv = 'ตีกลับ'),0)               as ret_amt,
      count(*) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ'))             as n_sales,
      count(*) filter (where dlv = 'ตีกลับ')                           as n_ret
    from cur group by brand
  ),
  depts as (
    select dept,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ')),0) as sales,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน')),0)             as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)               as waiting,
      coalesce(sum(amt) filter (where dlv = 'ตีกลับ'),0)               as ret_amt,
      count(*) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ'))             as n_sales,
      count(*) filter (where dlv = 'ตีกลับ')                           as n_ret
    from cur group by dept
  ),
  -- ฝ่าย × แบรนด์ (เจ้านายขอเพิ่ม 2026-09-22): แอดมิน/CRM ขายแบรนด์ไหนไปเท่าไหร่
  dept_brands as (
    select dept, brand,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ')),0) as sales,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน')),0)             as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)               as waiting,
      count(*) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ'))             as n_sales
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

-- 5) get_orders: ส่งยอดที่รับจริงให้ sidebar
CREATE OR REPLACE FUNCTION public.get_orders(p_token text, p_month text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_uid uuid; v_uname text; v_role text; v_start date; v_end date; v_days int; v_orders jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if p_month !~ '^\d{4}-\d{2}$' then
    return jsonb_build_object('authorized', true, 'error', 'bad_month');
  end if;
  v_start := to_date(p_month || '-01', 'YYYY-MM-DD');
  v_end   := (v_start + interval '1 month')::date;
  v_days  := extract(day from (v_end - interval '1 day'))::int;

  select coalesce(jsonb_agg(row order by ord_at asc, oid asc), '[]'::jsonb) into v_orders
  from (
    select o.id as oid, o.ordered_at as ord_at, jsonb_build_object(
      'id', o.id,
      'date', to_char(o.ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD'),
      'ordered_at', to_char(o.ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI:SS') || '+07:00',
      'phone', coalesce(o.phone, ''),
      'customer_name', coalesce(o.customer_name, ''),
      'address', array_to_string(array_remove(array[
        nullif(btrim(o.addr_detail), ''), nullif(btrim(o.subdistrict), ''),
        nullif(btrim(o.district), ''), nullif(btrim(o.province), ''), nullif(btrim(o.postal_code), '')
      ], null), ' '),
      'address_parts', (
        select coalesce(jsonb_agg(x.p order by x.ord), '[]'::jsonb)
        from unnest(array[
          nullif(btrim(o.addr_detail), ''), nullif(btrim(o.subdistrict), ''),
          nullif(btrim(o.district), ''), nullif(btrim(o.province), ''), nullif(btrim(o.postal_code), '')
        ]) with ordinality as x(p, ord)
        where x.p is not null
      ),
      'carrier', coalesce(o.carrier, ''),
      'tracking_no', coalesce(o.tracking_no, ''),
      'payment_method', coalesce(o.payment_method, ''),
      'total_sales', coalesce(o.total_sales, 0),
      'delivery_status', o.delivery_status,
      'payment_status', o.payment_status,
      'paid_amount', o.paid_amount,
      'return_arrived', o.return_arrived,
      'return_reason', coalesce(o.return_reason, ''),
      'status_detail', coalesce(o.status_detail, ''),
      'recon_conflict', o.recon_conflict,
      'inspection_result', coalesce((
        select rr.inspection_result from public.recon_returns rr
        where btrim(rr.tracking_out) = btrim(coalesce(o.tracking_no,''))
        order by rr.recorded_at desc, rr.id desc limit 1
      ), ''),
      'seller_code', coalesce(sel.employee_code, ''),
      'seller_name', coalesce(sel.name, ''),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object('name', coalesce(pr.name, '?'), 'qty', oi.quantity) order by oi.id)
        from public.order_items oi
        left join public.products pr on pr.id = oi.product_id
        where oi.order_id = o.id
      ), '[]'::jsonb),
      'note', coalesce(o.note, ''),
      'last_note_text', (
        select t.note from public.order_tracking t
        where t.order_id = o.id and t.entry_type = 'note' and nullif(btrim(coalesce(t.note,'')),'') is not null
        order by t.created_at desc, t.id desc limit 1
      ),
      'last_note_at', (
        select to_char(max(t.created_at) at time zone 'Asia/Bangkok', 'YYYY-MM-DD')
        from public.order_tracking t
        where t.order_id = o.id and t.created_by is not null
      )
    ) as row
    from public.orders o
    left join public.sellers sel on sel.id = o.seller_id
    where o.ordered_at >= (v_start::timestamp at time zone 'Asia/Bangkok')
      and o.ordered_at <  (v_end::timestamp at time zone 'Asia/Bangkok')
  ) s;

  select v_user.username, v_user.role into v_uname, v_role from public.app_users v_user where id = v_uid;
  insert into public.audit_log(user_id, username, event, detail)
    values (v_uid, v_uname, 'view_orders', jsonb_build_object('month', p_month));

  return jsonb_build_object(
    'authorized', true,
    'role', coalesce(v_role, 'editor'),
    'month', p_month,
    'days_in_month', v_days,
    'today', to_char((now() at time zone 'Asia/Bangkok')::date, 'YYYY-MM-DD'),
    'orders', v_orders
  );
end $function$;

-- 6) บันทึกสถานะจากหน้าเว็บ: รับบางส่วน + ยอดที่รับจริง (ลบตัวเก่า 7 พารามิเตอร์ กัน PostgREST เจอ 2 overload)
drop function if exists public.app_save_order_tracking(text, bigint, text, text, text, text, text);
CREATE OR REPLACE FUNCTION public.app_save_order_tracking(p_token text, p_order_id bigint, p_delivery_status text DEFAULT NULL::text, p_payment_status text DEFAULT NULL::text, p_return_reason text DEFAULT NULL::text, p_status_detail text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_paid_amount numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_uid   uuid;
  v_uname text;
  v_role  text;
  v_cur   record;
  v_new_delivery text;
  v_new_payment  text;
  v_reason  text;
  v_detail  text;
  v_note    text;
  v_deliv_changed boolean := false;
  v_pay_changed   boolean := false;
  v_changed       boolean := false;
  v_deliv_valid text[] := array['กำลังส่ง','ส่งสำเร็จ','ตีกลับ','ยกเลิก','มีปัญหา'];
  v_pay_valid   text[] := array['รอชำระ','ชำระแล้ว','บางส่วน','ยกเลิก','ไม่ใช่งานขาย'];
  v_paid numeric;
  v_paid_changed boolean := false;
  v_cancel_couple boolean := false;
  v_timeline jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;

  select coalesce(display_name, username), role into v_uname, v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','OM') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden_viewer');
  end if;

  select id, delivery_status, payment_status, return_reason, status_detail, payment_method, paid_amount, total_sales
    into v_cur
    from public.orders where id = p_order_id;
  if not found then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'order_not_found');
  end if;

  v_note := nullif(btrim(coalesce(p_note,'')), '');
  v_new_delivery := coalesce(nullif(btrim(coalesce(p_delivery_status,'')), ''), v_cur.delivery_status);
  v_new_payment  := coalesce(nullif(btrim(coalesce(p_payment_status,'')), ''),  v_cur.payment_status);

  if not (v_new_delivery = any(v_deliv_valid)) then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_delivery_status');
  end if;
  if not (v_new_payment = any(v_pay_valid)) then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_payment_status');
  end if;

  -- ยกเลิกออเดอร์ = ไม่ได้ส่ง ไม่มีเงินเข้าแน่นอน → ผูก payment='ยกเลิก' ให้เหมือน app_bulk_set_delivery
  -- (เดิมสองเส้นทางไม่ตรงกัน: กดอัพเดตหลายรายการผูกให้ แต่แก้ทีละใบไม่ผูก → ได้ 'ยกเลิก + รอชำระ')
  -- ผูกเฉพาะตอนที่ผู้ใช้ไม่ได้เจตนาเลือก payment อื่น (ชำระแล้ว/ไม่ใช่งานขาย) เช่นเคสจ่ายแล้วยกเลิกทีหลัง
  v_cancel_couple := (v_new_delivery = 'ยกเลิก'
                      and v_cur.delivery_status is distinct from 'ยกเลิก'
                      and v_new_payment in ('รอชำระ','ยกเลิก'));
  if v_cancel_couple then
    v_new_payment := 'ยกเลิก';
  end if;

  -- COD: สถานะชำระแก้มือไม่ได้ (ระบบ reconcile จัดการเอง)
  -- ยกเว้นการผูกอัตโนมัติตอนยกเลิก — ถือเป็นการตั้งโดยระบบ ไม่ใช่แก้มือ (bulk ก็ไม่ติด guard นี้)
  if not v_cancel_couple
     and v_new_payment is distinct from v_cur.payment_status and v_cur.payment_method = 'เก็บเงินปลายทาง' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'cod_payment_locked');
  end if;

  -- บางส่วน (ได้เงินไม่เต็ม): ใช้ได้เฉพาะ "มีปัญหา" + ต้องมียอดที่รับจริง > 0 และ < ยอดขาย
  if v_new_payment = 'บางส่วน' then
    if v_new_delivery is distinct from 'มีปัญหา' then
      return jsonb_build_object('authorized', true, 'ok', false, 'error', 'partial_needs_problem');
    end if;
    v_paid := coalesce(p_paid_amount, v_cur.paid_amount);
    if v_paid is null or v_paid <= 0 or v_paid >= v_cur.total_sales then
      return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_paid_amount');
    end if;
  else
    v_paid := null;
  end if;

  if v_new_delivery = 'ตีกลับ' then
    v_reason := coalesce(nullif(btrim(coalesce(p_return_reason,'')), ''), v_cur.return_reason);
    if v_reason is null then
      return jsonb_build_object('authorized', true, 'ok', false, 'error', 'return_reason_required');
    end if;
    v_detail := coalesce(nullif(btrim(coalesce(p_status_detail,'')), ''), v_cur.status_detail);
  elsif v_new_delivery = 'มีปัญหา' then
    v_detail := coalesce(nullif(btrim(coalesce(p_status_detail,'')), ''), v_cur.status_detail);
    if v_detail is null then
      return jsonb_build_object('authorized', true, 'ok', false, 'error', 'status_detail_required');
    end if;
    v_reason := null;
  else
    v_reason := null;
    v_detail := null;
  end if;

  v_deliv_changed := v_new_delivery is distinct from v_cur.delivery_status;
  v_pay_changed   := v_new_payment  is distinct from v_cur.payment_status;
  v_paid_changed  := v_paid is distinct from v_cur.paid_amount;
  v_changed := v_deliv_changed or v_pay_changed or v_paid_changed
               or (v_reason is distinct from v_cur.return_reason)
               or (v_detail is distinct from v_cur.status_detail);

  if not v_changed and v_note is null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', t.id, 'type', t.entry_type, 'note', t.note, 'old', t.old_value,
      'new', t.new_value, 'detail', t.detail, 'by', coalesce((select coalesce(au.display_name, au.username::text) from public.app_users au where au.id = t.created_by), t.created_by_name, ''), 'mine', (t.created_by = v_uid),
      'at', to_char(t.created_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI:SS')
    ) order by t.created_at desc, t.id desc), '[]'::jsonb) into v_timeline
    from public.order_tracking t where t.order_id = p_order_id;
    return jsonb_build_object('authorized', true, 'ok', true, 'noop', true,
      'delivery_status', v_cur.delivery_status, 'payment_status', v_cur.payment_status,
      'return_reason', v_cur.return_reason, 'status_detail', v_cur.status_detail, 'paid_amount', v_cur.paid_amount,
      'timeline', v_timeline);
  end if;

  if v_changed then
    update public.orders
      set delivery_status = v_new_delivery,
          payment_status  = v_new_payment,
          return_reason   = v_reason,
          status_detail   = v_detail,
          paid_amount     = v_paid,
          updated_at      = now()
      where id = p_order_id;
  end if;

  if v_deliv_changed then
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
    values (p_order_id, 'delivery_change', v_cur.delivery_status, v_new_delivery,
      case when v_new_delivery = 'ตีกลับ'
             then v_reason || coalesce(' — ' || v_detail, '')
           when v_new_delivery = 'มีปัญหา' then v_detail
           else null end,
      v_uid, v_uname);
  end if;

  if v_pay_changed or (v_paid_changed and v_new_payment = 'บางส่วน') then
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
    values (p_order_id, 'payment_change', v_cur.payment_status, v_new_payment,
      case when v_new_payment = 'บางส่วน'
           then 'รับจริง ฿'||to_char(v_paid,'FM999,999,990.##')||' จาก ฿'||to_char(v_cur.total_sales,'FM999,999,990') end,
      v_uid, v_uname);
  end if;

  if v_note is not null then
    insert into public.order_tracking(order_id, entry_type, note, created_by, created_by_name)
    values (p_order_id, 'note', v_note, v_uid, v_uname);
  end if;

  insert into public.audit_log(user_id, username, event, detail)
  values (v_uid, v_uname, 'order_tracking_save', jsonb_build_object(
    'order_id', p_order_id,
    'delivery_change', case when v_deliv_changed then v_cur.delivery_status || '→' || v_new_delivery else null end,
    'payment_change',  case when v_pay_changed   then v_cur.payment_status  || '→' || v_new_payment  else null end,
    'note', v_note is not null));

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'type', t.entry_type, 'note', t.note, 'old', t.old_value,
    'new', t.new_value, 'detail', t.detail, 'by', coalesce((select coalesce(au.display_name, au.username::text) from public.app_users au where au.id = t.created_by), t.created_by_name, ''), 'mine', (t.created_by = v_uid),
    'at', to_char(t.created_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI:SS')
  ) order by t.created_at desc, t.id desc), '[]'::jsonb) into v_timeline
  from public.order_tracking t where t.order_id = p_order_id;

  return jsonb_build_object('authorized', true, 'ok', true,
    'delivery_status', v_new_delivery, 'payment_status', v_new_payment,
    'return_reason', v_reason, 'status_detail', v_detail, 'paid_amount', v_paid,
    'timeline', v_timeline);
end $function$;
grant execute on function public.app_save_order_tracking(text, bigint, text, text, text, text, text, numeric) to anon, authenticated, service_role;

-- 7) กระทบยอด: รู้จักบางส่วน
CREATE OR REPLACE FUNCTION public.reconcile_order(p_order_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  o record;
  has_ret boolean;
  has_cod boolean;
  v_cod_amount numeric;
  v_cod_from text;
  v_target text;
begin
  select id, btrim(coalesce(tracking_no,'')) as tr, payment_method, delivery_status,
         payment_status, return_reason, return_arrived, recon_conflict, total_sales
    into o from public.orders where id = p_order_id;
  if not found or o.tr = '' then return; end if;

  select exists(select 1 from public.recon_returns r where btrim(r.tracking_out) = o.tr) into has_ret;
  select exists(select 1 from public.recon_cod_payments c where btrim(c.tracking_out) = o.tr) into has_cod;

  -- รับเงินแล้ว + ของตีกลับถึง = ต้องให้คนตัดสิน (เก็บเงิน/ยกเลิก/ลงผิด) → ส่งเข้า EDITH
  -- "รับเงินแล้ว" = มีรายการ COD รับเงิน  หรือ  สถานะชำระเป็น 'ชำระแล้ว' (โอนเงิน/ตัดบัตร/ตั้งมือ)
  if has_ret and (has_cod or public.is_paid_status(o.payment_status)) then
    if not coalesce(o.recon_conflict, false) then
      update public.orders set recon_conflict = true, updated_at = now() where id = o.id;
      insert into public.order_tracking(order_id, entry_type, note, created_by_name)
        values (o.id, 'note',
          case when has_cod
            then 'ระบบพบข้อมูลขัดแย้ง: มีทั้งรายการ COD รับเงิน และ ตีกลับถึงแล้ว — โปรดตรวจสอบ'
            else 'ระบบพบข้อมูลขัดแย้ง: ออเดอร์ชำระแล้ว ('||coalesce(nullif(btrim(o.payment_method),''),'ไม่ระบุวิธี')
                 ||') แต่มีตีกลับถึงแล้ว — โปรดตรวจสอบ'
          end, 'ระบบ');
    end if;
    return;
  end if;

  if coalesce(o.recon_conflict, false) then
    update public.orders set recon_conflict = false where id = o.id;
  end if;

  if has_ret then
    if o.delivery_status is distinct from 'ตีกลับ'
       or o.payment_status is distinct from 'ยกเลิก'
       or not coalesce(o.return_arrived, false) then
      if o.delivery_status is distinct from 'ตีกลับ' then
        insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by_name)
          values (o.id, 'delivery_change', o.delivery_status, 'ตีกลับ', 'ตีกลับถึงแล้ว (ระบบ)', 'ระบบ');
      end if;
      if o.payment_status is distinct from 'ยกเลิก' then
        insert into public.order_tracking(order_id, entry_type, old_value, new_value, created_by_name)
          values (o.id, 'payment_change', o.payment_status, 'ยกเลิก', 'ระบบ');
      end if;
      update public.orders set
        delivery_status = 'ตีกลับ',
        payment_status  = 'ยกเลิก',
        return_arrived  = true,
        return_reason   = coalesce(nullif(btrim(coalesce(return_reason, '')), ''), 'ตีกลับถึงแล้ว'),
        updated_at = now()
      where id = o.id;
    end if;

  elsif has_cod and o.payment_method = 'เก็บเงินปลายทาง' then
    select c.amount, c.received_from into v_cod_amount, v_cod_from
      from public.recon_cod_payments c
      where btrim(c.tracking_out) = o.tr
      order by c.id desc limit 1;
    -- บางส่วน: ยืนยันแล้ว (ออเดอร์เป็นบางส่วนอยู่) + เงินเคลมน้อยกว่ายอดขาย → คงบางส่วน ไม่ใช่ error
    v_target := case when v_cod_amount is not null and round(v_cod_amount) = o.total_sales then 'ชำระแล้ว'
                     when o.payment_status = 'บางส่วน' and v_cod_from = 'ทำเคลม'
                          and v_cod_amount > 0 and v_cod_amount < o.total_sales then 'บางส่วน'
                     else 'error' end;
    if v_target = 'บางส่วน' then
      update public.orders set paid_amount = v_cod_amount where id = o.id and paid_amount is distinct from v_cod_amount;
    end if;
    if o.payment_status is distinct from v_target then
      insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by_name)
        values (o.id, 'payment_change', o.payment_status, v_target,
                case when v_target='error'
                     then 'ยอดรับ COD ('||coalesce(v_cod_amount::text,'—')||') ไม่ตรงยอดออเดอร์ ('||o.total_sales||')'
                     else null end,
                'ระบบ');
      update public.orders set payment_status = v_target, updated_at = now() where id = o.id;
    end if;
  end if;
end $function$;

-- 8) นำเข้า COD (ไฟล์ + บันทึกมือ): ยืนยันรับบางส่วน (ลบตัวเก่า 5 พารามิเตอร์)
drop function if exists public.app_import_cod_payments(text, jsonb, text, jsonb, text);
CREATE OR REPLACE FUNCTION public.app_import_cod_payments(p_token text, p_rows jsonb, p_mode text, p_fix_trackings jsonb DEFAULT '[]'::jsonb, p_source text DEFAULT NULL::text, p_confirm_partial boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_uid uuid; v_uname text; v_role text;
  v_problems jsonb; v_mismatches jsonb; v_partials jsonb; v_partial int := 0;
  v_ok boolean;
  v_rows_total int; v_rows_ok int;
  v_inserted int := 0; v_fixed int := 0; v_paid int := 0; v_err int := 0;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role, username into v_role, v_uname from public.app_users where id = v_uid;
  if v_role not in ('Adm','OM') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden_viewer');
  end if;
  if p_mode not in ('preflight','confirm') then
    return jsonb_build_object('authorized', true, 'error', 'bad_mode');
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'ไม่มีข้อมูลในไฟล์');
  end if;

  create temp table _cod on commit drop as
  select (row_number() over ())::int as k,
         btrim(coalesce(r->>'tracking_out','')) as tracking_out,
         nullif(btrim(coalesce(r->>'amount','')),'')::numeric as amount,
         nullif(btrim(coalesce(r->>'received_from','')),'') as received_from,
         nullif(btrim(coalesce(r->>'note','')),'') as note
  from jsonb_array_elements(p_rows) r;

  create temp table _cod_eval on commit drop as
  select c.*,
         o.id as order_id, o.order_no, o.total_sales as order_amount, o.payment_method,
         count(*) over (partition by c.tracking_out) as same_tr,
         exists(select 1 from public.recon_cod_payments x
                where btrim(x.tracking_out) = c.tracking_out and c.tracking_out <> '') as in_cod_db
  from _cod c
  left join lateral (
    select id, order_no, total_sales, payment_method
    from public.orders
    where btrim(coalesce(tracking_no,'')) = c.tracking_out and c.tracking_out <> ''
    order by id limit 1
  ) o on true;

  -- problems (บล็อกทั้งไฟล์)
  select coalesce(jsonb_agg(jsonb_build_object(
           'tracking', case when e.tracking_out = '' then 'แถวที่ '||e.k else e.tracking_out end,
           'reason', p.reason) order by e.k), '[]'::jsonb)
    into v_problems
  from _cod_eval e
  cross join lateral (
    select case
      when e.tracking_out = '' then 'ไม่มีเลขแทร็ค'
      when e.received_from is not null and e.received_from not in ('ขนส่ง','ระบบ','ทำเคลม')
        then 'ค่า "ได้รับจาก" ไม่ถูกต้อง ('||e.received_from||')'
      when e.same_tr > 1 then 'เลขแทร็คซ้ำกันในไฟล์'
      when e.in_cod_db then 'มีในระบบ COD แล้ว (บันทึกซ้ำ)'
      when e.order_id is null then 'ไม่พบออเดอร์ที่ใช้เลขแทร็คนี้'
      when e.payment_method is distinct from 'เก็บเงินปลายทาง'
        then 'ในฐานข้อมูล ออเดอร์นี้ชำระแบบโอนเงิน โปรดตรวจสอบไฟล์'
      else null end as reason
  ) p
  where p.reason is not null;

  -- mismatches (ไม่บล็อก) — แถวที่ผ่าน block ทั้งหมด และยอดไม่ตรง (เทียบ round)
  select coalesce(jsonb_agg(jsonb_build_object(
           'tracking', e.tracking_out, 'order_no', e.order_no, 'order_id', e.order_id,
           'order_amount', e.order_amount, 'received_amount', e.amount,
           'fixable', (e.amount is not null)
         ) order by e.k), '[]'::jsonb)
    into v_mismatches
  from _cod_eval e
  where e.tracking_out <> ''
    and (e.received_from is null or e.received_from in ('ขนส่ง','ระบบ','ทำเคลม'))
    and e.same_tr = 1 and not e.in_cod_db
    and e.order_id is not null and e.payment_method = 'เก็บเงินปลายทาง'
    and (e.amount is null or round(e.amount) is distinct from e.order_amount::numeric);

  -- บางส่วน: เงินเคลม (ทำเคลม) น้อยกว่ายอดขาย และไม่ได้เลือกแก้ยอด → ต้องยืนยันก่อน (ไม่ยืนยัน = ไม่บันทึกทั้งไฟล์)
  select coalesce(jsonb_agg(jsonb_build_object(
           'tracking', e.tracking_out, 'order_no', e.order_no, 'order_id', e.order_id,
           'order_amount', e.order_amount, 'received_amount', e.amount) order by e.k), '[]'::jsonb)
    into v_partials
  from _cod_eval e
  where e.received_from = 'ทำเคลม' and e.same_tr = 1 and not e.in_cod_db
    and e.order_id is not null and e.payment_method = 'เก็บเงินปลายทาง'
    and e.amount is not null and e.amount > 0 and round(e.amount) < e.order_amount::numeric
    and e.tracking_out not in (select btrim(x) from jsonb_array_elements_text(coalesce(p_fix_trackings,'[]'::jsonb)) x);

  select count(*) into v_rows_total from _cod;
  v_ok := (jsonb_array_length(v_problems) = 0);
  v_rows_ok := case when v_ok then v_rows_total else 0 end;

  if p_mode = 'confirm' and v_ok then
    if p_source is null or btrim(p_source) = '' then
      return jsonb_build_object('authorized', true, 'ok', false, 'error', 'no_evidence');
    end if;
    if jsonb_array_length(v_partials) > 0 and not coalesce(p_confirm_partial, false) then
      return jsonb_build_object('authorized', true, 'mode', p_mode, 'ok', false, 'error', 'partial_unconfirmed',
        'partials', v_partials, 'problems', v_problems, 'mismatches', v_mismatches);
    end if;

    -- แก้ยอดออเดอร์ตามที่เลือก (round → total_sales int)
    update public.orders o
       set total_sales = round(e.amount)::int, updated_at = now()
      from _cod_eval e
     where o.id = e.order_id and e.amount is not null
       and e.tracking_out in (select btrim(x) from jsonb_array_elements_text(coalesce(p_fix_trackings,'[]'::jsonb)) x)
       and round(e.amount) is distinct from e.order_amount::numeric;
    get diagnostics v_fixed = row_count;

    -- บางส่วน (ยืนยันแล้ว): ตั้ง บางส่วน · มีปัญหา · ยอดที่รับจริง ก่อน reconcile
    create temp table _partial on commit drop as
      select (x->>'order_id')::bigint as order_id, (x->>'received_amount')::numeric as amount from jsonb_array_elements(v_partials) x;
    with p as (
      select o.id, o.payment_status as old_pay, o.delivery_status as old_del, pt.amount, o.total_sales
      from _partial pt join public.orders o on o.id = pt.order_id),
    u as (
      update public.orders o set payment_status='บางส่วน', paid_amount=p.amount, delivery_status='มีปัญหา',
             status_detail='รับเงินเคลมแล้ว ไม่เต็มจำนวน', updated_at=now()
      from p where o.id=p.id returning o.id, p.old_pay, p.old_del, p.amount, p.total_sales),
    t1 as (
      insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
      select id, 'payment_change', old_pay, 'บางส่วน',
             'รับจริง ฿'||to_char(amount,'FM999,999,990.##')||' จาก ฿'||to_char(total_sales,'FM999,999,990')||' (เงินเคลม · ยืนยันตอนนำเข้า)', v_uid, v_uname
      from u where old_pay is distinct from 'บางส่วน' returning 1)
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
    select id, 'delivery_change', old_del, 'มีปัญหา', 'รับเงินเคลมแล้ว ไม่เต็มจำนวน', v_uid, v_uname
    from u where old_del is distinct from 'มีปัญหา';
    get diagnostics v_partial = row_count;
    select count(*) into v_partial from _partial;

    -- ปิด trigger reconcile ต่อแถว ระหว่าง bulk แล้ว reconcile แบบ set-based (เร็วพอ 5k-10k)
    perform set_config('app.skip_reconcile','1', true);
    insert into public.recon_cod_payments(tracking_out, amount, received_from, note, source, created_by)
    select e.tracking_out, e.amount, e.received_from, e.note, p_source, v_uid
      from _cod_eval e order by e.k;
    get diagnostics v_inserted = row_count;
    with c as (
      update public.orders o set recon_conflict=true, updated_at=now()
      from _cod_eval e
      where o.id=e.order_id and not coalesce(o.recon_conflict,false)
        and exists(select 1 from public.recon_returns r where btrim(r.tracking_out)=e.tracking_out)
      returning o.id)
    insert into public.order_tracking(order_id, entry_type, note, created_by_name)
    select id, 'note', 'ระบบพบข้อมูลขัดแย้ง: มีทั้งรายการ COD รับเงิน และ ตีกลับถึงแล้ว — โปรดตรวจสอบ', 'ระบบ' from c;
    with t as (
      select e.order_id, e.amount, o.total_sales, o.payment_status as old_pay,
        case when round(e.amount) = o.total_sales then 'ชำระแล้ว'
             when e.order_id in (select order_id from _partial) then 'บางส่วน'
             else 'error' end as new_pay
      from _cod_eval e join public.orders o on o.id=e.order_id
      where e.order_id is not null
        and not exists(select 1 from public.recon_returns r where btrim(r.tracking_out)=e.tracking_out)),
    upd as (
      update public.orders o set payment_status=t.new_pay, recon_conflict=false, updated_at=now()
      from t where o.id=t.order_id and o.payment_status is distinct from t.new_pay
      returning o.id as oid, t.old_pay, t.new_pay, t.amount, t.total_sales)
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by_name)
    select oid, 'payment_change', old_pay, new_pay,
      case when new_pay='error' then 'ยอดรับ COD ('||coalesce(amount::text,'—')||') ไม่ตรงยอดออเดอร์ ('||total_sales||')' else null end,
      'ระบบ' from upd;

    -- นำเข้าจากไฟล์ (ไม่ใช่แก้มือ): รับเงิน COD = ส่งถึงแล้ว → ตั้ง delivery=ส่งสำเร็จ ให้อัตโนมัติ (ยกเว้นออเดอร์ที่ตีกลับ)
    if p_source is distinct from 'manual' then
      with dt as (
        select e.order_id, o.delivery_status as old_del
        from _cod_eval e join public.orders o on o.id=e.order_id
        where e.order_id is not null
          and o.delivery_status is distinct from 'ส่งสำเร็จ'
          and e.received_from is distinct from 'ทำเคลม'   -- เคลมขนส่ง: เงินเข้าแต่ลูกค้าไม่ได้ของ → ห้ามตั้ง 'ส่งสำเร็จ'
          and not exists(select 1 from public.recon_returns r where btrim(r.tracking_out)=e.tracking_out)),
      dupd as (
        update public.orders o set delivery_status='ส่งสำเร็จ', updated_at=now()
        from dt where o.id=dt.order_id returning o.id as oid, dt.old_del)
      insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by_name)
      select oid, 'delivery_change', old_del, 'ส่งสำเร็จ', 'รับเงิน COD แล้ว (นำเข้า)', 'ระบบ' from dupd;
    end if;

    select count(*) filter (where o.payment_status = 'ชำระแล้ว'),
           count(*) filter (where o.payment_status = 'error')
      into v_paid, v_err
      from _cod_eval e join public.orders o on o.id = e.order_id;

    insert into public.audit_log(user_id, username, event, detail)
      values (v_uid, v_uname, 'import_cod',
              jsonb_build_object('inserted', v_inserted, 'fixed', v_fixed,
                                 'paid', v_paid, 'error', v_err, 'source', p_source));
  end if;

  return jsonb_build_object(
    'authorized', true, 'mode', p_mode, 'ok', v_ok,
    'problems', v_problems, 'mismatches', v_mismatches,
    'rows_total', v_rows_total, 'rows_ok', v_rows_ok,
    'inserted', v_inserted, 'fixed', v_fixed, 'paid', v_paid, 'err', v_err,
    'partials', v_partials, 'partial', v_partial
  );
end $function$;
grant execute on function public.app_import_cod_payments(text, jsonb, text, jsonb, text, boolean) to anon, authenticated, service_role;

-- 9) ย้อนผลกระทบยอด: baseline สาย COD รวมบางส่วน
CREATE OR REPLACE FUNCTION public.revert_recon_effects(p_tracking text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_oid bigint;
  v_ret_deliv text;
  v_ret_pay text;
  v_cod_pay text;
begin
  select id into v_oid from public.orders
   where btrim(coalesce(tracking_no,'')) = btrim(p_tracking) order by id limit 1;
  if v_oid is null then return; end if;

  -- delivery เดิมก่อนระบบมาร์ค 'ตีกลับ' (เอาครั้งแรกสุด = baseline จริง)
  select old_value into v_ret_deliv from public.order_tracking
   where order_id = v_oid and entry_type = 'delivery_change'
     and created_by_name = 'ระบบ' and new_value = 'ตีกลับ'
   order by id asc limit 1;
  -- payment เดิมก่อนระบบมาร์ค 'ยกเลิก' (สาย return)
  select old_value into v_ret_pay from public.order_tracking
   where order_id = v_oid and entry_type = 'payment_change'
     and created_by_name = 'ระบบ' and new_value = 'ยกเลิก'
   order by id asc limit 1;
  -- payment เดิมก่อนระบบมาร์ค 'ชำระแล้ว'/'error' (สาย COD)
  select old_value into v_cod_pay from public.order_tracking
   where order_id = v_oid and entry_type = 'payment_change'
     and created_by_name = 'ระบบ' and new_value in ('ชำระแล้ว','error','บางส่วน')
   order by id asc limit 1;

  update public.orders set
    delivery_status = coalesce(v_ret_deliv, delivery_status),
    payment_status  = coalesce(v_ret_pay, v_cod_pay, payment_status),
    return_arrived  = false,
    return_reason   = case when return_reason = 'ตีกลับถึงแล้ว' then null else return_reason end,
    recon_conflict  = false,
    updated_at = now()
  where id = v_oid;
end $function$;
