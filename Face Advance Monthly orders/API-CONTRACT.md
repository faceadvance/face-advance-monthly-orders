# API Contract — เว็บแอป Face Advance (local backend)

> backend = FastAPI, bind **127.0.0.1** เท่านั้น · frontend (Vite, http://localhost:5173) เรียกผ่าน CORS
> DB = Face Advance DB (Postgres 17) · connection string จาก `~/.claude/secrets.env` คีย์ **`SUPABASE_DB_URL_FACEADVANCE`**
> 🔒 ห้าม return DB URL/service key/password ออกไปเด็ดขาด · ห้าม log ค่าเหล่านี้

เวลาไทย = **Asia/Bangkok** ทุกจุดที่แปลงวัน (ordered_at เป็น timestamptz)

---

## GET /api/health
→ `200 {"status":"ok"}` (เช็ก backend+DB ต่อได้)

## GET /api/months
คืนเดือนที่มีข้อมูล (ช่วย month-picker) เรียงใหม่→เก่า
```json
{ "months": ["2026-08"] }
```

## GET /api/orders?month=YYYY-MM
กรอง `ordered_at` (แปลงเป็นเวลาไทย) ให้อยู่ในเดือนนั้น · **รวมทุกแบรนด์** · เรียง `ordered_at` **ascending (เก่า→ใหม่)**

ถ้า `month` ผิดรูป → `400`. เดือนไม่มีข้อมูล → คืน orders ว่าง + kpi/daily เป็น 0 (ไม่ error)

```json
{
  "month": "2026-08",
  "days_in_month": 31,
  "today": "2026-08-31",          // วันนี้เวลาไทย (ISO date) — frontend ใช้เว้นแท่งวันอนาคต
  "orders": [
    {
      "id": 123,
      "date": "2026-08-26",                 // (ordered_at เวลาไทย)::date
      "ordered_at": "2026-08-26T10:30:00+07:00",
      "phone": "0812345678",
      "customer_name": "สมชาย ใจดี C209",     // เก็บโค้ดท้ายชื่อไว้ (ตามไฟล์)
      "address": "123 ม.4 บางรัก เมือง กรุงเทพฯ 10500",  // ประกอบบรรทัดเดียว (ดูกฎล่าง)
      "carrier": "Flash",                    // ว่าง = ""
      "tracking_no": "TH1234567890",         // ว่าง = ""
      "payment_method": "เก็บเงินปลายทาง",     // ช่องทางชำระ (เก็บเงินปลายทาง/โอนเงิน/ตัดบัตรเครดิต) · ว่าง = ""
      "total_sales": 590,                    // integer บาทถ้วน
      "delivery_status": "ส่งสำเร็จ",          // รอส่ง/ส่งแล้ว/ส่งสำเร็จ/ตีกลับ/ยกเลิก
      "payment_status": "ชำระแล้ว",           // รอชำระ/ชำระแล้ว/ยกเลิก
      "note": "SO202608-069031"              // ว่าง = ""
    }
  ],
  "kpi": {
    "exported_count": 219,        // จำนวนออเดอร์ทั้งเดือน (ทุกออเดอร์ในตาราง = ส่งจริง, ยกเลิกถูกกรองตั้งแต่ import)
    "sales_total": 370198,        // sum(total_sales) ทั้งเดือน
    "sales_paid": 12345,          // sum(total_sales) where payment_status='ชำระแล้ว'
    "sales_unpaid": 357853,       // sum(total_sales) where payment_status='รอชำระ'
    "returned_count": 0,          // count where delivery_status='ตีกลับ'
    "returned_amount": 0          // sum(total_sales) where delivery_status='ตีกลับ'
  },
  "daily": {
    "exported":    [/* len = days_in_month, index0=วันที่1 */ 0,0,...],
    "sales_paid":  [/* บาท ต่อวัน (payment_status='ชำระแล้ว') */],
    "sales_unpaid":[/* บาท ต่อวัน (payment_status='รอชำระ') */],
    "returned":    [/* count ต่อวัน (delivery_status='ตีกลับ') */]
  }
}
```

### กฎประกอบ `address` (บรรทัดเดียว)
เอา `[addr_detail, subdistrict, district, province, postal_code]` — ตัดตัวที่ว่าง/null ออก แล้ว join ด้วยช่องว่าง 1 ตัว (`' '`). ไม่ต้องเติมคำนำหน้า ต./อ./จ. (frontend ตัด ... เอง, คลิกดูเต็ม)

### schema อ้างอิง (public)
- `orders`: id, brand_id, customer_id, order_no, ordered_at(timestamptz), customer_name, phone, addr_detail, subdistrict, district, province, postal_code, total_sales(int), seller_id, payment_method, payment_status, delivery_status, carrier, tracking_no, note, created_at, updated_at
- ค่าตายตัว: payment_status ∈ {รอชำระ, ชำระแล้ว, ยกเลิก} · delivery_status ∈ {รอส่ง, ส่งแล้ว, ส่งสำเร็จ, ตีกลับ, ยกเลิก}

---

## Stage 2 (ยังไม่ทำ) — นำเข้าไฟล์
- `POST /api/import/preflight` (multipart xlsx) → รายงานตรวจ ไม่เข้า DB
- `POST /api/import/confirm` → เข้าจริง
- พอร์ต logic จาก `database/seed/import_gosell_orders.py` (guards ครบ) — spec เต็มทำตอน Stage 2
