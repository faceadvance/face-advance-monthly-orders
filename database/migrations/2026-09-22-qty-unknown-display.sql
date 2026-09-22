-- 2026-09-22 · แสดง '×?' แทน '×0' เมื่อไม่ทราบจำนวนสินค้า (ปิดงานข้อ A)
--
-- คู่กับ 2026-09-22-order-items-qty-unknown.sql ที่เปิดให้ quantity = 0 ได้
-- 0 = ไม่ทราบจำนวน (ไฟล์ย้อนหลังเขียนเป็น '-') → โชว์ '×0' จะเข้าใจผิดว่าศูนย์ชิ้นจริง
--
-- ครอบ 7 ฟังก์ชันที่ประกอบสตริงรายการสินค้าฝั่ง DB
-- (get_orders ส่ง JSON {name, qty} ให้หน้าเว็บประกอบเอง → แก้ที่ main.ts แยก 2 จุด)
--
-- 🔴 ใช้ฟังก์ชันกลาง qty_txt() ไม่กระจาย CASE ไว้ 9 ที่ — แก้ที่เดียวถ้ากติกาเปลี่ยน

create or replace function public.qty_txt(n integer)
returns text
language sql
immutable
parallel safe
set search_path to ''
as $$ select case when n is null then '?' when n = 0 then '?' else n::text end $$;

comment on function public.qty_txt(integer) is
  'จำนวนสินค้าสำหรับแสดงผล — 0 หรือ NULL = ไม่ทราบจำนวน แสดงเป็น ?';

