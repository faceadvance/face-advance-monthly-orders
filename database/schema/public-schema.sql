-- Face Advance DB — โครงสร้าง schema public (ตาราง · ฟังก์ชัน/RPC · trigger · index · RLS policy · สิทธิ์)
-- ⚠️ โครงสร้างอย่างเดียว ไม่มีข้อมูลในตาราง · ไม่มีรหัสผ่าน/คีย์ (สแกนแล้วก่อน commit)
-- สร้างเมื่อ 2026-09-29 จาก DB จริง (Postgres 17) ด้วย pg_dump --schema-only --schema=public --no-owner --no-comments
-- ใช้เป็นต้นฉบับอ้างอิง/เอกสาร · migration ที่เพิ่มทีหลังอยู่ใน database/migrations/ · สร้างไฟล์นี้ใหม่: ดู database/schema/README.md

--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 17.10 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: _dedup_key(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._dedup_key(t text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $$
  select lower(regexp_replace(coalesce(t,''), '[[:space:].,/()_''"|–—-]', '', 'g'))
$$;


--
-- Name: _dedup_vals(bigint, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._dedup_vals(p_cid bigint, p_other bigint, p_kind text) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
  with raw as (
    select case p_kind
        when 'name'  then customer_name
        when 'phone' then phone
        else nullif(trim(coalesce(addr_detail,'')||' '||coalesce(subdistrict,'')||' '||coalesce(district,'')||' '||coalesce(province,'')||' '||coalesce(postal_code,'')),'')
      end as v,
      addr_detail as ad
    from public.orders where customer_id = p_cid
  ),
  vals as (
    -- ยุบค่าที่ต่างแค่ช่องว่าง/วรรคตอน (แสดงตัวแทน 1 อัน)
    select distinct on (public._dedup_key(v)) v, ad
    from raw where v is not null and v <> ''
    order by public._dedup_key(v), v
  ),
  calc as (
    select vals.v, vals.ad,
      -- ตรงเป๊ะ (ความหมายเดิมของ hit)
      case p_kind
        when 'name'  then exists(select 1 from public.orders o2 where o2.customer_id=p_other
                                 and public.norm_name(o2.customer_name) = public.norm_name(vals.v))
        when 'phone' then exists(select 1 from public.orders o2 where o2.customer_id=p_other
                                 and o2.phone = vals.v)
        else vals.ad is distinct from 'ไม่ทราบที่อยู่'   -- ข้อมูลเก่าไม่มีที่อยู่ → ไม่ใช่เกณฑ์ (เจ้านายสั่ง 2026-09-28)
             and exists(select 1 from public.orders o2 where o2.customer_id=p_other
                    and public._dedup_key(nullif(trim(concat_ws(' ', o2.addr_detail, o2.subdistrict, o2.district, o2.province, o2.postal_code)),''))
                      = public._dedup_key(vals.v))
      end as is_exact,
      -- ความคล้ายสูงสุดกับอีกฝั่ง (เทียบฟิลด์เดียวกับที่ตัวจับใช้)
      case p_kind
        when 'name'  then (select max(extensions.similarity(public.norm_name(o2.customer_name), public.norm_name(vals.v)))
                           from public.orders o2 where o2.customer_id=p_other)
        when 'phone' then null
        else (select max(extensions.similarity(coalesce(o2.addr_detail,''), coalesce(vals.ad,'')))
              from public.orders o2 where o2.customer_id=p_other
               and vals.ad is distinct from 'ไม่ทราบที่อยู่' and o2.addr_detail is distinct from 'ไม่ทราบที่อยู่')
      end as sim_raw
    from vals
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'v', v,
           'hit', is_exact,
           'sim', case when is_exact or sim_raw is null then null
                       when p_kind='name' and sim_raw >= 0.60 then round(sim_raw::numeric, 2)
                       when p_kind='addr' and sim_raw >= 0.85 then round(sim_raw::numeric, 2)
                       else null end
         ) order by v), '[]'::jsonb)
  from calc
$$;


--
-- Name: app_admin_create_user(text, text, text, text, boolean, jsonb, integer, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_admin_create_user(p_token text, p_username text, p_display_name text, p_role text, p_all_teams boolean, p_team_ids jsonb, p_idle_minutes integer, p_session_hours integer, p_line_user_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text; v_new uuid; v_pass text; v_u text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name,username::text) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  v_u := btrim(coalesce(p_username,''));
  if v_u = '' then return jsonb_build_object('authorized',true,'ok',false,'error','username_required'); end if;
  if p_role not in ('Adm','OM','Vm','RT+','RTs') then return jsonb_build_object('authorized',true,'ok',false,'error','bad_role'); end if;
  if exists(select 1 from public.app_users where username = v_u::citext) then
    return jsonb_build_object('authorized',true,'ok',false,'error','username_taken'); end if;
  v_pass := public.app_gen_password();
  insert into public.app_users(username, display_name, role, password_hash, is_active, all_teams, idle_minutes, session_hours, line_user_id)
    values (v_u::citext, nullif(btrim(coalesce(p_display_name,'')),''), p_role,
            crypt(v_pass, gen_salt('bf')), true, coalesce(p_all_teams,false),
            coalesce(p_idle_minutes,30), coalesce(p_session_hours,12),
            nullif(btrim(coalesce(p_line_user_id,'')),''))
    returning id into v_new;
  if not coalesce(p_all_teams,false) and p_team_ids is not null then
    insert into public.app_user_teams(user_id, team_id)
      select v_new, (e)::bigint from jsonb_array_elements_text(p_team_ids) e;
  end if;
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'admin_create_user', jsonb_build_object('new_user',v_new,'username',v_u,'role',p_role));
  return jsonb_build_object('authorized',true,'ok',true,'user_id',v_new,'username',v_u,'password',v_pass);
end $$;


--
-- Name: app_admin_list_users(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_admin_list_users(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_res jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if (select role from public.app_users where id=v_uid) <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  select jsonb_build_object('authorized',true,'ok',true,'me',v_uid,
    'users', coalesce((select jsonb_agg(jsonb_build_object(
        'id',u.id,'username',u.username::text,'display_name',u.display_name,'role',u.role,
        'is_active',u.is_active,'all_teams',u.all_teams,'idle_minutes',u.idle_minutes,'session_hours',u.session_hours,
        'has_line', u.line_user_id is not null, 'line_user_id', u.line_user_id,
        'created_at', u.created_at,
        'last_seen_at', (select max(s.last_seen_at) from public.auth_sessions s where s.user_id=u.id),
        'teams', coalesce((select jsonb_agg(t.name order by t.name) from public.app_user_teams ut join public.teams t on t.id=ut.team_id where ut.user_id=u.id),'[]'::jsonb)
      ) order by (u.role='Adm') desc, u.role, u.username::text) from public.app_users u),'[]'::jsonb),
    'teams', coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'is_active',is_active) order by name) from public.teams),'[]'::jsonb)
  ) into v_res;
  return v_res;
end $$;


--
-- Name: app_admin_reset_password(text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_admin_reset_password(p_token text, p_user_id uuid, p_new_password text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text; v_target text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name,username::text) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  if length(coalesce(p_new_password,'')) < 6 then return jsonb_build_object('authorized',true,'ok',false,'error','password_too_short'); end if;
  select username::text into v_target from public.app_users where id=p_user_id;
  if v_target is null then return jsonb_build_object('authorized',true,'ok',false,'error','not_found'); end if;
  update public.app_users set password_hash = crypt(p_new_password, gen_salt('bf')), updated_at=now() where id=p_user_id;
  update public.auth_sessions set expires_at=now() where user_id=p_user_id and expires_at>now();
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'admin_reset_password', jsonb_build_object('target_user',p_user_id,'target_username',v_target));
  return jsonb_build_object('authorized',true,'ok',true);
end $$;


--
-- Name: app_admin_update_user(text, uuid, text, text, boolean, jsonb, boolean, integer, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_admin_update_user(p_token text, p_user_id uuid, p_display_name text, p_role text, p_all_teams boolean, p_team_ids jsonb, p_is_active boolean, p_idle_minutes integer, p_session_hours integer, p_line_user_id text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text; v_old record; v_other_adm int;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name,username::text) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  if p_role not in ('Adm','OM','Vm','RT+','RTs') then return jsonb_build_object('authorized',true,'ok',false,'error','bad_role'); end if;
  select * into v_old from public.app_users where id=p_user_id;
  if v_old is null then return jsonb_build_object('authorized',true,'ok',false,'error','not_found'); end if;
  if v_old.role='Adm' and (p_role<>'Adm' or not coalesce(p_is_active,true)) then
    select count(*) into v_other_adm from public.app_users where role='Adm' and is_active and id<>p_user_id;
    if v_other_adm = 0 then return jsonb_build_object('authorized',true,'ok',false,'error','last_admin'); end if;
  end if;
  if p_user_id = v_uid and not coalesce(p_is_active,true) then
    return jsonb_build_object('authorized',true,'ok',false,'error','cannot_disable_self'); end if;
  update public.app_users set
    display_name = nullif(btrim(coalesce(p_display_name,'')),''),
    role = p_role,
    all_teams = coalesce(p_all_teams,false),
    is_active = coalesce(p_is_active,true),
    idle_minutes = coalesce(p_idle_minutes, idle_minutes),
    session_hours = coalesce(p_session_hours, session_hours),
    line_user_id = nullif(btrim(coalesce(p_line_user_id,'')),''),
    updated_at = now()
  where id=p_user_id;
  delete from public.app_user_teams where user_id=p_user_id;
  if not coalesce(p_all_teams,false) and p_team_ids is not null then
    insert into public.app_user_teams(user_id, team_id)
      select p_user_id, (e)::bigint from jsonb_array_elements_text(p_team_ids) e;
  end if;
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'admin_update_user', jsonb_build_object('target_user',p_user_id,'role',p_role,'is_active',coalesce(p_is_active,true)));
  return jsonb_build_object('authorized',true,'ok',true);
end $$;


