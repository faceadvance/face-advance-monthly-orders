-- 2026-09-22 · EDITH: คิวใหม่ "ออเดอร์ที่ไม่มีเซล" — เติมพนักงานขาย หรือยืนยันว่าไม่มี
--
-- เจ้านายสั่ง: "หน้า EDITH เพิ่มรายการ ออเดอร์ที่ไม่มีเซล เข้าไปด้วย ให้เติมเซลลงไปจากตัวเลือกที่มี
--              (มีให้เลือกว่า ไม่เติมเซลด้วย กรณีที่เป็นงานส่วนกลางไม่มีผู้ขาย)"
--
-- 🔴 ทำไมต้องมีคอลัมน์ใหม่: ถ้า "ไม่เติมเซล" แล้วไม่จดอะไรไว้ ออเดอร์นั้นจะยังเข้าเงื่อนไข
--    seller_id is null อยู่ → โผล่กลับมาในคิวทุกครั้ง เคลียร์ไม่จบ
--
-- ขอบเขตคิว (ตรวจกับข้อมูลจริง 2026-09-22): ออเดอร์ seller_id ว่าง มี 229 ใบ แต่
--    196 ใบเป็นแบรนด์ 'ตัวแทน' (เอกสาร · ยอด 0 ทุกใบ) ซึ่ง "ไม่ควรมีเซล" อยู่แล้ว → ต้องกันออก
--    เหลือเข้าคิวจริง 33 ใบ (HOPEFUL 16 · แบรนด์อื่นๆ 17) ตรงกับก้อน "อื่นๆ" ในหน้ายอดขาย
--    กรองข้อมูลจำลอง MOCK2512- ออกด้วย

alter table public.orders
  add column if not exists seller_waived boolean not null default false;

comment on column public.orders.seller_waived is
  'ยืนยันแล้วว่าออเดอร์นี้ไม่มีพนักงานขาย (งานส่วนกลาง) — ใช้ตัด EDITH คิว noseller ออก';

-- ดัชนีบางส่วน: คิวนี้อ่านบ่อย (ทุกครั้งที่เปิด EDITH) แต่แถวที่เข้าเงื่อนไขน้อยมาก
create index if not exists orders_noseller_idx
  on public.orders (ordered_at)
  where seller_id is null and not seller_waived;

-- ---------- รายชื่อพนักงานขายให้เลือก ----------
create or replace function public.app_edith_sellers(p_token text)
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
  if v_role <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;
  return jsonb_build_object('authorized', true, 'ok', true,
    'sellers', coalesce((select jsonb_agg(jsonb_build_object(
        'code', s.employee_code, 'name', s.name,
        'department', s.department,
        'team', coalesce(t.name, '—ไม่มีทีม—'),
        'active', s.is_active)
      -- คนที่ยังทำงานอยู่ขึ้นก่อน แล้วเรียงตามทีม/รหัส
      order by s.is_active desc, coalesce(t.name,'zzz'), s.employee_code)
      from public.sellers s
      left join public.teams t on t.id = s.team_id
      where s.employee_code is not null), '[]'::jsonb));
end $function$;

grant execute on function public.app_edith_sellers(text) to anon, authenticated, service_role;

