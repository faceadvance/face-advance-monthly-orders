# Face Advance DB

Supabase database สำหรับโปรเจคหลัก Face Advance Systems (Phase 1).
แต่ละงานในโปรเจคแยกโฟลเดอร์ของตัวเอง แต่ใช้ DB ตัวนี้ร่วมกันได้.

## ข้อมูล Project (ไม่ใช่ secret)

| รายการ | ค่า |
|--------|-----|
| Project name | Face Advance DB |
| Project ref / ID | `xfayguljywhjwqcuimvw` |
| API URL | https://xfayguljywhjwqcuimvw.supabase.co |
| Region | ap-southeast-1 (Singapore) |
| Postgres | 17 |
| Organization | Face Advance Systems (`aboozsvkrxatjyowtlsj`) |
| Org owner | faceadvances.th@gmail.com (บัญชีบริษัท) |
| Plan | Free |
| สร้างเมื่อ | 2026-08-28 |

## หมายเหตุ

- Org **"Face Advance Systems"** (`aboozsvkrxatjyowtlsj`) เจ้าของคือบัญชีบริษัท `faceadvances.th@gmail.com` (role Owner, member คนเดียว).
- Project ใน org นี้ตอนนี้มี 2 ตัว: `Face Advance DB` (ตัวนี้) และ `crm-sale-dashboard`
  (ย้ายมาจาก org ส่วนตัวเดิม "Face Advance" ของบัญชี `ainzth45-commits` เมื่อ 2026-08-28).
- Supabase MCP เชื่อมต่อผ่าน Personal Access Token ของบัญชีบริษัท เก็บใน `~/.claude/secrets.env`
  (`SUPABASE_ACCESS_TOKEN`) — **ห้าม commit ค่า token / service key / db password**.
- Free tier จำกัด 2 active project ต่อบัญชีเจ้าของ org.

## Schema (Phase 1 — แบรนด์ + สินค้า) ✅

ลำดับชั้น: **แบรนด์ (ประเภทหลัก) → ประเภทย่อย → สินค้า**

- `brands` — แบรนด์ = ประเภทหลัก (`name` unique, `sort_order`)
- `categories` — ประเภทย่อย ผูก `brand_id`, unique(brand_id, name)
- `products` — สินค้า ผูก `category_id`, unique(category_id, name), `is_freebie`, `is_active`, `code`(SKU เผื่ออนาคต)
- `v_product_catalog` — view รวม แบรนด์+ประเภทย่อย+สินค้า (security_invoker) สำหรับดูภาพรวม/filter ตามแบรนด์
- Trigger `set_updated_at` (search_path ล็อกแล้ว) แตะ `updated_at` ทุกตาราง
- RLS เปิดทุกตาราง + policy `select` ให้ role `authenticated` (เขียนผ่าน service_role เท่านั้น)

### ข้อมูลที่ import (seed ชุดแรก: `seed/products_seed_01.tsv`, 135 แถว)

| แบรนด์ | ประเภทย่อย | สินค้า |
|--------|-----------|--------|
| HOPEFUL | 23 | 38 |
| แบรนด์อื่นๆ | 15 | 97 |
| **รวม** | **38** | **135** (ของแถม 8) |

- import ครบ 135/135 ไม่มีตกหล่น/ซ้ำ
- ⚠️ คู่ที่อาจเป็นสินค้าเดียวกัน (ยังแยกเป็น 2 ตัว รอเจ้านายตัดสินใจรวม):
  `LYO MY LUMI HAIR OIL (50 ml.)` กับ `[ LYO MY LUMI HAIR OIL (50 ml.) * 1 ]`
- วิธี re-import: `python3 seed/gen_import_sql.py` เพื่อ regen SQL จาก TSV (idempotent, on conflict do nothing)

## Schema (Phase 2 — ลูกค้า + คำสั่งซื้อ + ผู้ขาย) ✅

ข้อมูลทั้งหมด **แยกตามแบรนด์ (ประเภทหลัก) ด้วยคอลัมน์ `brand_id`** — ภาพรวม = ดูหมด, รายแบรนด์ = filter brand_id. เพิ่มแบรนด์ที่ 3 ไม่ต้องแก้โครง. คนซื้อ 2 แบรนด์ = นับ 2 ลูกค้า (identity ผูกกับแบรนด์).

