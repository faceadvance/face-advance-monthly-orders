-- ============================================================
-- ลบเคสเดโม EDITH (ติดป้าย EDITHTEST) — ใช้ก่อน go-live หรือเมื่อไม่ต้องการแล้ว
-- สร้างโดยฟรายเดย์ 2026-09-08 เพื่อให้เจ้านายลองใช้งาน resolver ครบ 4 ชนิด
-- atomic: พังก็ rollback ทั้งหมด · รันบน Supabase project xfayguljywhjwqcuimvw
-- ============================================================
do $$
declare oids bigint[]; custs bigint[];
begin
  select array_agg(id), array_agg(distinct customer_id)
    into oids, custs
    from public.orders where note = 'EDITHTEST';

  if oids is null then raise notice 'ไม่พบเคส EDITHTEST — ไม่มีอะไรให้ลบ'; return; end if;

  delete from public.order_items      where order_id = any(oids);
  delete from public.recon_cod_payments where tracking_out like 'EDITHTEST%';
  delete from public.recon_returns    where tracking_out like 'EDITHTEST%';
  delete from public.return_conflicts where tracking_out like 'EDITHTEST%';
  delete from public.customer_review  where new_customer_id = any(custs) or candidate_customer_id = any(custs);
  delete from public.orders           where note = 'EDITHTEST';
  delete from public.customer_phones  where customer_id = any(custs);
  delete from public.customers        where id = any(custs);

  raise notice 'ลบเคสเดโม EDITHTEST เรียบร้อย (orders=%, customers=%)', array_length(oids,1), array_length(custs,1);
end $$;
