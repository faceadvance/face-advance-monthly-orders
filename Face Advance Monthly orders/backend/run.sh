#!/usr/bin/env bash
# รัน backend local — bind 127.0.0.1 เท่านั้น (ไม่เปิดออกเน็ต)
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -d .venv ]; then
  echo "สร้าง venv + ติดตั้ง deps ครั้งแรก..."
  python3 -m venv .venv
  ./.venv/bin/pip install -q --upgrade pip
  ./.venv/bin/pip install -q -r requirements.txt
fi

exec ./.venv/bin/uvicorn app:app --host 127.0.0.1 --port 8787 "$@"
