"""การเชื่อมต่อ DB — โหลด connection string จาก ~/.claude/secrets.env
🔒 ห้าม return / log ค่า connection string หรือ password ออกไปเด็ดขาด
"""
from __future__ import annotations

import os
import re
from pathlib import Path

import psycopg

_SECRETS = Path.home() / ".claude" / "secrets.env"
_KEY = "SUPABASE_DB_URL_FACEADVANCE"


def _load_dsn() -> str:
    """อ่านค่าคีย์ DB จาก secrets.env (รองรับค่าที่ครอบด้วย ' หรือ ")."""
    # เผื่อ export ไว้ใน environment แล้ว
    env = os.environ.get(_KEY)
    if env:
        return env.strip().strip("'\"")

    if not _SECRETS.exists():
        raise RuntimeError(f"ไม่พบไฟล์ secrets: {_SECRETS}")

    for line in _SECRETS.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(rf"^(?:export\s+)?{re.escape(_KEY)}=(.*)$", line)
        if m:
            val = m.group(1).strip()
            # ตัด inline comment ที่อยู่นอก quote ทิ้ง (ระวัง comment ไม่ให้ตัดกลาง value)
            if val and val[0] in "'\"":
                q = val[0]
                end = val.find(q, 1)
                if end != -1:
                    return val[1:end]
            return val.split(" #")[0].strip().strip("'\"")

    raise RuntimeError(f"ไม่พบคีย์ {_KEY} ใน {_SECRETS}")


_DSN = _load_dsn()


def connect() -> psycopg.Connection:
    """เปิด connection ใหม่ (read-only, autocommit) — volume ต่ำ ผู้ใช้เดียว."""
    return psycopg.connect(_DSN, autocommit=True, connect_timeout=10)