-- ---------- รายละเอียดออเดอร์ที่ไม่มีเซล (ใช้ในแผงขวาของ EDITH) ----------
create or replace function public.app_edith_noseller_detail(p_token text, p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
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
    'subdistrict', o.subdistrict, 'addr_detail', o.addr_detail, 'postal_code', o.postal_code,
    'brand', b.name, 'total_sales', o.total_sales,
    'payment_method', o.payment_method, 'payment_status', o.payment_status,
    'delivery_status', o.delivery_status, 'tracking_no', o.tracking_no, 'carrier', o.carrier,
    'return_reason', o.return_reason, 'status_detail', o.status_detail,
    'note', o.note,
    -- โน้ตติดตามล่าสุดจากไทม์ไลน์ (ช่วยเดาว่าใครดูแลออเดอร์นี้อยู่)
    'last_note', (select t.note from public.order_tracking t
                   where t.order_id = o.id and t.entry_type = 'note'
                     and nullif(btrim(coalesce(t.note,'')),'') is not null
                   order by t.created_at desc limit 1),
    'last_note_by', (select t.created_by_name from public.order_tracking t
                      where t.order_id = o.id and t.entry_type = 'note'
                        and nullif(btrim(coalesce(t.note,'')),'') is not null
                      order by t.created_at desc limit 1),
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

grant execute on function public.app_edith_noseller_detail(text,bigint) to anon, authenticated, service_role;

-- ---------- เติมเซล / ยืนยันว่าไม่มีเซล ----------
-- p_seller_code = null หรือ '' → ยืนยันว่าไม่มีเซล (ตั้ง seller_waived = true)
create or replace function public.app_edith_set_seller(
  p_token text, p_order_id bigint, p_seller_code text default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_uid uuid; v_role text; v_uname text;
  v_sid bigint; v_sname text; v_code text;
  v_old bigint; v_oldname text; v_order_no text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role, coalesce(display_name, username) into v_role, v_uname
    from public.app_users where id = v_uid;
  if v_role <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;

  select o.order_no, o.seller_id into v_order_no, v_old
    from public.orders o where o.id = p_order_id;
  if v_order_no is null then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'not_found');
  end if;
  select s.name into v_oldname from public.sellers s where s.id = v_old;

  v_code := nullif(btrim(coalesce(p_seller_code, '')), '');

  if v_code is null then
    -- ไม่เติมเซล: จดธงไว้ ไม่ต้องแตะ seller_id (ยังว่างอยู่ตามความจริง)
    update public.orders set seller_waived = true, updated_at = now() where id = p_order_id;
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
      values (p_order_id, 'note', coalesce(v_oldname, '—'), '—',
              'ยืนยันว่าออเดอร์นี้ไม่มีพนักงานขาย (งานส่วนกลาง)', v_uid, v_uname);
    insert into public.audit_log(user_id, username, event, detail)
      values (v_uid, v_uname, 'edith_set_seller',
              jsonb_build_object('order_id', p_order_id, 'order_no', v_order_no, 'waived', true));
    return jsonb_build_object('authorized', true, 'ok', true, 'waived', true);
  end if;

  select s.id, s.name into v_sid, v_sname
    from public.sellers s where s.employee_code = v_code;
  if v_sid is null then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_seller');
  end if;

  update public.orders
     set seller_id = v_sid, seller_waived = false, updated_at = now()
   where id = p_order_id;
  -- 🔴 ต้อง coalesce ชื่อเซล: 20 จาก 74 คนไม่มีชื่อในระบบ (name เป็น NULL)
  --    ต่อสตริงกับ NULL ใน Postgres ได้ NULL ทั้งก้อน → detail หายทั้งช่อง ไทม์ไลน์ไม่บอกอะไรเลย
  --    (เจอตอนกดทดสอบจริงกับ m01 ที่ไม่มีชื่อ — 2026-09-22)
  insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
    values (p_order_id, 'note', coalesce(v_oldname, '—'), v_code,
            'เติมพนักงานขาย: ' || coalesce(nullif(btrim(v_sname), ''), '(ไม่มีชื่อในระบบ)')
              || ' (' || v_code || ')', v_uid, v_uname);
  insert into public.audit_log(user_id, username, event, detail)
    values (v_uid, v_uname, 'edith_set_seller',
            jsonb_build_object('order_id', p_order_id, 'order_no', v_order_no,
                               'seller_code', v_code, 'seller_id', v_sid));
  return jsonb_build_object('authorized', true, 'ok', true,
                            'seller_code', v_code, 'seller_name', v_sname);
end $function$;

grant execute on function public.app_edith_set_seller(text,bigint,text) to anon, authenticated, service_role;
