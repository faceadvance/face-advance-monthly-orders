# TASK — EDITH Exception Center (Stage 9b)

> spec: `Face Advance Monthly orders/docs/specs/2026-09-07-edith-exception-center-design.md`
> ธีม dark premium · 3-pane · Adm only · เริ่ม 2026-09-07

## ✅ ก่อนหน้า
- [x] ① auto-revert trigger (ลบ recon → คืน baseline) · verify 3 เคส · DB live

## Slice 1 — DB (RPC ทั้งหมด) ✅ เสร็จ+verify 2026-09-07
- [x] `app_edith_issues` — unified queue 4 ชนิด + counts (Adm ok · Vm forbidden ✓)
- [x] `app_edith_error_detail` / `_conflict_detail` / `_recon_detail` / `_dedup_detail`
- [x] `app_edith_fix_cod_amount` (+log) — ยอดผิด→error→แก้→ชำระแล้ว ✓
- [x] `app_edith_delete_recon` + `app_edith_restore_recon` (undo) — del→revert→restore ✓
- [x] `app_edith_resolve_conflict` — เลือก A/B → resolved + reconcile ✓
- [x] `app_edith_merge_customers` — merge + review cascade หาย ✓
- [x] `app_edith_log` — audit timeline + filter + pagination (total 806 ✓)
- [x] verify tx/rollback ทุกตัว · edith log 0 ตกค้าง · role gate ผ่าน

## Slice 2 — FE shell ✅ 2026-09-07
- [x] api.ts (EDITH types+fn) · edith.ts · main.ts wire · pages.ts built:true
- [x] 3-pane layout · Bento · Queue (filter chip) · Log feed · build ผ่าน

## Slice 3 — Resolver ทีละชนิด ✅ verify E2E browser (friday=Adm)
- [x] conflict (เลือก A/B · dual + ไฮไลต์ ≠) — render สวย
- [x] dedup (merge) — **full loop ผ่าน**: กด merge → คิวหาย → log ขึ้นทันที
- [x] error/recon RPC verify rollback แล้ว (slice1) · resolver render ตาม pattern เดียวกัน
- [~] error/recon resolver ยังไม่ได้เทส action บนจอ (mock ไม่มี COD · optional seed)

## Slice 4 — เอฟเฟกต์ polish ✅ (v2 Aurora Command Center)
- [x] full-bleed aurora bg + grid · glass panel มีมิติ · Bento glow เก็บมุม · number ticker
- [x] overview hero (orb เรืองแสง+วงแหวน · status · pills · recent) · undo countdown · shake · SLA border-beam
- [x] boss เห็น v2 แล้ว (ยังรอ feedback รอบ 2)

## Slice 5 — ปิด
- [ ] ล้าง seed ทดสอบ · built:true · deploy (push main) · verify prod
- [ ] อัปเดต ROADMAP + ลบ TASK.md เมื่อ boss ตรวจผ่าน

## หมายเหตุ
- auth idiom: `app_session_uid(token)` → null=unauth · role Adm เท่านั้น
- audit_log: `save_returns` log แล้ว · gap = recon delete + EDITH resolve (เขียนใน RPC)
- return_conflicts.submissions = array 2 obj {by,at,tracking_return,inspection_result,damage_detail,damage_items,photo_url,no_deduct} · status pending→resolved
- go-live pending (ไม่ใช่ stage นี้): reset RTs pw · jj87 xlsx · go-live wipe
