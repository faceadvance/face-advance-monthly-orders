# database/schema — ต้นฉบับโครงสร้าง DB

`public-schema.sql` = โครงสร้างทั้งหมดของ schema `public` ใน Face Advance DB (Supabase)
ตาราง · ฟังก์ชัน/RPC (`SECURITY DEFINER`) · trigger · index · RLS policy · สิทธิ์ (`GRANT`)

- **ไม่มีข้อมูลในตาราง** และไม่มีรหัสผ่าน/คีย์ — สแกนหา secret และข้อมูลลูกค้าก่อน commit ทุกครั้ง (repo เป็น public)
- เหตุผลที่ต้องมี: migration ช่วงแรกของโปรเจกต์ (ก่อน 2026-09-16) ทำผ่าน Supabase ตรง ไม่ได้เก็บเป็นไฟล์ · แพลนฟรีไม่มี backup อัตโนมัติ → ไฟล์นี้คือต้นฉบับโค้ดหลังบ้าน
- migration ที่เพิ่มหลังจากนี้ → `database/migrations/` ตามเดิม · สร้าง snapshot ใหม่เป็นระยะ (เช่น หลังเปลี่ยนโครงสร้างใหญ่)

## สร้างใหม่
ต้องใช้ `pg_dump` เวอร์ชันเดียวกับ DB ขึ้นไป (DB = Postgres 17) · connection string อยู่ในไฟล์ secret นอก repo

```bash
/opt/homebrew/opt/postgresql@17/bin/pg_dump "$SUPABASE_DB_URL" \
  --schema-only --schema=public --no-owner --no-comments -f /tmp/public.sql
# ตัดบรรทัด \restrict / \unrestrict (รหัสสุ่มของ pg_dump) → สแกน secret/ข้อมูลลูกค้า → ค่อยคัดลอกมาแทนไฟล์นี้
```
