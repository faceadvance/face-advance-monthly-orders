-- 2026-09-17 · "ชำระแล้ว + ตีกลับถึง" ต้องเข้า EDITH เหมือนเคส COD
--
-- ปัญหา: reconcile_order ตั้ง recon_conflict เฉพาะเมื่อมี "รายการรับเงิน COD" คู่กับ "ตีกลับถึง"
--        ออเดอร์ที่รับเงินทางอื่น (โอนเงิน / ตัดบัตร / ตั้ง ชำระแล้ว มือ) แล้วของตีกลับมา
--        จะตกไปสาขาที่สอง → พลิกเป็น ตีกลับ/ยกเลิก เงียบๆ ไม่มีใครเห็นใน EDITH
--        (เจอตอนเตรียมนำเข้าตีกลับย้อนหลัง: 8 ออเดอร์ · 11,030 บาท จะหายจากยอด "ชำระแล้ว")
--
-- แก้: เงื่อนไขขัดแย้ง = มีตีกลับถึง  และ  (มีรายการ COD  หรือ  payment_status='ชำระแล้ว')
--      พร้อมข้อความที่ตรงกับเคสจริง (ห้ามให้ UI พูดว่า "มีทั้งรายการ COD" ตอนที่ไม่มี)
--
-- ของใหม่: app_edith_confirm_return — ทางออกที่ 3 ของเคสไม่มี COD
--          (ยืนยันว่าตีกลับจริง → ตีกลับ/ยกเลิก · เคสไม่มี COD ไม่มีปุ่ม "ลบ COD" ให้กดแทนได้)

begin;

-- ═══ 1. reconcile_order ═══
create or replace function public.reconcile_order(p_order_id bigint)
returns void
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  o record;
  has_ret boolean;
  has_cod boolean;
  v_cod_amount numeric;
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
  if has_ret and (has_cod or o.payment_status = 'ชำระแล้ว') then
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
    select c.amount into v_cod_amount
      from public.recon_cod_payments c
      where btrim(c.tracking_out) = o.tr
      order by c.id desc limit 1;
    v_target := case when v_cod_amount is not null and round(v_cod_amount) = o.total_sales
                     then 'ชำระแล้ว' else 'error' end;
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

-- ═══ 2. app_edith_issues — ข้อความในลิสต์ต้องตรงกับเคสจริง ═══
create or replace function public.app_edith_issues(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
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
    'total',    jsonb_array_length(v_issues)
  ) into v_counts;
  return jsonb_build_object('authorized', true, 'ok', true, 'issues', v_issues, 'counts', v_counts);
end $function$;

-- ═══ 3. app_edith_confirm_return — "ยืนยันตีกลับ · ยกเลิกการขาย" ═══
-- เคสไม่มีรายการ COD กดปุ่ม "ลบ COD" ไม่ได้ (ไม่มีอะไรให้ลบ) จึงต้องมีปุ่มนี้แทน
-- ผลลัพธ์เท่ากับสาขา has_ret ของ reconcile_order — ไม่แตะ no_deduct (ตั้งตอนบันทึกตีกลับเท่านั้น)
create or replace function public.app_edith_confirm_return(p_token text, p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare v_uid uuid; v_uname text; v_role text; o record;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name, username), role into v_uname, v_role from public.app_users where id = v_uid;
  if v_role <> 'Adm' then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;

  select id, btrim(coalesce(tracking_no,'')) as tr, delivery_status, payment_status, return_reason
    into o from public.orders where id = p_order_id;
  if not found then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'not_found'); end if;
  if o.tr = '' then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'no_tracking'); end if;
  -- ต้องมีบันทึกตีกลับอยู่จริง ไม่ใช่ยกเลิกลอยๆ
  if not exists(select 1 from public.recon_returns r where btrim(r.tracking_out) = o.tr) then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'no_return_record');
  end if;

  if o.delivery_status is distinct from 'ตีกลับ' then
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
      values (o.id, 'delivery_change', o.delivery_status, 'ตีกลับ', 'ยืนยันตีกลับ (EDITH)', v_uid, v_uname);
  end if;
  if o.payment_status is distinct from 'ยกเลิก' then
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, created_by, created_by_name)
      values (o.id, 'payment_change', o.payment_status, 'ยกเลิก', v_uid, v_uname);
  end if;

  update public.orders set
    delivery_status = 'ตีกลับ', payment_status = 'ยกเลิก',
    return_arrived = true, recon_conflict = false,
    return_reason = coalesce(nullif(btrim(coalesce(return_reason, '')), ''), 'ตีกลับถึงแล้ว'),
    updated_at = now()
  where id = o.id;

  insert into public.order_tracking(order_id, entry_type, note, created_by, created_by_name)
    values (o.id, 'note', 'ยืนยันตีกลับ จาก EDITH (ยกเลิกการขาย · ไม่ลบบันทึกตีกลับ)', v_uid, v_uname);

  insert into public.audit_log(user_id, username, event, detail)
    values (v_uid, v_uname, 'edith_confirm_return', jsonb_build_object('order_id', o.id, 'tracking', o.tr));

  return jsonb_build_object('authorized', true, 'ok', true);
end $function$;

-- สิทธิ์ให้ตรงกับ app_edith_* ตัวอื่น (SECURITY DEFINER + เช็ค token/role ในตัวฟังก์ชันเอง)
grant execute on function public.app_edith_confirm_return(text, bigint) to anon, authenticated, service_role;

commit;
