// ข้อความของปุ่ม "คัดลอกข้อมูล" หน้ารายการตีกลับ
// แยกไฟล์เพื่อเทสได้ด้วย node --test (ไม่พึ่ง DOM) — แนวเดียวกับ dock.ts / dashboard_calc.ts

/** ฟิลด์เท่าที่ข้อความคัดลอกใช้ — รับแบบ structural จะได้ไม่ผูกกับ api.ts (เทสง่าย) */
export interface CopyRow {
  phone: string | null;
  customer_name: string | null;
  total_sales: number;
  tracking_out: string | null;
  items: string | null;
}

const dash = (s: string | null | undefined) => (s && s.trim() !== "" ? s.trim() : "-");

/** แตกรายการสินค้าที่ RPC ส่งมา ("ชื่อ ×จำนวน" คั่น \n) เป็นบรรทัดๆ
 *  กัน: null · สตริงว่าง · \r\n จากข้อมูลนำเข้า · บรรทัดว่าง · ช่องว่างหัวท้าย */
export function itemLines(items: string | null | undefined): string[] {
  if (!items) return [];
  return items.split(/\r?\n/).map((s) => s.trim()).filter((s) => s !== "");
}

/** 1 แถว → ข้อความตามแพทเทิร์นที่เจ้านายกำหนด
 *    เบอร์โทร : xxx
 *    ชื่อลูกค้า : xxx
 *    ยอดขาย : x,xxx
 *    เลขแทร็ค : xxx
 *    รายการสินค้า : <ชิ้นแรก>
 *    <ชิ้นที่ 2>
 *    ...
 *  🔴 ชิ้นแรกต่อท้ายหัวข้อ ที่เหลือขึ้นบรรทัดใหม่ บรรทัดละชิ้น ไม่เยื้อง (เจ้านายกำหนด 2026-09-21)
 *  ส่ง nf เข้ามาแทนที่จะ import จาก util.ts เพราะ util แตะ DOM — เทสใน node จะพัง */
export function rowToText(r: CopyRow, nf: (n: number) => string): string {
  const items = itemLines(r.items);
  return [
    `เบอร์โทร : ${dash(r.phone)}`,
    `ชื่อลูกค้า : ${dash(r.customer_name)}`,
    `ยอดขาย : ${nf(r.total_sales)}`,
    `เลขแทร็ค : ${dash(r.tracking_out)}`,
    `รายการสินค้า : ${items.length ? items.join("\n") : "-"}`,
  ].join("\n");
}

/** คั่นระหว่างแถว: บรรทัดว่าง · --- · บรรทัดว่าง */
export const ROW_SEP = "\n\n---\n\n";

export function rowsToText(rows: CopyRow[], nf: (n: number) => string): string {
  return rows.map((r) => rowToText(r, nf)).join(ROW_SEP);
}
