-- หน้าค้นหา: เลือกค้นเฉพาะคอลัมน์ได้ (เจ้านายขอ 2026-09-23)
-- ค่าเริ่มต้น 'all' = ค้นทั้ง 5 ช่องเหมือนเดิม → เว็บเวอร์ชันเก่าที่ไม่ส่ง p_field ยังใช้ได้
-- เงื่อนไขค้นหาย้ายมาอยู่ search_match() ตัวเดียว ใช้ร่วมกันทั้งโหมดออเดอร์/หักยอด (เดิมเขียนซ้ำ 4 ที่)

create or replace function public.search_match(
  p_field text, p_q text, p_phone text, p_name text, p_addr text, p_trk text, p_note text)
returns boolean language sql immutable parallel safe as $$
  select (p_field in ('all','phone')    and p_phone ilike '%'||p_q||'%')
      or (p_field in ('all','name')     and p_name  ilike '%'||p_q||'%')
      or (p_field in ('all','address')  and p_addr  ilike '%'||p_q||'%')
      or (p_field in ('all','tracking') and p_trk   ilike '%'||p_q||'%')
      or (p_field in ('all','note')     and p_note  ilike '%'||p_q||'%')
$$;
revoke all on function public.search_match(text,text,text,text,text,text,text) from public, anon, authenticated;

-- ตัวเก่า 3 พารามิเตอร์ต้องลบ ไม่งั้น PostgREST เจอ 2 overload แล้วเลือกไม่ถูก
drop function if exists public.app_search_orders(text, text, text);

create or replace function public.app_search_orders(p_token text, p_query text, p_view text default 'order', p_field text default 'all')
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_uid uuid; v_role text; v_all_teams boolean; v_all boolean; v_teams bigint[];
  v_q text := btrim(coalesce(p_query,''));
  v_view text := case when p_view='deduct' then 'deduct' else 'order' end;
  v_field text := case when p_field in ('phone','name','address','tracking','note') then p_field else 'all' end;
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
    return jsonb_build_object('authorized',true,'ok',true,'too_short',true,'rows','[]'::jsonb,'count',0,'view',v_view,'field',v_field);
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
          case when public.search_match(v_field, v_q, o.phone, null, null, null, null) then 'phone' end,
          case when public.search_match(v_field, v_q, null, o.customer_name, null, null, null) then 'name' end,
          case when public.search_match(v_field, v_q, null, null, concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code), null, null) then 'address' end,
          case when public.search_match(v_field, v_q, null, null, null, o.tracking_no, null) then 'tracking' end,
          case when public.search_match(v_field, v_q, null, null, null, null, o.note) then 'note' end ], null) as matched_fields
      from public.orders o
      left join public.sellers s on s.id=o.seller_id
      left join public.teams t on t.id=s.team_id
      where public.search_match(v_field, v_q, o.phone, o.customer_name,
              concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code), o.tracking_no, o.note)
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
          case when public.search_match(v_field, v_q, o.phone, null, null, null, null) then 'phone' end,
          case when public.search_match(v_field, v_q, null, o.customer_name, null, null, null) then 'name' end,
          case when public.search_match(v_field, v_q, null, null, concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code), null, null) then 'address' end,
          case when public.search_match(v_field, v_q, null, null, null, o.tracking_no, null) then 'tracking' end,
          case when public.search_match(v_field, v_q, null, null, null, null, o.note) then 'note' end ], null) as matched_fields
      from public.recon_returns r
      join public.orders o on btrim(o.tracking_no) = btrim(r.tracking_out)
      left join public.sellers s on s.id=o.seller_id
      left join public.teams t on t.id=s.team_id
      cross join lateral (select case when extract(day from (r.recorded_at at time zone 'Asia/Bangkok')::date) >= 26
                       then (date_trunc('month',(r.recorded_at at time zone 'Asia/Bangkok')::date)+interval '1 month')::date
                       else date_trunc('month',(r.recorded_at at time zone 'Asia/Bangkok')::date)::date end as cyc) cc
      where public.search_match(v_field, v_q, o.phone, o.customer_name,
              concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code), o.tracking_no, o.note)
        and (v_all or s.team_id = any(v_teams))
      limit 5000
    ) x;
  end if;

  return jsonb_build_object('authorized',true,'ok',true,'view',v_view,'field',v_field,'query',v_q,'rows',v_rows,'count',v_count);
end $function$;

grant execute on function public.app_search_orders(text, text, text, text) to anon, authenticated, service_role;