### ส่วนที่ 3 — ลูกค้า
- `customers` — ตัวลูกค้า ผูก `brand_id`, `created_at` = วันเป็นลูกค้าใหม่ของแบรนด์นั้น. มี `unique(id, brand_id)` ให้ตารางลูกอ้าง composite FK ล็อกถังได้. **ตอนนี้เก็บแค่เบอร์** (ชื่อ/ที่อยู่/ช่องทาง = งาน CRM ทีหลัง)
- `customer_phones` — 1 ลูกค้ามีได้หลายเบอร์ (เพิ่ม/ลบอิสระ). `unique(brand_id, phone)` = เบอร์ห้ามซ้ำในแบรนด์. `check phone ~ '^[0-9]{8,15}$'` = เบอร์ตัวเลขล้วน (กัน dedupe พลาด — **ต้อง normalize เบอร์ก่อน import**). composite FK `(customer_id, brand_id) → customers` กันผูกผิดถัง, on delete cascade

### ส่วนที่ 4 — คำสั่งซื้อ
- `orders` — หัวออเดอร์ (21 คอลัมน์). **1 ออเดอร์ = 1 แบรนด์**. ผูกลูกค้าด้วย composite FK `(customer_id, brand_id) → customers` (กันลูกค้าผิดถัง). ที่อยู่เก็บบนออเดอร์ (ที่อยู่ส่งครั้งนั้นๆ). ฟิลด์สำคัญ:
  - `order_no` — เลขจากระบบภายนอก, ว่างได้/ซ้ำได้ (ไม่บังคับ unique)
  - `ordered_at` — วันที่+เวลา (timestamptz)
  - `customer_name`, `phone` — บังคับมี (ชื่อ ณ ตอนสั่ง + เบอร์ที่ใช้ผูกลูกค้า)
  - ที่อยู่: `addr_detail`, `subdistrict`(ตำบล), `district`(อำเภอ), `province`, `postal_code`(check 5 หลัก)
  - `total_sales` — integer ≥0 บาทถ้วน รวมทุกอย่างแล้ว (ไม่คำนวณจากรายการ)
  - `seller_id` → sellers (ว่างได้)
  - **ค่าตายตัว (CHECK):** `payment_method` (เก็บเงินปลายทาง/โอนเงิน/ตัดบัตรเครดิต, null ได้), `payment_status` (รอชำระ/ชำระแล้ว/ยกเลิก, default รอชำระ), `delivery_status` (รอส่ง/ส่งแล้ว/ส่งสำเร็จ/ตีกลับ/ยกเลิก, default รอส่ง)
  - `carrier` (ขนส่ง) = กรอกเองอิสระ, `tracking_no` = ว่างได้
  - `note` = ฟิลด์ยืดหยุ่น (เก็บต่างกันตามช่วงเวลา, ว่างได้/แก้ได้). **ช่วงนี้:** เก็บค่าคอลัมน์ H (ชื่อโซเชียล) เฉพาะแถวที่มี "SO20" (เลิกใช้คอลัมน์ 'โน๊ต' แล้ว)
- `order_items` — รายการสินค้า (สินค้า + จำนวน, ไม่เก็บราคา). `quantity > 0`, `unique(order_id, product_id)`. trigger `order_items_brand_guard` บังคับสินค้า (รวมของแถม) เป็นแบรนด์เดียวกับออเดอร์ (เช็ค brand ผ่าน category), on delete cascade จาก orders

### ส่วนที่ 5 — ผู้ขาย (พนักงาน)
- `sellers` — `id, name, employee_code, department, is_active, created_at, updated_at` (ออเดอร์อ้าง `seller_id`)
  - `is_active` — สถานะ active/inactive
  - `employee_code` — รหัสพนักงาน. **ซ้ำได้ทั่วไป (คนลาออกแล้วเอารหัสมาใช้ซ้ำได้) แต่ห้ามซ้ำในกลุ่ม active** → partial unique index `sellers_active_employee_code_key on (employee_code) where is_active`
  - `name` — ชื่อพนักงาน **nullable** (คนละคนชื่อซ้ำได้ + ข้อมูลจริงมีคนรหัสเก่า/ยังไม่ตั้งชื่อ). migration `sellers_name_nullable`
  - `department` — แผนก, ค่าตายตัว CHECK (`admin` / `crm` / `อื่นๆ`), default `อื่นๆ`
  - verify: 6 test ผ่าน (valid, default แผนก=อื่นๆ, บล็อกรหัสซ้ำใน active, อนุญาตรหัสซ้ำเป็น inactive, บล็อกแผนกมั่ว, อนุญาตชื่อซ้ำ). migration `phase5_sellers_fields`

