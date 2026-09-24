// สถานะชำระ "บางส่วน" (2026-09-24) — ได้เงินไม่เต็ม เช่น เงินเคลมขนส่ง
// นับเงินเหมือน "ชำระแล้ว" เต็มจำนวนทุกที่ (เจ้านายเคาะ) · ตรงกับ public.is_paid_status ใน DB
export const PARTIAL = "บางส่วน";

export function isPaidStatus(s: string | null | undefined): boolean {
  return s === "ชำระแล้ว" || s === PARTIAL;
}

/** ตรวจยอดที่รับจริง: null = ผ่าน · ข้อความ = ผิด (เงื่อนไขเดียวกับ CHECK ใน DB) */
export function validatePartial(amount: number | null | undefined, total: number): string | null {
  if (amount == null || Number.isNaN(amount)) return "กรอกยอดที่รับจริง";
  if (amount <= 0) return "ยอดที่รับจริงต้องมากกว่า 0";
  if (amount >= total) return "ยอดที่รับจริงต้องน้อยกว่ายอดขาย (ถ้าได้เต็มให้เลือก ชำระแล้ว)";
  return null;
}

const baht = (n: number) => "฿" + n.toLocaleString("en-US", { maximumFractionDigits: 2 });
export function partialLabel(paid: number, total: number): string {
  return `รับจริง ${baht(paid)} จาก ${baht(total)}`;
}
