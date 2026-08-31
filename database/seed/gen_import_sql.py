#!/usr/bin/env python3
"""อ่าน products_seed_01.tsv -> ตรวจตัวซ้ำ + gen SQL staging insert (escape ปลอดภัย)."""
import csv, sys, os
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
TSV = os.path.join(HERE, "products_seed_01.tsv")
OUT = os.path.join(HERE, "stg_insert.sql")

rows = []
with open(TSV, encoding="utf-8") as f:
    r = csv.reader(f, delimiter="\t")
    next(r)  # header
    for line in r:
        if not line or all(not c.strip() for c in line):
            continue
        main, sub, prod = (c.strip() for c in line[:3])
        rows.append((main, sub, prod))

print(f"อ่านได้ {len(rows)} แถว")

# ตัวซ้ำแบบเป๊ะ (main,sub,prod เหมือนกันทุกช่อง)
exact = [k for k, n in Counter(rows).items() if n > 1]
print(f"\n== ตัวซ้ำเป๊ะทั้ง 3 ช่อง: {len(exact)} ==")
for k in exact:
    print("  ", k, "x", Counter(rows)[k])

# ชื่อสินค้าเดียวกัน (prod) โผล่ >1 (อาจต่าง sub/ต่างขนาด)
prod_counter = Counter(p for _, _, p in rows)
dup_names = {p: n for p, n in prod_counter.items() if n > 1}
print(f"\n== ชื่อสินค้าซ้ำ (prod เดียวกัน >1 แถว): {len(dup_names)} ==")
for p, n in dup_names.items():
    ctx = [(m, s) for m, s, pp in rows if pp == p]
    print(f"  '{p}' x{n} -> {ctx}")

# near-dup: prod ต่างกันแต่คล้าย (normalize เอา space/เครื่องหมายออก) — เตือนคู่ [..*1]
def norm(s):
    return "".join(ch for ch in s.lower() if ch.isalnum())
byn = {}
for _, _, p in rows:
    byn.setdefault(norm(p), set()).add(p)
near = {k: v for k, v in byn.items() if len(v) > 1}
print(f"\n== near-dup (ชื่อคล้ายกันมากหลัง normalize): {len(near)} ==")
for k, v in near.items():
    print("  ", sorted(v))

# gen SQL
def esc(s):
    return s.replace("'", "''")

with open(OUT, "w", encoding="utf-8") as f:
    f.write("-- Auto-generated import: staging -> normalize -> drop. รันทีเดียว.\n")
    f.write("begin;\n")
    f.write("drop table if exists _import_stg;\n")
    f.write("create table _import_stg(main text, sub text, prod text);\n")
    f.write("insert into _import_stg(main,sub,prod) values\n")
    vals = ",\n".join(f"  ('{esc(m)}','{esc(s)}','{esc(p)}')" for m, s, p in rows)
    f.write(vals + ";\n\n")
    f.write("""-- brands (ประเภทหลัก)
insert into public.brands(name)
select distinct main from _import_stg
on conflict (name) do nothing;

-- categories (ประเภทย่อย) ผูกกับแบรนด์
insert into public.categories(brand_id, name)
select distinct b.id, s.sub
from _import_stg s
join public.brands b on b.name = s.main
on conflict (brand_id, name) do nothing;

-- products (รายการสินค้า) + ธง is_freebie เมื่อ ประเภทย่อย = 'แถม'
insert into public.products(category_id, name, is_freebie)
select distinct c.id, s.prod, (s.sub = 'แถม')
from _import_stg s
join public.brands b     on b.name = s.main
join public.categories c on c.brand_id = b.id and c.name = s.sub
on conflict (category_id, name) do nothing;

drop table _import_stg;
commit;
""")
print(f"\nเขียน SQL -> {OUT} ({len(rows)} rows)")
