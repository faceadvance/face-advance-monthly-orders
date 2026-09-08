# EDITH — Exception Center (ศูนย์รวมปัญหาทั้งระบบ)

> Stage 9b · ออกแบบ 2026-09-07 · หน้าที่ 4 ของระบบ MO (เดิม placeholder "กำลังก่อสร้าง")
> ธีม: **Dark Premium Console** (แยกจากหน้าอื่นที่เป็น light) · layout **3-pane เต็มจอ** · เฉพาะ role **Adm**

---

## 1. เป้าหมาย

EDITH = จุดเดียวที่ **ทุกปัญหาของระบบ** ไหลมารวมให้แอดมินเคลียร์ พร้อม **audit log ทั้งระบบ** (ทุก action ของทุก user)
ไม่ใช่หน้าดูข้อมูลทั่วไป แต่เป็น **"ศูนย์กู้ภัยระบบ" (mission control)** — ออกแบบให้:
- เห็นปัญหาค้างทุกชนิดในที่เดียว เรียงตามความเร่งด่วน/อายุค้าง
- เคลียร์ปัญหาแต่ละชนิดด้วยหน้าจอเฉพาะทาง (resolver) ที่เร็ว มั่นใจ กดผิดกู้คืนได้
- ตรวจสอบย้อนหลังได้ว่าใครทำอะไรเมื่อไหร่ทั้งระบบ
- **extensible** — เพิ่มชนิดปัญหาใหม่ทีหลังได้โดยไม่รื้อโครง

## 2. ขอบเขต

**อยู่ในนี้:** 4 ชนิดปัญหา (ด้านล่าง) · unified issue queue · resolver รายชนิด · system audit log · Bento overview
**ไม่อยู่ในนี้:** ค่าคอม (boss ตัดออก) · responsive มือถือ/iPad (แยกงาน · EDITH เอา desktop ก่อน) · ชนิดปัญหาที่ยังไม่เกิด (เผื่อโครงไว้ ยังไม่ทำ)

## 3. ชนิดปัญหา (issue types) + แหล่งข้อมูล

| # | ชนิด | code | แหล่ง | เกณฑ์ "ค้าง" | ตอนนี้ |
|---|---|---|---|---|:--:|
| 1 | ⚠️ Error ออเดอร์ (COD ยอดไม่ตรง) | `error` | `orders.payment_status='error'` | ยัง error อยู่ | 1 |
| 2 | ⚔️ Conflict บันทึกตีกลับชน | `conflict` | `return_conflicts.status='open'` | ยังไม่ resolve | 0 |
| 3 | 🔀 Recon ขัดแย้ง (COD+ตีกลับ) | `recon` | `orders.recon_conflict=true` | ยังตั้งธง | 0 |
| 4 | 👥 ลูกค้าซ้ำ (dedup review) | `dedup` | `v_pending_customer_review` | ยัง pending | 0 |

> backend ทั้ง 4 พร้อมแล้ว (dedup: `customer_review`+view+`merge_customers` · conflict: `return_conflicts`+`revert_return_effects` · recon/error: `reconcile_order`+auto-revert trigger ที่เพิ่งทำ)

## 4. Data model — RPC (SECURITY DEFINER · Adm-only)

ทุก RPC เช็ค role=Adm ผ่าน `app_session_uid(token)` ก่อนเสมอ · reject ถ้าไม่ใช่

### 4.1 `app_edith_issues(p_token)` → jsonb
UNION 4 แหล่ง เป็น model เดียว เรียงตาม `age_minutes` มาก→น้อย:
```
{ type, ref, key, severity, age_minutes, opened_at, summary, extra }
```
- `type` = error|conflict|recon|dedup
- `ref` = ตัวชี้ (order_id / conflict_id / order_id / review_id)
- `key` = ข้อความแสดง (tracking_no / order_no / ชื่อลูกค้า)
- `severity` = high|med|low (จาก age + ชนิด — error/conflict = สูงกว่า dedup)
- `age_minutes` = now() server − เวลาที่ปัญหาเกิด
- `opened_at`, `summary` (สั้น 1 บรรทัด), `extra` (jsonb เล็กๆ สำหรับ badge เช่น Δ ยอด)
- คืน `counts:{error,conflict,recon,dedup,total}` + `sla:{lt2h,h2_6,gt12h}` สำหรับ Bento

