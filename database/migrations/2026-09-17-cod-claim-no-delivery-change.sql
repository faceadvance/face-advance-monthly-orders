-- ═══════════════════════════════════════════════════════════════════════════
-- COD "ทำเคลม" → ห้ามเปลี่ยนสถานะจัดส่งเป็น "ส่งสำเร็จ"
--
-- ปัญหา : เดิม app_import_cod_payments ตั้ง delivery_status='ส่งสำเร็จ' ให้ทุกแถว
--         ที่นำเข้าจากไฟล์ (ยกเว้นออเดอร์ที่มีบันทึกตีกลับ) โดย**ไม่ดู** received_from
--         → เคสเคลมขนส่ง (ของหาย/เสียหาย · ขนส่งจ่ายชดใช้ · ลูกค้าไม่ได้ของ)
--           จะถูกนับเป็น "ส่งสำเร็จ" ทั้งที่ลูกค้าไม่เคยได้รับสินค้า
--         พบตอนนำเข้า COD ย้อนหลัง ม.ค.–มิ.ย. 2569: มี 5 ออเดอร์สถานะ "มีปัญหา ·
--         รับเงินเคลมแล้ว" ที่จะถูกกลืนเป็น "ส่งสำเร็จ"
--
-- แก้    : เพิ่มเงื่อนไขเดียว — ข้ามการตั้ง delivery_status ถ้า received_from='ทำเคลม'
--          (payment_status ยังตั้งตามปกติ เพราะเงินเข้าจริง)
--
-- ขอบเขต: backend เท่านั้น · frontend ไม่ต้องแก้ (dropdown "ทำเคลม" มีอยู่แล้วที่
--          main.ts:2990 และไฟล์นำเข้ากรอกคอลัม "ได้รับจาก" = ทำเคลม ได้อยู่แล้ว)
-- ผลกับข้อมูลเดิม: ไม่มี — ปัจจุบัน received_from='ทำเคลม' มี 0 แถวในระบบ
--          (ระบบ 12,533 · ขนส่ง 1,554 · ทำเคลม 0)
-- หมายเหตุ: reconcile_order (COD แก้มือ/trigger) ไม่แตะ delivery_status อยู่แล้ว
--          จึงไม่ต้องแก้ → พฤติกรรมสองเส้นทางสอดคล้องกันหลังแก้
-- rollback: /tmp/cod_fn_BEFORE.sql (หรือลบบรรทัด received_from ออก)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.app_import_cod_payments(p_token text, p_rows jsonb, p_mode text, p_fix_trackings jsonb DEFAULT '[]'::jsonb, p_source text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_uid uuid; v_uname text; v_role text;
  v_problems jsonb; v_mismatches jsonb;
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

  select count(*) into v_rows_total from _cod;
  v_ok := (jsonb_array_length(v_problems) = 0);
  v_rows_ok := case when v_ok then v_rows_total else 0 end;

  if p_mode = 'confirm' and v_ok then
    if p_source is null or btrim(p_source) = '' then
      return jsonb_build_object('authorized', true, 'ok', false, 'error', 'no_evidence');
    end if;

    -- แก้ยอดออเดอร์ตามที่เลือก (round → total_sales int)
    update public.orders o
       set total_sales = round(e.amount)::int, updated_at = now()
      from _cod_eval e
     where o.id = e.order_id and e.amount is not null
       and e.tracking_out in (select btrim(x) from jsonb_array_elements_text(coalesce(p_fix_trackings,'[]'::jsonb)) x)
       and round(e.amount) is distinct from e.order_amount::numeric;
    get diagnostics v_fixed = row_count;

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
        case when round(e.amount) = o.total_sales then 'ชำระแล้ว' else 'error' end as new_pay
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
    'inserted', v_inserted, 'fixed', v_fixed, 'paid', v_paid, 'err', v_err
  );
end $function$

;
