// คณิต/ตรรกะล้วนของหน้า Dashboard — แยกไฟล์เพื่อเทสได้ด้วย node --test (ไม่พึ่ง DOM)
// แนวเดียวกับ dock.ts ที่แยกคณิตออกมาเทส

export type Gran = "year" | "month" | "day";

/** ป้ายแกน X ตาม granularity — ปี "2026" · เดือน "ม.ค." · วัน "1 ก.ย." */
const M_SHORT = ["ม.ค.", "ก.พ.", "มี.ค.", "เม.ย.", "พ.ค.", "มิ.ย.", "ก.ค.", "ส.ค.", "ก.ย.", "ต.ค.", "พ.ย.", "ธ.ค."];
export function axisLabel(k: string, gran: Gran): string {
  if (gran === "year") return k;
  const p = k.split("-");
  const mi = Number(p[1]) - 1;
  if (gran === "month") return M_SHORT[mi] ?? k;
  return `${Number(p[2])} ${M_SHORT[mi] ?? ""}`.trim();
}

/** ป้ายช่วงเวลาแบบอ่านง่าย — ใช้ในหัวเรื่อง */
export function rangeLabel(from: string, to: string, gran: Gran): string {
  const f = from.split("-"), t = to.split("-");
  if (gran === "year") return f[0] === t[0] ? f[0] : `${f[0]}–${t[0]}`;
  const fm = `${M_SHORT[Number(f[1]) - 1]} ${f[0]}`, tm = `${M_SHORT[Number(t[1]) - 1]} ${t[0]}`;
  if (gran === "month") return fm === tm ? fm : `${fm} – ${tm}`;
  const fd = `${Number(f[2])} ${M_SHORT[Number(f[1]) - 1]}`, td = `${Number(t[2])} ${M_SHORT[Number(t[1]) - 1]}`;
  if (from === to) return `${fd} ${f[0]}`;
  return `${fd} – ${td} ${t[0]}`;
}

/** % เติบโตเทียบช่วงก่อน — ช่วงก่อนเป็น 0 ถือว่าเทียบไม่ได้ (null) ไม่ใช่ +∞ */
export function growth(cur: number, prev: number): number | null {
  if (!prev) return null;
  return ((cur - prev) / prev) * 100;
}

/** ขีดแกน Y: หาค่าสูงสุดแล้วปัดขึ้นเป็นเลขกลมๆ + คืนเส้นกริด 4 ขีด */
export function yTicks(max: number, steps = 4): { top: number; ticks: number[] } {
  if (!(max > 0)) return { top: 1, ticks: [1, 0.75, 0.5, 0.25, 0] };
  // เลือก "ขั้นสวย" (1/2/2.5/5 × 10^n) ให้ top หารด้วย steps ลงตัว และไม่เหลือที่ว่างเกินจำเป็น
  // เดิมปัดด้วย 10^n ตรงๆ ทำให้ 14.76 ล้าน → แกนสูง 20 ล้าน เสียพื้นที่ 26% · ตอนนี้ได้ 16 ล้าน (ใช้ 92%)
  const target = max / steps;
  const mag = Math.pow(10, Math.floor(Math.log10(target)));
  let step = 0;
  for (const m of LADDER) {
    if (m * mag >= target) { step = m * mag; break; }
  }
  if (!step) step = 10 * mag;
  let top = step * steps;
  // แท่งสูงสุดไม่ชิดขอบบน
  if (max / top > 0.98) { step = nextStep(step); top = step * steps; }
  const ticks: number[] = [];
  for (let i = steps; i >= 0; i--) ticks.push(step * i);
  return { top, ticks };
}
const LADDER = [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10];
function nextStep(step: number): number {
  const mag = Math.pow(10, Math.floor(Math.log10(step)));
  const m = step / mag;
  const i = LADDER.findIndex((x) => Math.abs(x - m) < 1e-9);
  return i < 0 || i === LADDER.length - 1 ? step * 2 : LADDER[i + 1] * mag;
}

/** ย่อจำนวนเงินให้อ่านบนแกน — 1.2 ล้าน / 950,000 */
export function shortMoney(n: number): string {
  if (Math.abs(n) >= 1_000_000) {
    const v = n / 1_000_000;
    return (Number.isInteger(v) ? String(v) : v.toFixed(1)) + " ล้าน";
  }
  return n.toLocaleString("en-US");
}

/** ความสูงแท่ง (สัดส่วน 0–1) — กัน top=0 หาร 0 และกันค่าลบ */
export function barRatio(v: number, top: number): number {
  if (!(top > 0)) return 0;
  return Math.max(0, Math.min(1, v / top));
}

/** สัดส่วนแบรนด์ในแท่ง — รวมต้องได้ 1 เสมอถ้า total > 0 · total 0 → 0/0 ไม่ใช่ NaN */
export function brandSplit(hope: number, other: number): { h: number; o: number } {
  const t = hope + other;
  if (!(t > 0)) return { h: 0, o: 0 };
  return { h: hope / t, o: other / t };
}

/** สัดส่วนของหลายก้อน (0–1) — ใช้กับการ์ด "แยกตามฝ่าย" ที่มี 3 ก้อนขึ้นไป
 *  รวมต้องได้ 1 เสมอถ้ามีค่าบวกอยู่บ้าง · ผลรวม 0 หรือค่าลบ → 0 ทุกก้อน ไม่ใช่ NaN
 *  (brandSplit ทำได้แค่ 2 ก้อน จึงต้องมีตัวนี้แยก) */
export function shares(values: number[]): number[] {
  const safe = values.map((v) => (Number.isFinite(v) && v > 0 ? v : 0));
  const t = safe.reduce((a, b) => a + b, 0);
  if (!(t > 0)) return values.map(() => 0);
  return safe.map((v) => v / t);
}

/** ช่วงวันที่เริ่มต้นเมื่อสลับ granularity — ยึดขอบข้อมูลจริง ไม่หลุดออกนอกช่วง */
export function defaultRange(gran: Gran, min: string, max: string): { from: string; to: string } {
  if (gran === "year") return { from: min, to: max };
  const [y, m] = max.split("-");
  if (gran === "month") {
    const from = `${y}-01-01`;
    return { from: from < min ? min : from, to: max };
  }
  const from = `${y}-${m}-01`;
  return { from: from < min ? min : from, to: max };
}

/** กันเลือกช่วงเพี้ยน: สลับให้ถูกลำดับ + หนีบอยู่ในขอบข้อมูล */
export function clampRange(from: string, to: string, min: string, max: string): { from: string; to: string } {
  let f = from, t = to;
  if (f > t) [f, t] = [t, f];
  if (f < min) f = min;
  if (t > max) t = max;
  if (f > t) f = t;
  return { from: f, to: t };
}

/** ช่วงที่ข้อมูลยังไม่ครบ (เดือน/ปีปัจจุบันที่ยังไม่จบ) — ใช้ทำแท่งเส้นประ */
export function isPartial(k: string, gran: Gran, maxDate: string): boolean {
  if (gran === "day") return false;              // รายวันครบเสมอ (วันนั้นผ่านไปแล้ว)
  if (gran === "month") return k === maxDate.slice(0, 7);
  return k === maxDate.slice(0, 4);
}
