"""สร้าง/รีเซ็ตบัญชีผู้ใช้เว็บแอป Face Advance
- เจ้านายพิมพ์รหัสผ่านเอง (getpass ซ่อน) → เก็บเป็น bcrypt hash เท่านั้น ไม่เก็บ plain
- ต่อ DB ผ่าน SUPABASE_DB_URL_FACEADVANCE ใน ~/.claude/secrets.env
รัน: bash webapp/auth/create_user.sh
"""
from __future__ import annotations
import re
import sys
import getpass
from pathlib import Path

import psycopg

SECRETS = Path.home() / ".claude" / "secrets.env"
KEY = "SUPABASE_DB_URL_FACEADVANCE"


def dsn() -> str:
    for line in SECRETS.read_text(encoding="utf-8").splitlines():
        m = re.match(rf"^(?:export\s+)?{KEY}=(.*)$", line.strip())
        if m:
            v = m.group(1).strip()
            if v and v[0] in "'\"":
                q = v[0]; e = v.find(q, 1)
                if e != -1:
                    return v[1:e]
            return v.split(" #")[0].strip().strip("'\"")
    sys.exit(f"ไม่พบ {KEY} ใน {SECRETS}")


def main() -> None:
    u = input("username: ").strip()
    if not u:
        sys.exit("username ว่างไม่ได้")
    p1 = getpass.getpass("password: ")
    p2 = getpass.getpass("password (พิมพ์อีกครั้ง): ")
    if p1 != p2:
        sys.exit("รหัสผ่านไม่ตรงกัน")
    if len(p1) < 6:
        sys.exit("รหัสผ่านสั้นเกินไป (อย่างน้อย 6 ตัว)")
    dn = input("display name (เว้นว่าง = username): ").strip() or u

    with psycopg.connect(dsn(), autocommit=True) as c:
        c.execute(
            "insert into public.app_users(username, password_hash, display_name) "
            "values (%s, extensions.crypt(%s, extensions.gen_salt('bf')), %s) "
            "on conflict (username) do update set "
            "  password_hash = extensions.crypt(%s, extensions.gen_salt('bf')), "
            "  display_name = excluded.display_name, is_active = true",
            (u, p1, dn, p1),
        )
    print(f"✅ สร้าง/อัปเดตบัญชีเรียบร้อย: {u}  (display: {dn})")


if __name__ == "__main__":
    main()