### 4.2 detail RPC (โหลดตอนคลิกเลือกงาน — ไม่ยัดทั้งหมดใน queue)
- `app_edith_error_detail(token, order_id)` → ข้อมูลออเดอร์ + ยอดออเดอร์ + recon_cod (amount, id) + Δ
- `app_edith_conflict_detail(token, conflict_id)` → submissions[] (แต่ละเวอร์ชัน: ผู้บันทึก, เวลา, ผลตรวจ, สินค้า, ธง, รูป) + ออเดอร์อ้างอิง
- `app_edith_recon_detail(token, order_id)` → recon_cod + recon_returns ทั้งคู่ + ยอด
- `app_edith_dedup_detail(token, review_id)` → 2 เรคคอร์ดลูกค้า (จาก view) เทียบฟิลด์

### 4.3 resolve RPC (ทุกตัว log ลง audit_log)
- `app_edith_fix_cod_amount(token, order_id, new_amount)` → update `recon_cod_payments.amount` → `reconcile_order(order_id)` → คืนสถานะใหม่ · event `edith_fix_cod`
- `app_edith_delete_recon(token, kind, order_id)` → ลบ recon_cod/recon_returns (trigger auto-revert ทำงาน) · คืนข้อมูล record ที่ลบ (ให้ Undo re-insert ได้) · event `edith_delete_recon`
- `app_edith_resolve_conflict(token, conflict_id, chosen_idx)` → เขียนเวอร์ชันที่เลือกลง `recon_returns` (reconcile) · set `return_conflicts.status='resolved', resolution, resolved_by, resolved_at` · event `edith_resolve_conflict`
- `app_edith_merge_customers(token, keep_id, dup_id)` → wrap `merge_customers` + ปิดคิว review · event `edith_merge_customers`

### 4.4 `app_edith_log(p_token, p_filter jsonb)` → jsonb
timeline จาก `audit_log` (ศูนย์กลางอยู่แล้ว: username/ip/geo/event/detail/created_at)
- filter: user, event(s), ช่วงวันที่, ค้นข้อความ · เรียงใหม่→เก่า · หน้า/limit (กันดึงทั้ง 806+ แถว)
- **เติม log ที่ขาด** (ปัจจุบัน audit_log ไม่มี): `save_returns` (บันทึกตีกลับ) → เพิ่มใน `app_save_returns` · recon delete → log ใน `app_edith_delete_recon` · EDITH resolves → log ในแต่ละ RPC
- แปลง event code → ข้อความไทยอ่านง่ายฝั่ง FE (map)

## 5. Layout — Dark 3-pane เต็มจอ

