-- ข้อมูลจำลองปี 2024 สำหรับทดสอบฟีเจอร์ — เจ้านายสั่ง 2026-09-22
-- "ทำไว้สักไม่กี่ออเดอร์ ในปี 2024 เพื่อให้ทดสอบงานเหล่านี้ด้วย ไม่ทดสอบกับข้อมูลจริงเด็ดขาด"
--
-- 🔴 เลขออเดอร์ขึ้นต้น MOCK24 → ถูกกรองออกจากรายงานทุกที่แล้ว
--    (app_sales_dashboard · app_edith_issues ใช้ LIKE 'MOCK%' ตั้งแต่ 2026-09-22-mock-filter-broaden.sql)
--    เลขพัสดุขึ้นต้น MOCK24TRK → ไม่ชนกับของจริง
--
-- ครอบเคสที่ต้องเทส:
--   · EDITH คิว "ไม่มีเซล"      → ออเดอร์ seller_id ว่าง + แบรนด์ไม่ใช่ตัวแทน (8 ใบ)
--   · ไฮไลท์โน้ต               → ออเดอร์ที่มีโน้ตในไทม์ไลน์ หลายบรรทัด/หลายคน (6 ใบ)
--   · จำนวนสินค้า = 0 (ไม่ทราบ) → order_items quantity 0 (ต้องแก้ CHECK ก่อน · ใส่ทีหลังแยกไฟล์)
--   · จำตัวกรอง / คอลัมน์กว้าง   → จำนวนแถวพอให้กรอง-เลื่อนได้ + สถานะหลากหลาย
--
-- ลบทิ้งได้ตลอด: database/seed/mock-2024-rollback.sql
-- รันซ้ำได้ (ลบของเดิมก่อนสร้างใหม่)

begin;

-- ลบของรอบก่อน (idempotent) — order_items/order_tracking ตามด้วย cascade
delete from public.orders where order_no like 'MOCK24%';
delete from public.customers c
 where not exists (select 1 from public.orders o where o.customer_id = c.id)
   and exists (select 1 from public.customer_phones p where p.customer_id = c.id and p.phone like '09999%');

-- ---------- ลูกค้าจำลอง ----------
-- 🔴 FK ของ orders เป็นคู่ (customer_id, brand_id) → อ้าง customers(id, brand_id)
--    แปลว่าลูกค้าผูกกับแบรนด์ · ออเดอร์ต้องใช้แบรนด์เดียวกับลูกค้า ไม่งั้นติด FK
--    จึงสร้างลูกค้าแยกตามแบรนด์ แล้วให้ออเดอร์ยืมแบรนด์จากลูกค้า
with ins as (
  insert into public.customers (brand_id)
  select b.id
  from generate_series(1, 40) g
  join public.brands b on b.name = case when g % 7 = 0 then 'ตัวแทน'
                                        when g % 3 = 0 then 'แบรนด์อื่นๆ'
                                        else 'HOPEFUL' end
  returning id, brand_id
), numbered as (select id, brand_id, row_number() over (order by id) rn from ins)
insert into public.customer_phones (customer_id, brand_id, phone)
select n.id, n.brand_id, '099990' || lpad(n.rn::text, 4, '0') from numbered n;

-- ---------- ออเดอร์จำลอง ----------
-- 40 ใบใน ม.ค.–ก.พ. 2024 · กระจายสถานะ/วิธีชำระ/แบรนด์/มี-ไม่มีเซล
with c as (
  select c.id cid, c.brand_id, b.name brand_name, p.phone, row_number() over (order by c.id) rn
  from public.customers c
  join public.brands b on b.id = c.brand_id
  join public.customer_phones p on p.customer_id = c.id
  where p.phone like '09999%'
),
s as (select id, employee_code, row_number() over (order by employee_code) rn
      from public.sellers where employee_code is not null and is_active),
n_s as (select count(*) k from s)
insert into public.orders
  (brand_id, customer_id, order_no, ordered_at, customer_name, phone,
   addr_detail, subdistrict, district, province, postal_code,
   seller_id, carrier, tracking_no, total_sales,
   payment_method, payment_status, delivery_status, return_reason, status_detail, note)
