"""Face Advance — local backend (Stage 1: ดูออเดอร์)
ดู API-CONTRACT.md · bind 127.0.0.1 เท่านั้น · อ่านอย่างเดียว
"""
from __future__ import annotations

import calendar
import re
from datetime import date, datetime
from zoneinfo import ZoneInfo

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware

from db import connect

TZ = ZoneInfo("Asia/Bangkok")
MONTH_RE = re.compile(r"^(\d{4})-(\d{2})$")

app = FastAPI(title="Face Advance API (local)", version="1.0")

app.add_middleware(
    CORSMiddleware,
    # เฉพาะ frontend local เท่านั้น (Vite dev + preview)
    allow_origins=[
        "http://localhost:5173",
        "http://127.0.0.1:5173",
        "http://localhost:4173",
        "http://127.0.0.1:4173",
    ],
    allow_methods=["GET", "POST"],
    allow_headers=["*"],
)


def _parse_month(month: str) -> tuple[int, int]:
    m = MONTH_RE.match(month or "")
    if not m:
        raise HTTPException(status_code=400, detail="month ต้องอยู่รูปแบบ YYYY-MM")
    year, mon = int(m.group(1)), int(m.group(2))
    if not (1 <= mon <= 12) or not (2000 <= year <= 2100):
        raise HTTPException(status_code=400, detail="month ไม่ถูกต้อง")
    return year, mon


def _compose_address(parts: list[str | None]) -> str:
    return " ".join(p.strip() for p in parts if p and p.strip())


@app.get("/api/health")
def health():
    try:
        with connect() as conn, conn.cursor() as cur:
            cur.execute("select 1")
            cur.fetchone()
        return {"status": "ok"}
    except Exception as e:  # noqa: BLE001 — คืน error กว้างๆ แต่ไม่หลุด DSN
        raise HTTPException(status_code=503, detail=f"DB ต่อไม่ได้: {type(e).__name__}")


@app.get("/api/months")
def months():
    sql = """
        select distinct to_char(ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM') as ym
        from public.orders
        order by ym desc
    """
    with connect() as conn, conn.cursor() as cur:
        cur.execute(sql)
        rows = [r[0] for r in cur.fetchall()]
    return {"months": rows}


@app.get("/api/orders")
def orders(month: str = Query(...)):
    year, mon = _parse_month(month)
    days_in_month = calendar.monthrange(year, mon)[1]
    start = date(year, mon, 1)
    end = date(year + (mon == 12), (mon % 12) + 1, 1)
    today = datetime.now(TZ).date().isoformat()

    sql = """
        select
            o.id,
            to_char(o.ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD')            as date_th,
            to_char(o.ordered_at at time zone 'Asia/Bangkok', 'YYYY-MM-DD"T"HH24:MI:SS') as ts_th,
            coalesce(o.phone, '')          as phone,
            coalesce(o.customer_name, '')  as customer_name,
            o.addr_detail, o.subdistrict, o.district, o.province, o.postal_code,
            coalesce(o.carrier, '')        as carrier,
            coalesce(o.tracking_no, '')    as tracking_no,
            coalesce(o.payment_method, '') as payment_method,
            coalesce(o.total_sales, 0)     as total_sales,
            o.delivery_status,
            o.payment_status,
            coalesce(o.note, '')           as note
        from public.orders o
        where (o.ordered_at at time zone 'Asia/Bangkok')::date >= %s
          and (o.ordered_at at time zone 'Asia/Bangkok')::date <  %s
        order by o.ordered_at asc, o.id asc
    """
    with connect() as conn, conn.cursor() as cur:
        cur.execute(sql, (start, end))
        rows = cur.fetchall()

    out_orders = []
    exported = [0] * days_in_month
    sales_paid = [0] * days_in_month
    sales_unpaid = [0] * days_in_month
    returned = [0] * days_in_month
    kpi = {
        "exported_count": 0,
        "sales_total": 0,
        "sales_paid": 0,
        "sales_unpaid": 0,
        "returned_count": 0,
        "returned_amount": 0,
    }

    for r in rows:
        (oid, date_th, ts_th, phone, cname, addr_detail, subdistrict, district,
         province, postal_code, carrier, tracking_no, payment_method, total_sales,
         delivery_status, payment_status, note) = r

        day_idx = int(date_th[8:10]) - 1  # 0-based
        total_sales = int(total_sales or 0)

        out_orders.append({
            "id": oid,
            "date": date_th,
            "ordered_at": ts_th + "+07:00",
            "phone": phone,
            "customer_name": cname,
            "address": _compose_address(
                [addr_detail, subdistrict, district, province, postal_code]
            ),
            "carrier": carrier,
            "tracking_no": tracking_no,
            "payment_method": payment_method,
            "total_sales": total_sales,
            "delivery_status": delivery_status,
            "payment_status": payment_status,
            "note": note,
        })

        # KPI + รายวัน
        kpi["exported_count"] += 1
        kpi["sales_total"] += total_sales
        if 0 <= day_idx < days_in_month:
            exported[day_idx] += 1
        if payment_status == "ชำระแล้ว":
            kpi["sales_paid"] += total_sales
            if 0 <= day_idx < days_in_month:
                sales_paid[day_idx] += total_sales
        elif payment_status == "รอชำระ":
            kpi["sales_unpaid"] += total_sales
            if 0 <= day_idx < days_in_month:
                sales_unpaid[day_idx] += total_sales
        if delivery_status == "ตีกลับ":
            kpi["returned_count"] += 1
            kpi["returned_amount"] += total_sales
            if 0 <= day_idx < days_in_month:
                returned[day_idx] += 1

    return {
        "month": month,
        "days_in_month": days_in_month,
        "today": today,
        "orders": out_orders,
        "kpi": kpi,
        "daily": {
            "exported": exported,
            "sales_paid": sales_paid,
            "sales_unpaid": sales_unpaid,
            "returned": returned,
        },
    }
