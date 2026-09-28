-- ความเร็ว: ป้ายสถานะเดือน (get_months) + คิว EDITH หลังข้อมูลโตเป็น 281k ออเดอร์ (นำเข้าย้อนหลัง 2022–2024)
-- ปัญหา: get_months ไล่ทุกออเดอร์ทุกครั้ง (cold 7.5 วิ · warm 0.5 วิ บน NANO) · EDITH นับ error/ขัดแย้ง/ไม่มีเซล แบบไล่ทั้งตาราง
-- แก้: partial index เฉพาะแถวที่ "มีปัญหา" (แถวน้อยมาก) + get_months หาเดือนด้วย index ordered_at ทีละเดือน (loose index scan)
-- ผลลัพธ์ต้องเหมือนเดิมทุกค่า (ทดสอบเทียบเวอร์ชันเก่าใน transaction แล้ว) · เจ้านายอนุมัติ 2026-09-28
-- ⚠️ ส่วน index ใช้ CREATE INDEX CONCURRENTLY — รันนอก transaction (ไม่ล็อกการเขียนของพนักงาน)

create index concurrently if not exists orders_error_idx on public.orders (ordered_at)
  where payment_status = 'error';
create index concurrently if not exists orders_recon_conflict_idx on public.orders (ordered_at)
  where coalesce(recon_conflict, false);
create index concurrently if not exists orders_pending_idx on public.orders (ordered_at)
  where payment_status <> 'ไม่ใช่งานขาย'
    and (delivery_status = 'กำลังส่ง' or payment_status in ('รอชำระ','error')
         or (delivery_status = 'ตีกลับ' and not coalesce(return_arrived, false)));
-- ให้ตรงเงื่อนไขใน app_edith_issues เป๊ะ (index เดิม orders_noseller_idx ใช้ NOT seller_waived → planner จับคู่ไม่ได้)
create index concurrently if not exists orders_noseller_coalesce_idx on public.orders (brand_id)
  where seller_id is null and not coalesce(seller_waived, false);

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
  with recursive
  -- เดือนที่มีออเดอร์: กระโดดทีละเดือนด้วย index ordered_at (ไม่ไล่ทุกแถว) · ขอบเดือนตามเวลาไทย
  mon(ym_start) as (
    select date_trunc('month', min(ordered_at) at time zone 'Asia/Bangkok') from public.orders
    union all
    select (select date_trunc('month', min(o.ordered_at) at time zone 'Asia/Bangkok') from public.orders o
             where o.ordered_at >= ((m.ym_start + interval '1 month') at time zone 'Asia/Bangkok'))
    from mon m where m.ym_start is not null
  ),
  m as (select to_char(ym_start, 'YYYY-MM') ym from mon where ym_start is not null),
  -- ธงต่อเดือน: ดูเฉพาะแถวใน partial index (ไม่กี่ร้อยแถว)
  e as (select distinct to_char(ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM') ym from public.orders where payment_status = 'error'),
  c as (select distinct to_char(ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM') ym from public.orders where coalesce(recon_conflict, false)),
  p as (select distinct to_char(ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM') ym from public.orders
         where payment_status <> 'ไม่ใช่งานขาย'
           and (delivery_status = 'กำลังส่ง' or payment_status in ('รอชำระ','error')
                or (delivery_status = 'ตีกลับ' and not coalesce(return_arrived, false))))
  select jsonb_build_object(
    'authorized', true,
    'idle_minutes', v_idle,
    'role', v_role,
    'display_name', (select coalesce(display_name, username::text) from public.app_users where id = v_uid),
    'months',          coalesce((select jsonb_agg(ym order by ym desc) from m), '[]'::jsonb),
    'months_error',    coalesce((select jsonb_agg(ym order by ym desc) from e), '[]'::jsonb),
    'months_conflict', coalesce((select jsonb_agg(ym order by ym desc) from c), '[]'::jsonb),
    'months_done',     coalesce((select jsonb_agg(ym order by ym desc) from m
                                 where ym not in (select ym from e union select ym from c union select ym from p)), '[]'::jsonb)
  ) into v_out;
  return v_out;
end $function$;
