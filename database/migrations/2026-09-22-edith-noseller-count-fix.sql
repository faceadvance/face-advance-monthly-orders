-- 2026-09-22 · แก้เลขบนชิป Noseller ให้ตรงกับจำนวนเคสในคิว
-- 🔴 บั๊กที่เพิ่งก่อ: เลิกกรอง MOCK ใน union แต่ลืมแก้ก้อน counts → คิวโชว์ 40 แต่ชิปบอก 33
-- บทเรียน: app_edith_issues มีเงื่อนไขเดียวกัน 2 ที่ (union + counts) แก้ที่เดียวไม่พอ

CREATE OR REPLACE FUNCTION public.app_edith_issues(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
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
end $function$;
