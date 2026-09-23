// หน้าค้นหา: เลือกค้นเฉพาะคอลัมน์ (เจ้านายขอ 2026-09-23) — ค่าต้องตรงกับ p_field ของ RPC app_search_orders
export type SearchField = "all" | "phone" | "name" | "address" | "tracking" | "note";

export const SEARCH_FIELDS: { value: SearchField; label: string }[] = [
  { value: "all", label: "ทั้งหมด" },
  { value: "phone", label: "เบอร์โทร" },
  { value: "name", label: "ชื่อลูกค้า" },
  { value: "address", label: "ที่อยู่" },
  { value: "tracking", label: "เลขแทร็ค" },
  { value: "note", label: "หมายเหตุ" },
];

export function normalizeField(v: string | null | undefined): SearchField {
  return (SEARCH_FIELDS.find((f) => f.value === v)?.value) ?? "all";
}

const labelOf = (f: SearchField) => SEARCH_FIELDS.find((x) => x.value === f)!.label;

export function searchPlaceholder(f: SearchField): string {
  return f === "all" ? "ค้นหา เบอร์ · ชื่อ · ที่อยู่ · แทร็ค · หมายเหตุ…" : `ค้นหาเฉพาะ${labelOf(f)}…`;
}

export function searchHint(f: SearchField): string {
  return f === "all"
    ? "พิมพ์ เบอร์ · ชื่อ · ที่อยู่ · แทร็คส่งออก · หมายเหตุ (อย่างน้อย 2 ตัว)"
    : `พิมพ์${labelOf(f)}ที่ต้องการค้นหา (อย่างน้อย 2 ตัว)`;
}
