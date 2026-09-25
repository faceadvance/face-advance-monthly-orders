// สินค้าเสียหาย/ขาดของบันทึกตีกลับ — ลอจิกล้วน (ไม่แตะ DOM) ใช้ในหน้าบันทึกตีกลับ + เทส
// กติกา (เจ้านายเคาะ 2026-09-25): สินค้าชนิดเดียวกันเลือกได้ทั้งใต้หัวข้อ "เสียหาย" และ "ขาด"
//   แต่จำนวนสองหัวข้อรวมกันต้องไม่เกินจำนวนในออเดอร์ (sync กัน)

export type DamageKind = "damaged" | "missing";   // เสียหาย (ส้ม) · ขาด/ไม่กลับมา (แดง)
export interface DamageItem { name: string; qty: number; kind: DamageKind }

/** ผลตรวจ → หัวข้อที่ต้องระบุ (ไม่ครบ+เสียหาย = ทั้งสองหัวข้อ) */
export function kindsFor(ins: string): DamageKind[] {
  if (ins === "สินค้าเสียหาย") return ["damaged"];
  if (ins === "สินค้าไม่ครบ") return ["missing"];
  if (ins === "สินค้าไม่ครบและเสียหาย") return ["damaged", "missing"];
  return [];
}

/** จำนวนของสินค้านี้ที่ใช้ไปในหัวข้ออื่น (ไม่นับหัวข้อ kind) */
function usedElsewhere(items: DamageItem[], name: string, kind: DamageKind): number {
  return items.filter((d) => d.name === name && d.kind !== kind).reduce((s, d) => s + d.qty, 0);
}

/** จำนวนสูงสุดที่ใส่ได้ในหัวข้อ kind = จำนวนในออเดอร์ − ที่ใช้ในอีกหัวข้อ */
export function maxQty(items: DamageItem[], name: string, kind: DamageKind, orderQty: number): number {
  return Math.max(0, orderQty - usedElsewhere(items, name, kind));
}

export const findDamage = (items: DamageItem[], name: string, kind: DamageKind) =>
  items.find((d) => d.name === name && d.kind === kind);

/** ติ๊ก/เอาออก สินค้าในหัวข้อ kind · คืนรายการใหม่ (null = เลือกไม่ได้ เพราะจำนวนถูกใช้ครบในอีกหัวข้อแล้ว) */
export function toggleDamage(items: DamageItem[], name: string, kind: DamageKind, orderQty: number): DamageItem[] | null {
  if (findDamage(items, name, kind)) return items.filter((d) => !(d.name === name && d.kind === kind));
  if (maxQty(items, name, kind, orderQty) < 1) return null;
  return [...items, { name, qty: 1, kind }];
}

/** ตั้งจำนวน (ปัดเป็นจำนวนเต็ม · อย่างน้อย 1 · ไม่เกินที่เหลือ) · คืนจำนวนที่ใช้จริง */
export function clampQty(items: DamageItem[], name: string, kind: DamageKind, want: number, orderQty: number): number {
  const max = maxQty(items, name, kind, orderQty);
  const n = Math.floor(Number.isFinite(want) ? want : 1);
  return Math.min(Math.max(n, 1), Math.max(max, 1));
}

/** ครบตามผลตรวจ = ทุกหัวข้อที่ต้องระบุมีสินค้าอย่างน้อย 1 รายการ และไม่มีสินค้าไหนเกินจำนวนในออเดอร์ */
export function damageOk(ins: string, items: DamageItem[], orderQty: (name: string) => number): boolean {
  const kinds = kindsFor(ins);
  if (!kinds.every((k) => items.some((d) => d.kind === k && d.qty >= 1))) return false;
  const names = new Set(items.map((d) => d.name));
  return [...names].every((n) => items.filter((d) => d.name === n).reduce((s, d) => s + d.qty, 0) <= orderQty(n));
}

/** ออเดอร์นี้เลือก "ไม่ครบ+เสียหาย" ได้ไหม — ต้องมีสินค้ารวมอย่างน้อย 2 ชิ้น (เสียหาย 1 + ขาด 1) */
export function canBoth(list: { qty: number }[]): boolean {
  return list.reduce((s, it) => s + Math.max(0, it.qty), 0) >= 2;
}