### ข้อมูลพนักงานที่ import (จาก `พนักงาน.xlsx` → `seed/sellers_seed.sql`, 74 คน) ✅
- รวม 74 · active 58 / inactive 16 · admin 33 / crm 40 / อื่นๆ 1 · ชื่อว่าง 20 (16 inactive + 4 active: m01,m03,m05,m06) · รหัสไม่ซ้ำในกลุ่ม active
- verify ตรงไฟล์ทุกตัวเลข. re-import: ต้อง `truncate public.sellers restart identity cascade` ก่อน (employee_code ไม่ unique ทั้งตาราง จึงไม่มี on-conflict)
- ⚠️ ระวัง: truncate sellers cascade จะกระทบ orders.seller_id ในอนาคต (ตอนนี้ orders ว่าง)

### กันพัง / เวอริฟาย
- ทุก FK มี index, RLS เปิดทุกตาราง + policy read ให้ `authenticated` (เขียนผ่าน service_role), trigger `set_updated_at` ทุกตาราง
- verify แล้ว: 7 edge-case test ผ่านหมด (valid chain + บล็อก: เบอร์ซ้ำ, เบอร์ไม่ใช่ตัวเลข, สินค้าข้ามแบรนด์, สถานะมั่ว, ลูกค้าผิดถัง, ยอดติดลบ) · security advisor 0 lint · ตารางว่างพร้อม import จริง
- migration: `phase2_customers_orders_sellers`

### 🔑 กฎ "ลูกค้าใหม่" (สำคัญ — คำนวณสด ห้ามยึดวันนำเข้า)
- **วันเป็นลูกค้าใหม่ = `MIN(orders.ordered_at)` ของลูกค้าคนนั้น (ในแบรนด์นั้น)** ไม่ใช่ `customers.created_at`
- เหตุผล: import รายวัน + ย้อนหลังทยอยเข้า → `created_at` = วัน insert ไม่ใช่วันซื้อจริง. ยึด MIN(ordered_at) ทำให้ "แม่นยำ ณ วันที่ถาม" และ**แก้ตัวเองอัตโนมัติ**เมื่อข้อมูลเก่าเข้าเพิ่ม
- `customers.created_at` = audit (เวลาแถวเข้า DB) เท่านั้น ห้ามเอาไปนับลูกค้าใหม่
- trade-off ที่ boss รับแล้ว: ตัวเลขลูกค้าใหม่ของวันเก่าอาจขยับเมื่อ backfill เข้า = ความถูกต้อง ไม่ใช่บั๊ก (สุดท้ายข้อมูลเก่าเข้าครบ ตัวเลขนิ่งเอง)
- view รายงาน (security_invoker, migration `views_new_customers`):
  - `v_customer_first_order` — customer_id, brand_id, first_ordered_at
  - `v_new_customers_daily` — brand_id, order_date (เวลาไทย Asia/Bangkok), new_customers

### logic ผูกลูกค้าตอน import (ทำในสเต็ป import ไม่ใช่ที่ตาราง)
1. normalize เบอร์ให้เหลือตัวเลขล้วน
2. หา `(brand_id, phone)` ใน `customer_phones` → เจอ = ลูกค้าเก่า (ใช้ customer_id เดิม), ไม่เจอ = สร้าง customer ใหม่ + เบอร์ (= ลูกค้าใหม่ของแบรนด์นั้น)
3. insert order (ผูก customer_id) + order_items

## 📥 นำเข้าออเดอร์จาก GoSell (วิธีหลัก รายวัน)

**ไฟล์:** Export Orders ของ GoSell (.xlsx, header อยู่แถว 4, 1 แถว=1 รายการสินค้า, 1 ออเดอร์กินหลายแถว)

