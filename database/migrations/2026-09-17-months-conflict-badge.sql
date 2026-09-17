-- 2026-09-17 · ป้ายเดือน: ⚠️ ชนะเสมอ — มีของรอตรวจแม้ใบเดียว เดือนนั้นห้ามได้ ✓
--
-- ปัญหา (เจ้านายจับได้): months_done ไม่นับ recon_conflict เลย
--   → เดือนติ๊ก ✓ "เสร็จสมบูรณ์" ได้ ทั้งที่ยังมีออเดอร์ขัดแย้งรอคนตัดสินใน EDITH
--   เช่น ม.ค. 2026 ติ๊ก ✓ แต่มี 2 ใบขัดแย้ง (พบหลังนำเข้าตีกลับย้อนหลัง)
--
-- แก้:
--   months_done     = ไม่มีของค้าง  และ  ไม่มี error  และ  ไม่มี recon_conflict
--   months_conflict = ฟิลด์ใหม่ ให้ frontend เขียน tooltip ได้ตรงเคส
--                     (ของเก่าไม่รู้จักฟิลด์นี้ก็ข้ามไป — เดือนนั้นจะไม่มีป้าย ซึ่งยังไม่ผิด
--                      ต่างจากการยัดเข้า months_error ที่จะทำให้ของเก่าพูดว่า "error" ทั้งที่ไม่มี)

create or replace function public.get_months(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare v_uid uuid; v_idle int; v_role text; v_out jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select idle_minutes, role into v_idle, v_role from public.app_users where id = v_uid;
  with m as (
    select to_char(ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM') as ym,
           bool_or(payment_status = 'error') as has_err,
           bool_or(coalesce(recon_conflict, false)) as has_conflict,
           bool_or(
             payment_status <> 'ไม่ใช่งานขาย'
             and (
               delivery_status = 'กำลังส่ง'
               or payment_status in ('รอชำระ','error')
               or (delivery_status = 'ตีกลับ' and not coalesce(return_arrived, false))
             )
           ) as has_pending
    from public.orders
    group by 1
  )
  select jsonb_build_object(
    'authorized', true,
    'idle_minutes', v_idle,
    'role', v_role,
    'display_name', (select coalesce(display_name, username::text) from public.app_users where id = v_uid),
    'months',          coalesce((select jsonb_agg(ym order by ym desc) from m), '[]'::jsonb),
    'months_error',    coalesce((select jsonb_agg(ym order by ym desc) from m where has_err), '[]'::jsonb),
    'months_conflict', coalesce((select jsonb_agg(ym order by ym desc) from m where has_conflict), '[]'::jsonb),
    'months_done',     coalesce((select jsonb_agg(ym order by ym desc) from m
                                 where not has_pending and not has_err and not has_conflict), '[]'::jsonb)
  ) into v_out;
  return v_out;
end $function$;
