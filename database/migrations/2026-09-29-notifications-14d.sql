-- 2026-09-29 แจ้งเตือน: นอกจาก 50 รายการล่าสุด ให้โชว์แค่ 14 วันย้อนหลัง (เจ้านายขอ)
-- + ตัดรายการตีกลับที่วันที่เป็นอนาคต (วันที่พิมพ์ผิดจากไฟล์ย้อนหลัง เช่นปี 3034 เคยค้างบนสุด)
-- หน้าเว็บไม่ต้องแก้ (รูปแบบผลลัพธ์เดิม)

CREATE OR REPLACE FUNCTION public.app_notifications(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_uid uuid; v_role text; v_items jsonb;
  v_see_orders boolean; v_see_returns boolean;
  v_since timestamptz := now() - interval '14 days';   -- แจ้งเตือนย้อนหลังแค่ 14 วัน (เจ้านายขอ 2026-09-29)
  v_until timestamptz := now() + interval '1 day';     -- กันวันที่พิมพ์ผิดเป็นอนาคตค้างบนสุด
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;

  -- สิทธิ์ตามหน้า (ดู app_can_page — ต้องตรงกับ ROLE_PAGES ใน frontend/src/pages.ts)
  v_see_orders  := public.app_can_page(v_role, 'orders');
  v_see_returns := v_see_orders or public.app_can_page(v_role, 'returns-list');

  select coalesce(jsonb_agg(jsonb_build_object(
           'kind', x.kind, 'at', x.at, 'by_name', x.by_name, 'n', x.n, 'trackings', x.trackings) order by x.at desc), '[]'::jsonb)
    into v_items
  from (
    -- 📦 บันทึกตีกลับ (group ต่อผู้บันทึก+เวลา) — เห็นได้ถ้าเข้าถึงหน้าออเดอร์ตีกลับ หรือ ออเดอร์
    select 'returns' as kind, r.recorded_at as at,
           coalesce(u.display_name, u.username::text) as by_name,
           count(*)::int as n,
           string_agg(r.tracking_out, ', ' order by r.tracking_out) as trackings
    from public.recon_returns r
    left join public.app_users u on u.id = r.created_by
    where v_see_returns
      and r.recorded_at >= v_since and r.recorded_at < v_until
    group by r.created_by, u.display_name, u.username, r.recorded_at
    union all
    -- 📥 นำเข้าออเดอร์ — เห็นได้ถ้าเข้าถึงหน้าออเดอร์
    select 'orders' as kind, a.created_at as at,
           coalesce(u.display_name, a.username) as by_name,
           coalesce((a.detail->>'orders')::int, 0) as n,
           null::text as trackings
    from public.audit_log a
    left join public.app_users u on u.id = a.user_id
    where v_see_orders
      and a.created_at >= v_since
      and a.event = 'import_orders'
      and coalesce((a.detail->>'orders')::int, 0) > 0
    union all
    -- 💰 นำเข้าไฟล์ COD — เห็นได้ถ้าเข้าถึงหน้าออเดอร์ · ข้าม source='manual' (รับเงินแก้มือทีละรายการ)
    select 'cod' as kind, a.created_at as at,
           coalesce(u.display_name, a.username) as by_name,
           coalesce((a.detail->>'paid')::int, 0) as n,
           null::text as trackings
    from public.audit_log a
    left join public.app_users u on u.id = a.user_id
    where v_see_orders
      and a.created_at >= v_since
      and a.event = 'import_cod'
      and coalesce(a.detail->>'source', '') <> 'manual'
      and coalesce((a.detail->>'paid')::int, 0) > 0
    order by at desc
    limit 50
  ) x;

  return jsonb_build_object('authorized', true, 'ok', true, 'items', v_items);
end $function$;
