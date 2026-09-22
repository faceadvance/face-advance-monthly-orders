-- ลบข้อมูลจำลองปี 2024 ทั้งหมด (คู่กับ database/seed/mock-2024.sql)
-- order_items / order_tracking หายตาม cascade · customer_phones หายตาม cascade ของ customers
begin;

delete from public.orders where order_no like 'MOCK24%';

-- ลูกค้าจำลอง: เบอร์ขึ้นต้น 09999 และไม่มีออเดอร์จริงอ้างถึงแล้ว
delete from public.customers c
 where not exists (select 1 from public.orders o where o.customer_id = c.id)
   and exists (select 1 from public.customer_phones p where p.customer_id = c.id and p.phone like '09999%');

commit;

select 'ออเดอร์ MOCK24 ที่เหลือ' k, count(*) n from public.orders where order_no like 'MOCK24%'
union all select 'ลูกค้าจำลองที่เหลือ',
  (select count(*) from public.customers c
    join public.customer_phones p on p.customer_id = c.id where p.phone like '09999%');