--
-- Name: app_auth_login(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_auth_login(p_username text, p_password text, p_ip text, p_ua text) RETURNS TABLE(ticket_id uuid, otp text, display_name text, line_user_id text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_user public.app_users; v_otp text; v_ticket uuid; v_recent int;
begin
  select * into v_user from public.app_users where username = p_username::citext and is_active;
  if not found or v_user.password_hash <> crypt(p_password, v_user.password_hash) then
    insert into public.audit_log(user_id, username, event, ip, user_agent)
      values (v_user.id, p_username, 'login_password_fail', p_ip, p_ua);
    return;
  end if;
  -- rate limit: <=5 ticket / 10 นาที
  select count(*) into v_recent from public.auth_login_tickets
    where user_id = v_user.id and created_at > now() - interval '10 minutes';
  if v_recent >= 5 then
    insert into public.audit_log(user_id, username, event, ip, user_agent, detail)
      values (v_user.id, v_user.username, 'login_rate_limited', p_ip, p_ua, jsonb_build_object('recent', v_recent));
    return;
  end if;
  v_otp := lpad((abs(('x' || encode(gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into public.auth_login_tickets(user_id, otp_hash, otp, expires_at, ip, user_agent)
    values (v_user.id, encode(digest(v_otp, 'sha256'), 'hex'), v_otp, now() + interval '5 minutes', p_ip, p_ua)
    returning id into v_ticket;
  insert into public.audit_log(user_id, username, event, ip, user_agent)
    values (v_user.id, v_user.username, 'otp_sent', p_ip, p_ua);
  return query select v_ticket, v_otp, coalesce(v_user.display_name, v_user.username::text), v_user.line_user_id;
end $$;


--
-- Name: app_auth_logout(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_auth_logout(p_token text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid;
begin
  update public.auth_sessions set expires_at = now()
    where token_hash = encode(digest(p_token, 'sha256'), 'hex') and expires_at > now()
    returning user_id into v_uid;
  if v_uid is not null then
    insert into public.audit_log(user_id, event) values (v_uid, 'logout');
  end if;
end $$;


--
-- Name: app_auth_verify(uuid, text, text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_auth_verify(p_ticket uuid, p_code text, p_ip text, p_ua text, p_geo jsonb) RETURNS TABLE(session_token text, display_name text, role text, alert boolean, wrong_digits integer, attempt_no integer, username text)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_t public.auth_login_tickets; v_user public.app_users; v_token text; v_wrong int; v_attempt int; i int;
begin
  select * into v_t from public.auth_login_tickets where id = p_ticket for update;
  if not found or v_t.consumed or v_t.expires_at < now() then
    return;
  end if;
  select * into v_user from public.app_users where id = v_t.user_id;

  if v_t.attempts >= 5 then
    update public.auth_login_tickets set consumed = true where id = p_ticket;
    return;
  end if;

  -- รหัสถูก → สร้าง session (อายุตาม session_hours ของ user) + คืน role
  if v_t.otp_hash = encode(digest(p_code, 'sha256'), 'hex') then
    update public.auth_login_tickets set consumed = true where id = p_ticket;
    v_token := encode(gen_random_bytes(32), 'hex');
    insert into public.auth_sessions(user_id, token_hash, expires_at, ip, user_agent, geo)
      values (v_user.id, encode(digest(v_token, 'sha256'), 'hex'),
              now() + make_interval(hours => v_user.session_hours), p_ip, p_ua, p_geo);
    insert into public.audit_log(user_id, username, event, ip, user_agent, geo)
      values (v_user.id, v_user.username, 'login_ok', p_ip, p_ua, p_geo);
    return query select v_token, coalesce(v_user.display_name, v_user.username::text),
                        v_user.role, false, null::int, null::int, null::text;
    return;
  end if;

  -- รหัสผิด → นับหลักที่ต่าง (เทียบ OTP จริง) + นับครั้งที่ผิด
  v_wrong := 0;
  for i in 1..6 loop
    if coalesce(substr(coalesce(p_code,''), i, 1), '') <> substr(coalesce(v_t.otp,''), i, 1) then
      v_wrong := v_wrong + 1;
    end if;
  end loop;
  if length(coalesce(p_code,'')) > 6 then v_wrong := v_wrong + (length(p_code) - 6); end if;
  v_attempt := v_t.attempts + 1;

  update public.auth_login_tickets set attempts = v_attempt where id = p_ticket;
  insert into public.audit_log(user_id, username, event, ip, user_agent, detail)
    values (v_user.id, v_user.username, 'otp_verify_fail', p_ip, p_ua,
            jsonb_build_object('wrong_digits', v_wrong, 'attempt_no', v_attempt));

  -- แจ้งเตือนกลุ่มเมื่อ ผิด >=2 หลัก หรือ ผิด >=2 ครั้ง
  if v_wrong >= 2 or v_attempt >= 2 then
    return query select null::text, null::text, null::text, true, v_wrong, v_attempt, v_user.username::text;
  end if;
  return;
end $$;


--
-- Name: app_bulk_set_delivery(text, bigint[], text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_bulk_set_delivery(p_token text, p_ids bigint[], p_status text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_uname text; v_role text;
  v_deliv_n int := 0; v_pay_n int := 0;
  v_allowed text[] := array['กำลังส่ง','ส่งสำเร็จ','ยกเลิก'];  -- ไม่มี ตีกลับ/มีปัญหา (ต้องใส่เหตุผล)
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name, username), role into v_uname, v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','OM') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden_viewer');
  end if;
  if not (p_status = any(v_allowed)) then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_status');
  end if;
  if p_ids is null or array_length(p_ids,1) is null then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'no_ids');
  end if;

  -- log ก่อนอัปเดต (อ่านค่าเก่า) เฉพาะแถวที่เปลี่ยนจริง
  insert into public.order_tracking(order_id, entry_type, old_value, new_value, created_by, created_by_name)
    select id, 'delivery_change', delivery_status, p_status, v_uid, v_uname
    from public.orders where id = any(p_ids) and delivery_status is distinct from p_status;
  get diagnostics v_deliv_n = row_count;

  if p_status = 'ยกเลิก' then
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, created_by, created_by_name)
      select id, 'payment_change', payment_status, 'ยกเลิก', v_uid, v_uname
      from public.orders where id = any(p_ids) and payment_status is distinct from 'ยกเลิก';
    get diagnostics v_pay_n = row_count;
    update public.orders
      set delivery_status = 'ยกเลิก', payment_status = 'ยกเลิก',
          return_reason = null, status_detail = null, updated_at = now()
      where id = any(p_ids)
        and (delivery_status is distinct from 'ยกเลิก' or payment_status is distinct from 'ยกเลิก');
  else
    update public.orders
      set delivery_status = p_status, return_reason = null, status_detail = null, updated_at = now()
      where id = any(p_ids) and delivery_status is distinct from p_status;
  end if;

  insert into public.audit_log(user_id, username, event, detail)
  values (v_uid, v_uname, 'bulk_set_delivery', jsonb_build_object(
    'status', p_status, 'selected', array_length(p_ids,1),
    'delivery_changed', v_deliv_n, 'payment_changed', v_pay_n));

  return jsonb_build_object('authorized', true, 'ok', true,
    'status', p_status, 'delivery_changed', v_deliv_n, 'payment_changed', v_pay_n);
end $$;


--
-- Name: app_can_page(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_can_page(p_role text, p_page text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  select case p_role
    when 'Adm' then p_page in ('orders','record-returns','returns-list','search','edith')
    when 'OM'  then p_page in ('orders','search')
    when 'RT+' then p_page in ('record-returns','returns-list','search')
    when 'RTs' then p_page in ('returns-list','search')
    when 'Vm'  then p_page in ('orders','returns-list','search')
    else false
  end;
$$;


--
-- Name: app_check_return_photo(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_check_return_photo(p_token text, p_photo text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_role text; v_p text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','RT+') then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  v_p := btrim(coalesce(p_photo, ''));
  if v_p = '' then return jsonb_build_object('authorized', true, 'ok', true, 'exists', false); end if;
  return jsonb_build_object('authorized', true, 'ok', true,
    'exists', exists(select 1 from public.recon_returns r where btrim(r.photo_url) = v_p));
end $$;


--
-- Name: app_edit_note(text, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edit_note(p_token text, p_note_id bigint, p_note text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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
end $$;


--
-- Name: app_edith_confirm_return(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_confirm_return(p_token text, p_order_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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
end $$;


--
-- Name: app_edith_conflict_detail(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_conflict_detail(p_token text, p_conflict_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_res jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if (select role from public.app_users where id=v_uid) <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  select jsonb_build_object('authorized',true,'ok',true,
    'conflict', jsonb_build_object('id',rc.id,'tracking_out',rc.tracking_out,'created_at',rc.created_at,'status',rc.status,'submissions',rc.submissions),
    'order', to_jsonb(x)) into v_res
  from public.return_conflicts rc
  left join lateral (
    select o.id, o.order_no, o.customer_name, o.phone, o.total_sales, o.carrier,
      s.employee_code as seller_code, s.name as seller_name,
      (select string_agg(p.name||' ×'||public.qty_txt(oi.quantity), E'\n' order by oi.id)
         from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=o.id) as items
    from public.orders o left join public.sellers s on s.id=o.seller_id
    where btrim(coalesce(o.tracking_no,''))=btrim(rc.tracking_out) limit 1
  ) x on true
  where rc.id=p_conflict_id;
  return coalesce(v_res, jsonb_build_object('authorized',true,'ok',false,'error','not_found'));
end $$;


--
-- Name: app_edith_dedup_detail(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_dedup_detail(p_token text, p_review_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_res jsonb; v_new bigint; v_cand bigint;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if (select role from public.app_users where id=v_uid) <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  select new_customer_id, candidate_customer_id into v_new, v_cand
    from public.v_pending_customer_review where id=p_review_id;
  if v_new is null then return jsonb_build_object('authorized',true,'ok',false,'error','not_found'); end if;
  select jsonb_build_object('authorized',true,'ok',true,'review', jsonb_build_object(
      'id', p_review_id,
      'brand', (select b.name from public.customers c join public.brands b on b.id=c.brand_id where c.id=v_new),
      'reason',(select reason from public.v_pending_customer_review where id=p_review_id),
      'score', (select score  from public.v_pending_customer_review where id=p_review_id),
      'new_customer_id', v_new, 'candidate_customer_id', v_cand,
      'new_names',  public._dedup_vals(v_new, v_cand, 'name'),
      'new_phones', public._dedup_vals(v_new, v_cand, 'phone'),
      'new_addrs',  public._dedup_vals(v_new, v_cand, 'addr'),
      'cand_names', public._dedup_vals(v_cand, v_new, 'name'),
      'cand_phones',public._dedup_vals(v_cand, v_new, 'phone'),
      'cand_addrs', public._dedup_vals(v_cand, v_new, 'addr'),
      'new_orders',(select count(*) from public.orders where customer_id=v_new),
      'new_spent', (select coalesce(sum(total_sales),0) from public.orders where customer_id=v_new),
      'new_first', (select min(ordered_at) from public.orders where customer_id=v_new),
      'new_last',  (select max(ordered_at) from public.orders where customer_id=v_new),
      'cand_orders',(select count(*) from public.orders where customer_id=v_cand),
      'cand_spent', (select coalesce(sum(total_sales),0) from public.orders where customer_id=v_cand),
      'cand_first', (select min(ordered_at) from public.orders where customer_id=v_cand),
      'cand_last',  (select max(ordered_at) from public.orders where customer_id=v_cand)
  )) into v_res;
  return v_res;
end $$;


--
-- Name: app_edith_delete_recon(text, text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_delete_recon(p_token text, p_kind text, p_order_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text; v_tr text; v_id bigint; v_deleted jsonb; v_status text; v_deliv text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name,username) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  select btrim(coalesce(tracking_no,'')) into v_tr from public.orders where id=p_order_id;
  if v_tr is null or v_tr='' then return jsonb_build_object('authorized',true,'ok',false,'error','no_tracking'); end if;
  if p_kind='cod' then
    select id, jsonb_build_object('tracking_out',tracking_out,'amount',amount,'received_from',received_from,'note',note,'source',source)
      into v_id, v_deleted from public.recon_cod_payments where btrim(tracking_out)=v_tr order by id desc limit 1;
    if v_id is null then return jsonb_build_object('authorized',true,'ok',false,'error','not_found'); end if;
    delete from public.recon_cod_payments where id=v_id;
  elsif p_kind='return' then
    select id, jsonb_build_object('tracking_out',tracking_out,'tracking_return',tracking_return,'inspection_result',inspection_result,'damage_detail',damage_detail,'damage_items',damage_items,'photo_url',photo_url,'no_deduct',no_deduct)
      into v_id, v_deleted from public.recon_returns where btrim(tracking_out)=v_tr order by id desc limit 1;
    if v_id is null then return jsonb_build_object('authorized',true,'ok',false,'error','not_found'); end if;
    delete from public.recon_returns where id=v_id;
  else
    return jsonb_build_object('authorized',true,'ok',false,'error','bad_kind');
  end if;
  select payment_status, delivery_status into v_status, v_deliv from public.orders where id=p_order_id;
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'edith_delete_recon', jsonb_build_object('kind',p_kind,'order_id',p_order_id,'deleted',v_deleted));
  return jsonb_build_object('authorized',true,'ok',true,'kind',p_kind,'deleted',v_deleted,'payment_status',v_status,'delivery_status',v_deliv);
end $$;


--
-- Name: app_edith_dismiss_dup(text, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_dismiss_dup(p_token text, p_a bigint, p_b bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text; v_n int;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name,username) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  update public.customer_review
     set status='rejected', decided_at=now()
   where status='pending'
     and least(new_customer_id,candidate_customer_id)=least(p_a,p_b)
     and greatest(new_customer_id,candidate_customer_id)=greatest(p_a,p_b);
  get diagnostics v_n = row_count;
  if v_n=0 then return jsonb_build_object('authorized',true,'ok',false,'error','not_found'); end if;
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'edith_dismiss_dup', jsonb_build_object('a',p_a,'b',p_b));
  return jsonb_build_object('authorized',true,'ok',true);
end $$;


--
-- Name: app_edith_error_detail(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_error_detail(p_token text, p_order_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_res jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if (select role from public.app_users where id=v_uid) <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  select jsonb_build_object('authorized',true,'ok',true,'order', to_jsonb(x)) into v_res
  from (
    select o.id, o.order_no, o.tracking_no, o.customer_name, o.phone,
      o.total_sales, o.payment_method, o.payment_status, o.delivery_status,
      s.employee_code as seller_code, s.name as seller_name, t.name as team_name,
      (select string_agg(p.name||' ×'||public.qty_txt(oi.quantity), E'\n' order by oi.id)
         from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=o.id) as items,
      cod.id as cod_id, cod.amount as cod_amount,
      coalesce(cod.amount,0)-o.total_sales as delta, cod.recorded_at as cod_recorded_at
    from public.orders o
    left join public.sellers s on s.id=o.seller_id
    left join public.teams t on t.id=s.team_id
    left join lateral (select id, amount, recorded_at from public.recon_cod_payments c
                       where btrim(c.tracking_out)=btrim(coalesce(o.tracking_no,'')) order by id desc limit 1) cod on true
    where o.id=p_order_id
  ) x;
  return coalesce(v_res, jsonb_build_object('authorized',true,'ok',false,'error','not_found'));
end $$;


--
-- Name: app_edith_exchange(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_exchange(p_token text, p_order_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_uname text; v_role text; o record;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name, username), role into v_uname, v_role from public.app_users where id = v_uid;
  if v_role <> 'Adm' then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;

  select id, btrim(coalesce(tracking_no,'')) as tr, delivery_status, payment_status
    into o from public.orders where id = p_order_id;
  if not found then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'not_found'); end if;
  if o.tr = '' then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'no_tracking'); end if;

  -- ไม่แตะ no_deduct (ค่านี้ตั้งตอนบันทึกตีกลับเท่านั้น · ปุ่มนี้แค่ปรับเป็นถึงแล้ว)
  if o.delivery_status is distinct from 'ส่งสำเร็จ' then
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
      values (o.id, 'delivery_change', o.delivery_status, 'ส่งสำเร็จ', 'ปรับเป็นถึงแล้ว (EDITH)', v_uid, v_uname);
  end if;
  if o.payment_status is distinct from 'ชำระแล้ว' then
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, created_by, created_by_name)
      values (o.id, 'payment_change', o.payment_status, 'ชำระแล้ว', v_uid, v_uname);
  end if;

  update public.orders set
    delivery_status = 'ส่งสำเร็จ', payment_status = 'ชำระแล้ว',
    return_arrived = true, recon_conflict = false, updated_at = now()
  where id = o.id;

  insert into public.order_tracking(order_id, entry_type, note, created_by, created_by_name)
    values (o.id, 'note', 'ปรับเป็นถึงแล้ว จาก EDITH (เก็บเงิน + รับของคืน · ไม่ลบ COD/ตีกลับ)', v_uid, v_uname);

  insert into public.audit_log(user_id, username, event, detail)
    values (v_uid, v_uname, 'edith_exchange', jsonb_build_object('order_id', o.id, 'tracking', o.tr));

  return jsonb_build_object('authorized', true, 'ok', true);
end $$;


--
-- Name: app_edith_fix_cod_amount(text, bigint, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_fix_cod_amount(p_token text, p_order_id bigint, p_new_amount numeric) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text; v_tr text; v_cod_id bigint; v_status text; v_deliv text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name,username) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  if p_new_amount is null or p_new_amount < 0 then return jsonb_build_object('authorized',true,'ok',false,'error','bad_amount'); end if;
  select btrim(coalesce(tracking_no,'')) into v_tr from public.orders where id=p_order_id;
  if v_tr is null or v_tr='' then return jsonb_build_object('authorized',true,'ok',false,'error','no_tracking'); end if;
  select id into v_cod_id from public.recon_cod_payments where btrim(tracking_out)=v_tr order by id desc limit 1;
  if v_cod_id is null then return jsonb_build_object('authorized',true,'ok',false,'error','no_cod_record'); end if;
  update public.recon_cod_payments set amount=p_new_amount where id=v_cod_id;
  perform public.reconcile_order(p_order_id);
  select payment_status, delivery_status into v_status, v_deliv from public.orders where id=p_order_id;
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'edith_fix_cod', jsonb_build_object('order_id',p_order_id,'new_amount',p_new_amount,'result',v_status));
  return jsonb_build_object('authorized',true,'ok',true,'payment_status',v_status,'delivery_status',v_deliv);
end $$;


--
-- Name: app_edith_issues(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_issues(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $_$
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
    union all
    -- ออเดอร์ที่ไม่มีพนักงานขาย (เจ้านายสั่ง 2026-09-22)
    -- กันแบรนด์ 'ตัวแทน' ออก: 196/229 ใบเป็นเอกสาร ยอด 0 ซึ่งไม่ควรมีเซลอยู่แล้ว
    -- กัน seller_waived (ยืนยันแล้วว่าไม่มีเซล) และข้อมูลจำลองออก
    select 'noseller', o.id,
      coalesce(nullif(btrim(o.order_no),''), 'ออเดอร์ #'||o.id), 'low', o.ordered_at,
      'ไม่มีพนักงานขาย · '||b.name||' · '||to_char(o.total_sales,'FM999,999,999')||' บาท',
      jsonb_build_object('brand', b.name, 'total', o.total_sales,
        'code_in_name', (select m[1] from regexp_match(coalesce(o.customer_name,''), '([A-Za-z]{1,4}[0-9]{1,4})\s*$') m))
    from public.orders o join public.brands b on b.id = o.brand_id
    where o.seller_id is null and not coalesce(o.seller_waived,false)
      and b.name <> 'ตัวแทน'
      -- 🔴 ไม่กรองข้อมูลจำลองออกจากคิวนี้ — ต่างจาก app_sales_dashboard ที่ต้องกรอง
      --   เหตุผล: EDITH คือเครื่องมือ "แก้ข้อมูลที่มีปัญหา" ไม่ใช่รายงานการเงิน
      --   ถ้ากรองออก จะทดสอบปุ่มเติมเซล/ไม่เติมเซล กับข้อมูลจำลองไม่ได้เลย
      --   ต้องไปกดทับข้อมูลจริง ซึ่งเจ้านายห้ามไว้ (2026-09-22)
      --   เลขออเดอร์ MOCK24xx-xxxxx มองออกชัดว่าเป็นของทดสอบ ไม่ทำให้สับสน
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
    -- ต้องใช้เงื่อนไขเดียวกับ union ด้านบนเป๊ะ ไม่งั้นเลขบนชิปกับจำนวนเคสในคิวไม่ตรงกัน
    'noseller', (select count(*) from public.orders o join public.brands b on b.id=o.brand_id
                 where o.seller_id is null and not coalesce(o.seller_waived,false)
                   and b.name <> 'ตัวแทน'),
    'total',    jsonb_array_length(v_issues)
  ) into v_counts;
  return jsonb_build_object('authorized', true, 'ok', true, 'issues', v_issues, 'counts', v_counts);
end $_$;


--
-- Name: app_edith_log(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_log(p_token text, p_filter jsonb DEFAULT '{}'::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_rows jsonb; v_total int;
  v_user text; v_events text[]; v_from timestamptz; v_to timestamptz; v_q text; v_limit int; v_offset int;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if (select role from public.app_users where id=v_uid) <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;

  v_user   := nullif(p_filter->>'user','');
  v_q      := nullif(p_filter->>'q','');
  v_limit  := least(coalesce(nullif(p_filter->>'limit','')::int, 100), 500);
  v_offset := coalesce(nullif(p_filter->>'offset','')::int, 0);
  v_from   := nullif(p_filter->>'from','')::timestamptz;
  v_to     := nullif(p_filter->>'to','')::timestamptz;
  select array_agg(x) into v_events from jsonb_array_elements_text(case when jsonb_typeof(p_filter->'events')='array' then p_filter->'events' else '[]'::jsonb end) x;

  with f as (
    select a.id, a.username, a.event, a.detail, a.ip, a.geo, a.created_at
    from public.audit_log a
    where (v_user is null or a.username = v_user)
      and (v_events is null or a.event = any(v_events))
      and (v_from is null or a.created_at >= v_from)
      and (v_to is null or a.created_at < v_to)
      and (v_q is null or a.username ilike '%'||v_q||'%' or a.event ilike '%'||v_q||'%' or a.detail::text ilike '%'||v_q||'%')
  )
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'username',username,'event',event,'detail',detail,'ip',ip,'geo',geo,'at',created_at) order by created_at desc), '[]'::jsonb),
         (select count(*) from f)
    into v_rows, v_total
  from (select * from f order by created_at desc limit v_limit offset v_offset) p;

  return jsonb_build_object('authorized',true,'ok',true,'rows',v_rows,'total',v_total,
    'users', (select coalesce(jsonb_agg(distinct username order by username),'[]'::jsonb) from public.audit_log),
    'events',(select coalesce(jsonb_agg(distinct event order by event),'[]'::jsonb) from public.audit_log));
end $$;


--
-- Name: app_edith_merge_customers(text, bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_merge_customers(p_token text, p_keep bigint, p_dup bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name,username) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  begin
    perform public.merge_customers(p_keep, p_dup);
  exception when others then
    return jsonb_build_object('authorized',true,'ok',false,'error', SQLERRM);
  end;
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'edith_merge_customers', jsonb_build_object('keep',p_keep,'dup',p_dup));
  return jsonb_build_object('authorized',true,'ok',true);
end $$;


--
-- Name: app_edith_noseller_detail(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_noseller_detail(p_token text, p_order_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $_$
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
end $_$;


--
-- Name: app_edith_recon_detail(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_recon_detail(p_token text, p_order_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_res jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if (select role from public.app_users where id=v_uid) <> 'Adm' then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  select jsonb_build_object('authorized',true,'ok',true,'order', to_jsonb(x)) into v_res
  from (
    select o.id, o.order_no, o.tracking_no, o.customer_name, o.phone, o.total_sales,
      o.payment_method, o.payment_status, o.delivery_status,
      to_char(o.ordered_at at time zone 'Asia/Bangkok','DD/MM/YYYY') as ordered_date,
      (select string_agg(p.name||' ×'||public.qty_txt(oi.quantity), E'\n' order by oi.id)
         from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=o.id) as items,
      codj.cod, retj.ret
    from public.orders o
    left join lateral (select jsonb_build_object('id',id,'amount',amount,'recorded_at',recorded_at,'tracking_out',tracking_out,'received_from',received_from) cod
       from public.recon_cod_payments c where btrim(c.tracking_out)=btrim(coalesce(o.tracking_no,'')) order by id desc limit 1) codj on true
    left join lateral (select jsonb_build_object('id',id,'inspection_result',inspection_result,'recorded_at',recorded_at,'no_deduct',no_deduct,'tracking_return',tracking_return,'tracking_out',tracking_out,'damage_detail',damage_detail,'photo_url',photo_url,'damage_items',damage_items) ret
       from public.recon_returns r where btrim(r.tracking_out)=btrim(coalesce(o.tracking_no,'')) order by id desc limit 1) retj on true
    where o.id=p_order_id
  ) x;
  return coalesce(v_res, jsonb_build_object('authorized',true,'ok',false,'error','not_found'));
end $$;


--
-- Name: app_edith_resolve_conflict(text, bigint, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_resolve_conflict(p_token text, p_conflict_id bigint, p_chosen_idx integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text; rc record; v_ch jsonb; v_status text; v_deliv text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name,username) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  select * into rc from public.return_conflicts where id=p_conflict_id;
  if rc is null then return jsonb_build_object('authorized',true,'ok',false,'error','not_found'); end if;
  if rc.status <> 'pending' then return jsonb_build_object('authorized',true,'ok',false,'error','already_resolved'); end if;
  if p_chosen_idx < 0 or p_chosen_idx >= jsonb_array_length(rc.submissions) then
    return jsonb_build_object('authorized',true,'ok',false,'error','bad_choice'); end if;
  v_ch := rc.submissions -> p_chosen_idx;
  begin
    insert into public.recon_returns(tracking_out, tracking_return, inspection_result, damage_detail, damage_items, photo_url, no_deduct, created_by)
    values (rc.tracking_out, v_ch->>'tracking_return', v_ch->>'inspection_result', v_ch->>'damage_detail',
            case when jsonb_typeof(v_ch->'damage_items')='array' then v_ch->'damage_items' else null end,
            v_ch->>'photo_url', coalesce((v_ch->>'no_deduct')::boolean,false), v_uid);
  exception when unique_violation then
    return jsonb_build_object('authorized',true,'ok',false,'error','recon_exists');
  end;
  update public.return_conflicts set status='resolved', resolution=p_chosen_idx::text, resolved_by=v_uid, resolved_at=now() where id=p_conflict_id;
  select payment_status, delivery_status into v_status, v_deliv
    from public.orders where btrim(coalesce(tracking_no,''))=btrim(rc.tracking_out) order by id limit 1;
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'edith_resolve_conflict', jsonb_build_object('conflict_id',p_conflict_id,'chosen',p_chosen_idx,'by',v_ch->>'by'));
  return jsonb_build_object('authorized',true,'ok',true,'payment_status',v_status,'delivery_status',v_deliv);
end $$;


--
-- Name: app_edith_resolve_error(text, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_resolve_error(p_token text, p_order_id bigint, p_use text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text; v_tr text; v_cod_id bigint; v_cod numeric; v_total integer; v_status text; v_deliv text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized',false); end if;
  select coalesce(display_name,username) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  if p_use not in ('order','received') then return jsonb_build_object('authorized',true,'ok',false,'error','bad_use'); end if;
  select btrim(coalesce(tracking_no,'')), total_sales into v_tr, v_total from public.orders where id=p_order_id;
  if v_tr is null or v_tr='' then return jsonb_build_object('authorized',true,'ok',false,'error','no_tracking'); end if;
  select id, amount into v_cod_id, v_cod from public.recon_cod_payments where btrim(tracking_out)=v_tr order by id desc limit 1;
  if v_cod_id is null then return jsonb_build_object('authorized',true,'ok',false,'error','no_cod_record'); end if;
  if p_use='order' then
    update public.recon_cod_payments set amount = v_total where id = v_cod_id;
  else
    update public.orders set total_sales = round(v_cod)::int where id = p_order_id;
  end if;
  perform public.reconcile_order(p_order_id);
  select payment_status, delivery_status into v_status, v_deliv from public.orders where id=p_order_id;
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'edith_fix_cod', jsonb_build_object('order_id',p_order_id,'use',p_use,'order_total',v_total,'received',v_cod,'result',v_status));
  return jsonb_build_object('authorized',true,'ok',true,'payment_status',v_status,'delivery_status',v_deliv);
end $$;


--
-- Name: app_edith_restore_recon(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_restore_recon(p_token text, p_kind text, p_payload jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select coalesce(display_name,username) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  if p_kind='cod' then
    insert into public.recon_cod_payments(tracking_out, amount, received_from, note, source, created_by)
    values (p_payload->>'tracking_out', nullif(p_payload->>'amount','')::numeric, p_payload->>'received_from', p_payload->>'note', p_payload->>'source', v_uid);
  elsif p_kind='return' then
    insert into public.recon_returns(tracking_out, tracking_return, inspection_result, damage_detail, damage_items, photo_url, no_deduct, created_by)
    values (p_payload->>'tracking_out', p_payload->>'tracking_return', p_payload->>'inspection_result', p_payload->>'damage_detail',
            case when jsonb_typeof(p_payload->'damage_items')='array' then p_payload->'damage_items' else null end,
            p_payload->>'photo_url', coalesce((p_payload->>'no_deduct')::boolean,false), v_uid);
  else
    return jsonb_build_object('authorized',true,'ok',false,'error','bad_kind');
  end if;
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'edith_restore_recon', jsonb_build_object('kind',p_kind,'tracking',p_payload->>'tracking_out'));
  return jsonb_build_object('authorized',true,'ok',true);
end $$;


--
-- Name: app_edith_sellers(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_sellers(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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
end $$;


--
-- Name: app_edith_set_payment_status(text, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_set_payment_status(p_token text, p_order_id bigint, p_status text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_uname text; v_old text; v_deliv text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized',false); end if;
  select coalesce(display_name,username) into v_uname from public.app_users where id=v_uid and role='Adm';
  if v_uname is null then return jsonb_build_object('authorized',true,'ok',false,'error','forbidden'); end if;
  if p_status not in ('รอชำระ','ชำระแล้ว','ไม่ใช่งานขาย','ยกเลิก') then return jsonb_build_object('authorized',true,'ok',false,'error','bad_status'); end if;
  select payment_status, delivery_status into v_old, v_deliv from public.orders where id=p_order_id;
  if v_old is null then return jsonb_build_object('authorized',true,'ok',false,'error','not_found'); end if;
  update public.orders set payment_status = p_status where id = p_order_id;
  insert into public.audit_log(user_id,username,event,detail)
    values (v_uid,v_uname,'edith_set_payment_status', jsonb_build_object('order_id',p_order_id,'from',v_old,'to',p_status));
  return jsonb_build_object('authorized',true,'ok',true,'payment_status',p_status,'delivery_status',v_deliv);
end $$;


--
-- Name: app_edith_set_seller(text, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_edith_set_seller(p_token text, p_order_id bigint, p_seller_code text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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
end $$;


--
-- Name: app_gen_password(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_gen_password() RETURNS text
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_alpha text := 'abcdefghjkmnpqrstuvwxyz23456789ABCDEFGHJKLMNPQRSTUVWXYZ'; v_b bytea := gen_random_bytes(12); v_p text := ''; i int;
begin
  for i in 0..11 loop v_p := v_p || substr(v_alpha, 1 + (get_byte(v_b,i) % length(v_alpha)), 1); end loop;
  return v_p;
end $$;


--
-- Name: app_get_detail_presets(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_get_detail_presets(p_token text, p_kind text DEFAULT 'problem'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_presets jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'label', label, 'use_count', use_count)
           order by sort_order, id), '[]'::jsonb)
    into v_presets
    from public.tracking_detail_presets where kind = p_kind;

  return jsonb_build_object('authorized', true, 'ok', true, 'presets', v_presets);
end $$;


--
-- Name: app_get_order_tracking(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_get_order_tracking(p_token text, p_order_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_timeline jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', t.id, 'type', t.entry_type, 'note', t.note, 'old', t.old_value,
    'new', t.new_value, 'detail', t.detail, 'by', coalesce((select coalesce(au.display_name, au.username::text) from public.app_users au where au.id = t.created_by), t.created_by_name, ''),
    'mine', (t.created_by = v_uid),
    'at', to_char(t.created_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI:SS')
  ) order by t.created_at desc, t.id desc), '[]'::jsonb) into v_timeline
  from public.order_tracking t where t.order_id = p_order_id;

  return jsonb_build_object('authorized', true, 'timeline', v_timeline);
end $$;


--
-- Name: app_get_view(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_get_view(p_token text, p_page text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_data jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select data into v_data from public.app_user_views where user_id = v_uid and page = p_page;
  return jsonb_build_object('authorized', true, 'ok', true, 'data', v_data);
end $$;


--
-- Name: app_import_cod_payments(text, jsonb, text, jsonb, text, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_import_cod_payments(p_token text, p_rows jsonb, p_mode text, p_fix_trackings jsonb DEFAULT '[]'::jsonb, p_source text DEFAULT NULL::text, p_confirm_partial boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_uname text; v_role text;
  v_problems jsonb; v_mismatches jsonb; v_partials jsonb; v_partial int := 0;
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

  -- บางส่วน: เงินเคลม (ทำเคลม) น้อยกว่ายอดขาย และไม่ได้เลือกแก้ยอด → ต้องยืนยันก่อน (ไม่ยืนยัน = ไม่บันทึกทั้งไฟล์)
  select coalesce(jsonb_agg(jsonb_build_object(
           'tracking', e.tracking_out, 'order_no', e.order_no, 'order_id', e.order_id,
           'order_amount', e.order_amount, 'received_amount', e.amount) order by e.k), '[]'::jsonb)
    into v_partials
  from _cod_eval e
  where e.received_from = 'ทำเคลม' and e.same_tr = 1 and not e.in_cod_db
    and e.order_id is not null and e.payment_method = 'เก็บเงินปลายทาง'
    and e.amount is not null and e.amount > 0 and round(e.amount) < e.order_amount::numeric
    and e.tracking_out not in (select btrim(x) from jsonb_array_elements_text(coalesce(p_fix_trackings,'[]'::jsonb)) x);

  select count(*) into v_rows_total from _cod;
  v_ok := (jsonb_array_length(v_problems) = 0);
  v_rows_ok := case when v_ok then v_rows_total else 0 end;

  if p_mode = 'confirm' and v_ok then
    if p_source is null or btrim(p_source) = '' then
      return jsonb_build_object('authorized', true, 'ok', false, 'error', 'no_evidence');
    end if;
    if jsonb_array_length(v_partials) > 0 and not coalesce(p_confirm_partial, false) then
      return jsonb_build_object('authorized', true, 'mode', p_mode, 'ok', false, 'error', 'partial_unconfirmed',
        'partials', v_partials, 'problems', v_problems, 'mismatches', v_mismatches);
    end if;

    -- แก้ยอดออเดอร์ตามที่เลือก (round → total_sales int)
    update public.orders o
       set total_sales = round(e.amount)::int, updated_at = now()
      from _cod_eval e
     where o.id = e.order_id and e.amount is not null
       and e.tracking_out in (select btrim(x) from jsonb_array_elements_text(coalesce(p_fix_trackings,'[]'::jsonb)) x)
       and round(e.amount) is distinct from e.order_amount::numeric;
    get diagnostics v_fixed = row_count;

    -- บางส่วน (ยืนยันแล้ว): ตั้ง บางส่วน · มีปัญหา · ยอดที่รับจริง ก่อน reconcile
    create temp table _partial on commit drop as
      select (x->>'order_id')::bigint as order_id, (x->>'received_amount')::numeric as amount from jsonb_array_elements(v_partials) x;
    with p as (
      select o.id, o.payment_status as old_pay, o.delivery_status as old_del, pt.amount, o.total_sales
      from _partial pt join public.orders o on o.id = pt.order_id),
    u as (
      update public.orders o set payment_status='บางส่วน', paid_amount=p.amount, delivery_status='มีปัญหา',
             status_detail='รับเงินเคลมแล้ว ไม่เต็มจำนวน', updated_at=now()
      from p where o.id=p.id returning o.id, p.old_pay, p.old_del, p.amount, p.total_sales),
    t1 as (
      insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
      select id, 'payment_change', old_pay, 'บางส่วน',
             'รับจริง ฿'||to_char(amount,'FM999,999,990.##')||' จาก ฿'||to_char(total_sales,'FM999,999,990')||' (เงินเคลม · ยืนยันตอนนำเข้า)', v_uid, v_uname
      from u where old_pay is distinct from 'บางส่วน' returning 1)
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
    select id, 'delivery_change', old_del, 'มีปัญหา', 'รับเงินเคลมแล้ว ไม่เต็มจำนวน', v_uid, v_uname
    from u where old_del is distinct from 'มีปัญหา';
    get diagnostics v_partial = row_count;
    select count(*) into v_partial from _partial;

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
        case when round(e.amount) = o.total_sales then 'ชำระแล้ว'
             when e.order_id in (select order_id from _partial) then 'บางส่วน'
             else 'error' end as new_pay
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
    'inserted', v_inserted, 'fixed', v_fixed, 'paid', v_paid, 'err', v_err,
    'partials', v_partials, 'partial', v_partial
  );
end $$;


--
-- Name: app_import_history(text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_import_history(p_token text, p_kind text DEFAULT 'orders'::text, p_limit integer DEFAULT 50) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_role text; v_rows jsonb;
  v_kind text := case when p_kind = 'cod' then 'cod' else 'orders' end;
  v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200);
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','OM') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden_viewer');
  end if;

  if v_kind = 'orders' then
    select coalesce(jsonb_agg(to_jsonb(q) order by q.sort_id desc), '[]'::jsonb) into v_rows
    from (
      select a.id as sort_id,
             to_char(a.created_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD') as at,
             (select min(d) from jsonb_array_elements_text(a.detail->'dates') d) as date_from,
             (select max(d) from jsonb_array_elements_text(a.detail->'dates') d) as date_to,
             coalesce((a.detail->>'orders')::int, 0) as orders,
             coalesce(u.display_name, a.username, '—') as by_name
      from public.audit_log a
      left join public.app_users u on u.id = a.user_id
      where a.event = 'import_orders'
      order by a.id desc
      limit v_lim
    ) q;
  else
    select coalesce(jsonb_agg(to_jsonb(q) order by q.sort_id desc), '[]'::jsonb) into v_rows
    from (
      select a.id as sort_id,
             to_char(a.created_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD') as at,
             case when coalesce(a.detail->>'source','') = 'manual' then 'แก้มือ' else 'ไฟล์' end as src,
             coalesce((a.detail->>'paid')::int, 0) as items,
             coalesce(u.display_name, a.username, '—') as by_name
      from public.audit_log a
      left join public.app_users u on u.id = a.user_id
      where a.event = 'import_cod'
      order by a.id desc
      limit v_lim
    ) q;
  end if;

  return jsonb_build_object('authorized', true, 'ok', true, 'kind', v_kind, 'rows', v_rows);
end $$;


--
-- Name: app_import_orders(text, jsonb, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_import_orders(p_token text, p_rows jsonb, p_mode text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_uname text; v_role text;
  v_dupdates text; v_problems jsonb; v_warnings jsonb;
  v_ok boolean; v_error text;
  v_orders_total int; v_orders_ok int; v_items_total int; v_total_sales bigint;
  v_dates jsonb; v_new_cust int;
  v_inserted int := 0; v_new_cust_ins int := 0;
  v_flagged int := 0;
  orow record; irow record;
  v_cust bigint; v_order bigint; v_brand bigint; v_seller bigint; v_prod bigint;
  v_agent bigint;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','OM') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden_viewer');
  end if;
  if p_mode not in ('preflight','confirm') then
    return jsonb_build_object('authorized', true, 'error', 'bad_mode');
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'ไม่มีข้อมูลในไฟล์');
  end if;

  select id into v_agent from public.brands where name = 'ตัวแทน';

  create temp table _imp_ord on commit drop as
  select (row_number() over ())::int as k,
         nullif(r->>'order_no','')                       as order_no,
         (r->>'ordered_at')::timestamptz                 as ordered_at,
         r->>'customer_name'                             as customer_name,
         r->>'phone'                                     as phone,
         r->>'addr_detail'                               as addr_detail,
         r->>'subdistrict'                               as subdistrict,
         r->>'district'                                  as district,
         r->>'province'                                  as province,
         r->>'postal_code'                               as postal_code,
         r->>'seller_code'                               as seller_code,
         r->>'carrier'                                   as carrier,
         r->>'tracking_no'                               as tracking_no,
         coalesce((r->>'total_sales')::int, 0)           as total_sales,
         r->>'payment_method'                            as payment_method,
         coalesce(r->>'payment_status','รอชำระ')          as payment_status,
         coalesce(r->>'delivery_status','กำลังส่ง')          as delivery_status,
         r->>'note'                                      as note,
         r->'items'                                      as items
  from jsonb_array_elements(p_rows) r;

  create temp table _imp_it on commit drop as
  select o.k,
         it->>'product_name'               as product_name,
         coalesce((it->>'quantity')::int,0) as quantity
  from _imp_ord o
  cross join lateral jsonb_array_elements(coalesce(o.items,'[]'::jsonb)) it
  where coalesce((it->>'quantity')::int,0) > 0;

  create temp table _imp_brand on commit drop as
  with pb as (
    select si.k, b.id as brand_id, (b.id = v_agent) as is_agent
    from _imp_it si
    join public.products p on p.name = si.product_name
    join public.categories c on c.id = p.category_id
    join public.brands b on b.id = c.brand_id
  )
  select o.k,
         case when bool_or(coalesce(pb.is_agent,false)) then 1
              else count(distinct pb.brand_id) end as nbrand,
         case when bool_or(coalesce(pb.is_agent,false)) then v_agent
              else min(pb.brand_id) end            as brand_id
  from _imp_ord o
  left join pb on pb.k = o.k
  group by o.k;

  select string_agg(x.d::text, ', ' order by x.d) into v_dupdates
  from (select distinct (ordered_at at time zone 'Asia/Bangkok')::date d from _imp_ord) x
  where exists (
    select 1 from public.orders ord
    where ord.ordered_at >= (x.d::timestamp at time zone 'Asia/Bangkok')
      and ord.ordered_at <  ((x.d + 1)::timestamp at time zone 'Asia/Bangkok')
  );

  select coalesce(jsonb_agg(jsonb_build_object(
           'order_no', coalesce(o.order_no, 'k'||o.k),
           'reason', case when br.nbrand = 0 then 'สินค้าไม่ตรงกับระบบ'
                          else 'ปนแบรนด์ ('||br.nbrand||' แบรนด์)' end)
         order by o.k), '[]'::jsonb)
    into v_problems
  from _imp_ord o join _imp_brand br on br.k = o.k
  where br.nbrand is null or br.nbrand = 0 or br.nbrand > 1;

  select coalesce(jsonb_agg(distinct si.product_name), '[]'::jsonb) into v_warnings
  from _imp_it si
  left join public.products p on p.name = si.product_name
  where p.id is null;

  select count(*) into v_orders_total from _imp_ord;
  select count(*) into v_orders_ok from _imp_ord o join _imp_brand br on br.k=o.k
    where br.nbrand = 1;
  select count(*) into v_items_total from _imp_it;
  select coalesce(sum(total_sales),0) into v_total_sales from _imp_ord;
  select coalesce(jsonb_agg(d order by d), '[]'::jsonb) into v_dates
    from (select distinct (ordered_at at time zone 'Asia/Bangkok')::date::text d from _imp_ord) x;
  select count(*) into v_new_cust from (
    select distinct br.brand_id, o.phone
    from _imp_ord o join _imp_brand br on br.k=o.k
    where br.nbrand = 1 and o.phone is not null
  ) x
  where not exists (select 1 from public.customer_phones cp
                    where cp.brand_id = x.brand_id and cp.phone = x.phone);

  v_error := case when v_dupdates is not null
                  then 'วันที่ซ้ำกับที่นำเข้าแล้ว: '||v_dupdates||' — ยกเลิกทั้งไฟล์'
                  else null end;
  v_ok := (v_error is null) and (jsonb_array_length(v_problems) = 0);

  if p_mode = 'confirm' and v_ok then
    for orow in select * from _imp_ord order by k loop
      select br.brand_id into v_brand from _imp_brand br where br.k = orow.k;

      v_seller := null;
      if orow.seller_code is not null then
        select id into v_seller from public.sellers
         where employee_code = orow.seller_code order by is_active desc, id limit 1;
      end if;

      select cp.customer_id into v_cust from public.customer_phones cp
       where cp.brand_id = v_brand and cp.phone = orow.phone;
      if v_cust is null then
        insert into public.customers(brand_id) values (v_brand) returning id into v_cust;
        insert into public.customer_phones(customer_id, brand_id, phone)
          values (v_cust, v_brand, orow.phone);
        v_new_cust_ins := v_new_cust_ins + 1;
      end if;

      insert into public.orders(
        brand_id, customer_id, order_no, ordered_at, customer_name, phone,
        addr_detail, subdistrict, district, province, postal_code, seller_id,
        total_sales, payment_method, carrier, tracking_no, payment_status, delivery_status, note)
      values(
        v_brand, v_cust, orow.order_no, orow.ordered_at,
        coalesce(orow.customer_name, orow.phone), orow.phone,
        orow.addr_detail, orow.subdistrict, orow.district, orow.province, orow.postal_code, v_seller,
        orow.total_sales, orow.payment_method, orow.carrier, orow.tracking_no, orow.payment_status, orow.delivery_status, orow.note)
      returning id into v_order;
      v_inserted := v_inserted + 1;

      for irow in select * from _imp_it where k = orow.k loop
        select id into v_prod from public.products where name = irow.product_name limit 1;
        if v_prod is not null then
          insert into public.order_items(order_id, product_id, quantity)
            values (v_order, v_prod, irow.quantity) on conflict (order_id, product_id) do update set quantity = order_items.quantity + excluded.quantity;
        end if;
      end loop;
    end loop;

    v_flagged := public.detect_customer_duplicates(now());

    select username into v_uname from public.app_users where id = v_uid;
    insert into public.audit_log(user_id, username, event, detail)
      values (v_uid, v_uname, 'import_orders',
              jsonb_build_object('orders', v_inserted, 'items', v_items_total,
                                 'new_customers', v_new_cust_ins, 'dates', v_dates,
                                 'flagged_dupes', v_flagged));
  end if;

  return jsonb_build_object(
    'authorized', true, 'mode', p_mode, 'ok', v_ok, 'error', v_error,
    'problems', v_problems, 'warnings', v_warnings,
    'orders_total', v_orders_total, 'orders_ok', v_orders_ok,
    'items_total', v_items_total, 'total_sales', v_total_sales, 'dates', v_dates,
    'new_customers', case when p_mode='confirm' and v_ok then v_new_cust_ins else v_new_cust end,
    'inserted', case when p_mode='confirm' and v_ok then v_inserted else 0 end,
    'flagged_dupes', case when p_mode='confirm' and v_ok then v_flagged else 0 end
  );
end $$;


--
-- Name: app_lookup_return_tracking(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_lookup_return_tracking(p_token text, p_tracking text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_role text; v_tr text; v_o record; v_items text; v_list jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','RT+') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;

  v_tr := btrim(coalesce(p_tracking, ''));
  if v_tr = '' then return jsonb_build_object('authorized', true, 'ok', false, 'error', 'empty'); end if;

  if exists (select 1 from public.recon_returns r where btrim(r.tracking_out) = v_tr) then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'already_recorded');
  end if;

  select o.id, o.order_no, o.customer_name, o.phone, o.total_sales, o.carrier,
         o.delivery_status, o.payment_status, o.payment_method,
         to_char(o.ordered_at at time zone 'Asia/Bangkok', 'DD/MM/YYYY') as ordered_date,
         s.employee_code as seller_code, s.name as seller_name
    into v_o
    from public.orders o
    left join public.sellers s on s.id = o.seller_id
   where btrim(coalesce(o.tracking_no, '')) = v_tr
   order by o.id limit 1;

  if not found then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'order_not_found');
  end if;

  select string_agg(p.name || ' ×' || public.qty_txt(oi.quantity), ', ' order by oi.id),
         coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'qty', oi.quantity) order by oi.id), '[]'::jsonb)
    into v_items, v_list
    from public.order_items oi join public.products p on p.id = oi.product_id
   where oi.order_id = v_o.id;

  return jsonb_build_object(
    'authorized', true, 'ok', true,
    'order', jsonb_build_object(
      'id', v_o.id, 'order_no', v_o.order_no, 'customer_name', v_o.customer_name,
      'phone', v_o.phone, 'total_sales', v_o.total_sales,
      'items', coalesce(v_items, ''), 'items_list', coalesce(v_list, '[]'::jsonb),
      'carrier', v_o.carrier, 'delivery_status', v_o.delivery_status,
      'payment_status', v_o.payment_status, 'payment_method', v_o.payment_method,
      'ordered_date', v_o.ordered_date,
      'seller_code', v_o.seller_code, 'seller_name', v_o.seller_name
    ));
end $$;


--
-- Name: app_note_marks(text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_note_marks(p_token text, p_order_id bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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
end $$;


--
-- Name: app_notifications(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_notifications(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_role text; v_items jsonb;
  v_see_orders boolean; v_see_returns boolean;
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
      and a.event = 'import_cod'
      and coalesce(a.detail->>'source', '') <> 'manual'
      and coalesce((a.detail->>'paid')::int, 0) > 0
    order by at desc
    limit 50
  ) x;

  return jsonb_build_object('authorized', true, 'ok', true, 'items', v_items);
end $$;


--
-- Name: app_returns_list(text, text, text, bigint, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_returns_list(p_token text, p_cycle text DEFAULT NULL::text, p_mode text DEFAULT 'deduct'::text, p_team_id bigint DEFAULT NULL::bigint, p_seller_code text DEFAULT NULL::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_role text; v_all_teams boolean; v_all boolean;
  v_teams bigint[];
  v_mode text := case when p_mode = 'status' then 'status' else 'deduct' end;
  v_cycle date; v_start date; v_end date; v_today date;
  v_pcycle date; v_pstart date; v_pend date; v_porders int; v_psales bigint;
  v_rows jsonb; v_cycles jsonb; v_teamlist jsonb; v_sellerlist jsonb; v_sellers_ret jsonb;
  v_orders int; v_sales bigint;
  v_months text[] := array['มกราคม','กุมภาพันธ์','มีนาคม','เมษายน','พฤษภาคม','มิถุนายน',
                           'กรกฎาคม','สิงหาคม','กันยายน','ตุลาคม','พฤศจิกายน','ธันวาคม'];
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role, all_teams into v_role, v_all_teams from public.app_users where id = v_uid;
  if v_role not in ('Adm','RT+','RTs','Vm') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;

  v_all := (v_role in ('Adm','Vm','RT+') or coalesce(v_all_teams, false));
  if not v_all then
    select coalesce(array_agg(team_id), '{}') into v_teams
      from public.app_user_teams where user_id = v_uid;
  end if;

  v_today := (now() at time zone 'Asia/Bangkok')::date;

  if v_mode = 'deduct' then
    if p_cycle is not null and p_cycle <> '' then
      v_cycle := to_date(p_cycle || '-01', 'YYYY-MM-DD');
    else
      v_cycle := case when extract(day from v_today) >= 26
                      then (date_trunc('month', v_today) + interval '1 month')::date
                      else date_trunc('month', v_today)::date end;
    end if;
    v_start := (v_cycle - interval '1 month' + interval '25 days')::date;
    v_end   := (v_cycle + interval '24 days')::date;
    v_pcycle := (v_cycle - interval '1 month')::date;
    v_pstart := (v_pcycle - interval '1 month' + interval '25 days')::date;
    v_pend   := (v_pcycle + interval '24 days')::date;
    select coalesce(jsonb_agg(jsonb_build_object(
             'value', to_char(cyc, 'YYYY-MM'),
             'label', v_months[extract(month from cyc)::int] || ' ' || extract(year from cyc)::text,
             'range', to_char(cyc - interval '1 month' + interval '25 days', 'DD/MM') || ' – ' || to_char(cyc + interval '24 days', 'DD/MM/YYYY')
           ) order by cyc desc), '[]'::jsonb)
      into v_cycles
      from (select distinct case when extract(day from dt) >= 26
                                 then (date_trunc('month', dt) + interval '1 month')::date
                                 else date_trunc('month', dt)::date end cyc
            from (select (recorded_at at time zone 'Asia/Bangkok')::date dt from public.recon_returns where not no_deduct) d) cc;
  else
    if p_cycle is not null and p_cycle <> '' then
      v_cycle := to_date(p_cycle || '-01', 'YYYY-MM-DD');
    else
      v_cycle := date_trunc('month', v_today)::date;
    end if;
    v_start := v_cycle;
    v_end   := (v_cycle + interval '1 month' - interval '1 day')::date;
    v_pcycle := (v_cycle - interval '1 month')::date;
    v_pstart := v_pcycle;
    v_pend   := (v_pcycle + interval '1 month' - interval '1 day')::date;
    select coalesce(jsonb_agg(jsonb_build_object(
             'value', to_char(cyc, 'YYYY-MM'),
             'label', v_months[extract(month from cyc)::int] || ' ' || extract(year from cyc)::text,
             'range', to_char(cyc, 'DD/MM') || ' – ' || to_char(cyc + interval '1 month' - interval '1 day', 'DD/MM/YYYY')
           ) order by cyc desc), '[]'::jsonb)
      into v_cycles
      from (select distinct date_trunc('month', (ordered_at at time zone 'Asia/Bangkok')::date)::date cyc
            from public.orders where delivery_status = 'ตีกลับ') cc;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name), '[]'::jsonb)
    into v_teamlist
    from public.teams where (v_all or id = any(v_teams));
  if v_all and exists (select 1 from public.sellers where team_id is null) then
    v_teamlist := v_teamlist || jsonb_build_array(jsonb_build_object('id', -1, 'name', '(ไม่มีทีม)'));
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('code', employee_code, 'name', name, 'team_id', team_id) order by employee_code), '[]'::jsonb)
    into v_sellerlist
    from public.sellers
   where (v_all or team_id = any(v_teams));

  -- รายชื่อ (employee_code) ของพนักงานที่ "มีตีกลับ" ในรอบ/ทีมที่เลือก (ไม่สน filter พนักงาน) → ใช้มาร์คจุดเขียว
  if v_mode = 'deduct' then
    select coalesce(jsonb_agg(distinct s.employee_code) filter (where s.employee_code is not null), '[]'::jsonb)
      into v_sellers_ret
      from public.recon_returns r
      join public.orders o  on o.tracking_no = r.tracking_out
      join public.sellers s on s.id = o.seller_id
     where not r.no_deduct
       and (r.recorded_at at time zone 'Asia/Bangkok')::date between v_start and v_end
       and (v_all or s.team_id = any(v_teams))
       and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id);
  else
    select coalesce(jsonb_agg(distinct s.employee_code) filter (where s.employee_code is not null), '[]'::jsonb)
      into v_sellers_ret
      from public.orders o
      join public.sellers s on s.id = o.seller_id
     where o.delivery_status = 'ตีกลับ'
       and (o.ordered_at at time zone 'Asia/Bangkok')::date between v_start and v_end
       and (v_all or s.team_id = any(v_teams))
       and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id);
  end if;

  if v_mode = 'deduct' then
    select coalesce(jsonb_agg(to_jsonb(q) order by q.return_date desc nulls last, q.ordered_at desc), '[]'::jsonb) into v_rows
    from (
      select r.id,
             (o.ordered_at   at time zone 'Asia/Bangkok')::date as ordered_at,
             (r.recorded_at  at time zone 'Asia/Bangkok')::date as return_date,
             o.order_no, o.customer_name, o.phone,
             nullif(concat_ws(' ', o.addr_detail, o.subdistrict, o.district, o.province, o.postal_code), '') as address,
             s.employee_code as seller_code, s.name as seller_name, t.name as team_name,
             o.carrier, o.total_sales, o.payment_method, o.payment_status, o.delivery_status, o.return_arrived,
             (select string_agg(p.name || ' ×' || public.qty_txt(oi.quantity), E'\n' order by oi.id)
                from public.order_items oi join public.products p on p.id = oi.product_id
               where oi.order_id = o.id) as items,
             r.inspection_result, r.tracking_return, r.tracking_out,
             r.no_deduct, true as has_recon
      from public.recon_returns r
      join public.orders o  on o.tracking_no = r.tracking_out
      join public.sellers s on s.id = o.seller_id
      left join public.teams t on t.id = s.team_id
      where not r.no_deduct
        and (r.recorded_at at time zone 'Asia/Bangkok')::date between v_start and v_end
        and (v_all or s.team_id = any(v_teams))
        and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id)
        and (p_seller_code is null or s.employee_code = p_seller_code)
    ) q;
    select count(*), coalesce(sum(o.total_sales), 0) into v_porders, v_psales
      from public.recon_returns r
      join public.orders o  on o.tracking_no = r.tracking_out
      join public.sellers s on s.id = o.seller_id
      where not r.no_deduct
        and (r.recorded_at at time zone 'Asia/Bangkok')::date between v_pstart and v_pend
        and (v_all or s.team_id = any(v_teams))
        and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id)
        and (p_seller_code is null or s.employee_code = p_seller_code);
  else
    select coalesce(jsonb_agg(to_jsonb(q) order by q.ordered_at desc), '[]'::jsonb) into v_rows
    from (
      select o.id,
             (o.ordered_at  at time zone 'Asia/Bangkok')::date as ordered_at,
             (r.recorded_at at time zone 'Asia/Bangkok')::date as return_date,
             o.order_no, o.customer_name, o.phone,
             nullif(concat_ws(' ', o.addr_detail, o.subdistrict, o.district, o.province, o.postal_code), '') as address,
             s.employee_code as seller_code, s.name as seller_name, t.name as team_name,
             o.carrier, o.total_sales, o.payment_method, o.payment_status, o.delivery_status, o.return_arrived,
             (select string_agg(p.name || ' ×' || public.qty_txt(oi.quantity), E'\n' order by oi.id)
                from public.order_items oi join public.products p on p.id = oi.product_id
               where oi.order_id = o.id) as items,
             r.inspection_result, r.tracking_return, o.tracking_no as tracking_out,
             coalesce(r.no_deduct, false) as no_deduct, (r.id is not null) as has_recon
      from public.orders o
      left join public.recon_returns r on r.tracking_out = o.tracking_no
      left join public.sellers s on s.id = o.seller_id
      left join public.teams t on t.id = s.team_id
      where o.delivery_status = 'ตีกลับ'
        and (o.ordered_at at time zone 'Asia/Bangkok')::date between v_start and v_end
        and (v_all or s.team_id = any(v_teams))
        and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id)
        and (p_seller_code is null or s.employee_code = p_seller_code)
    ) q;
    select count(*), coalesce(sum(o.total_sales), 0) into v_porders, v_psales
      from public.orders o
      left join public.sellers s on s.id = o.seller_id
      where o.delivery_status = 'ตีกลับ'
        and (o.ordered_at at time zone 'Asia/Bangkok')::date between v_pstart and v_pend
        and (v_all or s.team_id = any(v_teams))
        and (p_team_id is null or (p_team_id = -1 and s.team_id is null) or s.team_id = p_team_id)
        and (p_seller_code is null or s.employee_code = p_seller_code);
  end if;

  v_orders := jsonb_array_length(v_rows);
  select coalesce(sum((e->>'total_sales')::bigint), 0) into v_sales
    from jsonb_array_elements(v_rows) e;

  return jsonb_build_object(
    'authorized', true, 'ok', true,
    'role', v_role, 'all_teams', v_all, 'mode', v_mode,
    'cycle', jsonb_build_object(
       'value', to_char(v_cycle, 'YYYY-MM'),
       'label', v_months[extract(month from v_cycle)::int] || ' ' || extract(year from v_cycle)::text,
       'range', to_char(v_start, 'DD/MM') || ' – ' || to_char(v_end, 'DD/MM/YYYY')),
    'cycles', v_cycles,
    'teams', v_teamlist,
    'sellers', v_sellerlist,
    'sellers_with_returns', coalesce(v_sellers_ret, '[]'::jsonb),
    'stats', jsonb_build_object('orders', v_orders, 'sales', v_sales),
    'prev', jsonb_build_object('orders', coalesce(v_porders,0), 'sales', coalesce(v_psales,0)),
    'rows', v_rows
  );
end $$;


--
-- Name: app_returns_signal(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_returns_signal(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  return jsonb_build_object('authorized', true, 'ok', true,
    'count', (select count(*) from public.recon_returns));
end $$;


--
-- Name: app_returns_stats(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_returns_stats(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_role text;
  v_today date; v_cycle date; v_start date; v_end date;
  v_deduct int; v_nodeduct int;
  v_months text[] := array['มกราคม','กุมภาพันธ์','มีนาคม','เมษายน','พฤษภาคม','มิถุนายน',
                           'กรกฎาคม','สิงหาคม','กันยายน','ตุลาคม','พฤศจิกายน','ธันวาคม'];
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','RT+','RTs','Vm') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;

  v_today := (now() at time zone 'Asia/Bangkok')::date;
  -- วันที่ >= 26 → นับเป็นรอบเดือนถัดไป
  v_cycle := case when extract(day from v_today) >= 26
                  then (date_trunc('month', v_today) + interval '1 month')::date
                  else date_trunc('month', v_today)::date end;
  v_start := (v_cycle - interval '1 month' + interval '25 days')::date;   -- 26 ของเดือนก่อน
  v_end   := (v_cycle + interval '24 days')::date;                        -- 25 ของเดือนรอบนี้

  select count(*) filter (where not r.no_deduct),
         count(*) filter (where r.no_deduct)
    into v_deduct, v_nodeduct
    from public.recon_returns r
   where (r.recorded_at at time zone 'Asia/Bangkok')::date between v_start and v_end;

  return jsonb_build_object(
    'authorized', true, 'ok', true,
    'cycle_label',  v_months[extract(month from v_cycle)::int] || ' ' || extract(year from v_cycle)::text,
    'cycle_short',  to_char(v_cycle, 'MM/YYYY'),
    'cycle_range',  to_char(v_start, 'DD/MM') || ' – ' || to_char(v_end, 'DD/MM/YYYY'),
    'deduct',       coalesce(v_deduct, 0),
    'no_deduct',    coalesce(v_nodeduct, 0)
  );
end $$;


--
-- Name: app_sales_dashboard(text, text, date, date, text, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_sales_dashboard(p_token text, p_gran text DEFAULT 'month'::text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_brand text DEFAULT NULL::text, p_team bigint DEFAULT NULL::bigint) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_role text;
  v_min date; v_max date; v_from date; v_to date;
  v_span int; v_pfrom date; v_pto date;
  v_out jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role is null or v_role not in ('Adm','Vm','Vw') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;
  if p_gran not in ('year','month','day') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_gran');
  end if;

  select min((ordered_at at time zone 'Asia/Bangkok')::date),
         max((ordered_at at time zone 'Asia/Bangkok')::date)
    into v_min, v_max
  from public.orders o join public.brands b on b.id = o.brand_id
  where o.order_no not like 'MOCK%' and b.name <> 'ตัวแทน';
  if v_min is null then
    return jsonb_build_object('authorized', true, 'ok', true, 'empty', true);
  end if;

  v_from := coalesce(p_from, case p_gran
              when 'year'  then v_min
              when 'month' then date_trunc('year',  v_max)::date
              else              date_trunc('month', v_max)::date end);
  v_to   := coalesce(p_to, v_max);
  if v_from > v_to then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_range');
  end if;
  v_span  := (v_to - v_from) + 1;
  v_pto   := v_from - 1;
  v_pfrom := v_pto - (v_span - 1);

  with src as (
    select (o.ordered_at at time zone 'Asia/Bangkok')::date as d,
           b.name as brand, o.total_sales as amt,
           o.payment_status as pay, o.delivery_status as dlv,
           -- ฝ่าย: ค่าที่ไม่ใช่ admin/crm และออเดอร์ที่ไม่มีเซล รวมเป็น "อื่นๆ"
           case s.department when 'admin' then 'แอดมิน' when 'crm' then 'CRM' else 'อื่นๆ' end as dept
    from public.orders o
    join public.brands b on b.id = o.brand_id
    left join public.sellers s on s.id = o.seller_id
    left join public.teams   t on t.id = s.team_id
    where o.order_no not like 'MOCK%'
      and b.name <> 'ตัวแทน'
      and (p_brand is null or b.name = p_brand)
      and (p_team is null or (p_team = -1 and t.id is null) or t.id = p_team)
  ),
  cur  as (select * from src where d between v_from and v_to),
  prev as (select * from src where d between v_pfrom and v_pto),
  agg as (
    select
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ')),0)       as sales,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน')),0)                   as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)                     as waiting,
      coalesce(sum(amt) filter (where dlv = 'ตีกลับ'),0)                     as ret_amt,
      count(*)                                                               as n_all,
      count(*) filter (where dlv = 'ส่งสำเร็จ')                              as n_done,
      count(*) filter (where dlv = 'ตีกลับ')                                 as n_ret,
      count(*) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ'))                   as n_sales,
      count(*) filter (where pay in ('ชำระแล้ว','บางส่วน'))                               as n_paid,
      count(*) filter (where pay = 'รอชำระ')                                 as n_waiting
    from cur
  ),
  pagg as (
    select coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ')),0) as sales,
           count(*) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ'))             as n_sales
    from prev
  ),
  brands as (
    select brand,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ')),0) as sales,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน')),0)             as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)               as waiting,
      coalesce(sum(amt) filter (where dlv = 'ตีกลับ'),0)               as ret_amt,
      count(*) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ'))             as n_sales,
      count(*) filter (where dlv = 'ตีกลับ')                           as n_ret
    from cur group by brand
  ),
  depts as (
    select dept,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ')),0) as sales,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน')),0)             as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)               as waiting,
      coalesce(sum(amt) filter (where dlv = 'ตีกลับ'),0)               as ret_amt,
      count(*) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ'))             as n_sales,
      count(*) filter (where dlv = 'ตีกลับ')                           as n_ret
    from cur group by dept
  ),
  -- ฝ่าย × แบรนด์ (เจ้านายขอเพิ่ม 2026-09-22): แอดมิน/CRM ขายแบรนด์ไหนไปเท่าไหร่
  dept_brands as (
    select dept, brand,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ')),0) as sales,
      coalesce(sum(amt) filter (where pay in ('ชำระแล้ว','บางส่วน')),0)             as paid,
      coalesce(sum(amt) filter (where pay = 'รอชำระ'),0)               as waiting,
      count(*) filter (where pay in ('ชำระแล้ว','บางส่วน','รอชำระ'))             as n_sales
    from cur group by dept, brand
  )
  select jsonb_build_object(
    'authorized', true, 'ok', true,
    'gran', p_gran, 'from', v_from, 'to', v_to,
    'prev_from', v_pfrom, 'prev_to', v_pto,
    'bounds', jsonb_build_object('min', v_min, 'max', v_max),
    'sales', jsonb_build_object(
        'total', (select sales from agg), 'paid', (select paid from agg), 'waiting', (select waiting from agg),
        'orders', (select n_sales from agg), 'orders_paid', (select n_paid from agg), 'orders_waiting', (select n_waiting from agg)),
    'prev', jsonb_build_object('total', (select sales from pagg), 'orders', (select n_sales from pagg)),
    'returns', jsonb_build_object('amount', (select ret_amt from agg), 'orders', (select n_ret from agg)),
    'counts', jsonb_build_object(
        'all', (select n_all from agg), 'done', (select n_done from agg), 'returned', (select n_ret from agg)),
    'brands', coalesce((select jsonb_agg(jsonb_build_object(
        'name', brand, 'sales', sales, 'paid', paid, 'waiting', waiting,
        'ret_amount', ret_amt, 'orders', n_sales, 'ret_orders', n_ret) order by sales desc)
      from brands), '[]'::jsonb),
    -- เรียงคงที่ แอดมิน → CRM → อื่นๆ (ไม่เรียงตามยอด เพื่อให้ตำแหน่งในการ์ดไม่สลับไปมาเวลาเปลี่ยนช่วง)
    'depts', coalesce((select jsonb_agg(jsonb_build_object(
        'name', dept, 'sales', sales, 'paid', paid, 'waiting', waiting,
        'ret_amount', ret_amt, 'orders', n_sales, 'ret_orders', n_ret)
        order by case dept when 'แอดมิน' then 1 when 'CRM' then 2 else 3 end)
      from depts), '[]'::jsonb),
    'dept_brands', coalesce((select jsonb_agg(jsonb_build_object(
        'dept', dept, 'brand', brand, 'sales', sales, 'paid', paid,
        'waiting', waiting, 'orders', n_sales)
        order by case dept when 'แอดมิน' then 1 when 'CRM' then 2 else 3 end, sales desc)
      from dept_brands), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $$;


--
-- Name: app_sales_dashboard_teams(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_sales_dashboard_teams(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid; v_role text;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role into v_role from public.app_users where id = v_uid;
  if v_role is null or v_role not in ('Adm','Vm','Vw') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;
  return jsonb_build_object('authorized', true, 'ok', true,
    'teams', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name)
                       from public.teams), '[]'::jsonb));
end $$;


--
-- Name: app_save_note_marks(text, bigint, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_save_note_marks(p_token text, p_note_id bigint, p_marks jsonb DEFAULT NULL::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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
end $$;


--
-- Name: app_save_order_tracking(text, bigint, text, text, text, text, text, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_save_order_tracking(p_token text, p_order_id bigint, p_delivery_status text DEFAULT NULL::text, p_payment_status text DEFAULT NULL::text, p_return_reason text DEFAULT NULL::text, p_status_detail text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_paid_amount numeric DEFAULT NULL::numeric) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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
  v_pay_valid   text[] := array['รอชำระ','ชำระแล้ว','บางส่วน','ยกเลิก','ไม่ใช่งานขาย'];
  v_paid numeric;
  v_paid_changed boolean := false;
  v_cancel_couple boolean := false;
  v_timeline jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;

  select coalesce(display_name, username), role into v_uname, v_role from public.app_users where id = v_uid;
  if v_role not in ('Adm','OM') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden_viewer');
  end if;

  select id, delivery_status, payment_status, return_reason, status_detail, payment_method, paid_amount, total_sales
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

  -- บางส่วน (ได้เงินไม่เต็ม): ใช้ได้เฉพาะ "มีปัญหา" + ต้องมียอดที่รับจริง > 0 และ < ยอดขาย
  if v_new_payment = 'บางส่วน' then
    if v_new_delivery is distinct from 'มีปัญหา' then
      return jsonb_build_object('authorized', true, 'ok', false, 'error', 'partial_needs_problem');
    end if;
    v_paid := coalesce(p_paid_amount, v_cur.paid_amount);
    if v_paid is null or v_paid <= 0 or v_paid >= v_cur.total_sales then
      return jsonb_build_object('authorized', true, 'ok', false, 'error', 'bad_paid_amount');
    end if;
  else
    v_paid := null;
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
  v_paid_changed  := v_paid is distinct from v_cur.paid_amount;
  v_changed := v_deliv_changed or v_pay_changed or v_paid_changed
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
      'return_reason', v_cur.return_reason, 'status_detail', v_cur.status_detail, 'paid_amount', v_cur.paid_amount,
      'timeline', v_timeline);
  end if;

  if v_changed then
    update public.orders
      set delivery_status = v_new_delivery,
          payment_status  = v_new_payment,
          return_reason   = v_reason,
          status_detail   = v_detail,
          paid_amount     = v_paid,
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

  if v_pay_changed or (v_paid_changed and v_new_payment = 'บางส่วน') then
    insert into public.order_tracking(order_id, entry_type, old_value, new_value, detail, created_by, created_by_name)
    values (p_order_id, 'payment_change', v_cur.payment_status, v_new_payment,
      case when v_new_payment = 'บางส่วน'
           then 'รับจริง ฿'||to_char(v_paid,'FM999,999,990.##')||' จาก ฿'||to_char(v_cur.total_sales,'FM999,999,990') end,
      v_uid, v_uname);
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
    'return_reason', v_reason, 'status_detail', v_detail, 'paid_amount', v_paid,
    'timeline', v_timeline);
end $$;


--
-- Name: app_save_returns(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_save_returns(p_token text, p_rows jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_uname text; v_role text;
  v_problems jsonb; v_inserted int := 0; v_conflicts jsonb := '[]'::jsonb;
  v_valid text[] := array['สินค้าครบ ไม่เสียหาย','สินค้าเสียหาย','สินค้าไม่ครบ','สินค้าไม่ครบและเสียหาย'];
  e record; v_prev record;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role, coalesce(display_name, username) into v_role, v_uname from public.app_users where id = v_uid;
  if v_role not in ('Adm','RT+') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden');
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'no_rows');
  end if;

  drop table if exists _ret;
  create temp table _ret on commit drop as
  select (row_number() over ())::int as k,
         btrim(coalesce(r->>'tracking_out',''))                as tracking_out,
         nullif(btrim(coalesce(r->>'tracking_return','')), '') as tracking_return,
         btrim(coalesce(r->>'inspection_result',''))           as inspection_result,
         nullif(btrim(coalesce(r->>'damage_detail','')), '')   as damage_detail,
         case when jsonb_typeof(r->'damage_items') = 'array' then r->'damage_items' else null end as damage_items,
         nullif(btrim(coalesce(r->>'photo_url','')), '')       as photo_url,
         coalesce((r->>'no_deduct')::boolean, false)           as no_deduct
  from jsonb_array_elements(p_rows) r;

  select coalesce(jsonb_agg(jsonb_build_object('row', x.k, 'tracking', x.tracking_out, 'reason', p.reason) order by x.k), '[]'::jsonb)
    into v_problems
  from _ret x
  cross join lateral (
    select case
      when x.tracking_out = '' then 'ไม่ได้กรอกเลขแทร็คส่งออก'
      when (select count(*) from _ret y where y.tracking_out = x.tracking_out) > 1 then 'เลขแทร็คซ้ำกันในหน้านี้'
      when exists (select 1 from public.recon_returns r where btrim(r.tracking_out) = x.tracking_out) then 'มีคนบันทึกแทร็คนี้ไปแล้ว — โปรดตรวจสอบและแก้ก่อนบันทึก'
      when not exists (select 1 from public.orders o where btrim(coalesce(o.tracking_no,'')) = x.tracking_out) then 'ไม่พบออเดอร์ที่ใช้เลขแทร็คนี้'
      when x.tracking_return is null then 'ต้องกรอกเลขแทร็คที่ตีกลับมา'
      when x.photo_url is null then 'ต้องใส่ลิงก์รูปกล่องตีกลับ'
      when x.photo_url !~* '^https?://' then 'ลิงก์รูปต้องขึ้นต้นด้วย http(s)://'
      when (select count(*) from _ret y where y.photo_url = x.photo_url) > 1 then 'ลิงก์รูปซ้ำกันในหน้านี้'
      when exists (select 1 from public.recon_returns r where btrim(r.photo_url) = x.photo_url) then 'ลิงก์รูปนี้ถูกใช้บันทึกไปแล้ว — โปรดใช้รูปอื่น'
      when not (x.inspection_result = any(v_valid)) then 'ยังไม่ได้เลือกผลการตรวจสอบ'
      when x.inspection_result <> 'สินค้าครบ ไม่เสียหาย'
        and (x.damage_items is null or jsonb_array_length(x.damage_items) = 0) then 'ต้องเลือกสินค้าที่เสียหาย/ขาด'
      when x.inspection_result = 'สินค้าไม่ครบและเสียหาย' and not (
        exists (select 1 from jsonb_array_elements(x.damage_items) d where d->>'kind' = 'damaged')
        and exists (select 1 from jsonb_array_elements(x.damage_items) d where d->>'kind' = 'missing')
      ) then 'ต้องระบุทั้งสินค้าที่เสียหาย และสินค้าที่ขาด'
      when x.inspection_result <> 'สินค้าครบ ไม่เสียหาย' and exists (
        select 1 from jsonb_array_elements(x.damage_items) d
        where coalesce((d->>'qty')::int, 0) < 1
           or coalesce((d->>'qty')::int, 0) > coalesce((
                select oi.quantity from public.orders o
                  join public.order_items oi on oi.order_id = o.id
                  join public.products pr on pr.id = oi.product_id
                 where btrim(coalesce(o.tracking_no,'')) = x.tracking_out and pr.name = d->>'name'
                 limit 1), -1)
      ) then 'จำนวนสินค้าที่เสียหาย/ขาด เกินจำนวนในออเดอร์'
      else null end as reason
  ) p
  where p.reason is not null;

  if jsonb_array_length(v_problems) > 0 then
    return jsonb_build_object('authorized', true, 'ok', false, 'problems', v_problems);
  end if;

  for e in select * from _ret order by k loop
    begin
      insert into public.recon_returns(tracking_out, tracking_return, inspection_result, damage_detail, damage_items, photo_url, no_deduct, created_by)
      values (e.tracking_out, e.tracking_return, e.inspection_result, e.damage_detail, e.damage_items, e.photo_url, e.no_deduct, v_uid);
      v_inserted := v_inserted + 1;
    exception when unique_violation then
      select r.*, coalesce(u.display_name, u.username::text) as by_name
        into v_prev
        from public.recon_returns r left join public.app_users u on u.id = r.created_by
       where btrim(r.tracking_out) = e.tracking_out;

      delete from public.recon_returns where btrim(tracking_out) = e.tracking_out;
      perform public.revert_return_effects(e.tracking_out);

      insert into public.return_conflicts(tracking_out, submissions)
      values (e.tracking_out, jsonb_build_array(
        jsonb_build_object('by', v_prev.by_name, 'at', v_prev.created_at,
          'tracking_return', v_prev.tracking_return, 'inspection_result', v_prev.inspection_result,
          'damage_detail', v_prev.damage_detail, 'damage_items', v_prev.damage_items,
          'photo_url', v_prev.photo_url, 'no_deduct', v_prev.no_deduct),
        jsonb_build_object('by', v_uname, 'at', now(),
          'tracking_return', e.tracking_return, 'inspection_result', e.inspection_result,
          'damage_detail', e.damage_detail, 'damage_items', e.damage_items,
          'photo_url', e.photo_url, 'no_deduct', e.no_deduct)
      ));

      v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object('row', e.k, 'tracking', e.tracking_out, 'with', v_prev.by_name));
    end;
  end loop;

  insert into public.audit_log(user_id, username, event, detail)
    values (v_uid, v_uname, 'save_returns',
            jsonb_build_object('inserted', v_inserted, 'conflicts', jsonb_array_length(v_conflicts)));

  return jsonb_build_object('authorized', true, 'ok', true,
    'inserted', v_inserted, 'conflicts', v_conflicts, 'problems', '[]'::jsonb);
end $$;


--
-- Name: app_save_view(text, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_save_view(p_token text, p_page text, p_data jsonb DEFAULT NULL::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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
end $$;


--
-- Name: app_search_orders(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_search_orders(p_token text, p_query text, p_view text DEFAULT 'order'::text, p_field text DEFAULT 'all'::text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_uid uuid; v_role text; v_all_teams boolean; v_all boolean; v_teams bigint[];
  v_q text := btrim(coalesce(p_query,''));
  v_view text := case when p_view='deduct' then 'deduct' else 'order' end;
  v_field text := case when p_field in ('phone','name','address','tracking','note') then p_field else 'all' end;
  v_rows jsonb; v_count int;
  v_months text[] := array['มกราคม','กุมภาพันธ์','มีนาคม','เมษายน','พฤษภาคม','มิถุนายน','กรกฎาคม','สิงหาคม','กันยายน','ตุลาคม','พฤศจิกายน','ธันวาคม'];
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  select role, all_teams into v_role, v_all_teams from public.app_users where id=v_uid;
  if v_role not in ('Adm','OM','Vm','RT+','RTs') then
    return jsonb_build_object('authorized', true, 'ok', false, 'error', 'forbidden'); end if;
  v_all := (v_role in ('Adm','OM','Vm','RT+') or coalesce(v_all_teams,false));
  if not v_all then
    select coalesce(array_agg(team_id),'{}') into v_teams from public.app_user_teams where user_id=v_uid;
  end if;
  if length(v_q) < 2 then
    return jsonb_build_object('authorized',true,'ok',true,'too_short',true,'rows','[]'::jsonb,'count',0,'view',v_view,'field',v_field);
  end if;

  if v_view='order' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.ordered_at desc),'[]'::jsonb), count(*) into v_rows, v_count
    from (
      select o.id,
        (o.ordered_at at time zone 'Asia/Bangkok')::date as ordered_at,
        o.order_no, o.customer_name, o.phone,
        nullif(concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code),'') as address,
        s.employee_code as seller_code, s.name as seller_name, t.name as team_name,
        o.carrier, o.total_sales, o.payment_method, o.payment_status, o.delivery_status, o.return_arrived, o.note,
        o.tracking_no as tracking_out,
        (select string_agg(p.name||' ×'||public.qty_txt(oi.quantity), E'\n' order by oi.id) from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=o.id) as items,
        array_remove(array[
          case when public.search_match(v_field, v_q, o.phone, null, null, null, null) then 'phone' end,
          case when public.search_match(v_field, v_q, null, o.customer_name, null, null, null) then 'name' end,
          case when public.search_match(v_field, v_q, null, null, concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code), null, null) then 'address' end,
          case when public.search_match(v_field, v_q, null, null, null, o.tracking_no, null) then 'tracking' end,
          case when public.search_match(v_field, v_q, null, null, null, null, o.note) then 'note' end ], null) as matched_fields
      from public.orders o
      left join public.sellers s on s.id=o.seller_id
      left join public.teams t on t.id=s.team_id
      where public.search_match(v_field, v_q, o.phone, o.customer_name,
              concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code), o.tracking_no, o.note)
        and (v_all or s.team_id = any(v_teams))
      limit 5000
    ) x;
  else
    select coalesce(jsonb_agg(to_jsonb(x) order by x.return_date desc nulls last, x.ordered_at desc),'[]'::jsonb), count(*) into v_rows, v_count
    from (
      select o.id,
        (o.ordered_at at time zone 'Asia/Bangkok')::date as ordered_at,
        (r.recorded_at at time zone 'Asia/Bangkok')::date as return_date,
        o.order_no, o.customer_name, o.phone,
        nullif(concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code),'') as address,
        s.employee_code as seller_code, s.name as seller_name, t.name as team_name,
        o.carrier, o.total_sales, o.payment_method, o.payment_status, o.delivery_status, o.return_arrived, o.note,
        o.tracking_no as tracking_out, r.inspection_result, r.tracking_return, r.no_deduct, true as has_recon,
        (select string_agg(p.name||' ×'||public.qty_txt(oi.quantity), E'\n' order by oi.id) from public.order_items oi join public.products p on p.id=oi.product_id where oi.order_id=o.id) as items,
        (v_months[extract(month from cc.cyc)::int]||' '||extract(year from cc.cyc)::text) as cycle_label,
        to_char(cc.cyc,'YYYY-MM') as cycle_value,
        array_remove(array[
          case when public.search_match(v_field, v_q, o.phone, null, null, null, null) then 'phone' end,
          case when public.search_match(v_field, v_q, null, o.customer_name, null, null, null) then 'name' end,
          case when public.search_match(v_field, v_q, null, null, concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code), null, null) then 'address' end,
          case when public.search_match(v_field, v_q, null, null, null, o.tracking_no, null) then 'tracking' end,
          case when public.search_match(v_field, v_q, null, null, null, null, o.note) then 'note' end ], null) as matched_fields
      from public.recon_returns r
      join public.orders o on btrim(o.tracking_no) = btrim(r.tracking_out)
      left join public.sellers s on s.id=o.seller_id
      left join public.teams t on t.id=s.team_id
      cross join lateral (select case when extract(day from (r.recorded_at at time zone 'Asia/Bangkok')::date) >= 26
                       then (date_trunc('month',(r.recorded_at at time zone 'Asia/Bangkok')::date)+interval '1 month')::date
                       else date_trunc('month',(r.recorded_at at time zone 'Asia/Bangkok')::date)::date end as cyc) cc
      where public.search_match(v_field, v_q, o.phone, o.customer_name,
              concat_ws(' ',o.addr_detail,o.subdistrict,o.district,o.province,o.postal_code), o.tracking_no, o.note)
        and (v_all or s.team_id = any(v_teams))
      limit 5000
    ) x;
  end if;

  return jsonb_build_object('authorized',true,'ok',true,'view',v_view,'field',v_field,'query',v_q,'rows',v_rows,'count',v_count);
end $$;


--
-- Name: app_session_uid(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.app_session_uid(p_token text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_uid uuid;
begin
  update public.auth_sessions s set last_seen_at = now()
    from public.app_users u
    where s.token_hash = encode(digest(p_token, 'sha256'), 'hex')
      and u.id = s.user_id
      and u.is_active
      and s.expires_at > now()
      and s.last_seen_at > now() - make_interval(mins => u.idle_minutes)
    returning s.user_id into v_uid;
  return v_uid;
end $$;


--
-- Name: check_order_item_brand(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_order_item_brand() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare
  v_product_brand bigint;
  v_order_brand   bigint;
begin
  select o.brand_id into v_order_brand from public.orders o where o.id = new.order_id;

  -- ออเดอร์ "ตัวแทน": รวมสินค้าหลายแบรนด์ได้ ไม่ต้องตรวจ
  if v_order_brand = (select id from public.brands where name = 'ตัวแทน') then
    return new;
  end if;

  select c.brand_id into v_product_brand
  from public.products p
  join public.categories c on c.id = p.category_id
  where p.id = new.product_id;

  if v_product_brand is distinct from v_order_brand then
    raise exception 'order_item product % (brand %) does not match order % (brand %)',
      new.product_id, v_product_brand, new.order_id, v_order_brand;
  end if;
  return new;
end;
$$;


--
-- Name: detect_customer_duplicates(timestamp with time zone, real, real); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.detect_customer_duplicates(p_since timestamp with time zone DEFAULT (now() - '1 day'::interval), p_thresh_name real DEFAULT 0.6, p_thresh_addr real DEFAULT 0.85) RETURNS integer
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_count int;
begin
  perform extensions.set_limit(p_thresh_name);
  with newc as (
    select id from public.customers where created_at >= p_since
  ),
  cand as (
    -- ชื่อคล้าย + ต้องอยู่จังหวัด+อำเภอเดียวกัน (กันชื่อเล่นซ้ำข้ามพื้นที่)
    select o1.brand_id, o1.customer_id nc_id, o2.customer_id cc_id, 'name'::text reason,
           max(extensions.similarity(public.norm_name(o1.customer_name), public.norm_name(o2.customer_name))) score
    from newc
    join public.orders o1 on o1.customer_id = newc.id
    join public.orders o2 on o2.brand_id = o1.brand_id and o2.customer_id <> o1.customer_id
       and o2.province is not distinct from o1.province
       and o2.district is not distinct from o1.district
    where o1.province is not null
      and public.norm_name(o1.customer_name) operator(extensions.%) public.norm_name(o2.customer_name)
    group by o1.brand_id, o1.customer_id, o2.customer_id
    union all
    -- ที่อยู่เดียวกัน (จังหวัด+อำเภอ+ตำบล+ไปรษณีย์ตรง และบ้านเลขที่คล้ายมาก)
    select o1.brand_id, o1.customer_id, o2.customer_id, 'address'::text,
           max(extensions.similarity(coalesce(o1.addr_detail,''), coalesce(o2.addr_detail,'')))
    from newc
    join public.orders o1 on o1.customer_id = newc.id
    join public.orders o2 on o2.brand_id = o1.brand_id and o2.customer_id <> o1.customer_id
       and o2.province     is not distinct from o1.province
       and o2.district     is not distinct from o1.district
       and o2.subdistrict  is not distinct from o1.subdistrict
       and o2.postal_code  is not distinct from o1.postal_code
    where o1.province is not null
      and extensions.similarity(coalesce(o1.addr_detail,''), coalesce(o2.addr_detail,'')) >= p_thresh_addr
    group by o1.brand_id, o1.customer_id, o2.customer_id
  )
  insert into public.customer_review (brand_id, new_customer_id, candidate_customer_id, reason, score)
  select distinct on (least(m.nc_id, m.cc_id), greatest(m.nc_id, m.cc_id))
         m.brand_id, m.nc_id, m.cc_id, m.reason, round(m.score::numeric, 3)
  from cand m
  where not exists (
    select 1 from public.customer_review r
    where least(r.new_customer_id, r.candidate_customer_id) = least(m.nc_id, m.cc_id)
      and greatest(r.new_customer_id, r.candidate_customer_id) = greatest(m.nc_id, m.cc_id)
  )
  order by least(m.nc_id, m.cc_id), greatest(m.nc_id, m.cc_id), m.score desc
  on conflict (new_customer_id, candidate_customer_id) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end $$;


--
-- Name: get_months(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_months(p_token text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
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
end $$;


--
-- Name: get_orders(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_orders(p_token text, p_month text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $_$
declare v_uid uuid; v_uname text; v_role text; v_start date; v_end date; v_days int; v_orders jsonb;
begin
  v_uid := public.app_session_uid(p_token);
  if v_uid is null then return jsonb_build_object('authorized', false); end if;
  if p_month !~ '^\d{4}-\d{2}$' then
    return jsonb_build_object('authorized', true, 'error', 'bad_month');
  end if;
  v_start := to_date(p_month || '-01', 'YYYY-MM-DD');
  v_end   := (v_start + interval '1 month')::date;
  v_days  := extract(day from (v_end - interval '1 day'))::int;

  select coalesce(jsonb_agg(row order by ord_at asc, oid asc), '[]'::jsonb) into v_orders
  from (
    select o.id as oid, o.ordered_at as ord_at, jsonb_build_object(
      'id', o.id,
      'date', to_char(o.ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD'),
      'ordered_at', to_char(o.ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI:SS') || '+07:00',
      'phone', coalesce(o.phone, ''),
      'customer_name', coalesce(o.customer_name, ''),
      'address', array_to_string(array_remove(array[
        nullif(btrim(o.addr_detail), ''), nullif(btrim(o.subdistrict), ''),
        nullif(btrim(o.district), ''), nullif(btrim(o.province), ''), nullif(btrim(o.postal_code), '')
      ], null), ' '),
      'address_parts', (
        select coalesce(jsonb_agg(x.p order by x.ord), '[]'::jsonb)
        from unnest(array[
          nullif(btrim(o.addr_detail), ''), nullif(btrim(o.subdistrict), ''),
          nullif(btrim(o.district), ''), nullif(btrim(o.province), ''), nullif(btrim(o.postal_code), '')
        ]) with ordinality as x(p, ord)
        where x.p is not null
      ),
      'carrier', coalesce(o.carrier, ''),
      'tracking_no', coalesce(o.tracking_no, ''),
      'payment_method', coalesce(o.payment_method, ''),
      'total_sales', coalesce(o.total_sales, 0),
      'delivery_status', o.delivery_status,
      'payment_status', o.payment_status,
      'paid_amount', o.paid_amount,
      'return_arrived', o.return_arrived,
      'return_reason', coalesce(o.return_reason, ''),
      'status_detail', coalesce(o.status_detail, ''),
      'recon_conflict', o.recon_conflict,
      'inspection_result', coalesce((
        select rr.inspection_result from public.recon_returns rr
        where btrim(rr.tracking_out) = btrim(coalesce(o.tracking_no,''))
        order by rr.recorded_at desc, rr.id desc limit 1
      ), ''),
      'seller_code', coalesce(sel.employee_code, ''),
      'seller_name', coalesce(sel.name, ''),
      'items', coalesce((
        select jsonb_agg(jsonb_build_object('name', coalesce(pr.name, '?'), 'qty', oi.quantity) order by oi.id)
        from public.order_items oi
        left join public.products pr on pr.id = oi.product_id
        where oi.order_id = o.id
      ), '[]'::jsonb),
      'note', coalesce(o.note, ''),
      'last_note_text', (
        select t.note from public.order_tracking t
        where t.order_id = o.id and t.entry_type = 'note' and nullif(btrim(coalesce(t.note,'')),'') is not null
        order by t.created_at desc, t.id desc limit 1
      ),
      'last_note_at', (
        select to_char(max(t.created_at) at time zone 'Asia/Bangkok', 'YYYY-MM-DD')
        from public.order_tracking t
        where t.order_id = o.id and t.created_by is not null
      )
    ) as row
    from public.orders o
    left join public.sellers sel on sel.id = o.seller_id
    where o.ordered_at >= (v_start::timestamp at time zone 'Asia/Bangkok')
      and o.ordered_at <  (v_end::timestamp at time zone 'Asia/Bangkok')
  ) s;

  select v_user.username, v_user.role into v_uname, v_role from public.app_users v_user where id = v_uid;
  insert into public.audit_log(user_id, username, event, detail)
    values (v_uid, v_uname, 'view_orders', jsonb_build_object('month', p_month));

  return jsonb_build_object(
    'authorized', true,
    'role', coalesce(v_role, 'editor'),
    'month', p_month,
    'days_in_month', v_days,
    'today', to_char((now() at time zone 'Asia/Bangkok')::date, 'YYYY-MM-DD'),
    'orders', v_orders
  );
end $_$;


--
-- Name: is_paid_status(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_paid_status(p text) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ select p in ('ชำระแล้ว','บางส่วน') $$;


--
-- Name: merge_customers(bigint, bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.merge_customers(p_keep bigint, p_dup bigint) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare v_kb bigint; v_db bigint;
begin
  if p_keep = p_dup then raise exception 'keep = dup'; end if;
  select brand_id into v_kb from public.customers where id = p_keep;
  select brand_id into v_db from public.customers where id = p_dup;
  if v_kb is null or v_db is null then raise exception 'ไม่พบลูกค้า'; end if;
  if v_kb is distinct from v_db then raise exception 'คนละแบรนด์ merge ไม่ได้'; end if;
  update public.orders set customer_id = p_keep where customer_id = p_dup;
  delete from public.customer_phones dp
   where dp.customer_id = p_dup
     and exists (select 1 from public.customer_phones kp
                 where kp.customer_id = p_keep and kp.phone = dp.phone);
  update public.customer_phones set customer_id = p_keep where customer_id = p_dup;
  delete from public.customers where id = p_dup;  -- cascade ลบ review ที่อ้าง dup
end $$;


--
-- Name: norm_name(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.norm_name(t text) RETURNS text
    LANGUAGE sql IMMUTABLE
    SET search_path TO ''
    AS $_$
  select lower(btrim(regexp_replace(
           regexp_replace(coalesce(t,''),
             '^\s*(คุณ|นางสาว|นาย|นาง|น\.ส\.|ด\.ช\.|ด\.ญ\.)\s*', ''),
           '\s*[A-Za-z]{1,4}[0-9]{1,4}\s*$', '')));
$_$;


--
-- Name: orders_clear_paid_amount(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.orders_clear_paid_amount() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  if new.payment_status is distinct from 'บางส่วน' then new.paid_amount := null; end if;
  return new;
end $$;


--
-- Name: qty_txt(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.qty_txt(n integer) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    SET search_path TO ''
    AS $$ select case when n is null then '?' when n = 0 then '?' else n::text end $$;


--
-- Name: reconcile_order(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reconcile_order(p_order_id bigint) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  o record;
  has_ret boolean;
  has_cod boolean;
  v_cod_amount numeric;
  v_cod_from text;
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
  if has_ret and (has_cod or public.is_paid_status(o.payment_status)) then
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
    select c.amount, c.received_from into v_cod_amount, v_cod_from
      from public.recon_cod_payments c
      where btrim(c.tracking_out) = o.tr
      order by c.id desc limit 1;
    -- บางส่วน: ยืนยันแล้ว (ออเดอร์เป็นบางส่วนอยู่) + เงินเคลมน้อยกว่ายอดขาย → คงบางส่วน ไม่ใช่ error
    v_target := case when v_cod_amount is not null and round(v_cod_amount) = o.total_sales then 'ชำระแล้ว'
                     when o.payment_status = 'บางส่วน' and v_cod_from = 'ทำเคลม'
                          and v_cod_amount > 0 and v_cod_amount < o.total_sales then 'บางส่วน'
                     else 'error' end;
    if v_target = 'บางส่วน' then
      update public.orders set paid_amount = v_cod_amount where id = o.id and paid_amount is distinct from v_cod_amount;
    end if;
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
end $$;


--
-- Name: revert_recon_effects(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revert_recon_effects(p_tracking text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare
  v_oid bigint;
  v_ret_deliv text;
  v_ret_pay text;
  v_cod_pay text;
begin
  select id into v_oid from public.orders
   where btrim(coalesce(tracking_no,'')) = btrim(p_tracking) order by id limit 1;
  if v_oid is null then return; end if;

  -- delivery เดิมก่อนระบบมาร์ค 'ตีกลับ' (เอาครั้งแรกสุด = baseline จริง)
  select old_value into v_ret_deliv from public.order_tracking
   where order_id = v_oid and entry_type = 'delivery_change'
     and created_by_name = 'ระบบ' and new_value = 'ตีกลับ'
   order by id asc limit 1;
  -- payment เดิมก่อนระบบมาร์ค 'ยกเลิก' (สาย return)
  select old_value into v_ret_pay from public.order_tracking
   where order_id = v_oid and entry_type = 'payment_change'
     and created_by_name = 'ระบบ' and new_value = 'ยกเลิก'
   order by id asc limit 1;
  -- payment เดิมก่อนระบบมาร์ค 'ชำระแล้ว'/'error' (สาย COD)
  select old_value into v_cod_pay from public.order_tracking
   where order_id = v_oid and entry_type = 'payment_change'
     and created_by_name = 'ระบบ' and new_value in ('ชำระแล้ว','error','บางส่วน')
   order by id asc limit 1;

  update public.orders set
    delivery_status = coalesce(v_ret_deliv, delivery_status),
    payment_status  = coalesce(v_ret_pay, v_cod_pay, payment_status),
    return_arrived  = false,
    return_reason   = case when return_reason = 'ตีกลับถึงแล้ว' then null else return_reason end,
    recon_conflict  = false,
    updated_at = now()
  where id = v_oid;
end $$;


--
-- Name: revert_return_effects(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.revert_return_effects(p_tracking text) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_oid bigint; v_old_deliv text; v_old_pay text;
begin
  select id into v_oid from public.orders where btrim(coalesce(tracking_no,'')) = btrim(p_tracking) order by id limit 1;
  if v_oid is null then return; end if;

  select old_value into v_old_deliv from public.order_tracking
   where order_id = v_oid and entry_type = 'delivery_change' and created_by_name = 'ระบบ' and new_value = 'ตีกลับ'
   order by id desc limit 1;
  select old_value into v_old_pay from public.order_tracking
   where order_id = v_oid and entry_type = 'payment_change' and created_by_name = 'ระบบ' and new_value = 'ยกเลิก'
   order by id desc limit 1;

  update public.orders set
    delivery_status = coalesce(v_old_deliv, delivery_status),
    payment_status  = coalesce(v_old_pay, payment_status),
    return_arrived  = false,
    return_reason   = case when return_reason = 'ตีกลับถึงแล้ว' then null else return_reason end,
    updated_at = now()
  where id = v_oid;

  insert into public.order_tracking(order_id, entry_type, note, created_by_name)
    values (v_oid, 'note', 'ระบบถอนรายการตีกลับ (บันทึกชนกัน) — ส่งให้ EDITH ตรวจสอบ', 'ระบบ');
end $$;


--
-- Name: search_match(text, text, text, text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_match(p_field text, p_q text, p_phone text, p_name text, p_addr text, p_trk text, p_note text) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  select (p_field in ('all','phone')    and p_phone ilike '%'||p_q||'%')
      or (p_field in ('all','name')     and p_name  ilike '%'||p_q||'%')
      or (p_field in ('all','address')  and p_addr  ilike '%'||p_q||'%')
      or (p_field in ('all','tracking') and p_trk   ilike '%'||p_q||'%')
      or (p_field in ('all','note')     and p_note  ilike '%'||p_q||'%')
$$;


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


--
-- Name: trg_order_after_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_order_after_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
begin
  perform public.reconcile_order(NEW.id);
  return NEW;
end $$;


--
-- Name: trg_recon_after_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_recon_after_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
declare v_oid bigint;
begin
  perform public.revert_recon_effects(OLD.tracking_out);
  perform public.reconcile_order(o.id)
    from public.orders o
    where btrim(coalesce(o.tracking_no,'')) = btrim(OLD.tracking_out);

  select id into v_oid from public.orders
   where btrim(coalesce(tracking_no,'')) = btrim(OLD.tracking_out) order by id limit 1;
  if v_oid is not null then
    insert into public.order_tracking(order_id, entry_type, note, created_by_name)
      values (v_oid, 'note', 'ระบบถอนผล reconcile อัตโนมัติ (ลบข้อมูล recon: ตีกลับ/COD)', 'ระบบ');
  end if;
  return OLD;
end $$;


--
-- Name: trg_recon_after_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_recon_after_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'extensions'
    AS $$
begin
  if current_setting('app.skip_reconcile', true) = '1' then
    return NEW;   -- bulk import: ข้าม reconcile ต่อแถว (RPC จะ reconcile แบบ set-based)
  end if;
  perform public.reconcile_order(o.id)
    from public.orders o
    where btrim(coalesce(o.tracking_no, '')) = btrim(NEW.tracking_out);
  return NEW;
end $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: _bak_hist_import; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public._bak_hist_import (
    batch text,
    kind text,
    id bigint,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: _bak_merge_a_20260928; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public._bak_merge_a_20260928 (
    kind text,
    cust_id bigint,
    brand_id bigint,
    ref_id bigint,
    phone text,
    created_at timestamp with time zone,
    keep bigint
);


--
-- Name: _bak_merge_b_20260928; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public._bak_merge_b_20260928 (
    kind text,
    cust_id bigint,
    brand_id bigint,
    ref_id bigint,
    phone text,
    created_at timestamp with time zone,
    keep bigint
);


--
-- Name: _bak_merge_c_20260928; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public._bak_merge_c_20260928 (
    kind text,
    cust_id bigint,
    brand_id bigint,
    ref_id bigint,
    phone text,
    created_at timestamp with time zone,
    keep bigint
);


--
-- Name: _bak_merge_n_20260928; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public._bak_merge_n_20260928 (
    kind text,
    cust_id bigint,
    brand_id bigint,
    ref_id bigint,
    phone text,
    created_at timestamp with time zone,
    keep bigint
);


--
-- Name: _stg_hist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public._stg_hist (
    k bigint NOT NULL,
    mo text,
    src_row integer,
    order_no text,
    ordered_at timestamp with time zone,
    customer_name text,
    phone text,
    addr_detail text,
    subdistrict text,
    district text,
    province text,
    postal_code text,
    seller_code text,
    carrier text,
    tracking_no text,
    total_sales integer,
    payment_method text,
    payment_status text,
    delivery_status text,
    note text,
    return_reason text,
    status_detail text,
    brand_name text,
    items jsonb,
    dst_order_id bigint,
    seller_waived boolean DEFAULT false NOT NULL
);


--
-- Name: _stg_hist_k_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public._stg_hist_k_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: _stg_hist_k_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public._stg_hist_k_seq OWNED BY public._stg_hist.k;


--
-- Name: app_user_teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_user_teams (
    user_id uuid NOT NULL,
    team_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_user_views; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_user_views (
    user_id uuid NOT NULL,
    page text NOT NULL,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: app_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_users (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    username public.citext NOT NULL,
    password_hash text NOT NULL,
    display_name text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    line_user_id text,
    role text DEFAULT 'editor'::text NOT NULL,
    session_hours integer DEFAULT 12 NOT NULL,
    idle_minutes integer DEFAULT 30 NOT NULL,
    all_teams boolean DEFAULT false NOT NULL,
    CONSTRAINT app_users_role_chk CHECK ((role = ANY (ARRAY['OM'::text, 'RT+'::text, 'RTs'::text, 'Adm'::text, 'Vm'::text])))
);


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    id bigint NOT NULL,
    user_id uuid,
    username text,
    event text NOT NULL,
    ip text,
    user_agent text,
    geo jsonb,
    detail jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.audit_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: auth_login_tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_login_tickets (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    otp_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    attempts integer DEFAULT 0 NOT NULL,
    consumed boolean DEFAULT false NOT NULL,
    ip text,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    otp text
);


--
-- Name: auth_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_sessions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    user_id uuid NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    ip text,
    user_agent text,
    geo jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: brands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brands (
    id bigint NOT NULL,
    name text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: brands_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.brands ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.brands_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.categories ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: customer_phones; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_phones (
    id bigint NOT NULL,
    customer_id bigint NOT NULL,
    brand_id bigint NOT NULL,
    phone text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT customer_phones_phone_digits_chk CHECK ((phone ~ '^[0-9]{8,15}$'::text))
);


--
-- Name: customer_phones_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.customer_phones ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.customer_phones_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: customer_review; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_review (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    new_customer_id bigint NOT NULL,
    candidate_customer_id bigint NOT NULL,
    reason text NOT NULL,
    score numeric,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    decided_at timestamp with time zone,
    CONSTRAINT customer_review_reason_check CHECK ((reason = ANY (ARRAY['name'::text, 'address'::text]))),
    CONSTRAINT customer_review_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'merged'::text, 'rejected'::text])))
);


--
-- Name: customer_review_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.customer_review ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.customer_review_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: customers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.customers ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.customers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: note_highlights; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.note_highlights (
    note_id bigint NOT NULL,
    user_id uuid NOT NULL,
    marks jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_items (
    id bigint NOT NULL,
    order_id bigint NOT NULL,
    product_id bigint NOT NULL,
    quantity integer NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT order_items_quantity_chk CHECK ((quantity >= 0))
);


--
-- Name: order_items_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.order_items ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.order_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: order_tracking; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_tracking (
    id bigint NOT NULL,
    order_id bigint NOT NULL,
    entry_type text NOT NULL,
    note text,
    old_value text,
    new_value text,
    detail text,
    created_by uuid,
    created_by_name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT order_tracking_entry_type_check CHECK ((entry_type = ANY (ARRAY['note'::text, 'delivery_change'::text, 'payment_change'::text])))
);


--
-- Name: order_tracking_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.order_tracking ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.order_tracking_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    id bigint NOT NULL,
    brand_id bigint NOT NULL,
    customer_id bigint NOT NULL,
    order_no text,
    ordered_at timestamp with time zone NOT NULL,
    customer_name text NOT NULL,
    phone text NOT NULL,
    addr_detail text,
    subdistrict text,
    district text,
    province text,
    postal_code text,
    seller_id bigint,
    total_sales integer NOT NULL,
    payment_method text,
    carrier text,
    tracking_no text,
    payment_status text DEFAULT 'รอชำระ'::text NOT NULL,
    delivery_status text DEFAULT 'กำลังส่ง'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    note text,
    return_arrived boolean DEFAULT false NOT NULL,
    return_reason text,
    status_detail text,
    recon_conflict boolean DEFAULT false NOT NULL,
    seller_waived boolean DEFAULT false NOT NULL,
    paid_amount numeric(12,2),
    CONSTRAINT orders_delivery_status_chk CHECK ((delivery_status = ANY (ARRAY['กำลังส่ง'::text, 'ส่งสำเร็จ'::text, 'ตีกลับ'::text, 'ยกเลิก'::text, 'มีปัญหา'::text]))),
    CONSTRAINT orders_paid_amount_chk CHECK ((((payment_status = 'บางส่วน'::text) = (paid_amount IS NOT NULL)) AND ((paid_amount IS NULL) OR ((paid_amount > (0)::numeric) AND (paid_amount < (total_sales)::numeric))))),
    CONSTRAINT orders_payment_method_chk CHECK (((payment_method IS NULL) OR (payment_method = ANY (ARRAY['เก็บเงินปลายทาง'::text, 'โอนเงิน'::text, 'ตัดบัตรเครดิต'::text])))),
    CONSTRAINT orders_payment_status_chk CHECK ((payment_status = ANY (ARRAY['รอชำระ'::text, 'ชำระแล้ว'::text, 'บางส่วน'::text, 'ยกเลิก'::text, 'error'::text, 'ไม่ใช่งานขาย'::text]))),
    CONSTRAINT orders_phone_digits_chk CHECK ((phone ~ '^[0-9]{8,15}$'::text)),
    CONSTRAINT orders_postal_code_chk CHECK (((postal_code IS NULL) OR (postal_code ~ '^[0-9]{5}$'::text))),
    CONSTRAINT orders_total_sales_chk CHECK ((total_sales >= 0))
);


--
-- Name: orders_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.orders ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.orders_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id bigint NOT NULL,
    category_id bigint NOT NULL,
    name text NOT NULL,
    code text,
    is_freebie boolean DEFAULT false NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: products_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.products ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.products_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recon_cod_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recon_cod_payments (
    id bigint NOT NULL,
    tracking_out text NOT NULL,
    amount numeric,
    received_from text,
    note text,
    source text,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT recon_cod_received_from_chk CHECK (((received_from IS NULL) OR (received_from = ANY (ARRAY['ขนส่ง'::text, 'ระบบ'::text, 'ทำเคลม'::text]))))
);


--
-- Name: recon_cod_payments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recon_cod_payments ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recon_cod_payments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: recon_returns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recon_returns (
    id bigint NOT NULL,
    tracking_out text NOT NULL,
    tracking_return text,
    inspection_result text NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    damage_detail text,
    no_deduct boolean DEFAULT false NOT NULL,
    photo_url text,
    damage_items jsonb,
    CONSTRAINT recon_returns_damage_detail_chk CHECK (((inspection_result = 'สินค้าครบ ไม่เสียหาย'::text) OR (COALESCE(btrim(damage_detail), ''::text) <> ''::text))),
    CONSTRAINT recon_returns_inspection_chk CHECK ((inspection_result = ANY (ARRAY['สินค้าครบ ไม่เสียหาย'::text, 'สินค้าเสียหาย'::text, 'สินค้าไม่ครบ'::text, 'สินค้าไม่ครบและเสียหาย'::text])))
);


--
-- Name: recon_returns_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.recon_returns ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.recon_returns_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: return_conflicts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.return_conflicts (
    id bigint NOT NULL,
    tracking_out text NOT NULL,
    submissions jsonb NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_by uuid,
    resolved_at timestamp with time zone,
    resolution text,
    CONSTRAINT return_conflicts_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'resolved'::text])))
);


--
-- Name: return_conflicts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.return_conflicts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.return_conflicts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sellers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sellers (
    id bigint NOT NULL,
    name text,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    employee_code text NOT NULL,
    department text DEFAULT 'อื่นๆ'::text NOT NULL,
    team_id bigint,
    CONSTRAINT sellers_department_chk CHECK ((department = ANY (ARRAY['admin'::text, 'crm'::text, 'อื่นๆ'::text])))
);


--
-- Name: sellers_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sellers ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sellers_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: teams; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.teams (
    id bigint NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: teams_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.teams ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.teams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: tracking_detail_presets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracking_detail_presets (
    id bigint NOT NULL,
    kind text DEFAULT 'problem'::text NOT NULL,
    label text NOT NULL,
    use_count integer DEFAULT 0 NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    last_used_at timestamp with time zone,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tracking_detail_presets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.tracking_detail_presets ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.tracking_detail_presets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: v_customer_first_order; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_customer_first_order WITH (security_invoker='true') AS
 SELECT customer_id,
    brand_id,
    min(ordered_at) AS first_ordered_at
   FROM public.orders o
  GROUP BY customer_id, brand_id;


--
-- Name: v_new_customers_daily; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_new_customers_daily WITH (security_invoker='true') AS
 SELECT brand_id,
    ((first_ordered_at AT TIME ZONE 'Asia/Bangkok'::text))::date AS order_date,
    count(*) AS new_customers
   FROM public.v_customer_first_order
  GROUP BY brand_id, (((first_ordered_at AT TIME ZONE 'Asia/Bangkok'::text))::date);


--
-- Name: v_pending_customer_review; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_pending_customer_review WITH (security_invoker='true') AS
 SELECT r.id,
    b.name AS brand,
    r.reason,
    r.score,
    r.new_customer_id,
    nn.name AS new_name,
    nn.addr AS new_addr,
    nn.phones AS new_phones,
    r.candidate_customer_id,
    cn.name AS cand_name,
    cn.addr AS cand_addr,
    cn.phones AS cand_phones,
    r.created_at
   FROM (((public.customer_review r
     JOIN public.brands b ON ((b.id = r.brand_id)))
     LEFT JOIN LATERAL ( SELECT o.customer_name AS name,
            concat_ws(' '::text, o.addr_detail, o.subdistrict, o.district, o.province, o.postal_code) AS addr,
            ( SELECT string_agg(cp.phone, ', '::text) AS string_agg
                   FROM public.customer_phones cp
                  WHERE (cp.customer_id = r.new_customer_id)) AS phones
           FROM public.orders o
          WHERE (o.customer_id = r.new_customer_id)
          ORDER BY o.ordered_at DESC
         LIMIT 1) nn ON (true))
     LEFT JOIN LATERAL ( SELECT o.customer_name AS name,
            concat_ws(' '::text, o.addr_detail, o.subdistrict, o.district, o.province, o.postal_code) AS addr,
            ( SELECT string_agg(cp.phone, ', '::text) AS string_agg
                   FROM public.customer_phones cp
                  WHERE (cp.customer_id = r.candidate_customer_id)) AS phones
           FROM public.orders o
          WHERE (o.customer_id = r.candidate_customer_id)
          ORDER BY o.ordered_at DESC
         LIMIT 1) cn ON (true))
  WHERE (r.status = 'pending'::text)
  ORDER BY r.score DESC;


--
-- Name: v_product_catalog; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_product_catalog WITH (security_invoker='true') AS
 SELECT p.id AS product_id,
    b.id AS brand_id,
    b.name AS brand_name,
    c.id AS category_id,
    c.name AS category_name,
    p.name AS product_name,
    p.code,
    p.is_freebie,
    p.is_active,
    p.created_at,
    p.updated_at
   FROM ((public.products p
     JOIN public.categories c ON ((c.id = p.category_id)))
     JOIN public.brands b ON ((b.id = c.brand_id)));


--
-- Name: _stg_hist k; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public._stg_hist ALTER COLUMN k SET DEFAULT nextval('public._stg_hist_k_seq'::regclass);


--
-- Name: _stg_hist _stg_hist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public._stg_hist
    ADD CONSTRAINT _stg_hist_pkey PRIMARY KEY (k);


--
-- Name: app_user_teams app_user_teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user_teams
    ADD CONSTRAINT app_user_teams_pkey PRIMARY KEY (user_id, team_id);


--
-- Name: app_user_views app_user_views_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user_views
    ADD CONSTRAINT app_user_views_pkey PRIMARY KEY (user_id, page);


--
-- Name: app_users app_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_users
    ADD CONSTRAINT app_users_pkey PRIMARY KEY (id);


--
-- Name: app_users app_users_username_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_users
    ADD CONSTRAINT app_users_username_key UNIQUE (username);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: auth_login_tickets auth_login_tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_login_tickets
    ADD CONSTRAINT auth_login_tickets_pkey PRIMARY KEY (id);


--
-- Name: auth_sessions auth_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_pkey PRIMARY KEY (id);


--
-- Name: auth_sessions auth_sessions_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_token_hash_key UNIQUE (token_hash);


--
-- Name: brands brands_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_name_key UNIQUE (name);


--
-- Name: brands brands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_pkey PRIMARY KEY (id);


--
-- Name: categories categories_brand_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_brand_id_name_key UNIQUE (brand_id, name);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: customer_phones customer_phones_brand_phone_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_phones
    ADD CONSTRAINT customer_phones_brand_phone_key UNIQUE (brand_id, phone);


--
-- Name: customer_phones customer_phones_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_phones
    ADD CONSTRAINT customer_phones_pkey PRIMARY KEY (id);


--
-- Name: customer_review customer_review_pair_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_review
    ADD CONSTRAINT customer_review_pair_uniq UNIQUE (new_customer_id, candidate_customer_id);


--
-- Name: customer_review customer_review_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_review
    ADD CONSTRAINT customer_review_pkey PRIMARY KEY (id);


--
-- Name: customers customers_id_brand_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_id_brand_id_key UNIQUE (id, brand_id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: note_highlights note_highlights_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_highlights
    ADD CONSTRAINT note_highlights_pkey PRIMARY KEY (note_id, user_id);


--
-- Name: order_items order_items_order_product_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_order_product_key UNIQUE (order_id, product_id);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);


--
-- Name: order_tracking order_tracking_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_tracking
    ADD CONSTRAINT order_tracking_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: products products_category_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_category_id_name_key UNIQUE (category_id, name);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: recon_cod_payments recon_cod_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recon_cod_payments
    ADD CONSTRAINT recon_cod_payments_pkey PRIMARY KEY (id);


--
-- Name: recon_returns recon_returns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recon_returns
    ADD CONSTRAINT recon_returns_pkey PRIMARY KEY (id);


--
-- Name: return_conflicts return_conflicts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_conflicts
    ADD CONSTRAINT return_conflicts_pkey PRIMARY KEY (id);


--
-- Name: sellers sellers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sellers
    ADD CONSTRAINT sellers_pkey PRIMARY KEY (id);


--
-- Name: teams teams_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_name_key UNIQUE (name);


--
-- Name: teams teams_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.teams
    ADD CONSTRAINT teams_pkey PRIMARY KEY (id);


--
-- Name: tracking_detail_presets tracking_detail_presets_kind_label_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracking_detail_presets
    ADD CONSTRAINT tracking_detail_presets_kind_label_key UNIQUE (kind, label);


--
-- Name: tracking_detail_presets tracking_detail_presets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracking_detail_presets
    ADD CONSTRAINT tracking_detail_presets_pkey PRIMARY KEY (id);


--
-- Name: customer_phones_customer_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_phones_customer_id_idx ON public.customer_phones USING btree (customer_id);


--
-- Name: customer_review_cand_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_review_cand_idx ON public.customer_review USING btree (candidate_customer_id);


--
-- Name: customer_review_new_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_review_new_idx ON public.customer_review USING btree (new_customer_id);


--
-- Name: customer_review_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customer_review_status_idx ON public.customer_review USING btree (status);


--
-- Name: customers_brand_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX customers_brand_id_idx ON public.customers USING btree (brand_id);


--
-- Name: idx_app_user_teams_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_app_user_teams_user ON public.app_user_teams USING btree (user_id);


--
-- Name: idx_audit_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_created ON public.audit_log USING btree (created_at DESC);


--
-- Name: idx_sellers_team_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sellers_team_id ON public.sellers USING btree (team_id);


--
-- Name: idx_sessions_token; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sessions_token ON public.auth_sessions USING btree (token_hash);


--
-- Name: idx_tickets_user_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tickets_user_created ON public.auth_login_tickets USING btree (user_id, created_at);


--
-- Name: note_highlights_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX note_highlights_user_idx ON public.note_highlights USING btree (user_id);


--
-- Name: order_items_order_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX order_items_order_id_idx ON public.order_items USING btree (order_id);


--
-- Name: order_items_product_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX order_items_product_id_idx ON public.order_items USING btree (product_id);


--
-- Name: order_tracking_order_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX order_tracking_order_created_idx ON public.order_tracking USING btree (order_id, created_at DESC);


--
-- Name: orders_addr_parts_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_addr_parts_idx ON public.orders USING btree (brand_id, province, district, subdistrict, postal_code);


--
-- Name: orders_brand_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_brand_id_idx ON public.orders USING btree (brand_id);


--
-- Name: orders_customer_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_customer_id_idx ON public.orders USING btree (customer_id);


--
-- Name: orders_customer_name_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_customer_name_trgm ON public.orders USING gin (public.norm_name(customer_name) extensions.gin_trgm_ops);


--
-- Name: orders_error_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_error_idx ON public.orders USING btree (ordered_at) WHERE (payment_status = 'error'::text);


--
-- Name: orders_noseller_coalesce_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_noseller_coalesce_idx ON public.orders USING btree (brand_id) WHERE ((seller_id IS NULL) AND (NOT COALESCE(seller_waived, false)));


--
-- Name: orders_noseller_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_noseller_idx ON public.orders USING btree (ordered_at) WHERE ((seller_id IS NULL) AND (NOT seller_waived));


--
-- Name: orders_order_no_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_order_no_idx ON public.orders USING btree (order_no) WHERE (order_no IS NOT NULL);


--
-- Name: orders_ordered_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_ordered_at_idx ON public.orders USING btree (ordered_at);


--
-- Name: orders_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_pending_idx ON public.orders USING btree (ordered_at) WHERE ((payment_status <> 'ไม่ใช่งานขาย'::text) AND ((delivery_status = 'กำลังส่ง'::text) OR (payment_status = ANY (ARRAY['รอชำระ'::text, 'error'::text])) OR ((delivery_status = 'ตีกลับ'::text) AND (NOT COALESCE(return_arrived, false)))));


--
-- Name: orders_recon_conflict_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_recon_conflict_idx ON public.orders USING btree (ordered_at) WHERE COALESCE(recon_conflict, false);


--
-- Name: orders_seller_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_seller_id_idx ON public.orders USING btree (seller_id);


--
-- Name: orders_tracking_btrim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_tracking_btrim_idx ON public.orders USING btree (btrim(tracking_no));


--
-- Name: orders_tracking_coalesce_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX orders_tracking_coalesce_idx ON public.orders USING btree (btrim(COALESCE(tracking_no, ''::text)));


--
-- Name: recon_cod_btrim_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX recon_cod_btrim_idx ON public.recon_cod_payments USING btree (btrim(tracking_out));


--
-- Name: recon_cod_tracking_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX recon_cod_tracking_idx ON public.recon_cod_payments USING btree (tracking_out);


--
-- Name: recon_returns_tracking_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX recon_returns_tracking_idx ON public.recon_returns USING btree (tracking_out);


--
-- Name: recon_returns_tracking_out_uidx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX recon_returns_tracking_out_uidx ON public.recon_returns USING btree (btrim(tracking_out));


--
-- Name: return_conflicts_pending_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX return_conflicts_pending_idx ON public.return_conflicts USING btree (status, created_at DESC);


--
-- Name: sellers_active_employee_code_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX sellers_active_employee_code_key ON public.sellers USING btree (employee_code) WHERE is_active;


--
-- Name: tracking_detail_presets_kind_order_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tracking_detail_presets_kind_order_idx ON public.tracking_detail_presets USING btree (kind, sort_order, id);


--
-- Name: order_items order_items_brand_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER order_items_brand_guard BEFORE INSERT OR UPDATE ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.check_order_item_brand();


--
-- Name: orders orders_clear_paid_amount; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER orders_clear_paid_amount BEFORE INSERT OR UPDATE OF payment_status, paid_amount ON public.orders FOR EACH ROW EXECUTE FUNCTION public.orders_clear_paid_amount();


--
-- Name: orders orders_recon_after_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER orders_recon_after_insert AFTER INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.trg_order_after_insert();


--
-- Name: recon_cod_payments recon_cod_after_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recon_cod_after_delete AFTER DELETE ON public.recon_cod_payments FOR EACH ROW EXECUTE FUNCTION public.trg_recon_after_delete();


--
-- Name: recon_cod_payments recon_cod_after_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recon_cod_after_insert AFTER INSERT ON public.recon_cod_payments FOR EACH ROW EXECUTE FUNCTION public.trg_recon_after_insert();


--
-- Name: recon_returns recon_returns_after_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recon_returns_after_delete AFTER DELETE ON public.recon_returns FOR EACH ROW EXECUTE FUNCTION public.trg_recon_after_delete();


--
-- Name: recon_returns recon_returns_after_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER recon_returns_after_insert AFTER INSERT ON public.recon_returns FOR EACH ROW EXECUTE FUNCTION public.trg_recon_after_insert();


--
-- Name: app_users set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.app_users FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: customer_phones set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.customer_phones FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: customers set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.customers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: order_items set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: orders set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: sellers set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.sellers FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: brands trg_brands_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_brands_updated_at BEFORE UPDATE ON public.brands FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: categories trg_categories_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_categories_updated_at BEFORE UPDATE ON public.categories FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: products trg_products_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_products_updated_at BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();


--
-- Name: app_user_teams app_user_teams_team_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user_teams
    ADD CONSTRAINT app_user_teams_team_id_fkey FOREIGN KEY (team_id) REFERENCES public.teams(id) ON DELETE CASCADE;


--
-- Name: app_user_teams app_user_teams_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user_teams
    ADD CONSTRAINT app_user_teams_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE CASCADE;


--
-- Name: app_user_views app_user_views_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.app_user_views
    ADD CONSTRAINT app_user_views_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE CASCADE;


--
-- Name: audit_log audit_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE SET NULL;


--
-- Name: auth_login_tickets auth_login_tickets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_login_tickets
    ADD CONSTRAINT auth_login_tickets_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE CASCADE;


--
-- Name: auth_sessions auth_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_sessions
    ADD CONSTRAINT auth_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE CASCADE;


--
-- Name: categories categories_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE RESTRICT;


--
-- Name: customer_phones customer_phones_customer_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_phones
    ADD CONSTRAINT customer_phones_customer_fkey FOREIGN KEY (customer_id, brand_id) REFERENCES public.customers(id, brand_id) ON DELETE CASCADE;


--
-- Name: customer_review customer_review_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_review
    ADD CONSTRAINT customer_review_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: customer_review customer_review_candidate_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_review
    ADD CONSTRAINT customer_review_candidate_customer_id_fkey FOREIGN KEY (candidate_customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: customer_review customer_review_new_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_review
    ADD CONSTRAINT customer_review_new_customer_id_fkey FOREIGN KEY (new_customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: customers customers_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE RESTRICT;


--
-- Name: note_highlights note_highlights_note_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_highlights
    ADD CONSTRAINT note_highlights_note_id_fkey FOREIGN KEY (note_id) REFERENCES public.order_tracking(id) ON DELETE CASCADE;


--
-- Name: note_highlights note_highlights_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.note_highlights
    ADD CONSTRAINT note_highlights_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.app_users(id) ON DELETE CASCADE;


--
-- Name: order_items order_items_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_items order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: order_tracking order_tracking_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_tracking
    ADD CONSTRAINT order_tracking_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.app_users(id);


--
-- Name: order_tracking order_tracking_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_tracking
    ADD CONSTRAINT order_tracking_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: orders orders_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE RESTRICT;


--
-- Name: orders orders_customer_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_customer_fkey FOREIGN KEY (customer_id, brand_id) REFERENCES public.customers(id, brand_id) ON DELETE RESTRICT;


--
-- Name: orders orders_seller_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_seller_id_fkey FOREIGN KEY (seller_id) REFERENCES public.sellers(id) ON DELETE RESTRICT;


--
-- Name: products products_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE RESTRICT;


--
-- Name: recon_cod_payments recon_cod_payments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recon_cod_payments
    ADD CONSTRAINT recon_cod_payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.app_users(id);


--
-- Name: recon_returns recon_returns_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recon_returns
    ADD CONSTRAINT recon_returns_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.app_users(id);


--
-- Name: return_conflicts return_conflicts_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.return_conflicts
    ADD CONSTRAINT return_conflicts_resolved_by_fkey FOREIGN KEY (resolved_by) REFERENCES public.app_users(id);


--
-- Name: sellers sellers_team_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sellers
    ADD CONSTRAINT sellers_team_id_fkey FOREIGN KEY (team_id) REFERENCES public.teams(id) ON DELETE SET NULL;


--
-- Name: tracking_detail_presets tracking_detail_presets_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tracking_detail_presets
    ADD CONSTRAINT tracking_detail_presets_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.app_users(id);


--
-- Name: app_user_teams; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_user_teams ENABLE ROW LEVEL SECURITY;

--
-- Name: app_users; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.app_users ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_log; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

--
-- Name: auth_login_tickets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.auth_login_tickets ENABLE ROW LEVEL SECURITY;

--
-- Name: auth_sessions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.auth_sessions ENABLE ROW LEVEL SECURITY;

--
-- Name: brands; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.brands ENABLE ROW LEVEL SECURITY;

--
-- Name: categories; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_phones; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_phones ENABLE ROW LEVEL SECURITY;

--
-- Name: customer_review; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customer_review ENABLE ROW LEVEL SECURITY;

--
-- Name: customers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.customers ENABLE ROW LEVEL SECURITY;

--
-- Name: order_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;

--
-- Name: order_tracking; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.order_tracking ENABLE ROW LEVEL SECURITY;

--
-- Name: orders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;

--
-- Name: products; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;

--
-- Name: brands read brands for authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read brands for authenticated" ON public.brands FOR SELECT TO authenticated USING (true);


--
-- Name: categories read categories for authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read categories for authenticated" ON public.categories FOR SELECT TO authenticated USING (true);


--
-- Name: customer_phones read customer_phones for authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read customer_phones for authenticated" ON public.customer_phones FOR SELECT TO authenticated USING (true);


--
-- Name: customer_review read customer_review for authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read customer_review for authenticated" ON public.customer_review FOR SELECT TO authenticated USING (true);


--
-- Name: customers read customers for authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read customers for authenticated" ON public.customers FOR SELECT TO authenticated USING (true);


--
-- Name: order_items read order_items for authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read order_items for authenticated" ON public.order_items FOR SELECT TO authenticated USING (true);


--
-- Name: orders read orders for authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read orders for authenticated" ON public.orders FOR SELECT TO authenticated USING (true);


--
-- Name: products read products for authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read products for authenticated" ON public.products FOR SELECT TO authenticated USING (true);


--
-- Name: sellers read sellers for authenticated; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "read sellers for authenticated" ON public.sellers FOR SELECT TO authenticated USING (true);


--
-- Name: recon_cod_payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recon_cod_payments ENABLE ROW LEVEL SECURITY;

--
-- Name: recon_returns; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recon_returns ENABLE ROW LEVEL SECURITY;

--
-- Name: sellers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.sellers ENABLE ROW LEVEL SECURITY;

--
-- Name: teams; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.teams ENABLE ROW LEVEL SECURITY;

--
-- Name: tracking_detail_presets; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.tracking_detail_presets ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION _dedup_key(t text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public._dedup_key(t text) TO anon;
GRANT ALL ON FUNCTION public._dedup_key(t text) TO authenticated;
GRANT ALL ON FUNCTION public._dedup_key(t text) TO service_role;


--
-- Name: FUNCTION _dedup_vals(p_cid bigint, p_other bigint, p_kind text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public._dedup_vals(p_cid bigint, p_other bigint, p_kind text) TO anon;
GRANT ALL ON FUNCTION public._dedup_vals(p_cid bigint, p_other bigint, p_kind text) TO authenticated;
GRANT ALL ON FUNCTION public._dedup_vals(p_cid bigint, p_other bigint, p_kind text) TO service_role;


--
-- Name: FUNCTION app_admin_create_user(p_token text, p_username text, p_display_name text, p_role text, p_all_teams boolean, p_team_ids jsonb, p_idle_minutes integer, p_session_hours integer, p_line_user_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_admin_create_user(p_token text, p_username text, p_display_name text, p_role text, p_all_teams boolean, p_team_ids jsonb, p_idle_minutes integer, p_session_hours integer, p_line_user_id text) TO anon;
GRANT ALL ON FUNCTION public.app_admin_create_user(p_token text, p_username text, p_display_name text, p_role text, p_all_teams boolean, p_team_ids jsonb, p_idle_minutes integer, p_session_hours integer, p_line_user_id text) TO authenticated;
GRANT ALL ON FUNCTION public.app_admin_create_user(p_token text, p_username text, p_display_name text, p_role text, p_all_teams boolean, p_team_ids jsonb, p_idle_minutes integer, p_session_hours integer, p_line_user_id text) TO service_role;


--
-- Name: FUNCTION app_admin_list_users(p_token text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_admin_list_users(p_token text) TO anon;
GRANT ALL ON FUNCTION public.app_admin_list_users(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.app_admin_list_users(p_token text) TO service_role;


--
-- Name: FUNCTION app_admin_reset_password(p_token text, p_user_id uuid, p_new_password text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_admin_reset_password(p_token text, p_user_id uuid, p_new_password text) TO anon;
GRANT ALL ON FUNCTION public.app_admin_reset_password(p_token text, p_user_id uuid, p_new_password text) TO authenticated;
GRANT ALL ON FUNCTION public.app_admin_reset_password(p_token text, p_user_id uuid, p_new_password text) TO service_role;


--
-- Name: FUNCTION app_admin_update_user(p_token text, p_user_id uuid, p_display_name text, p_role text, p_all_teams boolean, p_team_ids jsonb, p_is_active boolean, p_idle_minutes integer, p_session_hours integer, p_line_user_id text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_admin_update_user(p_token text, p_user_id uuid, p_display_name text, p_role text, p_all_teams boolean, p_team_ids jsonb, p_is_active boolean, p_idle_minutes integer, p_session_hours integer, p_line_user_id text) TO anon;
GRANT ALL ON FUNCTION public.app_admin_update_user(p_token text, p_user_id uuid, p_display_name text, p_role text, p_all_teams boolean, p_team_ids jsonb, p_is_active boolean, p_idle_minutes integer, p_session_hours integer, p_line_user_id text) TO authenticated;
GRANT ALL ON FUNCTION public.app_admin_update_user(p_token text, p_user_id uuid, p_display_name text, p_role text, p_all_teams boolean, p_team_ids jsonb, p_is_active boolean, p_idle_minutes integer, p_session_hours integer, p_line_user_id text) TO service_role;


--
-- Name: FUNCTION app_auth_login(p_username text, p_password text, p_ip text, p_ua text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_auth_login(p_username text, p_password text, p_ip text, p_ua text) TO anon;
GRANT ALL ON FUNCTION public.app_auth_login(p_username text, p_password text, p_ip text, p_ua text) TO authenticated;
GRANT ALL ON FUNCTION public.app_auth_login(p_username text, p_password text, p_ip text, p_ua text) TO service_role;


--
-- Name: FUNCTION app_auth_logout(p_token text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.app_auth_logout(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.app_auth_logout(p_token text) TO service_role;


--
-- Name: FUNCTION app_auth_verify(p_ticket uuid, p_code text, p_ip text, p_ua text, p_geo jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_auth_verify(p_ticket uuid, p_code text, p_ip text, p_ua text, p_geo jsonb) TO anon;
GRANT ALL ON FUNCTION public.app_auth_verify(p_ticket uuid, p_code text, p_ip text, p_ua text, p_geo jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.app_auth_verify(p_ticket uuid, p_code text, p_ip text, p_ua text, p_geo jsonb) TO service_role;


--
-- Name: FUNCTION app_bulk_set_delivery(p_token text, p_ids bigint[], p_status text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_bulk_set_delivery(p_token text, p_ids bigint[], p_status text) TO anon;
GRANT ALL ON FUNCTION public.app_bulk_set_delivery(p_token text, p_ids bigint[], p_status text) TO authenticated;
GRANT ALL ON FUNCTION public.app_bulk_set_delivery(p_token text, p_ids bigint[], p_status text) TO service_role;


--
-- Name: FUNCTION app_can_page(p_role text, p_page text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_can_page(p_role text, p_page text) TO anon;
GRANT ALL ON FUNCTION public.app_can_page(p_role text, p_page text) TO authenticated;
GRANT ALL ON FUNCTION public.app_can_page(p_role text, p_page text) TO service_role;


--
-- Name: FUNCTION app_check_return_photo(p_token text, p_photo text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_check_return_photo(p_token text, p_photo text) TO anon;
GRANT ALL ON FUNCTION public.app_check_return_photo(p_token text, p_photo text) TO authenticated;
GRANT ALL ON FUNCTION public.app_check_return_photo(p_token text, p_photo text) TO service_role;


--
-- Name: FUNCTION app_edit_note(p_token text, p_note_id bigint, p_note text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edit_note(p_token text, p_note_id bigint, p_note text) TO anon;
GRANT ALL ON FUNCTION public.app_edit_note(p_token text, p_note_id bigint, p_note text) TO authenticated;
GRANT ALL ON FUNCTION public.app_edit_note(p_token text, p_note_id bigint, p_note text) TO service_role;


--
-- Name: FUNCTION app_edith_confirm_return(p_token text, p_order_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_confirm_return(p_token text, p_order_id bigint) TO anon;
GRANT ALL ON FUNCTION public.app_edith_confirm_return(p_token text, p_order_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_confirm_return(p_token text, p_order_id bigint) TO service_role;


--
-- Name: FUNCTION app_edith_conflict_detail(p_token text, p_conflict_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_conflict_detail(p_token text, p_conflict_id bigint) TO anon;
GRANT ALL ON FUNCTION public.app_edith_conflict_detail(p_token text, p_conflict_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_conflict_detail(p_token text, p_conflict_id bigint) TO service_role;


--
-- Name: FUNCTION app_edith_dedup_detail(p_token text, p_review_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_dedup_detail(p_token text, p_review_id bigint) TO anon;
GRANT ALL ON FUNCTION public.app_edith_dedup_detail(p_token text, p_review_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_dedup_detail(p_token text, p_review_id bigint) TO service_role;


--
-- Name: FUNCTION app_edith_delete_recon(p_token text, p_kind text, p_order_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_delete_recon(p_token text, p_kind text, p_order_id bigint) TO anon;
GRANT ALL ON FUNCTION public.app_edith_delete_recon(p_token text, p_kind text, p_order_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_delete_recon(p_token text, p_kind text, p_order_id bigint) TO service_role;


--
-- Name: FUNCTION app_edith_dismiss_dup(p_token text, p_a bigint, p_b bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_dismiss_dup(p_token text, p_a bigint, p_b bigint) TO anon;
GRANT ALL ON FUNCTION public.app_edith_dismiss_dup(p_token text, p_a bigint, p_b bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_dismiss_dup(p_token text, p_a bigint, p_b bigint) TO service_role;


--
-- Name: FUNCTION app_edith_error_detail(p_token text, p_order_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_error_detail(p_token text, p_order_id bigint) TO anon;
GRANT ALL ON FUNCTION public.app_edith_error_detail(p_token text, p_order_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_error_detail(p_token text, p_order_id bigint) TO service_role;


--
-- Name: FUNCTION app_edith_exchange(p_token text, p_order_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_exchange(p_token text, p_order_id bigint) TO anon;
GRANT ALL ON FUNCTION public.app_edith_exchange(p_token text, p_order_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_exchange(p_token text, p_order_id bigint) TO service_role;


--
-- Name: FUNCTION app_edith_fix_cod_amount(p_token text, p_order_id bigint, p_new_amount numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_fix_cod_amount(p_token text, p_order_id bigint, p_new_amount numeric) TO anon;
GRANT ALL ON FUNCTION public.app_edith_fix_cod_amount(p_token text, p_order_id bigint, p_new_amount numeric) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_fix_cod_amount(p_token text, p_order_id bigint, p_new_amount numeric) TO service_role;


--
-- Name: FUNCTION app_edith_issues(p_token text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_issues(p_token text) TO anon;
GRANT ALL ON FUNCTION public.app_edith_issues(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_issues(p_token text) TO service_role;


--
-- Name: FUNCTION app_edith_log(p_token text, p_filter jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_log(p_token text, p_filter jsonb) TO anon;
GRANT ALL ON FUNCTION public.app_edith_log(p_token text, p_filter jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_log(p_token text, p_filter jsonb) TO service_role;


--
-- Name: FUNCTION app_edith_merge_customers(p_token text, p_keep bigint, p_dup bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_merge_customers(p_token text, p_keep bigint, p_dup bigint) TO anon;
GRANT ALL ON FUNCTION public.app_edith_merge_customers(p_token text, p_keep bigint, p_dup bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_merge_customers(p_token text, p_keep bigint, p_dup bigint) TO service_role;


--
-- Name: FUNCTION app_edith_noseller_detail(p_token text, p_order_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_noseller_detail(p_token text, p_order_id bigint) TO anon;
GRANT ALL ON FUNCTION public.app_edith_noseller_detail(p_token text, p_order_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_noseller_detail(p_token text, p_order_id bigint) TO service_role;


--
-- Name: FUNCTION app_edith_recon_detail(p_token text, p_order_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_recon_detail(p_token text, p_order_id bigint) TO anon;
GRANT ALL ON FUNCTION public.app_edith_recon_detail(p_token text, p_order_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_recon_detail(p_token text, p_order_id bigint) TO service_role;


--
-- Name: FUNCTION app_edith_resolve_conflict(p_token text, p_conflict_id bigint, p_chosen_idx integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_resolve_conflict(p_token text, p_conflict_id bigint, p_chosen_idx integer) TO anon;
GRANT ALL ON FUNCTION public.app_edith_resolve_conflict(p_token text, p_conflict_id bigint, p_chosen_idx integer) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_resolve_conflict(p_token text, p_conflict_id bigint, p_chosen_idx integer) TO service_role;


--
-- Name: FUNCTION app_edith_resolve_error(p_token text, p_order_id bigint, p_use text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_resolve_error(p_token text, p_order_id bigint, p_use text) TO anon;
GRANT ALL ON FUNCTION public.app_edith_resolve_error(p_token text, p_order_id bigint, p_use text) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_resolve_error(p_token text, p_order_id bigint, p_use text) TO service_role;


--
-- Name: FUNCTION app_edith_restore_recon(p_token text, p_kind text, p_payload jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_restore_recon(p_token text, p_kind text, p_payload jsonb) TO anon;
GRANT ALL ON FUNCTION public.app_edith_restore_recon(p_token text, p_kind text, p_payload jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_restore_recon(p_token text, p_kind text, p_payload jsonb) TO service_role;


--
-- Name: FUNCTION app_edith_sellers(p_token text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_sellers(p_token text) TO anon;
GRANT ALL ON FUNCTION public.app_edith_sellers(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_sellers(p_token text) TO service_role;


--
-- Name: FUNCTION app_edith_set_payment_status(p_token text, p_order_id bigint, p_status text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_set_payment_status(p_token text, p_order_id bigint, p_status text) TO anon;
GRANT ALL ON FUNCTION public.app_edith_set_payment_status(p_token text, p_order_id bigint, p_status text) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_set_payment_status(p_token text, p_order_id bigint, p_status text) TO service_role;


--
-- Name: FUNCTION app_edith_set_seller(p_token text, p_order_id bigint, p_seller_code text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_edith_set_seller(p_token text, p_order_id bigint, p_seller_code text) TO anon;
GRANT ALL ON FUNCTION public.app_edith_set_seller(p_token text, p_order_id bigint, p_seller_code text) TO authenticated;
GRANT ALL ON FUNCTION public.app_edith_set_seller(p_token text, p_order_id bigint, p_seller_code text) TO service_role;


--
-- Name: FUNCTION app_gen_password(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_gen_password() TO anon;
GRANT ALL ON FUNCTION public.app_gen_password() TO authenticated;
GRANT ALL ON FUNCTION public.app_gen_password() TO service_role;


--
-- Name: FUNCTION app_get_detail_presets(p_token text, p_kind text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_get_detail_presets(p_token text, p_kind text) TO anon;
GRANT ALL ON FUNCTION public.app_get_detail_presets(p_token text, p_kind text) TO authenticated;
GRANT ALL ON FUNCTION public.app_get_detail_presets(p_token text, p_kind text) TO service_role;


--
-- Name: FUNCTION app_get_order_tracking(p_token text, p_order_id bigint); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.app_get_order_tracking(p_token text, p_order_id bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION public.app_get_order_tracking(p_token text, p_order_id bigint) TO anon;
GRANT ALL ON FUNCTION public.app_get_order_tracking(p_token text, p_order_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_get_order_tracking(p_token text, p_order_id bigint) TO service_role;


--
-- Name: FUNCTION app_get_view(p_token text, p_page text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_get_view(p_token text, p_page text) TO anon;
GRANT ALL ON FUNCTION public.app_get_view(p_token text, p_page text) TO authenticated;
GRANT ALL ON FUNCTION public.app_get_view(p_token text, p_page text) TO service_role;


--
-- Name: FUNCTION app_import_cod_payments(p_token text, p_rows jsonb, p_mode text, p_fix_trackings jsonb, p_source text, p_confirm_partial boolean); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_import_cod_payments(p_token text, p_rows jsonb, p_mode text, p_fix_trackings jsonb, p_source text, p_confirm_partial boolean) TO anon;
GRANT ALL ON FUNCTION public.app_import_cod_payments(p_token text, p_rows jsonb, p_mode text, p_fix_trackings jsonb, p_source text, p_confirm_partial boolean) TO authenticated;
GRANT ALL ON FUNCTION public.app_import_cod_payments(p_token text, p_rows jsonb, p_mode text, p_fix_trackings jsonb, p_source text, p_confirm_partial boolean) TO service_role;


--
-- Name: FUNCTION app_import_history(p_token text, p_kind text, p_limit integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.app_import_history(p_token text, p_kind text, p_limit integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.app_import_history(p_token text, p_kind text, p_limit integer) TO anon;
GRANT ALL ON FUNCTION public.app_import_history(p_token text, p_kind text, p_limit integer) TO authenticated;
GRANT ALL ON FUNCTION public.app_import_history(p_token text, p_kind text, p_limit integer) TO service_role;


--
-- Name: FUNCTION app_import_orders(p_token text, p_rows jsonb, p_mode text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_import_orders(p_token text, p_rows jsonb, p_mode text) TO anon;
GRANT ALL ON FUNCTION public.app_import_orders(p_token text, p_rows jsonb, p_mode text) TO authenticated;
GRANT ALL ON FUNCTION public.app_import_orders(p_token text, p_rows jsonb, p_mode text) TO service_role;


--
-- Name: FUNCTION app_lookup_return_tracking(p_token text, p_tracking text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_lookup_return_tracking(p_token text, p_tracking text) TO anon;
GRANT ALL ON FUNCTION public.app_lookup_return_tracking(p_token text, p_tracking text) TO authenticated;
GRANT ALL ON FUNCTION public.app_lookup_return_tracking(p_token text, p_tracking text) TO service_role;


--
-- Name: FUNCTION app_note_marks(p_token text, p_order_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_note_marks(p_token text, p_order_id bigint) TO anon;
GRANT ALL ON FUNCTION public.app_note_marks(p_token text, p_order_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_note_marks(p_token text, p_order_id bigint) TO service_role;


--
-- Name: FUNCTION app_notifications(p_token text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_notifications(p_token text) TO anon;
GRANT ALL ON FUNCTION public.app_notifications(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.app_notifications(p_token text) TO service_role;


--
-- Name: FUNCTION app_returns_list(p_token text, p_cycle text, p_mode text, p_team_id bigint, p_seller_code text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_returns_list(p_token text, p_cycle text, p_mode text, p_team_id bigint, p_seller_code text) TO anon;
GRANT ALL ON FUNCTION public.app_returns_list(p_token text, p_cycle text, p_mode text, p_team_id bigint, p_seller_code text) TO authenticated;
GRANT ALL ON FUNCTION public.app_returns_list(p_token text, p_cycle text, p_mode text, p_team_id bigint, p_seller_code text) TO service_role;


--
-- Name: FUNCTION app_returns_signal(p_token text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_returns_signal(p_token text) TO anon;
GRANT ALL ON FUNCTION public.app_returns_signal(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.app_returns_signal(p_token text) TO service_role;


--
-- Name: FUNCTION app_returns_stats(p_token text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_returns_stats(p_token text) TO anon;
GRANT ALL ON FUNCTION public.app_returns_stats(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.app_returns_stats(p_token text) TO service_role;


--
-- Name: FUNCTION app_sales_dashboard(p_token text, p_gran text, p_from date, p_to date, p_brand text, p_team bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_sales_dashboard(p_token text, p_gran text, p_from date, p_to date, p_brand text, p_team bigint) TO anon;
GRANT ALL ON FUNCTION public.app_sales_dashboard(p_token text, p_gran text, p_from date, p_to date, p_brand text, p_team bigint) TO authenticated;
GRANT ALL ON FUNCTION public.app_sales_dashboard(p_token text, p_gran text, p_from date, p_to date, p_brand text, p_team bigint) TO service_role;


--
-- Name: FUNCTION app_sales_dashboard_teams(p_token text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_sales_dashboard_teams(p_token text) TO anon;
GRANT ALL ON FUNCTION public.app_sales_dashboard_teams(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.app_sales_dashboard_teams(p_token text) TO service_role;


--
-- Name: FUNCTION app_save_note_marks(p_token text, p_note_id bigint, p_marks jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_save_note_marks(p_token text, p_note_id bigint, p_marks jsonb) TO anon;
GRANT ALL ON FUNCTION public.app_save_note_marks(p_token text, p_note_id bigint, p_marks jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.app_save_note_marks(p_token text, p_note_id bigint, p_marks jsonb) TO service_role;


--
-- Name: FUNCTION app_save_order_tracking(p_token text, p_order_id bigint, p_delivery_status text, p_payment_status text, p_return_reason text, p_status_detail text, p_note text, p_paid_amount numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_save_order_tracking(p_token text, p_order_id bigint, p_delivery_status text, p_payment_status text, p_return_reason text, p_status_detail text, p_note text, p_paid_amount numeric) TO anon;
GRANT ALL ON FUNCTION public.app_save_order_tracking(p_token text, p_order_id bigint, p_delivery_status text, p_payment_status text, p_return_reason text, p_status_detail text, p_note text, p_paid_amount numeric) TO authenticated;
GRANT ALL ON FUNCTION public.app_save_order_tracking(p_token text, p_order_id bigint, p_delivery_status text, p_payment_status text, p_return_reason text, p_status_detail text, p_note text, p_paid_amount numeric) TO service_role;


--
-- Name: FUNCTION app_save_returns(p_token text, p_rows jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_save_returns(p_token text, p_rows jsonb) TO anon;
GRANT ALL ON FUNCTION public.app_save_returns(p_token text, p_rows jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.app_save_returns(p_token text, p_rows jsonb) TO service_role;


--
-- Name: FUNCTION app_save_view(p_token text, p_page text, p_data jsonb); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_save_view(p_token text, p_page text, p_data jsonb) TO anon;
GRANT ALL ON FUNCTION public.app_save_view(p_token text, p_page text, p_data jsonb) TO authenticated;
GRANT ALL ON FUNCTION public.app_save_view(p_token text, p_page text, p_data jsonb) TO service_role;


--
-- Name: FUNCTION app_search_orders(p_token text, p_query text, p_view text, p_field text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.app_search_orders(p_token text, p_query text, p_view text, p_field text) TO anon;
GRANT ALL ON FUNCTION public.app_search_orders(p_token text, p_query text, p_view text, p_field text) TO authenticated;
GRANT ALL ON FUNCTION public.app_search_orders(p_token text, p_query text, p_view text, p_field text) TO service_role;


--
-- Name: FUNCTION app_session_uid(p_token text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.app_session_uid(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.app_session_uid(p_token text) TO service_role;


--
-- Name: FUNCTION check_order_item_brand(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.check_order_item_brand() TO anon;
GRANT ALL ON FUNCTION public.check_order_item_brand() TO authenticated;
GRANT ALL ON FUNCTION public.check_order_item_brand() TO service_role;


--
-- Name: FUNCTION detect_customer_duplicates(p_since timestamp with time zone, p_thresh_name real, p_thresh_addr real); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.detect_customer_duplicates(p_since timestamp with time zone, p_thresh_name real, p_thresh_addr real) TO anon;
GRANT ALL ON FUNCTION public.detect_customer_duplicates(p_since timestamp with time zone, p_thresh_name real, p_thresh_addr real) TO authenticated;
GRANT ALL ON FUNCTION public.detect_customer_duplicates(p_since timestamp with time zone, p_thresh_name real, p_thresh_addr real) TO service_role;


--
-- Name: FUNCTION get_months(p_token text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_months(p_token text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_months(p_token text) TO anon;
GRANT ALL ON FUNCTION public.get_months(p_token text) TO authenticated;
GRANT ALL ON FUNCTION public.get_months(p_token text) TO service_role;


--
-- Name: FUNCTION get_orders(p_token text, p_month text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.get_orders(p_token text, p_month text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_orders(p_token text, p_month text) TO anon;
GRANT ALL ON FUNCTION public.get_orders(p_token text, p_month text) TO authenticated;
GRANT ALL ON FUNCTION public.get_orders(p_token text, p_month text) TO service_role;


--
-- Name: FUNCTION is_paid_status(p text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.is_paid_status(p text) TO anon;
GRANT ALL ON FUNCTION public.is_paid_status(p text) TO authenticated;
GRANT ALL ON FUNCTION public.is_paid_status(p text) TO service_role;


--
-- Name: FUNCTION merge_customers(p_keep bigint, p_dup bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.merge_customers(p_keep bigint, p_dup bigint) TO anon;
GRANT ALL ON FUNCTION public.merge_customers(p_keep bigint, p_dup bigint) TO authenticated;
GRANT ALL ON FUNCTION public.merge_customers(p_keep bigint, p_dup bigint) TO service_role;


--
-- Name: FUNCTION norm_name(t text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.norm_name(t text) TO anon;
GRANT ALL ON FUNCTION public.norm_name(t text) TO authenticated;
GRANT ALL ON FUNCTION public.norm_name(t text) TO service_role;


--
-- Name: FUNCTION orders_clear_paid_amount(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.orders_clear_paid_amount() TO anon;
GRANT ALL ON FUNCTION public.orders_clear_paid_amount() TO authenticated;
GRANT ALL ON FUNCTION public.orders_clear_paid_amount() TO service_role;


--
-- Name: FUNCTION qty_txt(n integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.qty_txt(n integer) TO anon;
GRANT ALL ON FUNCTION public.qty_txt(n integer) TO authenticated;
GRANT ALL ON FUNCTION public.qty_txt(n integer) TO service_role;


--
-- Name: FUNCTION reconcile_order(p_order_id bigint); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.reconcile_order(p_order_id bigint) TO anon;
GRANT ALL ON FUNCTION public.reconcile_order(p_order_id bigint) TO authenticated;
GRANT ALL ON FUNCTION public.reconcile_order(p_order_id bigint) TO service_role;


--
-- Name: FUNCTION revert_recon_effects(p_tracking text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.revert_recon_effects(p_tracking text) TO anon;
GRANT ALL ON FUNCTION public.revert_recon_effects(p_tracking text) TO authenticated;
GRANT ALL ON FUNCTION public.revert_recon_effects(p_tracking text) TO service_role;


--
-- Name: FUNCTION revert_return_effects(p_tracking text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.revert_return_effects(p_tracking text) TO anon;
GRANT ALL ON FUNCTION public.revert_return_effects(p_tracking text) TO authenticated;
GRANT ALL ON FUNCTION public.revert_return_effects(p_tracking text) TO service_role;


--
-- Name: FUNCTION search_match(p_field text, p_q text, p_phone text, p_name text, p_addr text, p_trk text, p_note text); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON FUNCTION public.search_match(p_field text, p_q text, p_phone text, p_name text, p_addr text, p_trk text, p_note text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.search_match(p_field text, p_q text, p_phone text, p_name text, p_addr text, p_trk text, p_note text) TO service_role;


--
-- Name: FUNCTION set_updated_at(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.set_updated_at() TO anon;
GRANT ALL ON FUNCTION public.set_updated_at() TO authenticated;
GRANT ALL ON FUNCTION public.set_updated_at() TO service_role;


--
-- Name: FUNCTION trg_order_after_insert(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.trg_order_after_insert() TO anon;
GRANT ALL ON FUNCTION public.trg_order_after_insert() TO authenticated;
GRANT ALL ON FUNCTION public.trg_order_after_insert() TO service_role;


--
-- Name: FUNCTION trg_recon_after_delete(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.trg_recon_after_delete() TO anon;
GRANT ALL ON FUNCTION public.trg_recon_after_delete() TO authenticated;
GRANT ALL ON FUNCTION public.trg_recon_after_delete() TO service_role;


--
-- Name: FUNCTION trg_recon_after_insert(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.trg_recon_after_insert() TO anon;
GRANT ALL ON FUNCTION public.trg_recon_after_insert() TO authenticated;
GRANT ALL ON FUNCTION public.trg_recon_after_insert() TO service_role;


--
-- Name: TABLE _bak_hist_import; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public._bak_hist_import TO service_role;


--
-- Name: TABLE _bak_merge_a_20260928; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public._bak_merge_a_20260928 TO service_role;


--
-- Name: TABLE _bak_merge_b_20260928; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public._bak_merge_b_20260928 TO service_role;


--
-- Name: TABLE _bak_merge_c_20260928; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public._bak_merge_c_20260928 TO service_role;


--
-- Name: TABLE _bak_merge_n_20260928; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public._bak_merge_n_20260928 TO service_role;


--
-- Name: TABLE _stg_hist; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public._stg_hist TO service_role;


--
-- Name: SEQUENCE _stg_hist_k_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public._stg_hist_k_seq TO anon;
GRANT ALL ON SEQUENCE public._stg_hist_k_seq TO authenticated;
GRANT ALL ON SEQUENCE public._stg_hist_k_seq TO service_role;


--
-- Name: TABLE app_user_teams; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.app_user_teams TO anon;
GRANT ALL ON TABLE public.app_user_teams TO authenticated;
GRANT ALL ON TABLE public.app_user_teams TO service_role;


--
-- Name: TABLE app_user_views; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.app_user_views TO service_role;


--
-- Name: TABLE app_users; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.app_users TO anon;
GRANT ALL ON TABLE public.app_users TO authenticated;
GRANT ALL ON TABLE public.app_users TO service_role;


--
-- Name: TABLE audit_log; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.audit_log TO anon;
GRANT ALL ON TABLE public.audit_log TO authenticated;
GRANT ALL ON TABLE public.audit_log TO service_role;


--
-- Name: SEQUENCE audit_log_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.audit_log_id_seq TO anon;
GRANT ALL ON SEQUENCE public.audit_log_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.audit_log_id_seq TO service_role;


--
-- Name: TABLE auth_login_tickets; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.auth_login_tickets TO anon;
GRANT ALL ON TABLE public.auth_login_tickets TO authenticated;
GRANT ALL ON TABLE public.auth_login_tickets TO service_role;


--
-- Name: TABLE auth_sessions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.auth_sessions TO anon;
GRANT ALL ON TABLE public.auth_sessions TO authenticated;
GRANT ALL ON TABLE public.auth_sessions TO service_role;


--
-- Name: TABLE brands; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.brands TO anon;
GRANT ALL ON TABLE public.brands TO authenticated;
GRANT ALL ON TABLE public.brands TO service_role;


--
-- Name: SEQUENCE brands_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.brands_id_seq TO anon;
GRANT ALL ON SEQUENCE public.brands_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.brands_id_seq TO service_role;


--
-- Name: TABLE categories; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.categories TO anon;
GRANT ALL ON TABLE public.categories TO authenticated;
GRANT ALL ON TABLE public.categories TO service_role;


--
-- Name: SEQUENCE categories_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.categories_id_seq TO anon;
GRANT ALL ON SEQUENCE public.categories_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.categories_id_seq TO service_role;


--
-- Name: TABLE customer_phones; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customer_phones TO anon;
GRANT ALL ON TABLE public.customer_phones TO authenticated;
GRANT ALL ON TABLE public.customer_phones TO service_role;


--
-- Name: SEQUENCE customer_phones_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.customer_phones_id_seq TO anon;
GRANT ALL ON SEQUENCE public.customer_phones_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.customer_phones_id_seq TO service_role;


--
-- Name: TABLE customer_review; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customer_review TO anon;
GRANT ALL ON TABLE public.customer_review TO authenticated;
GRANT ALL ON TABLE public.customer_review TO service_role;


--
-- Name: SEQUENCE customer_review_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.customer_review_id_seq TO anon;
GRANT ALL ON SEQUENCE public.customer_review_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.customer_review_id_seq TO service_role;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customers TO anon;
GRANT ALL ON TABLE public.customers TO authenticated;
GRANT ALL ON TABLE public.customers TO service_role;


--
-- Name: SEQUENCE customers_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.customers_id_seq TO anon;
GRANT ALL ON SEQUENCE public.customers_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.customers_id_seq TO service_role;


--
-- Name: TABLE note_highlights; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.note_highlights TO service_role;


--
-- Name: TABLE order_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.order_items TO anon;
GRANT ALL ON TABLE public.order_items TO authenticated;
GRANT ALL ON TABLE public.order_items TO service_role;


--
-- Name: SEQUENCE order_items_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.order_items_id_seq TO anon;
GRANT ALL ON SEQUENCE public.order_items_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.order_items_id_seq TO service_role;


--
-- Name: TABLE order_tracking; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.order_tracking TO anon;
GRANT ALL ON TABLE public.order_tracking TO authenticated;
GRANT ALL ON TABLE public.order_tracking TO service_role;


--
-- Name: SEQUENCE order_tracking_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.order_tracking_id_seq TO anon;
GRANT ALL ON SEQUENCE public.order_tracking_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.order_tracking_id_seq TO service_role;


--
-- Name: TABLE orders; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.orders TO anon;
GRANT ALL ON TABLE public.orders TO authenticated;
GRANT ALL ON TABLE public.orders TO service_role;


--
-- Name: SEQUENCE orders_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.orders_id_seq TO anon;
GRANT ALL ON SEQUENCE public.orders_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.orders_id_seq TO service_role;


--
-- Name: TABLE products; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.products TO anon;
GRANT ALL ON TABLE public.products TO authenticated;
GRANT ALL ON TABLE public.products TO service_role;


--
-- Name: SEQUENCE products_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.products_id_seq TO anon;
GRANT ALL ON SEQUENCE public.products_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.products_id_seq TO service_role;


--
-- Name: TABLE recon_cod_payments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recon_cod_payments TO anon;
GRANT ALL ON TABLE public.recon_cod_payments TO authenticated;
GRANT ALL ON TABLE public.recon_cod_payments TO service_role;


--
-- Name: SEQUENCE recon_cod_payments_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.recon_cod_payments_id_seq TO anon;
GRANT ALL ON SEQUENCE public.recon_cod_payments_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recon_cod_payments_id_seq TO service_role;


--
-- Name: TABLE recon_returns; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recon_returns TO anon;
GRANT ALL ON TABLE public.recon_returns TO authenticated;
GRANT ALL ON TABLE public.recon_returns TO service_role;


--
-- Name: SEQUENCE recon_returns_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.recon_returns_id_seq TO anon;
GRANT ALL ON SEQUENCE public.recon_returns_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.recon_returns_id_seq TO service_role;


--
-- Name: TABLE return_conflicts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.return_conflicts TO service_role;


--
-- Name: SEQUENCE return_conflicts_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.return_conflicts_id_seq TO anon;
GRANT ALL ON SEQUENCE public.return_conflicts_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.return_conflicts_id_seq TO service_role;


--
-- Name: TABLE sellers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.sellers TO anon;
GRANT ALL ON TABLE public.sellers TO authenticated;
GRANT ALL ON TABLE public.sellers TO service_role;


--
-- Name: SEQUENCE sellers_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.sellers_id_seq TO anon;
GRANT ALL ON SEQUENCE public.sellers_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.sellers_id_seq TO service_role;


--
-- Name: TABLE teams; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.teams TO anon;
GRANT ALL ON TABLE public.teams TO authenticated;
GRANT ALL ON TABLE public.teams TO service_role;


--
-- Name: SEQUENCE teams_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.teams_id_seq TO anon;
GRANT ALL ON SEQUENCE public.teams_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.teams_id_seq TO service_role;


--
-- Name: TABLE tracking_detail_presets; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tracking_detail_presets TO anon;
GRANT ALL ON TABLE public.tracking_detail_presets TO authenticated;
GRANT ALL ON TABLE public.tracking_detail_presets TO service_role;


--
-- Name: SEQUENCE tracking_detail_presets_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.tracking_detail_presets_id_seq TO anon;
GRANT ALL ON SEQUENCE public.tracking_detail_presets_id_seq TO authenticated;
GRANT ALL ON SEQUENCE public.tracking_detail_presets_id_seq TO service_role;


--
-- Name: TABLE v_customer_first_order; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_customer_first_order TO anon;
GRANT ALL ON TABLE public.v_customer_first_order TO authenticated;
GRANT ALL ON TABLE public.v_customer_first_order TO service_role;


--
-- Name: TABLE v_new_customers_daily; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_new_customers_daily TO anon;
GRANT ALL ON TABLE public.v_new_customers_daily TO authenticated;
GRANT ALL ON TABLE public.v_new_customers_daily TO service_role;


--
-- Name: TABLE v_pending_customer_review; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_pending_customer_review TO anon;
GRANT ALL ON TABLE public.v_pending_customer_review TO authenticated;
GRANT ALL ON TABLE public.v_pending_customer_review TO service_role;


--
-- Name: TABLE v_product_catalog; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.v_product_catalog TO anon;
GRANT ALL ON TABLE public.v_product_catalog TO authenticated;
GRANT ALL ON TABLE public.v_product_catalog TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--


