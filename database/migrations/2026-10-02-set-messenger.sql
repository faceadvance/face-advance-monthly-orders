-- 2026-10-02 · ปุ่ม "ส่งแมส" ใน sidebar ออเดอร์ (เจ้านายสั่ง)
-- กดแล้ว: ขนส่ง → 'ส่งแมส' · ลบเลขแทร็ก · ถ้าเป็น COD → 'โอนเงิน' (สถานะชำระเลือกเองต่อได้ ไม่ติดล็อก COD)
-- เก็บค่าเดิมทั้งหมดในไทม์ไลน์ (entry_type ใหม่ 'shipping_change') + audit_log → ย้อนดู/กู้คืนได้
-- กันพัง: เลขแทร็กนี้มีบันทึกเงิน COD หรือบันทึกตีกลับแล้ว (recon จับคู่ด้วยเลขแทร็ก) → ไม่ให้ทำ ไม่งั้นรายการเงิน/ตีกลับหลุดคู่

-- 1) ไทม์ไลน์รับประเภทใหม่ (NOT VALID + VALIDATE = ไม่ล็อกตารางนาน)
alter table public.order_tracking drop constraint if exists order_tracking_entry_type_check;
alter table public.order_tracking add constraint order_tracking_entry_type_check
  check (entry_type = any (array['note','delivery_change','payment_change','shipping_change'])) not valid;
alter table public.order_tracking validate constraint order_tracking_entry_type_check;

-- 2) RPC
create or replace function public.app_set_messenger(p_token text, p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_uid uuid; v_uname text; v_role text;
  v_cur record;
  v_new_method text;
  v_detail text;
  v_timeline jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name, username), role into v_uname, v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','OM') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden_viewer');
  end if;

  select id, carrier, tracking_no, payment_method, payment_status, delivery_status
    into v_cur from public.orders where id = p_order_id for update;   -- กันกดพร้อมกัน 2 เครื่อง
  if not found then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'order_not_found');
  end if;

  if v_cur.carrier = 'ส่งแมส' and v_cur.tracking_no is null and v_cur.payment_method is distinct from 'เก็บเงินปลายทาง' then
    return jsonb_build_object('authorized', true, 'ok', true, 'noop', true,
      'carrier', v_cur.carrier, 'tracking_no', v_cur.tracking_no, 'payment_method', v_cur.payment_method,
      'payment_status', v_cur.payment_status, 'delivery_status', v_cur.delivery_status);
  end if;

  if v_cur.tracking_no is not null and (
       exists (select 1 from public.recon_cod_payments where tracking_out = v_cur.tracking_no)
    or exists (select 1 from public.recon_returns where tracking_out = v_cur.tracking_no)) then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'tracking_reconciled');
  end if;

  v_new_method := case when v_cur.payment_method = 'เก็บเงินปลายทาง' then 'โอนเงิน' else v_cur.payment_method end;

  update public.orders
     set carrier = 'ส่งแมส', tracking_no = null, payment_method = v_new_method, updated_at = now()
   where id = p_order_id;

  v_detail := concat_ws(' · ',
    'เลขแทร็กเดิม ' || coalesce(v_cur.tracking_no, '—'),
    case when v_new_method is distinct from v_cur.payment_method
         then 'ชำระ ' || coalesce(v_cur.payment_method, '—') || ' → ' || coalesce(v_new_method, '—') end);
  insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
  values (p_order_id, 'shipping_change', coalesce(v_cur.carrier, '—'), 'ส่งแมส', v_detail, v_uid, v_uname);

  insert into public.audit_log(user_id, username, event, detail)
  values (v_uid, v_uname, 'order_set_messenger', jsonb_build_object(
    'order_id', p_order_id,
    'from', jsonb_build_object('carrier', v_cur.carrier, 'tracking_no', v_cur.tracking_no,
                               'payment_method', v_cur.payment_method, 'payment_status', v_cur.payment_status),
    'to',   jsonb_build_object('carrier', 'ส่งแมส', 'tracking_no', null, 'payment_method', v_new_method)));

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'type', t.entry_type, 'note', t.note, 'old', t.old_value,
    'new', t.new_value, 'detail', t.detail, 'by', coalesce((select coalesce(au.display_name, au.username::text) from public.app_users au where au.id = t.created_by), t.created_by_name, ''), 'mine', (t.created_by = v_uid),
    'at', to_char(t.created_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI:SS')
  ) order by t.created_at desc, t.id desc), '[]'::jsonb) into v_timeline
  from public.order_tracking t where t.order_id = p_order_id;

  return jsonb_build_object('authorized', true, 'ok', true,
    'carrier', 'ส่งแมส', 'tracking_no', null, 'payment_method', v_new_method,
    'payment_status', v_cur.payment_status, 'delivery_status', v_cur.delivery_status,
    'timeline', v_timeline);
end $function$;

revoke all on function public.app_set_messenger(text, bigint) from public;
grant execute on function public.app_set_messenger(text, bigint) to anon, authenticated, service_role;