**เครื่องมือ:** `seed/import_gosell_orders.py` (แปลง xlsx→SQL) + `seed/run_import.sh` (รัน+ยามกันเข้าผิด DB)

**ขั้นตอน:**
```bash
# 1) แปลงไฟล์ → SQL (มี warning ออก stderr ถ้ามีแถวผิดปกติ)
python3 database/seed/import_gosell_orders.py "database/<ไฟล์.xlsx>" > /tmp/import_orders.sql
# 2) รัน (ยามตรวจว่าเป็น Face Advance DB จริงก่อนเขียน = guard 6/0)
bash database/seed/run_import.sh /tmp/import_orders.sql
```

**map สำคัญ (ยืนยันกับ boss):**
- `total_sales` = คอลัมน์ **"รวมทั้งสิ้น"** (ยอดหลังหักส่วนลดท้ายบิล) · ยอดระดับออเดอร์อยู่บรรทัดแรก
- `seller_id` = **รหัสท้ายชื่อลูกค้า** (เช่น m11) → sellers.employee_code (คอลัมน์ "พนักงานขาย" ไม่ใช้)
- `note` (ช่วงนี้) = คอลัมน์ H (ชื่อโซเชียล) เฉพาะแถวที่มี **"SO20"** (เช่น SO202608-069031) แถวอื่น note=ว่าง · เปลี่ยน source ได้ตามช่วงเวลา (แก้ที่ importer)
- `customer_name` = เก็บทั้งชื่อ+โค้ดท้ายตามไฟล์ · เบอร์ = เบอร์โทร1 เท่านั้น
- brand = อนุมานจากสินค้าในออเดอร์ (ยาม SQL บล็อกถ้าปนแบรนด์/สินค้าไม่ match DB)
- **กรองออเดอร์ยกเลิกทิ้ง:** ข้ามแถวที่ **คอลัมน์ K (สถานะคำสั่งซื้อ) = "ยกเลิก"** (เอาเฉพาะออเดอร์ส่งจริง) — ตัวนำเข้าจะ warn บอกเลขที่ข้าม
- สถานะ map: การชำระเงิน(การโอนเงิน→โอนเงิน) · ชำระ(รอการชำระเงิน→รอชำระ, ยืนยันแล้ว→ชำระแล้ว, canceled→ยกเลิก) · จัดส่ง(พร้อมจัดส่ง→รอส่ง, จัดส่งแล้ว→ส่งแล้ว, จัดส่งสำเร็จ→ส่งสำเร็จ)

**🛡️ กันวันซ้ำ (idempotency ระดับวันที่):** โมเดลบริษัท = นำเข้าย้อนหลังเฉพาะออเดอร์ที่ส่งจริง (นิ่งแล้ว ไม่มีแก้/ยกเลิก), เร็วสุด = 2 วันก่อน. "สิ่งที่ชัวร์" = **วันที่** (นำเข้าวันซ้ำ = โหลดไฟล์เดิมซ้ำ). ตัวนำเข้ามียาม: ถ้าวัน (เวลาไทย) ใดในไฟล์มีใน DB แล้ว → **RAISE EXCEPTION ยกเลิกทั้งไฟล์** (ไม่ข้าม ไม่ลบ) บอกวันที่ซ้ำ ให้ boss ไปตรวจ/ export ช่วงใหม่. verify แล้ว: รันไฟล์เดิมซ้ำ → error "วันที่ซ้ำ: 2026-08-26", orders คงเดิม 220 ไม่ขยับ

## 🔎 ตรวจจับลูกค้าซ้ำ (customer dedup — 2 เฟส)

**ปัญหา:** match ด้วยเบอร์อย่างเดียว → ลูกค้าเปลี่ยนเบอร์ หรือคนในครอบครัว (สามี/ภรรยา ส่งบ้านเดียวกัน) กลายเป็นลูกค้าใหม่ผิดๆ → ตัวเลขลูกค้าใหม่เฟ้อ + พนักงานแย่งยอด/ดูแลทับซ้อน. นิยาม "ลูกค้า" ของ boss = รวมคนในครอบครัวบ้านเดียวกันเป็น **ลูกค้าเดียว** (ไม่แยกชั้น household).

