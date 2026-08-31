#!/usr/bin/env python3
"""
แปลงไฟล์ Export Orders ของ GoSell (.xlsx) → SQL สำหรับนำเข้าตาราง orders / order_items
(+ สร้าง/ผูก customers ผ่านเบอร์โทรอัตโนมัติ).

ใช้: python3 import_gosell_orders.py "<ไฟล์.xlsx>" > out.sql
แล้วรัน out.sql กับ Supabase (execute_sql) — เป็น transaction เดียว (begin/commit).

หลักการ map (ยืนยันกับ boss 2026-08-28):
- 1 แถว = 1 รายการสินค้า, 1 ออเดอร์กินหลายแถว (group by เลขที่คำสั่งซื้อ)
- ยอดเงินระดับออเดอร์อยู่บรรทัดแรก (บรรทัดอื่นเป็น '-')
- total_sales = คอลัมน์ "รวมทั้งสิ้น" (ยอดหลังหักส่วนลดท้ายบิล)
- seller_id = รหัสพนักงานที่ต่อท้ายชื่อลูกค้า (เช่น m11) → sellers.employee_code  (คอลัมน์ "พนักงานขาย" ไม่ใช้)
- customer_name = เก็บทั้งชื่อ+โค้ดท้าย ตามไฟล์
- เบอร์: ใช้เบอร์โทร1 เท่านั้น (normalize เป็นตัวเลขล้วน)
- brand = อนุมานจากสินค้าในออเดอร์ (validate ห้ามปนแบรนด์) — ทำใน SQL
"""
import sys, re, openpyxl

# --- mapping ค่าตายตัว (GoSell → schema เรา) ---
PAYMENT_METHOD = {
    'เก็บเงินปลายทาง': 'เก็บเงินปลายทาง',
    'การโอนเงิน': 'โอนเงิน',
    'ตัดบัตรเครดิต': 'ตัดบัตรเครดิต',
    'บัตรเครดิต': 'ตัดบัตรเครดิต',
}
PAYMENT_STATUS = {
    'รอการชำระเงิน': 'รอชำระ',
    'ยืนยันแล้ว': 'ชำระแล้ว',
    'canceled': 'ยกเลิก',
    'ยกเลิก': 'ยกเลิก',
}
DELIVERY_STATUS = {
    'กำลังแพ็ค': 'รอส่ง',   # ยังไม่ส่ง = รอส่ง (ยืนยันกับ boss 2026-08-31)
    'พร้อมจัดส่ง': 'รอส่ง',
    'จัดส่งแล้ว': 'ส่งแล้ว',
    'จัดส่งสำเร็จ': 'ส่งสำเร็จ',
    'ตีกลับ': 'ตีกลับ',
    'ยกเลิก': 'ยกเลิก',
}


def clean(v):
    """คืน None ถ้าเป็นค่าว่าง / '-' / ช่องว่างล้วน"""
    if v is None:
        return None
    s = str(v).strip()
    if s == '' or s == '-':
        return None
    return s


def q(v):
    """escape เป็น SQL literal หรือ null"""
    if v is None:
        return 'null'
    return "'" + str(v).replace("'", "''") + "'"


def norm_phone(v):
    s = clean(v)
    if s is None:
        return None
    return re.sub(r'\D', '', s)


def seller_code(customer_name):
    if not customer_name:
        return None
    m = re.search(r'([A-Za-z]{1,4}\d{1,4})$', customer_name.strip())
    return m.group(1) if m else None