```
┌─ EDITH · ศูนย์จัดการปัญหา ────────────── ●health · live ─┐
│ ┌ Bento KPI (glow · number ticker · tabular-nums) ──────┐ │
│ │  ⚠️ Error N │ ⚔️ Conflict N │ 🔀 Recon N │ ⏱ SLA aging │ │
│ └────────────────────────────────────────────────────────┘ │
│ ┌ QUEUE ────┬ WORKSPACE ───────────────┬ LOG ───────────┐ │
│ │ ●⚠ #tr…    │  ╔════════════════════╗  │ • 14:20 ซิน …  │ │
│ │ ●⚔ #tr…    │  ║  resolver ตามชนิด   ║  │ • 14:18 นัน …  │ │
│ │ ●🔀 #tr…   │  ║  ของงานที่เลือก      ║  │ • 14:15 plug…  │ │
│ │ ●👥 ชื่อ…   │  ╚════════════════════╝  │ • 14:02 fri …  │ │
│ │ [กรองชนิด] │                          │ [กรอง user/…] │ │
│ └────────────┴──────────────────────────┴────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

- **Top — Bento KPI:** นับปัญหาต่อชนิด (number ticker) + SLA aging spectrum bar (คลิก drill-down กรอง queue)
- **ซ้าย — Queue:** คิวปัญหาทุกชนิด เรียง SLA (ค้างนานอยู่บน) · ติ๊กกรองชนิด · badge สี/ไอคอนต่อชนิด · คลิก 1 งาน → โหลด detail เข้า Workspace · เลือกอยู่ = highlight
- **กลาง — Workspace:** ว่างตอนแรก ("เลือกงานจากคิว") · เลือกแล้ว render resolver ตามชนิด (ดู §6)
- **ขวา — Log:** ฟีดกิจกรรมสดทั้งระบบ · กรอง user/event/วันที่ · ค้นได้ · auto-poll (เช่น 45 วิ เหมือนศูนย์แจ้งเตือน)
- ล็อกความสูงพอดีจอ เลื่อนในแต่ละ pane (เหมือนหน้า order/record-returns) · โซนคงที่ ไม่กระพริบ (อัปเดตเฉพาะข้อมูล)

## 6. Workspace resolver รายชนิด

### 6.1 ⚠️ Error (COD ยอดไม่ตรง)
- แสดง: ออเดอร์ (เลข, ลูกค้า, ยอดออเดอร์) · **ยอด COD ที่รับ** · **Δ ส่วนต่าง** (เรืองแดง rose)
- action:
  - **แก้ยอด COD** — ช่องคีย์ยอดใหม่ · ถ้ายังไม่ตรง input **shake + ขอบแดง** · กด → `fix_cod_amount` → ตรง = ธง error หาย ออกจากคิว
  - **ลบ record** — → `delete_recon` (auto-revert → ออเดอร์กลับ "รอชำระ") · **Undo toast นับถอยหลัง** (undo = re-insert record เดิม)
  - **ทำเครื่องหมายจัดการแล้ว** (ถ้าตัดสินว่ายอมรับ) — optional เฟสหลัง
- verify: แก้ยอดตรง→error หาย · ลบ→รอชำระ · undo→กลับ error (tx/rollback)

### 6.2 ⚔️ Conflict (บันทึกตีกลับชน)
- **Dual-card A | B** (จาก `submissions`) · หัวการ์ด: ผู้บันทึก + เวลา (ระดับวินาที) + ช่องทาง (ถ้ามีใน detail)
- ฟิลด์เหมือน = สีปกติ · **ฟิลด์ต่าง = ไฮไลต์ amber + `≠`** (ผลตรวจ, สินค้าเสีย/ขาด, ธงไม่หักยอด, รูป)
- ปุ่ม **"เลือกทั้งฝั่ง A / B"** — เลือกทั้งเวอร์ชัน (boss เคาะ 2026-09-07: **ไม่ทำ cherry-pick รายฟิลด์** · ไฮไลต์ `≠` ไว้ช่วยตัดสินใจว่าฝั่งไหนถูก)
- กล่อง **Live Final** ล่าง โชว์เวอร์ชันที่จะบันทึกจริง
- ยืนยัน → `resolve_conflict(chosen_idx)` → เขียนผู้ชนะลง recon_returns · ปิด conflict · อีกฝั่งถูกทิ้ง
- verify: seed conflict จำลอง → เลือก A → recon_returns ได้ค่า A · return_conflicts=resolved (tx/rollback)

### 6.3 🔀 Recon ขัดแย้ง (มีทั้ง COD + ตีกลับ)
- แสดงทั้ง 2 record (COD amount/เวลา · ตีกลับ ผลตรวจ/เวลา) + ออเดอร์
- แอดมินเลือก **อันที่ผิด → ลบ** (`delete_recon`) → trigger auto-revert + reconcile เคลียร์ธง conflict อัตโนมัติ
- Undo toast เช่นกัน
- verify: order ที่ recon_conflict=true → ลบฝั่งผิด → conflict=false + สถานะตามฝั่งที่เหลือ (มีเทสจาก ① T3 ครอบแล้ว)

### 6.4 👥 Dedup (ลูกค้าซ้ำ)
- 2 เรคคอร์ดลูกค้าเทียบ side-by-side (ชื่อ/ที่อยู่/เบอร์/จำนวนออเดอร์) · ไฮไลต์จุดต่าง
- เลือก **เก็บอันไหน (keep) / รวมอันไหน (dup)** → `merge_customers(keep,dup)` → ปิดคิว
- verify: seed review → merge → เบอร์/ออเดอร์ย้ายไป keep, dup หาย, คิวปิด (tx/rollback)

## 7. System Log (zone ③)
- แหล่งหลัก `audit_log` (มี view_orders/login/logout/otp/import/tracking_save อยู่แล้ว)
- **เก็บทุก action จริงๆ รวม view_orders (ดูหน้า)** (boss เคาะ 2026-09-07) — pagination บังคับ (669+ แถว) · มี **filter chip แยกกลุ่ม** (ความปลอดภัย/ข้อมูล/ดูหน้า) ให้กรอง noise เอง · default แสดงทั้งหมด
- **เติม log ให้ครบ:** save_returns · recon delete · EDITH resolve ทุกชนิด (ทำใน RPC ที่เกี่ยวข้อง)
- แถวฟีด: เวลา · user (badge) · event (แปลงไทย) · สรุป detail · ip/geo (hover) · ไอคอนตามชนิด event
- กรอง: user, ชนิด event, ช่วงวันที่, ค้นข้อความ · pagination · poll สด
- (พิจารณาเฟสหลัง: คลิก log ที่ผูกออเดอร์ → jump ไป order/timeline)

## 8. เอฟเฟกต์ / UX rules (จาก 21st.dev research · dark premium)
- **ต้อง:** transition **≤200ms** · เลข `tabular-nums` (Geist/Inter/JetBrains Mono) · action หลักอยู่บนผิวหน้าจอ (ห้ามซ่อนใน `...`) · **ลบทุกจุดมี Undo นับถอยหลัง** · โซนคงที่ไม่กระพริบ (อัปเดตเฉพาะข้อมูล — เลขวิ่ง/พิมพ์ดีด เหมือนหน้าอื่น)
- **หยิบมา:** Bento glow + radial glass · Number ticker (นับปัญหา) · **SLA border-beam** เคสค้างนาน/ที่เลือก · shake on mismatch (แก้ยอด) · morphing เมื่อเลือกฝั่ง conflict (ฝั่งแพ้ยุบ)
- **เลี่ยง:** pure black `#000` (ใช้ zinc-950 `#090A0F` + card zinc-900) · ฟอนต์ไซไฟอ่านยาก · animation ยาว · ลบแบบไม่มี undo