**เฟส 1 (auto ตอน import):** `run_import.sh` เรียก `detect_customer_duplicates(p_since)` หลังนำเข้า → หาลูกค้าที่เพิ่งเข้ามาที่:
- **ชื่อคล้าย** (pg_trgm บน `norm_name`, ≥0.6) **และต้องอยู่จังหวัด+อำเภอเดียวกัน** (กันชื่อเล่นไทยซ้ำข้ามพื้นที่)
- หรือ **ที่อยู่เดียวกัน** (จังหวัด+อำเภอ+ตำบล+ไปรษณีย์ ตรง และบ้านเลขที่คล้าย **≥0.85** = เกือบเป๊ะ)
- → บันทึกคู่ต้องสงสัยลง `customer_review` (status=pending). ที่ไม่คล้าย = ลูกค้าใหม่ตามปกติ
- *(จูนจากทดลอง preview ไฟล์ 31ก.ค–25ส.ค ~5.6k ออเดอร์: เกณฑ์เดิม 146 คู่มั่วเยอะ → จูนนี้เหลือ ~8 คู่คุณภาพเกือบทั้งหมดของจริง. เข้มขึ้น=แม่นขึ้นแต่อาจพลาดคู่ที่ย้ายอำเภอ/พิมพ์ที่อยู่ต่างมาก — ลด threshold ผ่านพารามิเตอร์ได้ถ้าอยากได้คู่มากขึ้น)*

**เฟส 2 (คนตรวจ):**
```sql
select * from public.v_pending_customer_review;              -- ดูคิว (ชื่อ/ที่อยู่/เบอร์ทั้ง 2 ฝั่ง + คะแนน)
select public.merge_customers(<keep_id>, <dup_id>);          -- ยืนยัน "คนเดียวกัน" → ย้ายออเดอร์+เบอร์รวมคนเก่า ลบตัวซ้ำ
update public.customer_review set status='rejected', decided_at=now() where id=<id>;  -- "ไม่ใช่"
```
- ของที่สร้าง: extension `pg_trgm`, `norm_name()`, ตาราง `customer_review` (unique คู่, RLS read), ฟังก์ชัน `detect_customer_duplicates()` / `merge_customers()`, view `v_pending_customer_review`. migrations: `customer_dedup_review`, `detect_dedup_canonical_pair`
- 🎁 "วันเป็นลูกค้าใหม่" แก้เองอัตโนมัติหลัง merge (view คิดจาก MIN ordered_at)
- ⚙️ threshold default (ชื่อ 0.6 / ที่อยู่ 0.85, ชื่อต้องอำเภอเดียวกัน) — จูนได้ผ่านพารามิเตอร์ `detect_customer_duplicates(p_since, p_thresh_name, p_thresh_addr)`. migrations dedup: `customer_dedup_review`, `detect_dedup_canonical_pair`, `detect_dedup_tuned`
- verify: เทสจำลอง detect จับคู่ซ้ำได้ (name/address, 1 คู่=1 แถว), merge ย้ายออเดอร์+เบอร์+ลบตัวซ้ำถูกต้อง, advisor 0 lint

### 🔌 Connection strings (มาร์คกันเข้าผิด DB — สำคัญ!)
ใน `~/.claude/secrets.env`:
- `SUPABASE_DB_URL_FACEADVANCE` = **Face Advance DB** (โปรเจกต์นี้ ref xfayguljywhjwqcuimvw, Session pooler)
- `SUPABASE_DB_URL` = **crm-sale-dashboard** (คนละตัว! มีตาราง calls/leaves/monthly_targets — อย่าปน)
- `run_import.sh` มียาม: ตรวจปลายทางต้องมี 6 ตารางเรา + ไม่มีตาราง crm (`guard=6/0`) ไม่งั้น abort

### บันทึกทดสอบนำเข้าครั้งแรก (2026-08-28, ไฟล์ 26 ส.ค.)
- **219 ออเดอร์ / 294 รายการ / 218 ลูกค้า** (กรองออเดอร์ยกเลิกออก 1 = OD260826179013) — ไม่มีปนแบรนด์, สินค้า match 100%, seller map ครบ
- verify: ยอดตรงไฟล์, spot-check ออเดอร์หลายบรรทัดตรง, สถานะ map ถูก, กันวันซ้ำทำงาน, view ลูกค้าใหม่ทำงาน
