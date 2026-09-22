-- 2026-09-22 · จำมุมมองตาราง "ต่อผู้ใช้" แทน "ต่อเครื่อง"
--
-- เจ้านายสั่ง: "เมื่อวานอัพเดตให้ระบบจดจำตัวกรองในหน้า order ไว้ ในระบบของ local
--               อยากอัพเดตให้กลายเป็นระบบ User ที่เปิดเครื่องไหน ก็ได้ผลเหมือนกัน
--               (เอา local ออกได้เลย ถ้าจำผ่าน User แล้ว)"
--
-- โครงเดิม (2026-09-21): เก็บใน localStorage คีย์ fa_view_orders → ผูกกับเครื่อง
-- โครงใหม่: เก็บใน DB ต่อ (user, page) → ล็อกอินเครื่องไหนก็ได้มุมมองเดิม
--
-- 🔴 เก็บก้อน jsonb ทั้งก้อนเหมือนเดิม ไม่แตกเป็นคอลัมน์
--    เพราะรูปแบบข้างในยังเปลี่ยนได้ (v1 มุมมองเดียว → v2 แยกรายเดือน) ถ้าแตกคอลัมน์ต้อง migrate ทุกครั้ง
--    ฝั่งหน้าเว็บมี parseSaved() ที่ไม่เชื่อใจข้อมูลอยู่แล้ว ค่าเสียก็ไม่พัง

create table if not exists public.app_user_views (
  user_id    uuid not null references public.app_users(id) on delete cascade,
  page       text not null,
  data       jsonb not null,
  updated_at timestamptz not null default now(),
  primary key (user_id, page)
);

comment on table public.app_user_views is
  'มุมมองตารางที่ผู้ใช้ค้างไว้ (เดือน · ตัวกรอง · การเรียง · คำค้น · แถวที่ค้างไว้) — ต่อผู้ใช้ ข้ามเครื่องได้';

-- ---------- อ่าน ----------
create or replace function public.app_get_view(p_token text, p_page text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare v_uid uuid; v_data jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select data into v_data from public.app_user_views where user_id = v_uid and page = p_page;
  return jsonb_build_object('authorized', true, 'ok', true, 'data', v_data);
end $function$;

grant execute on function public.app_get_view(text,text) to anon, authenticated, service_role;

-- ---------- เขียน ----------
-- p_data เป็น null → ลบทิ้ง (เท่ากับล้างมุมมอง)
create or replace function public.app_save_view(p_token text, p_page text, p_data jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare v_uid uuid;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if p_page is null or btrim(p_page) = '' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_page');
  end if;

  if p_data is null then
    delete from public.app_user_views where user_id = v_uid and page = p_page;
    return jsonb_build_object('authorized', true, 'ok', true, 'cleared', true);
  end if;

  -- 🔴 กันก้อนใหญ่เกินเหตุ: มุมมองปกติ ~1-3 KB · ถ้าเกิน 64 KB แปลว่าผิดปกติ (ตัวกรองบวมหรือถูกยัดข้อมูล)
  --    ไม่ throw เพื่อไม่ให้หน้าเว็บพัง แค่ไม่เก็บ แล้วบอกกลับไป
  if length(p_data::text) > 65536 then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'too_big');
  end if;

  insert into public.app_user_views (user_id, page, data, updated_at)
  values (v_uid, p_page, p_data, now())
  on conflict (user_id, page) do update
    set data = excluded.data, updated_at = now();
  return jsonb_build_object('authorized', true, 'ok', true);
end $function$;

grant execute on function public.app_save_view(text,text,jsonb) to anon, authenticated, service_role;

-- ไม่เปิด RLS: ทุก RPC เป็น SECURITY DEFINER และผูก user_id จาก token เท่านั้น
-- ผู้ใช้อ่าน/เขียนของคนอื่นไม่ได้ เพราะไม่มีทางส่ง user_id เข้ามาเอง
revoke all on table public.app_user_views from anon, authenticated;
