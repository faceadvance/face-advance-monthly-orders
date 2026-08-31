#!/usr/bin/env bash
# สร้าง/รีเซ็ตบัญชีผู้ใช้เว็บแอป — เจ้านายพิมพ์รหัสผ่านเอง
set -euo pipefail
cd "$(dirname "$0")"
PY="../backend/.venv/bin/python"
[ -x "$PY" ] || { echo "ไม่พบ venv — รัน backend/run.sh ครั้งแรกก่อน หรือ pip install psycopg[binary]"; exit 1; }
exec "$PY" create_user.py