def main():
    if len(sys.argv) < 2:
        sys.exit('usage: import_gosell_orders.py <xlsx>')
    path = sys.argv[1]
    wb = openpyxl.load_workbook(path, data_only=True)
    ws = wb.worksheets[0]

    # หา header row (แถวที่มี 'เลขที่คำสั่งซื้อ')
    hdr_row = None
    for r in range(1, 8):
        vals = [ws.cell(row=r, column=c).value for c in range(1, ws.max_column + 1)]
        if 'เลขที่คำสั่งซื้อ' in vals:
            hdr_row = r
            H = vals
            break
    if hdr_row is None:
        sys.exit('หา header (เลขที่คำสั่งซื้อ) ไม่เจอ')

    def col(name):
        return H.index(name)

    c = {n: col(n) for n in [
        'เลขที่คำสั่งซื้อ', 'ลูกค้า', 'เบอร์โทร1', 'ที่อยู่', 'แขวง/ ตำบล', 'เขต/ อำเภอ',
        'จังหวัด', 'รหัสไปรษณีย์', 'ขนส่ง', 'หมายเลขพัสดุ', 'การชำระเงิน', 'สถานะการชำระเงิน',
        'สถานะการจัดส่ง', 'ชื่อสินค้า', 'จำนวนสินค้า', 'รวมทั้งสิ้น', 'วันที่สั่งซื้อ',
        'สถานะคำสั่งซื้อ', 'ชื่อโซเชียล',
    ]}

    rows = []
    for r in range(hdr_row + 1, ws.max_row + 1):
        v = [ws.cell(row=r, column=cc).value for cc in range(1, len(H) + 1)]
        if all(x is None for x in v):
            continue
        rows.append(v)

    # group by order (รักษาลำดับ)
    orders = {}
    for v in rows:
        key = str(v[c['เลขที่คำสั่งซื้อ']])
        orders.setdefault(key, []).append(v)

    warnings = []
    stg_ord = []   # (k, dict)
    stg_it = []    # (k, product_name, qty)

    for k, (okey, lines) in enumerate(orders.items(), start=1):
        first = lines[0]

        def firstval(ci):
            for l in lines:
                x = clean(l[ci])
                if x is not None:
                    return x
            return None

        # ข้ามออเดอร์ที่ยกเลิก (คอลัมน์ K = สถานะคำสั่งซื้อ) — เอาเฉพาะออเดอร์ส่งจริง
        order_status = firstval(c['สถานะคำสั่งซื้อ'])
        if order_status == 'ยกเลิก':
            warnings.append(f'order {okey}: สถานะคำสั่งซื้อ=ยกเลิก — ข้าม (ไม่ใช่ออเดอร์ส่งจริง)')
            continue

        cust = firstval(c['ลูกค้า'])
        phone = norm_phone(first[c['เบอร์โทร1']])
        if phone is None:
            warnings.append(f'order {okey}: ไม่มีเบอร์โทร1 — ข้าม')
            continue
        if not re.fullmatch(r'\d{8,15}', phone):
            warnings.append(f'order {okey}: เบอร์ผิดรูป {phone!r} — ข้าม')
            continue

        pm_raw = firstval(c['การชำระเงิน'])
        ps_raw = firstval(c['สถานะการชำระเงิน'])
        ds_raw = firstval(c['สถานะการจัดส่ง'])
        pm = PAYMENT_METHOD.get(pm_raw) if pm_raw else None
        if pm_raw and pm is None:
            warnings.append(f'order {okey}: การชำระเงินไม่รู้จัก {pm_raw!r} → เก็บ null')
        ps = PAYMENT_STATUS.get(ps_raw) if ps_raw else None
        ds = DELIVERY_STATUS.get(ds_raw) if ds_raw else None
        if ps is None:
            warnings.append(f'order {okey}: สถานะชำระไม่รู้จัก {ps_raw!r} → default รอชำระ')
            ps = 'รอชำระ'
        if ds is None:
            warnings.append(f'order {okey}: สถานะจัดส่งไม่รู้จัก {ds_raw!r} → default รอส่ง')
            ds = 'รอส่ง'

        tot_raw = firstval(c['รวมทั้งสิ้น'])
        try:
            total = int(round(float(tot_raw))) if tot_raw is not None else 0
        except (ValueError, TypeError):
            warnings.append(f'order {okey}: ยอดรวมอ่านไม่ได้ {tot_raw!r} → 0')
            total = 0
        if total < 0:
            warnings.append(f'order {okey}: ยอดติดลบ {total} → 0')
            total = 0

        dt = firstval(c['วันที่สั่งซื้อ'])
        ordered_at = f'{dt}+07' if dt else None
        if ordered_at is None:
            warnings.append(f'order {okey}: ไม่มีวันที่สั่งซื้อ — ข้าม')
            continue

        pc = firstval(c['รหัสไปรษณีย์'])
        if pc is not None:
            pc = re.sub(r'\D', '', pc)
            if not re.fullmatch(r'\d{5}', pc):
                warnings.append(f'order {okey}: ไปรษณีย์ผิดรูป {pc!r} → null')
                pc = None

        stg_ord.append((k, {
            'order_no': okey,
            'ordered_at': ordered_at,
            'customer_name': cust,
            'phone': phone,
            'addr_detail': firstval(c['ที่อยู่']),
            'subdistrict': firstval(c['แขวง/ ตำบล']),
            'district': firstval(c['เขต/ อำเภอ']),
            'province': firstval(c['จังหวัด']),
            'postal_code': pc,
            'seller_code': seller_code(cust),
            'carrier': firstval(c['ขนส่ง']),
            'tracking_no': firstval(c['หมายเลขพัสดุ']),
            'total_sales': total,
            'payment_method': pm,
            'payment_status': ps,
            'delivery_status': ds,
            # note (ช่วงนี้): เก็บค่าคอลัมน์ H (ชื่อโซเชียล) เฉพาะแถวที่มี "SO20"
            'note': (lambda s: s if (s and 'SO20' in s.upper()) else None)(firstval(c['ชื่อโซเชียล'])),
        }))

        for l in lines:
            pname = clean(l[c['ชื่อสินค้า']])
            if pname is None:
                continue
            try:
                qty = int(round(float(clean(l[c['จำนวนสินค้า']]) or 0)))
            except (ValueError, TypeError):
                qty = 0
            if qty <= 0:
                warnings.append(f'order {okey}: {pname} จำนวน<=0 — ข้ามรายการ')
                continue
            stg_it.append((k, pname, qty))

    # --- สร้าง SQL ---
    out = []
    out.append('-- generated by import_gosell_orders.py')
    out.append(f'-- source: {path}')
    out.append(f'-- orders: {len(stg_ord)} | items: {len(stg_it)}')
    out.append('begin;')
    out.append('create temp table stg_ord (k int primary key, order_no text, ordered_at timestamptz,'
               ' customer_name text, phone text, addr_detail text, subdistrict text, district text,'
               ' province text, postal_code text, seller_code text, carrier text, tracking_no text,'
               ' total_sales int, payment_method text, payment_status text, delivery_status text, note text)'
               ' on commit drop;')
    out.append('create temp table stg_it (k int, product_name text, quantity int) on commit drop;')

    for k, o in stg_ord:
        out.append(
            'insert into stg_ord values (' + ', '.join([
                str(k), q(o['order_no']), q(o['ordered_at']), q(o['customer_name']), q(o['phone']),
                q(o['addr_detail']), q(o['subdistrict']), q(o['district']), q(o['province']),
                q(o['postal_code']), q(o['seller_code']), q(o['carrier']), q(o['tracking_no']),
                str(o['total_sales']), q(o['payment_method']), q(o['payment_status']),
                q(o['delivery_status']), q(o['note']),
            ]) + ');')
    for k, pname, qty in stg_it:
        out.append(f'insert into stg_it values ({k}, {q(pname)}, {qty});')

    out.append(r'''
do $$
declare
  o record; it record;
  v_cust bigint; v_order bigint; v_brand bigint; v_nbrand int; v_seller bigint; v_prod bigint;
  v_dupdates text;
begin
  -- ── ยามกันวันซ้ำ: ถ้ามีวัน (เวลาไทย) ที่นำเข้าไปแล้ว → abort ทั้งไฟล์ ──
  select string_agg(x.d::text, ', ' order by x.d) into v_dupdates
  from (select distinct (ordered_at at time zone 'Asia/Bangkok')::date d from stg_ord) x
  where exists (
    select 1 from public.orders ord
    where ord.ordered_at >= (x.d::timestamp at time zone 'Asia/Bangkok')
      and ord.ordered_at <  ((x.d + 1)::timestamp at time zone 'Asia/Bangkok')
  );
  if v_dupdates is not null then
    raise exception 'วันที่ซ้ำกับที่นำเข้าแล้ว: % — ยกเลิกทั้งไฟล์ กรุณาตรวจสอบ (ถ้าซ้ำจริงให้ export ช่วงใหม่)', v_dupdates;
  end if;

  for o in select * from stg_ord order by k loop
    -- แบรนด์จากสินค้าในออเดอร์ (ห้ามปนแบรนด์ / สินค้าต้อง match ครบ)
    select count(distinct b.id), min(b.id) into v_nbrand, v_brand
    from stg_it si
    join public.products p on p.name = si.product_name
    join public.categories c on c.id = p.category_id
    join public.brands b on b.id = c.brand_id
    where si.k = o.k;
    if v_nbrand is null or v_nbrand = 0 then
      raise exception 'order k=% (%): สินค้าไม่ match DB เลย', o.k, o.order_no;
    elsif v_nbrand > 1 then
      raise exception 'order k=% (%): ปนแบรนด์ % ชนิด', o.k, o.order_no, v_nbrand;
    end if;

    -- ผู้ขายจากรหัสท้ายชื่อ (active ก่อน)
    v_seller := null;
    if o.seller_code is not null then
      select id into v_seller from public.sellers
       where employee_code = o.seller_code order by is_active desc, id limit 1;
    end if;

    -- ลูกค้า: หา/สร้างจาก (แบรนด์ + เบอร์)
    select cp.customer_id into v_cust from public.customer_phones cp
     where cp.brand_id = v_brand and cp.phone = o.phone;
    if v_cust is null then
      insert into public.customers(brand_id) values (v_brand) returning id into v_cust;
      insert into public.customer_phones(customer_id, brand_id, phone)
        values (v_cust, v_brand, o.phone);
    end if;

    insert into public.orders(
      brand_id, customer_id, order_no, ordered_at, customer_name, phone,
      addr_detail, subdistrict, district, province, postal_code, seller_id,
      total_sales, payment_method, carrier, tracking_no, payment_status, delivery_status, note)
    values(
      v_brand, v_cust, nullif(o.order_no,''), o.ordered_at, o.customer_name, o.phone,
      o.addr_detail, o.subdistrict, o.district, o.province, o.postal_code, v_seller,
      o.total_sales, o.payment_method, o.carrier, o.tracking_no, o.payment_status, o.delivery_status, o.note)
    returning id into v_order;

    for it in select * from stg_it where k = o.k loop
      select id into v_prod from public.products where name = it.product_name limit 1;
      insert into public.order_items(order_id, product_id, quantity)
        values (v_order, v_prod, it.quantity);
    end loop;
  end loop;
end $$;
commit;''')

    sys.stdout.write('\n'.join(out) + '\n')
    if warnings:
        sys.stderr.write(f'\n=== WARNINGS ({len(warnings)}) ===\n')
        for w in warnings:
            sys.stderr.write('  ' + w + '\n')


if __name__ == '__main__':
    main()
