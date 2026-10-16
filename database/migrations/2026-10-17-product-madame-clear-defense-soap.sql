-- 2026-10-17 · เพิ่มสินค้าใหม่ 1 ชนิด · เจ้านายสั่ง
-- 'Madame Louise Clear Defense Soap' · หมวด MADAME (แบรนด์อื่นๆ) · ไม่ใช่ของแถม
-- ⚠️ นำเข้าออเดอร์จับสินค้าด้วยชื่อตรงตัว → ชื่อต้องตรงกับไฟล์ออเดอร์ทุกตัวอักษร
-- รัน: psql -v commit=1 -f (ไม่ใส่ = rollback)
\set ON_ERROR_STOP 1
begin;

do $$ begin
  if (select count(*) from public.categories c join public.brands b on b.id = c.brand_id
       where c.name = 'MADAME' and b.name = 'แบรนด์อื่นๆ') <> 1 then raise exception 'หาหมวด MADAME (แบรนด์อื่นๆ) ไม่เจอ/เจอซ้ำ'; end if;
  -- กันชื่อซ้ำ (ไม่สนตัวพิมพ์เล็กใหญ่ · เว้นวรรค · เเ/แ)
  if exists (select 1 from public.products
              where lower(regexp_replace(replace(name, 'เเ', 'แ'), '\s+', '', 'g')) = 'madamelouisecleardefensesoap')
  then raise exception 'มีสินค้าชื่อนี้อยู่แล้ว — ยกเลิก'; end if;
end $$;

insert into public.products (category_id, name, is_freebie, is_active)
select c.id, 'Madame Louise Clear Defense Soap', false, true
  from public.categories c join public.brands b on b.id = c.brand_id
 where c.name = 'MADAME' and b.name = 'แบรนด์อื่นๆ';

select p.id, p.name, c.name category, b.name brand, p.is_freebie, p.is_active
  from public.products p join public.categories c on c.id = p.category_id join public.brands b on b.id = c.brand_id
 where p.name = 'Madame Louise Clear Defense Soap';

\if :{?commit}
commit;
\else
rollback;
\endif