## 9. สิทธิ์ / Security
- เข้าถึงเฉพาะ **Adm** — `pages.ts` มี edith ใน Adm อยู่แล้ว · เปลี่ยน `built:false`→`true` เมื่อเสร็จ
- ทุก RPC = SECURITY DEFINER + เช็ค role Adm ต้นทาง · reject อื่น (verify tx/rollback ทุกตัว)
- resolve action ทุกตัวเขียน audit_log (ใคร/เมื่อ/ทำอะไร)

## 10. แผน slice (ทำทั้งหมด · แบ่งให้ verify ได้ทีละก้อน)
1. **DB:** issues RPC + detail RPC + resolve RPC + log RPC + เติม log gap · verify tx/rollback ทุกตัว + ทุก role gate
2. **FE shell:** dark theme + 3-pane + Bento (ข้อมูลจริง) + Queue list + Log feed (อ่านอย่างเดียวก่อน) · ทำหน้าไม่กระพริบ
3. **Resolver ทีละชนิด:** error → recon → conflict (seed) → dedup (seed) · แต่ละอัน verify E2E บนเบราว์เซอร์ (friday=Adm)
4. **เอฟเฟกต์ polish:** glow/ticker/border-beam/undo/shake/morphing · เก็บ ≤200ms
5. **ปิด:** ล้างข้อมูล seed ทดสอบ · `built:true` · deploy

## 11. Dependencies / การตัดสินใจ
- ✅ auto-revert trigger (① · เสร็จ 2026-09-07) — resolver error/recon พึ่งพา
- ✅ conflict = เลือกทั้งเวอร์ชัน A/B (ไม่ cherry-pick) — boss เคาะ 2026-09-07
- ✅ log = ทุก action รวม view_orders + filter chip กรอง noise — boss เคาะ 2026-09-07
- SLA threshold (2h/6h/12h) — ใช้ค่าเริ่มจาก research ก่อน · ปรับได้ตอนเห็นของจริง
- ฟอนต์ตัวเลข premium (Geist?) — เลือกตอนทำ shell