select
  c.brand_id,
  c.cid,
  'MOCK24' || lpad((((c.rn - 1) / 25) + 1)::text, 2, '0') || '-' || lpad(c.rn::text, 5, '0'),
  (date '2024-01-05' + ((c.rn - 1) % 25) * interval '2 day'
     + ((c.rn * 37) % 600) * interval '1 minute') at time zone 'Asia/Bangkok',
  'คุณทดสอบ ' || c.rn || case when c.rn % 5 = 0 then '' else ' ' || coalesce(sel.employee_code, '') end,
  c.phone,
  c.rn || '/' || (c.rn * 3) || ' หมู่ ' || (c.rn % 12 + 1),
  'ในเมือง', 'เมืองขอนแก่น', 'ขอนแก่น', '40000',
  -- 🔴 ทุกใบที่ rn % 5 = 0 ไม่มีเซล → เข้าคิว EDITH "ไม่มีเซล" (8 ใบจาก 40)
  case when c.rn % 5 = 0 then null else sel.id end,
  case when c.rn % 2 = 0 then 'KEX' else 'DHL eCommerce' end,
  'MOCK24TRK' || lpad(c.rn::text, 7, '0'),
  case when c.brand_name = 'ตัวแทน' then 0 else 690 + (c.rn % 6) * 300 end,
  case when c.rn % 4 = 0 then 'โอนเงิน' else 'เก็บเงินปลายทาง' end,
  case when c.brand_name = 'ตัวแทน' then 'ไม่ใช่งานขาย'
       when c.rn % 11 = 0 then 'ยกเลิก'
       when c.rn % 3 = 0 then 'รอชำระ' else 'ชำระแล้ว' end,
  case when c.rn % 11 = 0 then 'ยกเลิก'
       when c.rn % 9 = 0 then 'ตีกลับ'
       when c.rn % 8 = 0 then 'มีปัญหา'
       when c.rn % 13 = 0 then 'กำลังส่ง' else 'ส่งสำเร็จ' end,
  case when c.rn % 9 = 0 then 'ลูกค้าปฏิเสธรับพัสดุ' end,
  case when c.rn % 8 = 0 then 'ไม่สามารถติดต่อได้' end,
  null
from c
left join s sel on sel.rn = ((c.rn - 1) % (select k from n_s)) + 1
where c.rn <= 40;

-- ---------- รายการสินค้า ----------
-- ออเดอร์ตัวแทนได้ 'เอกสาร' · ที่เหลือได้สินค้าตามแบรนด์ 1–3 ชนิด
insert into public.order_items (order_id, product_id, quantity)
select o.id, p.id, 1 + ((o.id + p.id) % 4)
from public.orders o
join public.brands b on b.id = o.brand_id
join lateral (
  select pr.id, row_number() over (order by pr.id) k
  from public.products pr
  join public.categories ct on ct.id = pr.category_id
  where ct.brand_id = b.id
) p on p.k <= 1 + (o.id % 3)
where o.order_no like 'MOCK24%'
on conflict (order_id, product_id) do nothing;

-- ---------- โน้ตในไทม์ไลน์ (ไว้เทสฟีเจอร์ไฮไลท์) ----------
insert into public.order_tracking (order_id, entry_type, note, created_by_name, created_at)
select o.id, 'note',
       case (o.id % 3)
         when 0 then 'ติดต่อหาลูกค้า 3 สายไม่รับสายเลยค่ะ แจ้งแอดมินแล้วค่ะ'
         when 1 then E'8/1/2024 ติดต่อหาลูกค้า 3 สายไม่รับสายเลยค่ะ\n9/1/2024 ลูกค้าแจ้งว่าให้ส่งใหม่อีกครั้ง รอบนี้ฝากไว้ที่ร้านค้าหน้าปากซอย'
         else 'ลูกค้าขอเลื่อนรับของเป็นสัปดาห์หน้า เบอร์สำรอง 0812345678 ติดต่อได้ช่วงเย็น'
       end,
       case when o.id % 2 = 0 then 'อ้อม' else 'นำเข้า (อัพเดตสถานะ)' end,
       o.ordered_at + interval '2 day'
from public.orders o
where o.order_no like 'MOCK24%' and o.id % 5 < 3;      -- ~24 ใบมีโน้ต บางใบหลายอัน

commit;

-- ---------- สรุปผล ----------
select 'ออเดอร์' k, count(*) n from public.orders where order_no like 'MOCK24%'
union all select 'รายการสินค้า', count(*) from public.order_items i join public.orders o on o.id=i.order_id where o.order_no like 'MOCK24%'
union all select 'โน้ต', count(*) from public.order_tracking t join public.orders o on o.id=t.order_id where o.order_no like 'MOCK24%' and t.entry_type='note'
union all select 'ไม่มีเซล (เข้าคิว EDITH)', count(*) from public.orders o join public.brands b on b.id=o.brand_id
  where o.order_no like 'MOCK24%' and o.seller_id is null and b.name <> 'ตัวแทน';
