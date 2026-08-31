#!/usr/bin/env bash
# นำเข้าไฟล์ SQL เข้า "Face Advance DB" อย่างปลอดภัย — มียามกันเข้าผิด DB
#
# ใช้: bash seed/run_import.sh <ไฟล์.sql>
#
# ต้องตั้งตัวแปรใน ~/.claude/secrets.env (มาร์คชื่อให้ชัดว่าตัวไหนคือตัวไหน):
#   SUPABASE_DB_URL_FACEADVANCE='...'   # ← Face Advance DB (โปรเจกต์นี้ ref xfayguljywhjwqcuimvw)
#   SUPABASE_DB_URL_CRM='...'           # ← crm-sale-dashboard (คนละตัว อย่าปน!)
#
set -euo pipefail

SQL_FILE="${1:?ใช้: run_import.sh <ไฟล์.sql>}"
[ -f "$SQL_FILE" ] || { echo "❌ ไม่พบไฟล์: $SQL_FILE"; exit 1; }

# shellcheck disable=SC1090
source ~/.claude/secrets.env
URL="${SUPABASE_DB_URL_FACEADVANCE:?❌ ยังไม่ได้ตั้ง SUPABASE_DB_URL_FACEADVANCE ใน ~/.claude/secrets.env}"

# ── ยาม: ต้องเป็น Face Advance DB จริง (มี 6 ตารางเรา + ไม่มีตารางของ crm) ──
GUARD=$(psql "$URL" -tAc "select
  (select count(*) from information_schema.tables
     where table_schema='public'
       and table_name in ('brands','products','customers','orders','order_items','sellers'))
  || '/' ||
  (select count(*) from information_schema.tables
     where table_schema='public'
       and table_name in ('calls','leaves','monthly_targets','hopeful_sales_map'))")

if [ "$GUARD" != "6/0" ]; then
  echo "❌ ABORT: ปลายทางไม่ใช่ Face Advance DB (guard=$GUARD, ต้องได้ 6/0)"
  echo "   กันเข้าผิด DB — ตรวจ SUPABASE_DB_URL_FACEADVANCE ให้ชี้โปรเจกต์ถูกก่อน"
  exit 1
fi

echo "✅ ปลายทาง = Face Advance DB (guard=$GUARD) — เริ่มนำเข้า $SQL_FILE"

# จับเวลาก่อน import เพื่อให้ detect สแกนเฉพาะลูกค้าที่เพิ่งเข้ามา
BEFORE=$(psql "$URL" -tAc "select now()")

psql "$URL" -v ON_ERROR_STOP=1 -f "$SQL_FILE"
echo "✅ นำเข้าเสร็จ (transaction commit แล้ว)"

# เฟส 1: ตรวจจับลูกค้าซ้ำ (ชื่อคล้าย/ที่อยู่เดียวกัน) เข้าคิวรอเจ้านายตรวจ
FLAGGED=$(psql "$URL" -tAc "select public.detect_customer_duplicates('${BEFORE}'::timestamptz)")
echo "🔍 ตรวจลูกค้าซ้ำ: เข้าคิวเพิ่ม ${FLAGGED// /} คู่"
PENDING=$(psql "$URL" -tAc "select count(*) from public.customer_review where status='pending'")
echo "   คิวรอตรวจทั้งหมด: ${PENDING// /} คู่ — ดู: select * from v_pending_customer_review;"
echo "   ยืนยันรวม: select public.merge_customers(<keep_id>, <dup_id>);"
