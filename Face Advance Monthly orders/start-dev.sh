#!/usr/bin/env bash
# เริ่ม backend + frontend พร้อมกัน — Ctrl-C ปิดทั้งคู่
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

bash "$DIR/backend/run.sh" >/tmp/fa-backend.log 2>&1 &
BPID=$!
( cd "$DIR/frontend" && npm run dev ) &
FPID=$!
trap 'kill $BPID $FPID 2>/dev/null || true' EXIT INT TERM

echo "───────────────────────────────────────────"
echo " Backend : http://127.0.0.1:8787  (log: /tmp/fa-backend.log)"
echo " Frontend: http://127.0.0.1:5173  ← เปิดอันนี้"
echo " กด Ctrl-C เพื่อปิดทั้งคู่"
echo "───────────────────────────────────────────"
wait
