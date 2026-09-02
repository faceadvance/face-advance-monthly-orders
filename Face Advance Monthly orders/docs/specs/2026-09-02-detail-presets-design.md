# Design — ชิปคำแนะนำ "รายละเอียดปัญหา" (detail presets)

วันที่: 2026-09-02 · ต่อยอดจาก Stage 5 (order tracking)

## เป้าหมาย
ช่อง "รายละเอียดปัญหา" (โผล่เมื่อสถานะจัดส่ง = **มีปัญหา**) ไม่ต้องพิมพ์ซ้ำทุกครั้ง —
มี "ชิป" คำที่เคยใช้ให้กดเลือกได้เลย คำใหม่ที่พิมพ์เองจะถูกจำเข้าคลังอัตโนมัติ
คลังใช้ร่วมทั้งทีม จัดลำดับด้วยการลากเอง (คำที่ใช้บ่อยลากมาไว้หน้า)

## ขอบเขต
- เฉพาะช่อง **รายละเอียดปัญหา** (มีปัญหา) · ช่องโน้ต/ระบุเพิ่มเติมตีกลับ = ต่อยอดทีหลัง (`kind` รองรับไว้แล้ว)
- คลัง + ลำดับ = **ใช้ร่วมทั้งทีม** (ไม่แยกรายคน)
- MVP: **ไม่มีปุ่มลบชิป** (ระบบกันคำซ้ำอยู่แล้ว) — เพิ่มทีหลังได้

## DB
ตาราง `tracking_detail_presets`
| คอลัมน์ | ชนิด | หมายเหตุ |
|---|---|---|
| id | bigint identity PK | |
| kind | text default 'problem' | ประเภทช่อง (เผื่อขยาย) |
| label | text | ข้อความ · unique(kind,label) |
| use_count | int default 0 | นับครั้งที่ใช้ |
| sort_order | int | ลำดับที่ลากจัด (ตัวหลักในการเรียง) |
| last_used_at | timestamptz | |
| created_by | uuid → app_users | |
| created_at | timestamptz default now() | |

RLS: เปิด ไม่มี policy ตรง → เข้าถึงผ่าน SECURITY DEFINER RPC เท่านั้น (เหมือนตารางอื่น)

Seed (kind='problem', sort_order 1..5):
1. ลูกค้าปฏิเสธรับพัสดุ  2. เบอร์ไม่ถูกต้อง  3. ไม่สามารถติดต่อได้  4. ขนส่งไม่ติดต่อลูกค้า  5. พัสดุสูญหาย

## RPC (SECURITY DEFINER · auth ผ่าน app_session_uid · grant anon,authenticated)
- `app_get_detail_presets(p_token, p_kind default 'problem')` → `{authorized, ok, presets:[{id,label,use_count}]}` เรียงตาม sort_order
- `app_reorder_detail_presets(p_token, p_ids bigint[], p_kind default 'problem')` → set sort_order = ตำแหน่งใน array
- ต่อยอด `app_save_order_tracking` +2 param:
  - `p_preset_label text` = คำที่จะบันทึกเข้าคลัง (base label ถ้ากดชิป / ข้อความเต็มถ้าพิมพ์เอง)
  - `p_preset_allow_create bool` = true เฉพาะกรณีพิมพ์เอง (ไม่ได้กดชิป)
  - logic: ถ้า delivery=มีปัญหา และ save สำเร็จ (ไม่ noop):
    - allow_create=true → upsert (on conflict +use_count) · sort_order ใหม่ = max+1
    - allow_create=false → update +use_count ให้ label ที่มีอยู่

## Frontend
- `api.ts`: `getDetailPresets(kind)`, `reorderDetailPresets(kind, ids)` · เพิ่ม 2 field ใน SaveTrackingArgs
- `main.ts` (problemBlock):
  - แถวชิปใต้ textarea (แนวนอน scroll ซ้ายขวา) โหลดตอนเปิด sidebar
  - **กดชิป** → แทนที่ข้อความทั้งกล่อง (`problemTa.value = label`), cursor ท้าย, mark activePreset, ไฮไลต์ชิป
  - **พิมพ์เอง**: ถ้า value ยังขึ้นต้นด้วย activePreset.label → คงเลือกไว้ · ถ้าไม่ขึ้นต้นแล้ว → ยกเลิกเลือก (activePreset=null)
  - **กดชิปอื่น** → แทนที่ + เปลี่ยน active
  - **ลากชิป** สลับตำแหน่ง (pointer drag ในแถบ) → reorder call + optimistic
  - ตอน save: activePreset≠null → ส่ง label=base, allow_create=false · activePreset=null → label=ข้อความเต็ม, allow_create=true

## แถม (คนละเรื่อง)
- fix: ไอคอนดินสอในตาราง — badge ชิดซ้าย + ดินสอชิดขวา cell (absolute) ให้เรียงตรงเป็นคอลัมน์ทั้งคู่

## Verify
- DB: get/reorder/save+preset ใน tx/rollback (happy + คำซ้ำ + กดชิปไม่สร้างใหม่ + พิมพ์เองสร้างใหม่)
- FE: เปิดจริง — กดชิปแทนที่, พิมพ์ต่อคงเลือก, ลบต้นยกเลิกเลือก, ลากสลับจำได้, คำใหม่เข้าคลัง
- เคลียร์ข้อมูลเทสให้สะอาด · deploy พร้อม fix ดินสอ