-- ---------- app_edith_conflict_detail (แทนที่ 1 จุด) ----------
CREATE OR REPLACE FUNCTION public.app_edith_conflict_detail(p_token text, p_conflict_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_uid uuid; v_res jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if (select role from public.app_users where id=v_uid) <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  select jsonb_build_object('authorized',true,'ok',true,
    'conflict', jsonb_build_object('id',rc.id,'tracking_out',rc.tracking_out,'created_at',rc.created_at,'status',rc.status,'submissions',rc.submissions),
    'order', to_jsonb(x)) into v_res
  from public.return_conflicts rc
  left join lateral (
    select o.id, o.order_no, o.customer_name, o.phone, o.total_sales, o.carrier,
      s.employee_code as seller_code, s.name as seller_name,
      (select string_agg(p.name||' ×'||public.qty_txt(oi.quantity), E'\n' order by oi.id)
         from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=o.id) as items
    from public.orders o left join public.sellers s on s.id=o.seller_id
    where btrim(coalesce(o.tracking_no,''))=btrim(rc.tracking_out) limit 1
  ) x on true
  where rc.id=p_conflict_id;
  return coalesce(v_res, jsonb_build_object('authorized',true,'ok',false,'error','not_found'));
end $function$;

-- ---------- app_edith_error_detail (แทนที่ 1 จุด) ----------
CREATE OR REPLACE FUNCTION public.app_edith_error_detail(p_token text, p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_uid uuid; v_res jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if (select role from public.app_users where id=v_uid) <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  select jsonb_build_object('authorized',true,'ok',true,'order', to_jsonb(x)) into v_res
  from (
    select o.id, o.order_no, o.tracking_no, o.customer_name, o.phone,
      o.total_sales, o.payment_method, o.payment_status, o.delivery_status,
      s.employee_code as seller_code, s.name as seller_name, t.name as team_name,
      (select string_agg(p.name||' ×'||public.qty_txt(oi.quantity), E'\n' order by oi.id)
         from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=o.id) as items,
      cod.id as cod_id, cod.amount as cod_amount,
      coalesce(cod.amount,0)-o.total_sales as delta, cod.recorded_at as cod_recorded_at
    from public.orders o
    left join public.sellers s on s.id=o.seller_id
    left join public.teams t on t.id=s.team_id
    left join lateral (select id, amount, recorded_at from public.recon_cod_payments c
                       where btrim(c.tracking_out)=btrim(coalesce(o.tracking_no,'')) order by id desc limit 1) cod on true
    where o.id=p_order_id
  ) x;
  return coalesce(v_res, jsonb_build_object('authorized',true,'ok',false,'error','not_found'));
end $function$;

-- ---------- app_edith_noseller_detail (แทนที่ 1 จุด) ----------
CREATE OR REPLACE FUNCTION public.app_edith_noseller_detail(p_token text, p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_uid uuid; v_role text; v_out jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;

  select jsonb_build_object(
    'id', o.id, 'order_no', o.order_no,
    'ordered_at', (o.ordered_at at time zone 'Asia/Bangkok'),
    'customer_name', o.customer_name, 'phone', o.phone,
    'province', o.province, 'district', o.district,
    'brand', b.name, 'total_sales', o.total_sales,
    'payment_method', o.payment_method, 'payment_status', o.payment_status,
    'delivery_status', o.delivery_status, 'tracking_no', o.tracking_no,
    'note', o.note,
    'items', coalesce((select string_agg(p.name || ' ×' || public.qty_txt(i.quantity), ', ' order by i.id)
                       from public.order_items i join public.products p on p.id = i.product_id
                       where i.order_id = o.id), '—'),
    -- เบาะแส: ชื่อลูกค้ามักมีรหัสเซลต่อท้าย (เช่น "คุณสมหญิง m11") → ช่วยให้เดาถูกเร็ว
    'code_in_name', (select m[1] from regexp_match(coalesce(o.customer_name,''), '([A-Za-z]{1,4}[0-9]{1,4})\s*$') m),
    -- ลูกค้าคนเดียวกันเคยซื้อกับเซลคนไหนมาก่อน (เรียงล่าสุดก่อน) — เบาะแสที่แม่นกว่าเดาจากชื่อ
    'history', coalesce((select jsonb_agg(x order by x->>'last_at' desc) from (
        select jsonb_build_object('code', s2.employee_code, 'name', s2.name,
                                  'orders', count(*), 'last_at', max(o2.ordered_at)) x
        from public.orders o2 join public.sellers s2 on s2.id = o2.seller_id
        where o2.customer_id = o.customer_id and o2.id <> o.id
        group by s2.employee_code, s2.name) y), '[]'::jsonb)
  ) into v_out
  from public.orders o join public.brands b on b.id = o.brand_id
  where o.id = p_order_id;

  if v_out is null then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'not_found'); end if;
  return jsonb_build_object('authorized', true, 'ok', true, 'order', v_out);
end $function$;

-- ---------- app_edith_recon_detail (แทนที่ 1 จุด) ----------
CREATE OR REPLACE FUNCTION public.app_edith_recon_detail(p_token text, p_order_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_uid uuid; v_res jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if (select role from public.app_users where id=v_uid) <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  select jsonb_build_object('authorized',true,'ok',true,'order', to_jsonb(x)) into v_res
  from (
    select o.id, o.order_no, o.tracking_no, o.customer_name, o.phone, o.total_sales,
      o.payment_method, o.payment_status, o.delivery_status,
      to_char(o.ordered_at at time zone 'Asia/Bangkok','DD/MM/YYYY') as ordered_date,
      (select string_agg(p.name||' ×'||public.qty_txt(oi.quantity), E'\n' order by oi.id)
         from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=o.id) as items,
      codj.cod, retj.ret
    from public.orders o
    left join lateral (select jsonb_build_object('id',id,'amount',amount,'recorded_at',recorded_at,'tracking_out',tracking_out,'received_from',received_from) cod
       from public.recon_cod_payments c where btrim(c.tracking_out)=btrim(coalesce(o.tracking_no,'')) order by id desc limit 1) codj on true
    left join lateral (select jsonb_build_object('id',id,'inspection_result',inspection_result,'recorded_at',recorded_at,'no_deduct',no_deduct,'tracking_return',tracking_return,'tracking_out',tracking_out,'damage_detail',damage_detail,'photo_url',photo_url,'damage_items',damage_items) ret
       from public.recon_returns r where btrim(r.tracking_out)=btrim(coalesce(o.tracking_no,'')) order by id desc limit 1) retj on true
    where o.id=p_order_id
  ) x;
  return coalesce(v_res, jsonb_build_object('authorized',true,'ok',false,'error','not_found'));
end $function$;

-- ---------- app_lookup_return_tracking (แทนที่ 1 จุด) ----------
CREATE OR REPLACE FUNCTION public.app_lookup_return_tracking(p_token text, p_tracking text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare v_uid uuid; v_role text; v_tr text; v_o record; v_items text; v_list jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','RT+') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;

  v_tr := btrim(coalesce(p_tracking, ''));
  if v_tr = '' then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'empty'); end if;

  if exists (select 1 from public.recon_returns r where btrim(r.tracking_out) = v_tr) then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'already_recorded');
  end if;

  select o.id, o.order_no, o.customer_name, o.phone, o.total_sales, o.carrier,
         o.delivery_status, o.payment_status, o.payment_method,
         to_char(o.ordered_at at time zone 'Asia/Bangkok', 'DD/MM/YYYY') as ordered_date,
         s.employee_code as seller_code, s.name as seller_name
    into v_o
    from public.orders o
    left join public.sellers s on s.id = o.seller_id
   where btrim(coalesce(o.tracking_no, '')) = v_tr
   order by o.id limit 1;

  if not found then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'order_not_found');
  end if;

  select string_agg(p.name || ' ×' || public.qty_txt(oi.quantity), ', ' order by oi.id),
         coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'qty', oi.quantity) order by oi.id), '[]'::jsonb)
    into v_items, v_list
    from public.order_items oi join public.products p on p.id = oi.product_id
   where oi.order_id = v_o.id;

  return jsonb_build_object(
    'authorized', true, 'ok', true,
    'order', jsonb_build_object(
      'id', v_o.id, 'order_no', v_o.order_no, 'customer_name', v_o.customer_name,
      'phone', v_o.phone, 'total_sales', v_o.total_sales,
      'items', coalesce(v_items, ''), 'items_list', coalesce(v_list, '[]'::jsonb),
      'carrier', v_o.carrier, 'delivery_status', v_o.delivery_status,
      'payment_status', v_o.payment_status, 'payment_method', v_o.payment_method,
      'ordered_date', v_o.ordered_date,
      'seller_code', v_o.seller_code, 'seller_name', v_o.seller_name
    ));
