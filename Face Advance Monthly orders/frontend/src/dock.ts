// คณิตจัดวาง Dock (macOS magnify) — pure function ไม่แตะ DOM เพื่อให้ test ได้
// สเปกเจ้านาย 2026-09-04:
//  1) ไอคอนที่ชี้ใหญ่สุด · โตจน "เส้นขอบซ้ายของ dock อยู่ที่ 25% ของไอคอน" (โผล่พ้นขอบซ้าย 25%) · ข้างๆ เป็น wave (cosine-bell)
//  2) ระยะห่างระหว่างไอคอน (ขอบถึงขอบ) = G คงที่เสมอ → repack แกน Y
//  3) กรอบ dock **ยืดแค่บน-ล่าง** (ระยะขอบ→ไอคอน = P คงที่) · **ความกว้างคงที่ ไม่ขยายออกซ้าย**
//     → ไอคอนที่โตจะเลื่อนตัวเองออกไปทางซ้าย (โผล่พ้นกรอบ) ส่วนกรอบอยู่กับที่

export const DOCK = {
  B: 46,          // ขนาดไอคอนตอนพัก
  G: 16,          // ระยะห่างขอบไอคอน (คงที่)
  P: 12,          // ระยะขอบ dock → ไอคอน แนวนอน (ขวา) — คงที่เสมอ
  PV: 24,         // ระยะขอบ dock → ไอคอน แนวตั้ง (บน/ล่าง) = 2 เท่าของแนวนอน — คงที่เสมอ
  SPREAD: 150,    // รัศมี wave จากเมาส์ (px)
  DOCK_RIGHT: 14, // ระยะกรอบจากขอบขวาจอ
  OUT: 0.25,      // ตอนโตสุด ไอคอนโผล่พ้นขอบซ้ายกรอบ = 25% ของความกว้างไอคอน
} as const;

/** ความกว้างกรอบ — คงที่เสมอ (ไม่ขยายออกซ้าย) · ตอนพักไอคอนเว้นขอบ P เท่ากันทุกด้าน */
export const DOCK_WIDTH = DOCK.B + 2 * DOCK.P;
/** ขอบขวาไอคอน (จากขอบขวาจอ) — **คงที่เสมอ** ไอคอนชิดขวาตรงกันทุกตัว โตออกทางซ้ายอย่างเดียว */
export const ITEM_RIGHT = DOCK.DOCK_RIGHT + DOCK.P;
/** ขนาดโตสุด — คำนวณจาก 2 เงื่อนไขพร้อมกัน (ขอบขวาคงที่ P + โผล่พ้นซ้าย OUT)
 *  overhang = (ITEM_RIGHT + s) − (DOCK_RIGHT + DOCK_WIDTH) = s − B − P  →  ตั้ง = OUT·s  ⇒  s = (B+P)/(1−OUT) */
export const MAX_ITEM = (DOCK.B + DOCK.P) / (1 - DOCK.OUT);
export const GROW = MAX_ITEM - DOCK.B;

/** กล่อง hit-area (ขนาดคงที่ ครอบ dock ได้ทุกสถานะ) — ให้ mousemove ต่อเนื่องแม้เมาส์อยู่ช่องว่างระหว่างไอคอน
 *  ต้องคงที่ ไม่ผูกกับ cursor มิฉะนั้นกล่องจะขยับหนีเมาส์ → เข้า/ออกสลับกัน (flicker) */
export function dockHitBox(n: number): { width: number; height: number } {
  const { G, PV } = DOCK;
  if (!Number.isFinite(n) || n <= 0) return { width: 0, height: 0 };
  return {
    width: ITEM_RIGHT + MAX_ITEM + 14,              // ครอบไอคอนที่โผล่พ้นซ้ายสุด + เผื่อเงา
    height: n * MAX_ITEM + (n - 1) * G + 2 * PV,    // ความสูงมากสุดที่เป็นไปได้
  };
}

export interface DockLayout {
  sizes: number[];   // ขนาดไอคอน (กว้าง=สูง)
  tops: number[];    // top ของไอคอน (px จากขอบบนจอ)
  rights: number[];  // ระยะขอบขวาไอคอน จากขอบขวาจอ (px) — โตแล้วเลื่อนออกซ้าย
  dockTop: number;
  dockHeight: number;
  dockWidth: number; // คงที่เสมอ = DOCK_WIDTH
}

export function computeDockLayout(n: number, cursorY: number | null, vh: number): DockLayout {
  const { B, G, PV, SPREAD } = DOCK;
  if (!Number.isFinite(n) || n <= 0) {
    return { sizes: [], tops: [], rights: [], dockTop: 0, dockHeight: 0, dockWidth: DOCK_WIDTH };
  }
  const totalRest = n * B + (n - 1) * G;
  const restTop = vh / 2 - totalRest / 2;
  const sizes: number[] = [];
  for (let i = 0; i < n; i++) {
    if (cursorY == null || !Number.isFinite(cursorY)) { sizes.push(B); continue; }
    const restCenter = restTop + B / 2 + i * (B + G);
    const d = Math.abs(cursorY - restCenter);
    const f = d >= SPREAD ? 0 : (Math.cos((d / SPREAD) * Math.PI) + 1) / 2;
    sizes.push(B + GROW * f);   // GROW คำนวณจากสเปก (ไม่ตั้งมั่ว) → โตสุด = MAX_ITEM
  }
  // แกน Y: repack ให้ระยะห่างขอบไอคอน = G เสมอ · จัดกลุ่มให้อยู่กึ่งกลางจอ
  const rel: number[] = [];
  for (let i = 0; i < n; i++) rel[i] = i === 0 ? sizes[0] / 2 : rel[i - 1] + sizes[i - 1] / 2 + G + sizes[i] / 2;
  const total = rel[n - 1] + sizes[n - 1] / 2;
  const top0 = vh / 2 - total / 2;
  const tops = sizes.map((s, i) => top0 + rel[i] - s / 2);
  // แกน X: **ขอบขวาไอคอนคงที่เสมอ** (ชิดขวาตรงกันทุกตัว ทุกสถานะ) → โตออกทางซ้ายอย่างเดียว
  const rights = sizes.map(() => ITEM_RIGHT);
  return { sizes, tops, rights, dockTop: top0 - PV, dockHeight: total + 2 * PV, dockWidth: DOCK_WIDTH };
}
