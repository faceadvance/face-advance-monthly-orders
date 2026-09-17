-- นำเข้าตีกลับย้อนหลัง ม.ค.–ส.ค. 2026 · สร้างชุดข้อมูลสุดท้ายจาก _stg_ret
-- ตามที่เจ้านายเคาะ 2026-09-17 (ไฟล์ 'รายการตีกลับ-ตรวจแล้ว (1).xlsx')
--   A (4)  → แมพผลตรวจให้เข้า CHECK · เก็บคำเดิมไว้ใน damage_detail
--   B (8)  → damage_detail = 'ไม่มีบันทึกรายละเอียด (นำเข้าย้อนหลัง)'
--   C (2)  → แถว 1266 แก้ tracking_out เป็น 7128051759004966 (ออเดอร์ HIST2605-04313 ลูกค้าคนเดียวกัน)
--   F (3)  → tracking_return = tracking_out · photo_url = null
--   ล้างเศษ float '.0' ท้ายเลขแทร็คตีกลับ (4 แถว: 13, 589, 1143, 1208)

begin;
set local statement_timeout = 0;

drop table if exists public._stg_ret_final;

create table public._stg_ret_final as
with fixed as (
  select
    s.src_row,
    -- C: ย้ายแถว 1266 ไปออเดอร์ที่ถูกต้อง
    case when s.src_row = 1266 then '7128051759004966'
         else btrim(s.tracking_out) end                                     as tracking_out,
    -- ล้าง '.0' ที่หลุดมาจาก Excel แล้วตัดช่องว่าง
    nullif(btrim(regexp_replace(coalesce(s.tracking_return, ''), '\.0$', '')), '')
                                                                            as tracking_return_in,
    s.arrived_at,
    btrim(s.inspection)                                                     as inspection_in,
    coalesce(btrim(s.no_deduct) = 'True', false)                            as no_deduct,
    nullif(btrim(coalesce(s.photo_url, '')), '')                            as photo_url
  from public._stg_ret s
)
select
  f.src_row,
  f.tracking_out,
  -- F: ไม่มีเลขแทร็คตีกลับ → ใช้เลขส่งออก (เจ้านายเคาะ)
  coalesce(f.tracking_return_in, f.tracking_out)                            as tracking_return,
  f.arrived_at                                                              as recorded_at,
  -- A: ค่าที่ CHECK ไม่รับ → แมพเข้าค่าที่ใกล้ที่สุด
  case f.inspection_in
    when 'สินค้าสูญหาย'      then 'สินค้าไม่ครบ'
    when 'บรรจุภัณฑ์เสียหาย' then 'สินค้าเสียหาย'
    else f.inspection_in
  end                                                                       as inspection_result,
  -- CHECK บังคับ damage_detail เมื่อผลตรวจ ≠ 'สินค้าครบ ไม่เสียหาย'
  case
    when f.inspection_in = 'สินค้าครบ ไม่เสียหาย' then null
    when f.inspection_in in ('สินค้าสูญหาย', 'บรรจุภัณฑ์เสียหาย') then f.inspection_in   -- A: เก็บคำเดิม
    else 'ไม่มีบันทึกรายละเอียด (นำเข้าย้อนหลัง)'                                        -- B
  end                                                                       as damage_detail,
  f.no_deduct,
  f.photo_url
from fixed f;

create unique index _stg_ret_final_trk_uidx on public._stg_ret_final (btrim(tracking_out));

commit;