end $function$;

-- ---------- app_returns_list (แทนที่ 2 จุด) ----------
CREATE OR REPLACE FUNCTION public.app_returns_list(p_token text, p_cycle text DEFAULT NULL::text, p_mode text DEFAULT 'deduct'::text, p_team_id bigint DEFAULT NULL::bigint, p_seller_code text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_uid uuid; v_role text; v_all_teams boolean; v_all boolean;
  v_teams bigint[];
  v_mode text := case when p_mode = 'status' then 'status' else 'deduct' end;
  v_cycle date; v_start date; v_end date; v_today date;
  v_pcycle date; v_pstart date; v_pend date; v_porders int; v_psales bigint;
  v_rows jsonb; v_cycles jsonb; v_teamlist jsonb; v_sellerlist jsonb; v_sellers_ret jsonb;
  v_orders int; v_sales bigint;
  v_months text[] := array['มกราคม','กุมภาพันธ์','มีนาคม','เมษายน','พฤษภาคม','มิถุนายน',
                           'กรกฎาคม','สิงหาคม','กันยายน','ตุลาคม','พฤศจิกายน','ธันวาคม'];
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role, all_teams into v_role, v_all_teams from public.app_users where id = v_uid;
  if v_role not in ('Adm','RT+','RTs','Vm') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;

  v_all := (v_role in ('Adm','Vm','RT+') or coalesce(v_all_teams, false));
  if not v_all then
    select coalesce(array_agg(team_id), '{}') into v_teams
      from public.app_user_teams where user_id = v_uid;
  end if;

  v_today := (now() at time zone 'Asia/Bangkok')::date;

  if v_mode = 'deduct' then
    if p_cycle is not null and p_cycle <> '' then
      v_cycle := to_date(p_cycle || '-01', 'YYYY-MM-DD');
    else
      v_cycle := case when extract(day from v_today) >= 26
                      then (date_trunc('month', v_today) + interval '1 month')::date
                      else date_trunc('month', v_today)::date end;
    end if;
    v_start := (v_cycle - interval '1 month' + interval '25 days')::date;
    v_end   := (v_cycle + interval '24 days')::date;
    v_pcycle := (v_cycle - interval '1 month')::date;
    v_pstart := (v_pcycle - interval '1 month' + interval '25 days')::date;
    v_pend   := (v_pcycle + interval '24 days')::date;
    select coalesce(jsonb_agg(jsonb_build_object(
             'value', to_char(cyc, 'YYYY-MM'),
             'label', v_months[extract(month from cyc)::int] || ' ' || extract(year from cyc)::text,
             'range', to_char(cyc - interval '1 month' + interval '25 days', 'DD/MM') || ' – ' || to_char(cyc + interval '24 days', 'DD/MM/YYYY')
           ) order by cyc desc), '[]'::jsonb)
      into v_cycles
      from (select distinct case when extract(day from dt) >= 26
                                 then (date_trunc('month', dt) + interval '1 month')::date
                                 else date_trunc('month', dt)::date end cyc
            from (select (recorded_at at time zone 'Asia/Bangkok')::date dt from public.recon_returns where not no_deduct) d) cc;
  else
    if p_cycle is not null and p_cycle <> '' then
      v_cycle := to_date(p_cycle || '-01', 'YYYY-MM-DD');
    else
      v_cycle := date_trunc('month', v_today)::date;
    end if;
    v_start := v_cycle;
    v_end   := (v_cycle + interval '1 month' - interval '1 day')::date;
    v_pcycle := (v_cycle - interval '1 month')::date;
    v_pstart := v_pcycle;
    v_pend   := (v_pcycle + interval '1 month' - interval '1 day')::date;
    select coalesce(jsonb_agg(jsonb_build_object(
             'value', to_char(cyc, 'YYYY-MM'),
             'label', v_months[extract(month from cyc)::int] || ' ' || extract(year from cyc)::text,
             'range', to_char(cyc, 'DD/MM') || ' – ' || to_char(cyc + interval '1 month' - interval '1 day', 'DD/MM/YYYY')
           ) order by cyc desc), '[]'::jsonb)
      into v_cycles
      from (select distinct date_trunc('month', (ordered_at at time zone 'Asia/Bangkok')::date)::date cyc
            from public.orders where delivery_status = 'ตีกลับ') cc;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name), '[]'::jsonb)
    into v_teamlist
    from public.teams where (v_all or id = any(v_teams));
  if v_all and exists (select 1 from public.sellers where team_id is null) then
    v_teamlist := v_teamlist || jsonb_build_array(jsonb_build_object('id', -1, 'name', '(ไม่มีทีม)'));
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('code', employee_code, 'name', name, 'team_id', team_id) order by employee_code), '[]'::jsonb)
    into v_sellerlist
    from public.sellers
   where (v_all or team_id = any(v_teams));

  -- รายชื่อ (employee_code) ของพนักงานที่ "มีตีกลับ" ในรอบ/ทีมที่เลือก (ไม่สน filter พนักงาน) → ใช้มาร์คจุดเขียว
  if v_mode = 'deduct' then
    select coalesce(jsonb_agg(distinct s.employee_code) filter (where s.employee_code is not null), '[]'::jsonb)
      into v_sellers_ret
      from public.recon_returns r
      join public.orders o  on o.tracking_no = r.tracking_out
      join public.sellers s on s.id = o.seller_id
     where not r.no_deduct
       and (r.recorded_at at time zone 'Asia/Bangkok')::date between v_start and v_end
       and (v_all or s.team_id = any(v_teams))
       and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id);
  else
    select coalesce(jsonb_agg(distinct s.employee_code) filter (where s.employee_code is not null), '[]'::jsonb)
      into v_sellers_ret
      from public.orders o
      join public.sellers s on s.id = o.seller_id
     where o.delivery_status = 'ตีกลับ'
       and (o.ordered_at at time zone 'Asia/Bangkok')::date between v_start and v_end
       and (v_all or s.team_id = any(v_teams))
       and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id);
  end if;

  if v_mode = 'deduct' then
    select coalesce(jsonb_agg(to_jsonb(q) order by q.return_date desc nulls last, q.ordered_at desc), '[]'::jsonb) into v_rows
    from (
      select r.id,
             (o.ordered_at   at time zone 'Asia/Bangkok')::date as ordered_at,
             (r.recorded_at  at time zone 'Asia/Bangkok')::date as return_date,
             o.order_no, o.customer_name, o.phone,
             nullif(concat_ws(' ', o.addr_detail, o.subdistrict, o.district, o.province, o.postal_code), '') as address,
             s.employee_code as seller_code, s.name as seller_name, t.name as team_name,
             o.carrier, o.total_sales, o.payment_method, o.payment_status, o.delivery_status, o.return_arrived,
             (select string_agg(p.name || ' ×' || public.qty_txt(oi.quantity), E'\n' order by oi.id)
                from public.order_items oi join public.products p on p.id = oi.product_id
               where oi.order_id = o.id) as items,
             r.inspection_result, r.tracking_return, r.tracking_out,
             r.no_deduct, true as has_recon
      from public.recon_returns r
      join public.orders o  on o.tracking_no = r.tracking_out
      join public.sellers s on s.id = o.seller_id
      left join public.teams t on t.id = s.team_id
      where not r.no_deduct
        and (r.recorded_at at time zone 'Asia/Bangkok')::date between v_start and v_end
        and (v_all or s.team_id = any(v_teams))
        and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id)
        and (p_seller_code is null or s.employee_code = p_seller_code)
    ) q;
    select count(*), coalesce(sum(o.total_sales), 0) into v_porders, v_psales
      from public.recon_returns r
      join public.orders o  on o.tracking_no = r.tracking_out
      join public.sellers s on s.id = o.seller_id
      where not r.no_deduct
        and (r.recorded_at at time zone 'Asia/Bangkok')::date between v_pstart and v_pend
        and (v_all or s.team_id = any(v_teams))
        and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id)
        and (p_seller_code is null or s.employee_code = p_seller_code);
  else
    select coalesce(jsonb_agg(to_jsonb(q) order by q.ordered_at desc), '[]'::jsonb) into v_rows
    from (
      select o.id,
             (o.ordered_at  at time zone 'Asia/Bangkok')::date as ordered_at,
             (r.recorded_at at time zone 'Asia/Bangkok')::date as return_date,
             o.order_no, o.customer_name, o.phone,
             nullif(concat_ws(' ', o.addr_detail, o.subdistrict, o.district, o.province, o.postal_code), '') as address,
             s.employee_code as seller_code, s.name as seller_name, t.name as team_name,
             o.carrier, o.total_sales, o.payment_method, o.payment_status, o.delivery_status, o.return_arrived,
             (select string_agg(p.name || ' ×' || public.qty_txt(oi.quantity), E'\n' order by oi.id)
                from public.order_items oi join public.products p on p.id = oi.product_id
               where oi.order_id = o.id) as items,
             r.inspection_result, r.tracking_return, o.tracking_no as tracking_out,
             coalesce(r.no_deduct, false) as no_deduct, (r.id is not null) as has_recon
      from public.orders o
      left join public.recon_returns r on r.tracking_out = o.tracking_no
      left join public.sellers s on s.id = o.seller_id
      left join public.teams t on t.id = s.team_id
      where o.delivery_status = 'ตีกลับ'
        and (o.ordered_at at time zone 'Asia/Bangkok')::date between v_start and v_end
        and (v_all or s.team_id = any(v_teams))
        and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id)
        and (p_seller_code is null or s.employee_code = p_seller_code)
    ) q;
    select count(*), coalesce(sum(o.total_sales), 0) into v_porders, v_psales
      from public.orders o
      left join public.sellers s on s.id = o.seller_id
      where o.delivery_status = 'ตีกลับ'
        and (o.ordered_at at time zone 'Asia/Bangkok')::date between v_pstart and v_pend
        and (v_all or s.team_id = any(v_teams))
        and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id)
        and (p_seller_code is null or s.employee_code = p_seller_code);
  end if;

  v_orders := jsonb_array_length(v_rows);
  select coalesce(sum((e->>'total_sales')::bigint), 0) into v_sales
    from jsonb_array_elements(v_rows) e;

  return jsonb_build_object(
    'authorized', true, 'ok', true,
    'role', v_role, 'all_teams', v_all, 'mode', v_mode,
    'cycle', jsonb_build_object(
       'value', to_char(v_cycle, 'YYYY-MM'),
       'label', v_months[extract(month from v_cycle)::int] || ' ' || extract(year from v_cycle)::text,
       'range', to_char(v_start, 'DD/MM') || ' – ' || to_char(v_end, 'DD/MM/YYYY')),
    'cycles', v_cycles,
    'teams', v_teamlist,
    'sellers', v_sellerlist,
    'sellers_with_returns', coalesce(v_sellers_ret, '[]'::jsonb),
    'stats', jsonb_build_object('orders', v_orders, 'sales', v_sales),
    'prev', jsonb_build_object('orders', coalesce(v_porders,0), 'sales', coalesce(v_psales,0)),
    'rows', v_rows
  );
