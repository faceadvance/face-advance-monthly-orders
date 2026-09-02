# ระบบ MO — Face Advance Monthly orders

เว็บแอปดู/จัดการ**ออเดอร์รายเดือน** (GoSell, รวมทุกแบรนด์) — frontend static ต่อ **Supabase** ตรง

> 📖 ไฟล์นี้คือสมุดอ้างอิงระบบ เปิดอ่านแล้วรู้ทันทีว่าอะไรเป็นอะไร

## คำเรียก / ชื่อย่อ
- **"ระบบ MO"** = ระบบนี้ (Monthly Orders) — เวลาพูดถึง "MO" หมายถึงตัวนี้

## ลิงก์
- **Live:** https://faceadvance.github.io/face-advance-monthly-orders/
- **Repo:** github.com/faceadvance/face-advance-monthly-orders (deploy GitHub Pages อัตโนมัติเมื่อ push main)
- **Supabase:** project ref `xfayguljywhjwqcuimvw` ("Face Advance DB", org faceadvances.th)

## สแตก / สถาปัตยกรรม (Architecture A)
- **Frontend:** Vite + TypeScript (vanilla) static → เรียก **Supabase RPC** ตรง (anon key + session token) · deploy GitHub Pages
- **Auth:** Edge Function `auth` (ถือ service role + LINE token) · RLS ล็อกทุกตาราง อ่าน/เขียนผ่าน SECURITY DEFINER RPC เท่านั้น
- service key / DB URL / LINE token **ไม่อยู่ frontend** · anon key = public ปลอดภัยโดยดีไซน์

## การเข้าสู่ระบบ (login)
- **username + password + LINE OTP** (2FA) · OTP หมดอายุ 5 นาที
- **OTP ส่งเข้า LINE ของผู้ใช้แต่ละคน** (ตาม `line_user_id` ของบัญชีนั้น) — บอทต้องเป็นเพื่อนกับ LINE ของ user นั้นก่อน
- **session มี 2 ตัวจับเวลา** (ต้องผ่านทั้งคู่):
  - **TTL** (`session_hours`, default 12ชม.) = อายุสูงสุดนับจากล็อกอิน
  - **idle lock** (`idle_minutes`, default 30น.) = นิ่งเกินนี้ = เด้งออก (ทุก action รีเซ็ตตัวนับ)

## สิทธิ์ (role)
| role | ทำอะไรได้ |
|---|---|
| **editor** | ดูทุกอย่าง + แก้สถานะ/บันทึกติดตาม (sidebar) + นำเข้าไฟล์ |
| **viewer** | **ดูอย่างเดียว** — ดู/ค้นหา/กรอง/คัดลอกเลขแทร็คได้ · เปิด sidebar/แก้ไข/นำเข้า **ไม่ได้** (ขึ้นเตือน "ไม่มีสิทธิ์แก้ไขข้อมูล") · บล็อกฝั่ง server ด้วย |

## บัญชีผู้ใช้
| username | role | session | หมายเหตุ |
|---|---|---|---|
| aom-pinchaya | editor | 12ชม. / 30น. | — |
| **friday** | editor | **24ชม. / 24ชม.** | บัญชีเจ้านาย |
| **plug** | viewer | 12ชม. / 30น. | ผู้ดูอย่างเดียว |

> สร้าง/รีเซ็ตบัญชี: `bash auth/create_user.sh` (พิมพ์รหัสเอง getpass → เก็บ bcrypt hash เท่านั้น ไม่เก็บ plain)
> LINE userid ปัจจุบันทั้ง 3 บัญชีชี้ที่ LINE ของเจ้านาย (aom/plug = ชั่วคราว)

## โครงสร้างโฟลเดอร์
- `frontend/` — Vite+TS · login `src/auth.ts` · แอปหลัก `src/main.ts` · API `src/api.ts` · config `src/config.ts` · session `src/session.ts`
- `edge-functions/auth/` — Edge Function login/verify/logout (ส่ง OTP Flex) — deploy บน Supabase
- `auth/` — `create_user.sh` / `create_user.py`
- `docs/specs/` — สเปกแต่ละฟีเจอร์ (ล่าสุด: order tracking, detail presets)
- `backend/` — **(เลิกใช้)** FastAPI Stage 1 เดิม · `design/` — mockup

## ฟีเจอร์ที่มี (ถึง 2026-09-02)
- **Stage 1:** ดูออเดอร์รายเดือน · KPI 3 การ์ด + กราฟรายวัน · กรอง/ค้นหา/ซูม · เลือกเลขแทร็คคัดลอก (สูงสุด 30)
- **Stage 3:** login username+password+LINE OTP + audit
- **Stage 5:** บันทึกติดตาม — แก้สถานะจัดส่ง/ชำระ (inline + sidebar) · โน้ต + ไทม์ไลน์ · เหตุผลตีกลับ/รายละเอียดปัญหา
- **Stage 5.1:** ชิปคำแนะนำรายละเอียดปัญหา (default=DB, คำใหม่+ลำดับ=localStorage) + autocomplete แบบ Sheets

## ยังไม่ทำ
- **Stage 2:** หน้านำเข้าไฟล์ (ปุ่ม "นำเข้าไฟล์" ยัง placeholder)
- ชื่อผู้ขาย 20/74 คนว่างใน DB · `return_arrived` "ถึงแล้ว"
