/** จำนวนสินค้าสำหรับแสดงผล — 0/ว่าง = ไม่ทราบจำนวน (ตรงกับ public.qty_txt ใน DB) */
export const qtyTxt = (n: number | null | undefined) => (n == null || n === 0 ? "?" : String(n));

/** บรรทัดสินค้า → "ชื่อ ×2" (จำนวน 0 → "ชื่อ ×?") */
export const itemLine = (it: { name: string; qty: number | null | undefined }) => `${it.name} ×${qtyTxt(it.qty)}`;