end $function$;

-- ---------- app_search_orders (แทนที่ 2 จุด) ----------
CREATE OR REPLACE FUNCTION public.app_search_orders(p_token text, p_query text, p_view text DEFAULT 'order'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_uid uuid; v_role text; v_all_teams boolean; v_all boolean; v_teams bigint[];
  v_q text := btrim(coalesce(p_query,''));
  v_view text := case when p_view='deduct' then 'deduct' else 'order' end;
  v_rows jsonb; v_count int;
  v_months text[] := array['มกราคม','กุมภาพันธ์','มีนาคม','เมษายน','พฤษภาคม','มิถุนายน','กรกฎาคม','สิงหาคม','กันยายน','ตุลาคม','พฤศจิกายน','ธันวาคม'];
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role, all_teams into v_role, v_all_teams from public.app_users where id=v_uid;
  if v_role not in ('Adm','OM','Vm','RT+','RTs') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  v_all := (v_role in ('Adm','OM','Vm','RT+') or coalesce(v_all_teams,false));
  if not v_all then
    select coalesce(array_agg(team_id),'{}') into v_teams from public.app_user_teams where user_id=v_uid;
  end if;
  if length(v_q) < 2 then
    return jsonb_build_object('authorized',true,'ok',true,'too_short',true,'rows','[]'::jsonb,'count',0,'view',v_view);
  end if;

  if v_view='order' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.ordered_at desc),'[]'::jsonb), count(*) into v_rows, v_count
    from (
      select o.id,
        (o.ordered_at at time zone 'Asia/Bangkok')::date as ordered_at,
        o.order_no, o.customer_name, o.phone,
        nullif(concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code),'') as address,
        s.employee_code as seller_code, s.name as seller_name, t.name as team_name,
        o.carrier, o.total_sales, o.payment_method, o.payment_status, o.delivery_status, o.return_arrived, o.note,
        o.tracking_no as tracking_out,
        (select string_agg(p.name||' ×'||public.qty_txt(oi.quantity), E'\n' order by oi.id) from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=o.id) as items,
        array_remove(array[
          case when o.phone ilike '%'||v_q||'%' then 'phone' end,
          case when o.customer_name ilike '%'||v_q||'%' then 'name' end,
          case when concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code) ilike '%'||v_q||'%' then 'address' end,
          case when o.tracking_no ilike '%'||v_q||'%' then 'tracking' end,
          case when o.note ilike '%'||v_q||'%' then 'note' end ], null) as matched_fields
      from public.orders o
      left join public.sellers s on s.id=o.seller_id
      left join public.teams t on t.id=s.team_id
      where (o.phone ilike '%'||v_q||'%' or o.customer_name ilike '%'||v_q||'%'
             or concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code) ilike '%'||v_q||'%'
             or o.tracking_no ilike '%'||v_q||'%' or o.note ilike '%'||v_q||'%')
        and (v_all or s.team_id = any(v_teams))
      limit 5000
    ) x;
  else
    select coalesce(jsonb_agg(to_jsonb(x) order by x.return_date desc nulls last, x.ordered_at desc),'[]'::jsonb), count(*) into v_rows, v_count
    from (
      select o.id,
        (o.ordered_at at time zone 'Asia/Bangkok')::date as ordered_at,
        (r.recorded_at at time zone 'Asia/Bangkok')::date as return_date,
        o.order_no, o.customer_name, o.phone,
        nullif(concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code),'') as address,
        s.employee_code as seller_code, s.name as seller_name, t.name as team_name,
        o.carrier, o.total_sales, o.payment_method, o.payment_status, o.delivery_status, o.return_arrived, o.note,
        o.tracking_no as tracking_out, r.inspection_result, r.tracking_return, r.no_deduct, true as has_recon,
        (select string_agg(p.name||' ×'||public.qty_txt(oi.quantity), E'\n' order by oi.id) from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=o.id) as items,
        (v_months[extract(month from cc.cyc)::int]||' '||extract(year from cc.cyc)::text) as cycle_label,
        to_char(cc.cyc,'YYYY-MM') as cycle_value,
        array_remove(array[
          case when o.phone ilike '%'||v_q||'%' then 'phone' end,
          case when o.customer_name ilike '%'||v_q||'%' then 'name' end,
          case when concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code) ilike '%'||v_q||'%' then 'address' end,
          case when o.tracking_no ilike '%'||v_q||'%' then 'tracking' end,
          case when o.note ilike '%'||v_q||'%' then 'note' end ], null) as matched_fields
      from public.recon_returns r
      join public.orders o on btrim(o.tracking_no) = btrim(r.tracking_out)
      left join public.sellers s on s.id=o.seller_id
      left join public.teams t on t.id=s.team_id
      cross join lateral (select case when extract(day from (r.recorded_at at time zone 'Asia/Bangkok')::date) >= 26
                       then (date_trunc('month',(r.recorded_at at time zone 'Asia/Bangkok')::date)+interval '1 month')::date
                       else date_trunc('month',(r.recorded_at at time zone 'Asia/Bangkok')::date)::date end as cyc) cc
      where (o.phone ilike '%'||v_q||'%' or o.customer_name ilike '%'||v_q||'%'
             or concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code) ilike '%'||v_q||'%'
             or o.tracking_no ilike '%'||v_q||'%' or o.note ilike '%'||v_q||'%')
        and (v_all or s.team_id = any(v_teams))
      limit 5000
    ) x;
  end if;

  return jsonb_build_object('authorized',true,'ok',true,'view',v_view,'query',v_q,'rows',v_rows,'count',v_count);
end $function$;
