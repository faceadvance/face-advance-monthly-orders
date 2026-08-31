import type { Order } from "./types";

export const THAI_MONTHS_FULL = [
  "มกราคม", "กุมภาพันธ์", "มีนาคม", "เมษายน", "พฤษภาคม", "มิถุนายน",
  "กรกฎาคม", "สิงหาคม", "กันยายน", "ตุลาคม", "พฤศจิกายน", "ธันวาคม",
];
export const THAI_MONTHS_SHORT = [
  "ม.ค.", "ก.พ.", "มี.ค.", "เม.ย.", "พ.ค.", "มิ.ย.",
  "ก.ค.", "ส.ค.", "ก.ย.", "ต.ค.", "พ.ย.", "ธ.ค.",
];

/** "2026-08" → "สิงหาคม 2026" (ปี ค.ศ. ตามข้อมูลจริง) */
export function monthLabel(month: string): string {
  const [y, m] = month.split("-").map(Number);
  return `${THAI_MONTHS_FULL[m - 1]} ${y}`;
}

/** "2026-08-26" → "26/8/2026" (d/M/yyyy) */
export function dmy(dateISO: string): string {
  const [y, m, d] = dateISO.split("-").map(Number);
  return `${d}/${m}/${y}`;
}

const NF = new Intl.NumberFormat("en-US");
export function nf(n: number): string {
  return NF.format(Math.round(n));
}

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K, attrs: Record<string, string> = {}, ...children: (Node | string)[]
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v;
    else node.setAttribute(k, v);
  }
  for (const c of children) node.append(c);
  return node;
}

export function icon(id: string, style = ""): SVGSVGElement {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("class", "ic");
  svg.setAttribute("viewBox", "0 0 24 24");
  if (style) svg.setAttribute("style", style);
  const use = document.createElementNS("http://www.w3.org/2000/svg", "use");
  use.setAttribute("href", `#${id}`);
  svg.append(use);
  return svg;
}

/** แยกโค้ดท้ายชื่อ (เช่น C209, j03, m11) ออกจากชื่อ — เก็บโค้ดไว้แสดงแยกสี */
export function splitNameCode(full: string): { name: string; code: string } {
  const m = full.match(/^(.*\S)\s+([A-Za-z]{1,4}\d{1,4})\s*$/);
  if (m) return { name: m[1], code: m[2] };
  return { name: full, code: "" };
}

/** map สถานะ → badge class + icon id */
export function deliveryBadge(s: string): { cls: string; icon: string } {
  switch (s) {
    case "ส่งสำเร็จ": return { cls: "g", icon: "i-check" };
    case "ส่งแล้ว":   return { cls: "b", icon: "i-truck" };
    case "รอส่ง":     return { cls: "a", icon: "i-clock" };
    case "ตีกลับ":    return { cls: "r", icon: "i-return" };
    case "ยกเลิก":    return { cls: "n", icon: "i-x" };
    default:          return { cls: "n", icon: "i-x" };
  }
}
export function paymentBadge(s: string): { cls: string; icon: string } {
  switch (s) {
    case "ชำระแล้ว": return { cls: "g", icon: "i-check" };
    case "รอชำระ":   return { cls: "a", icon: "i-clock" };
    case "ยกเลิก":   return { cls: "n", icon: "i-x" };
    default:         return { cls: "n", icon: "i-x" };
  }
}

/** ค่าที่ใช้ค้นหา/กรองของแต่ละคอลัมน์ */
export type ColKey =
  | "date" | "phone" | "customer_name" | "address"
  | "carrier" | "tracking_no" | "payment_method" | "total_sales"
  | "delivery_status" | "payment_status" | "note";

/** ช่องทางชำระ: ย่อ "เก็บเงินปลายทาง" → "COD" ให้สั้น (ค่าใน DB คงเดิม) */
export function paymentMethodLabel(v: string): string {
  return v === "เก็บเงินปลายทาง" ? "COD" : v;
}

export function cellValue(o: Order, col: ColKey): string {
  switch (col) {
    case "date": return dmy(o.date);
    case "total_sales": return String(o.total_sales);
    case "payment_method": return paymentMethodLabel(o.payment_method || "");
    default: return (o[col] ?? "") as string;
  }
}

/** ข้อความที่ใช้จับ search รวมทุกช่อง */
export function searchBlob(o: Order): string {
  return [o.phone, o.customer_name, o.tracking_no, o.address, o.note]
    .join(" ").toLowerCase();
}
