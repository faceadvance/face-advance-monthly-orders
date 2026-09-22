-- 2026-09-22 · ไฮไลท์ข้อความในโน้ต — เก็บ "ต่อผู้ใช้" เห็นแค่คนที่ไฮไลท์เอง
--
-- เจ้านายสั่ง: "พนักงานอยากได้ฟีเจอร์ไฮไลท์ข้อความ ลักษณะเหมือนเอาปากกาไฮไลท์ไปขีดเลย"
-- และเคาะรายละเอียด:
--   · แสดงเฉพาะใน sidebar
--   · "ฉันจะทำให้ไฮไลท์นี้เห็นแค่เฉพาะ user ที่ไฮไลท์เท่านั้น มันเป็นการไฮไลท์ส่วนที่ตัวเอง
--      ต้องการไม่ใช่ทุกคนต้องการ เห็นข้ามเครื่องได้"
--   · "ตอนแก้ไขโน๊ต ล้างไฮไลท์คนอื่นไปด้วยเลยนะ เพราะมันมีการแก้ไขข้อความไม่งั้นเดี๋ยวเพี้ยน"
--
-- 🔴 เก็บเป็น "ช่วงตัวอักษร" ไม่ใช่ HTML ในตัวโน้ต
--    เพราะ order_tracking.note ถูกใช้อีก 4 ที่: คอลัมน์โน๊ตล่าสุด · หน้าค้นหา ·
--    ปุ่มคัดลอกข้อมูล · ไฟล์ export Excel — ถ้ายัด HTML ลงไปจะเลอะทุกที่

create table if not exists public.note_highlights (
  note_id    bigint not null references public.order_tracking(id) on delete cascade,
  user_id    uuid   not null references public.app_users(id)      on delete cascade,
  marks      jsonb  not null,
  updated_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

comment on table public.note_highlights is
  'ไฮไลท์ข้อความในโน้ต — [{s,e,bg,fg}] ต่อ (โน้ต, ผู้ใช้) · เห็นแค่เจ้าของ · ถูกล้างทั้งหมดเมื่อโน้ตถูกแก้';

create index if not exists note_highlights_user_idx on public.note_highlights (user_id);

-- ---------- อ่านไฮไลท์ของตัวเอง ทุกโน้ตในออเดอร์นั้น ----------
create or replace function public.app_note_marks(p_token text, p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare v_uid uuid;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  return jsonb_build_object('authorized', true, 'ok', true,
    'marks', coalesce((
      select jsonb_object_agg(h.note_id::text, h.marks)
      from public.note_highlights h
      join public.order_tracking t on t.id = h.note_id
      where h.user_id = v_uid and t.order_id = p_order_id
    ), '{}'::jsonb));
end $function$;

grant execute on function public.app_note_marks(text,bigint) to anon, authenticated, service_role;

-- ---------- บันทึก / ลบไฮไลท์ของโน้ตหนึ่ง ----------
-- p_marks = null หรือ [] → ลบทิ้ง (= ปุ่ม "ลบไฮไลท์ทั้งหมด")
create or replace function public.app_save_note_marks(p_token text, p_note_id bigint, p_marks jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare v_uid uuid; v_exists boolean;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;

  -- ต้องเป็นโน้ตที่มีอยู่จริง (กันยัด note_id เดาสุ่ม)
  select exists(select 1 from public.order_tracking where id = p_note_id and entry_type = 'note')
    into v_exists;
  if not v_exists then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'not_found'); end if;

  if p_marks is null or jsonb_typeof(p_marks) <> 'array' or jsonb_array_length(p_marks) = 0 then
    delete from public.note_highlights where note_id = p_note_id and user_id = v_uid;
    return jsonb_build_object('authorized', true, 'ok', true, 'cleared', true);
  end if;

  -- กันก้อนบวม: ไฮไลท์ปกติไม่กี่ช่วง · โน้ตยาวสุดในระบบ 651 ตัวอักษร
  if jsonb_array_length(p_marks) > 200 or length(p_marks::text) > 16384 then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'too_big');
  end if;

  insert into public.note_highlights (note_id, user_id, marks, updated_at)
  values (p_note_id, v_uid, p_marks, now())
  on conflict (note_id, user_id) do update
    set marks = excluded.marks, updated_at = now();
  return jsonb_build_object('authorized', true, 'ok', true);
end $function$;

grant execute on function public.app_save_note_marks(text,bigint,jsonb) to anon, authenticated, service_role;

-- ---------- แก้ไขโน้ต → ล้างไฮไลท์ทั้งหมดของโน้ตนั้น (ทุกคน) ----------
-- 🔴 ต้องล้างของคนอื่นด้วย ไม่ใช่แค่ของคนที่แก้ — ข้อความเปลี่ยน ตำแหน่งตัวอักษรเลื่อน
--    ไฮไลท์เดิมจะไปคร่อมผิดที่แบบเงียบๆ (เจ้านายสั่งชัด 2026-09-22)
create or replace function public.app_edit_note(p_token text, p_note_id bigint, p_note text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare v_uid uuid; v_txt text; v_oid bigint; v_cleared int;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  v_txt := nullif(btrim(coalesce(p_note,'')), '');
  if v_txt is null then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'empty'); end if;
  -- แก้ได้เฉพาะโน้ตของตัวเอง (created_by=uid) + สร้างวันนี้ (เวลาไทย)
  update public.order_tracking
     set note = v_txt
   where id = p_note_id and entry_type = 'note' and created_by = v_uid
     and (created_at at time zone 'Asia/Bangkok')::date = (now() at time zone 'Asia/Bangkok')::date
   returning order_id into v_oid;
  if v_oid is null then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'not_editable'); end if;

  delete from public.note_highlights where note_id = p_note_id;
  get diagnostics v_cleared = row_count;

  return jsonb_build_object('authorized', true, 'ok', true, 'order_id', v_oid, 'note', v_txt,
                            'highlights_cleared', v_cleared);
end $function$;

grant execute on function public.app_edit_note(text,bigint,text) to anon, authenticated, service_role;

revoke all on table public.note_highlights from anon, authenticated;
