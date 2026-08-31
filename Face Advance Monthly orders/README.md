# เว็บแอป Face Advance (local)

เว็บแอปดูออเดอร์ + **login (username+password+LINE OTP)** — frontend static ต่อ **Supabase** (Edge Functions + RPC) ตรง · ยังไม่ deploy GitHub

## เริ่มใช้งาน
```bash
cd "webapp/frontend" && npm run dev
```
เปิด **http://127.0.0.1:5173** → หน้า login → กรอก username+รหัส → OTP เด้งเข้ากลุ่ม LINE → กรอก → เข้าแอป
> (ไม่ต้องรัน backend Python แล้ว — frontend คุย Supabase ตรง · `start-dev.sh`/`backend/` = ของเก่า Stage 1 เก็บไว้อ้างอิง)

## สร้าง/รีเซ็ตบัญชีผู้ใช้
```bash
bash "webapp/auth/create_user.sh"     # ถาม username + password (ซ่อน) → เก็บ bcrypt hash
```

## โครงสร้าง
- `frontend/` — Vite + TypeScript · login (`src/auth.ts`) + ดูออเดอร์ · เรียก Supabase RPC/Edge ตรง (`src/config.ts`, `src/api.ts`)
- `edge-functions/auth/` — Edge Function login/verify/logout (ส่ง OTP Flex เข้ากลุ่ม LINE) — deploy บน Supabase แล้ว
- `auth/` — `create_user.sh`/`create_user.py` สร้างบัญชี
- `backend/` — **(เลิกใช้)** FastAPI Stage 1 เดิม เก็บไว้อ้างอิง (venv ยังใช้โดย create_user)
- `design/` — mockup (`mockup-orders-v6.html`, `mockup-login.html`) · `DESIGN-DECISIONS.md`

## สถาปัตยกรรม (Architecture A)
- frontend static (anon key = public ปลอดภัย) → **Supabase RPC** (get_orders/get_months ตรวจ session token ในตัว) + **Edge Function `auth`** (ถือ service role + LINE token ข้างใน)
- RLS ล็อกทุกตาราง อ่านผ่าน SECURITY DEFINER fn เท่านั้น · service key/DB url/LINE token ไม่อยู่ frontend
- deploy ทีหลัง = push frontend ขึ้น GitHub Pages (Edge Functions อยู่ Supabase แล้ว ไม่ต้องทำ backend เพิ่ม)

## ฟีเจอร์ (Stage 1)
- ดูออเดอร์รายเดือน (รวมทุกแบรนด์) · การ์ดสรุป 3 ใบ + กราฟแท่งรายวัน
- ตารางเรียงเก่า→ใหม่ · กรองแต่ละคอลัมน์แบบ Google Sheets · ค้นหา · ซูมในแอป (จำค่า)
- หัวตารางตรึง (sticky) เวลาเลื่อน
- **เลือกเลขแทร็คหลายรายการแล้วคัดลอก** (สูงสุด 30 · คั่นเว้นวรรค · ปุ่มก๊อป+จำนวน+ยกเลิก)

## ยังไม่ทำ (ถัดไป)
- Stage 2: หน้านำเข้าไฟล์ · Stage 3: login (LINE OTP) + audit + deploy
- ปุ่ม "นำเข้าไฟล์" ตอนนี้ยังเป็น placeholder

## 🔒 ความปลอดภัย
- service key / DB URL อยู่แค่ backend ในเครื่อง ไม่หลุดออก frontend · backend bind 127.0.0.1 (ไม่เปิดออกเน็ต)
