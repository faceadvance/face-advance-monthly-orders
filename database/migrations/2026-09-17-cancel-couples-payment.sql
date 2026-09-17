-- ═══════════════════════════════════════════════════════════════════════════
-- delivery='ยกเลิก' → ผูก payment='ยกเลิก' ให้ (แก้ 2 เส้นทางไม่สอดคล้องกัน)
--
-- ปัญหา : app_bulk_set_delivery (กดอัพเดตหลายรายการจากตาราง) ผูกให้อยู่แล้ว
--         แต่ app_save_order_tracking (แก้ทีละใบใน sidebar) **ไม่ผูก**
--         → พนักงานเลือก "ยกเลิก" ใน sidebar จะได้ 'ยกเลิก + รอชำระ'
--           ซึ่งไม่ตรงความจริง (ยกเลิกแล้วไม่มีเงินเข้า) และต่างจาก bulk
--
-- แก้    : ถ้า delivery เปลี่ยนเป็น 'ยกเลิก' และผู้ใช้ไม่ได้เจตนาเลือก payment อื่น
--          (คือค่าที่ส่งมาเป็น รอชำระ/ยกเลิก) → ตั้ง payment='ยกเลิก'
--          เคารพเจตนาผู้ใช้: ถ้าเลือก ชำระแล้ว/ไม่ใช่งานขาย มาเอง จะไม่ทับ
--          (เคสจ่ายแล้วยกเลิกทีหลัง → ต้องคืนเงิน ยังตั้ง ชำระแล้ว ได้)
--
-- 🔴 กับดักที่ต้องระวัง: guard 'cod_payment_locked' (COD แก้ payment มือไม่ได้)
--    ถ้าไม่ยกเว้น การผูกนี้จะถูกบล็อกกับออเดอร์ COD ทั้งหมด
--    (ข้อมูลจริง: 22 จาก 26 ออเดอร์ที่ยกเลิกเป็น COD) → จึงใส่ not v_cancel_couple
--    ให้ข้าม guard เฉพาะการผูกอัตโนมัติ — สอดคล้องกับ bulk ที่ไม่มี guard นี้
--
-- ขอบเขต: backend เท่านั้น · frontend จะ deploy ตามทีหลัง (ให้ชิป payment เด้งเป็น
--          "ยกเลิก" ให้ผู้ใช้เห็นก่อนกดบันทึก — ผลลัพธ์เหมือนกันทั้งก่อน/หลัง deploy)
-- rollback: /tmp/sot_BEFORE.sql
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.app_save_order_tracking(p_token text, p_order_id bigint, p_delivery_status text DEFAULT NULL::text, p_payment_status text DEFAULT NULL::text, p_return_reason text DEFAULT NULL::text, p_status_detail text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
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
  v_pay_valid   text[] := array['รอชำระ','ชำระแล้ว','ยกเลิก','ไม่ใช่งานขาย'];
  v_cancel_couple boolean := false;
  v_timeline jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;

  select coalesce(display_name, username), role into v_uname, v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','OM') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden_viewer');
  end if;

  select id, delivery_status, payment_status, return_reason, status_detail, payment_method
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
  v_changed := v_deliv_changed or v_pay_changed
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
      'return_reason', v_cur.return_reason, 'status_detail', v_cur.status_detail,
      'timeline', v_timeline);
  end if;

  if v_changed then
    update public.orders
      set delivery_status = v_new_delivery,
          payment_status  = v_new_payment,
          return_reason   = v_reason,
          status_detail   = v_detail,
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

  if v_pay_changed then
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, created_by, created_by_name)
    values (p_order_id, 'payment_change', v_cur.payment_status, v_new_payment, v_uid, v_uname);
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
    'return_reason', v_reason, 'status_detail', v_detail,
    'timeline', v_timeline);
end $function$

;
