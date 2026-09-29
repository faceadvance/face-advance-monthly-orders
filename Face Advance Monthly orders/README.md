# ระบบ MO — Face Advance Monthly Orders

เว็บแอปจัดการออเดอร์รายเดือนของ Face Advance: ตารางออเดอร์ · ติดตามสถานะจัดส่ง/ชำระ · นำเข้าไฟล์ออเดอร์และเงินเข้า COD · บันทึก/รายการตีกลับ · หน้าค้นหา · แดชบอร์ดยอดขาย · EDITH (ศูนย์จัดการเคส) · จัดการผู้ใช้

- เว็บจริง: https://faceadvance.github.io/face-advance-monthly-orders/
- ประวัติการเปลี่ยนแปลงทุก deploy: [`CHANGELOG.md`](CHANGELOG.md)

## สถาปัตยกรรม (Architecture A)
```
เบราว์เซอร์ ── frontend (static · GitHub Pages) ──► Supabase
                                                    ├─ RPC = ฟังก์ชันใน Postgres (ตรรกะหลักทั้งหมด)
                                                    ├─ Edge Functions: auth (login + LINE OTP), cod-upload
                                                    └─ Postgres: ตาราง · trigger · RLS
```
- **frontend ไม่อ่าน/เขียนตารางตรง** — เรียกผ่าน RPC (`frontend/src/api.ts`) และ Edge Function เท่านั้น
- ทุก RPC เป็น `SECURITY DEFINER` และตรวจ session token ในตัว · RLS ล็อกทุกตาราง
- frontend ถือแค่ anon key (เปิดเผยได้) · service key / DB URL / LINE token อยู่ฝั่ง Supabase หรือไฟล์ secret นอก repo เท่านั้น
- ตรรกะธุรกิจอยู่ใน DB เป็นหลัก เช่น `reconcile_order` (trigger คิดสถานะจากเงินเข้า COD / ตีกลับ) · CHECK constraint กันข้อมูลผิด

## โครงสร้างโฟลเดอร์
| โฟลเดอร์ | คืออะไร |
|---|---|
| `frontend/` | Vite + TypeScript · โค้ดหน้าเว็บ `src/` · เทส `tests/` (node:test) |
| `edge-functions/` | Edge Function `auth` และ `cod-upload` (deploy บน Supabase) |
| `auth/` | สคริปต์สร้าง/รีเซ็ตบัญชีผู้ใช้ (`create_user.sh`) |
| `docs/specs/` | สเปก/แผนงานของฟีเจอร์ |
| `design/` | mockup หน้าจอ · ดู `DESIGN-DECISIONS.md` |
| `API-CONTRACT.md` | สัญญา RPC ระหว่าง frontend ↔ DB |
| `backend/`, `start-dev.sh` | ⚠️ **เลิกใช้แล้ว** (FastAPI รุ่นแรก) เก็บไว้อ้างอิง — `auth/create_user` ยังใช้ venv ในนี้ |

โค้ดฝั่ง DB อยู่นอกโฟลเดอร์นี้ (รากโปรเจกต์):
- `database/schema/public-schema.sql` — โครงสร้าง DB ทั้งหมด (ตาราง · ฟังก์ชัน · trigger · สิทธิ์) · ไม่มีข้อมูล
- `database/migrations/` — การเปลี่ยนแปลง DB แต่ละครั้ง (ตั้งแต่ 2026-09-16)

## พัฒนาในเครื่อง
```bash
cd "frontend"
npm install
npm run dev          # http://127.0.0.1:5173
npm test             # เทสหน้าเว็บ (node:test)
npx tsc --noEmit     # ตรวจ type
npm run build        # build ไป dist/
```
หน้าเว็บในเครื่องต่อ Supabase จริง → **ห้ามทดสอบกับข้อมูลจริง** · ทดสอบ DB ด้วย transaction แล้ว rollback · ทดสอบหน้าเว็บด้วย RPC จำลอง

## Deploy
- **frontend:** push `main` → GitHub Actions build + deploy ขึ้น GitHub Pages อัตโนมัติ · deploy ตามเวลาที่ตกลงกันเท่านั้น
- **DB:** รัน migration ใน `database/migrations/` (ทดสอบใน transaction ก่อนเสมอ) · ถ้าไม่เข้ากับเว็บเวอร์ชันเก่า → ขึ้นหน้าเว็บก่อน
- ทุก deploy ต้องบันทึกใน `CHANGELOG.md` ใน commit เดียวกัน (ทั้ง frontend และ DB)

## 🔒 ความปลอดภัย (repo นี้เป็น public)
- ห้าม commit: ข้อมูลลูกค้า (ชื่อ เบอร์ ที่อยู่ เลขพัสดุ) · ไฟล์ Excel/CSV · secret ทุกชนิด — ดู `.gitignore` ที่รากโปรเจกต์
- ก่อน commit ไฟล์ที่ดึงมาจาก DB (เช่น schema) ต้องสแกนหา secret และข้อมูลลูกค้าก่อน
