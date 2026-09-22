// จำมุมมองตารางหน้าออเดอร์ — เก็บ "แยกรายเดือน" (ตัวกรอง · การเรียง · คำค้น · แถวที่ค้างไว้)
// แยกไฟล์เพราะเป็นตรรกะล้วน ไม่พึ่ง DOM → เทสได้ด้วย node --test (แนวเดียวกับ dock.ts / dashboard_calc.ts)
//
// 🔄 2026-09-22: ย้ายที่เก็บจาก localStorage (ผูกเครื่อง) → ตาราง app_user_views ใน DB (ต่อผู้ใช้)
//    รูปแบบข้อมูลข้างในเหมือนเดิมทุกอย่าง · ไฟล์นี้ยังเป็นตรรกะล้วน ไม่รู้ว่าเก็บที่ไหน
//
// ใช้ 2 จังหวะ:
//  1. สลับเดือนไปมาในระหว่างใช้งาน — กลับมาเดือนไหน ได้ตัวกรองของเดือนนั้นคืนทันที (เจ้านายขอ 2026-09-21)
//  2. ล็อกอินเข้ามาใหม่ บนหน้าออเดอร์ที่เป็นหน้าแรกของ role นั้น
//
// 🔴 กติกาเดือนตอนล็อกอิน (เจ้านายกำหนด):
//    เดือนล่าสุดที่ดูค้างไว้ "มีตัวกรอง/คำค้น" = ทำงานเจาะจงยังไม่จบ → กลับไปเดือนนั้น + แถวเดิม
//    ไม่มีเลย                               = เข้ามาทำงานปกติ     → เดือนปัจจุบัน/ล่าสุดที่มีข้อมูล + บนสุด
//    เหตุผล: กันพนักงานเปิดมาเจอเดือนเก่าค้างแล้วคีย์งานผิดเดือนโดยไม่รู้ตัว

/** ชื่อหน้าที่ใช้เป็นคีย์ใน app_user_views (เดิมเป็นคีย์ localStorage ชื่อ fa_view_orders) */
export const VIEW_PAGE = "orders";
/** v2 = เก็บแยกรายเดือน (v1 เก็บมุมมองเดียว · ค่าเก่าถูกทิ้งอัตโนมัติเพราะเวอร์ชันไม่ตรง) */
export const VIEW_VERSION = 2;
/** เดือนที่ไม่ได้แตะเกินนี้ → ทิ้ง (ทั้งตอนอ่านและตอนเขียน) */
export const MAX_AGE_DAYS = 14;
/** เก็บได้มากสุดกี่เดือน — กัน localStorage โตไม่สิ้นสุด (เก่าสุดหลุดก่อน) */
export const MAX_MONTHS = 12;

export interface MonthView {
  filters: [string, string[]][];                      // Map ลง JSON ตรงๆ ไม่ได้ → เก็บเป็น entries
  sort: { col: string; dir: "asc" | "desc" } | null;
  search: string;
  anchorId: number | null;                            // id แถวบนสุดที่เห็น (ไม่ใช่พิกเซล)
  savedAt: string;                                    // ISO — แยกรายเดือน เดือนที่ไม่ได้แตะจะหมดอายุเอง
}

export interface SavedView {
  v: number;
  lastMonth: string;                                  // เดือนที่ดูค้างไว้ล่าสุด
  months: Record<string, MonthView>;
}

/** แผนตอนล็อกอิน — ตอบแค่ 2 อย่าง: เปิดเดือนไหน · คืนตำแหน่งแถวไหม
 *  (ตัวกรอง/การเรียง/คำค้น ไม่ต้องอยู่ในแผน เพราะกฎ "จำตัวกรองรายเดือน" ใส่ให้อยู่แล้วทุกครั้งที่โหลดเดือน) */
export interface RestorePlan {
  month: string;
  anchorId: number | null;                            // null = ขึ้นบนสุด
}

const emptyView = (now: Date): MonthView =>
  ({ filters: [], sort: null, search: "", anchorId: null, savedAt: now.toISOString() });

/** เดือนเริ่มต้นเดิมของระบบ — เดือนล่าสุดที่มีข้อมูล ไม่มีเลยก็ใช้เดือนปัจจุบัน (main.ts:ensureOrders) */
export function defaultMonth(monthsWithData: string[], now = new Date()): string {
  return monthsWithData[0] ?? now.toISOString().slice(0, 7);
}

/** "กำลังทำงานเจาะจงอยู่" = มีตัวกรอง หรือ มีคำค้น (การเรียงไม่นับ เพราะไม่ได้ซ่อนแถวไหน) */
export function isNarrowed(v: Pick<MonthView, "filters" | "search"> | null | undefined): boolean {
  return !!v && (v.filters.length > 0 || v.search.trim() !== "");
}

export function isStale(v: MonthView, now = new Date(), days = MAX_AGE_DAYS): boolean {
  const t = Date.parse(v.savedAt);
  if (!Number.isFinite(t)) return true;
  return now.getTime() - t > days * 86_400_000;
}

// ---------- อ่านค่าแบบไม่เชื่อใจข้อมูล ----------
function parseMonthView(o: unknown): MonthView | null {
  if (!o || typeof o !== "object") return null;
  const d = o as Record<string, unknown>;
  if (typeof d.savedAt !== "string") return null;
  // ตัวกรองต้องเป็น [[string, string[]], ...] — แถวที่รูปไม่ตรงทิ้งทีละแถว ไม่ทิ้งทั้งก้อน
  const filters: [string, string[]][] = [];
  if (Array.isArray(d.filters)) {
    for (const e of d.filters) {
      if (!Array.isArray(e) || e.length !== 2) continue;
      const [k, vs] = e as [unknown, unknown];
      if (typeof k !== "string" || !Array.isArray(vs)) continue;
      const vals = vs.filter((x): x is string => typeof x === "string");
      if (vals.length) filters.push([k, vals]);
    }
  }
  let sort: MonthView["sort"] = null;
  if (d.sort && typeof d.sort === "object") {
    const s = d.sort as Record<string, unknown>;
    if (typeof s.col === "string" && (s.dir === "asc" || s.dir === "desc")) sort = { col: s.col, dir: s.dir };
  }
  return {
    filters,
    sort,
    search: typeof d.search === "string" ? d.search : "",
    anchorId: typeof d.anchorId === "number" && Number.isFinite(d.anchorId) ? d.anchorId : null,
    savedAt: d.savedAt,
  };
}

export function parseSaved(raw: string | null | undefined): SavedView | null {
  if (!raw) return null;
  let o: unknown;
  try { o = JSON.parse(raw); } catch { return null; }
  if (!o || typeof o !== "object") return null;
  const d = o as Record<string, unknown>;
  if (d.v !== VIEW_VERSION) return null;                       // คนละเวอร์ชัน → ทิ้ง ไม่ต้องแปลง
  if (typeof d.lastMonth !== "string" || !/^\d{4}-\d{2}$/.test(d.lastMonth)) return null;
  if (!d.months || typeof d.months !== "object") return null;
  const months: Record<string, MonthView> = {};
  for (const [k, v] of Object.entries(d.months as Record<string, unknown>)) {
    if (!/^\d{4}-\d{2}$/.test(k)) continue;
    const mv = parseMonthView(v);
    if (mv) months[k] = mv;
  }
  return { v: VIEW_VERSION, lastMonth: d.lastMonth, months };
}

/** มุมมองของเดือนนั้นที่ยังไม่หมดอายุ — ไม่มี/เก่าเกินไป → null */
export function monthView(saved: SavedView | null, month: string, now = new Date()): MonthView | null {
  const v = saved?.months[month];
  if (!v || isStale(v, now)) return null;
  return v;
}

/** เขียนมุมมองของเดือนหนึ่งลงก้อนเดิม + ตัดเดือนที่หมดอายุ/เกินโควต้าทิ้ง */
export function upsertMonth(
  saved: SavedView | null,
  month: string,
  view: Omit<MonthView, "savedAt">,
  now = new Date(),
): SavedView {
  const months: Record<string, MonthView> = { ...(saved?.months ?? {}) };
  months[month] = { ...view, savedAt: now.toISOString() };
  // ทิ้งเดือนที่ไม่ได้แตะเกิน MAX_AGE_DAYS
  for (const [k, v] of Object.entries(months)) if (isStale(v, now)) delete months[k];
  // เหลือเกินโควต้า → ตัดเดือนที่แตะล่าสุดเก่าสุดออกก่อน (เดือนที่เพิ่งเขียนรอดเสมอ)
  const keys = Object.keys(months);
  if (keys.length > MAX_MONTHS) {
    keys.sort((a, b) => Date.parse(months[b].savedAt) - Date.parse(months[a].savedAt));
    for (const k of keys.slice(MAX_MONTHS)) if (k !== month) delete months[k];
  }
  return { v: VIEW_VERSION, lastMonth: month, months };
}

/** ตัดสินใจตอนล็อกอิน: เปิดเดือนไหน · คืนตำแหน่งแถวไหม
 *  คงเดือนเดิมไว้ก็ต่อเมื่อเดือนนั้น "มีตัวกรอง/คำค้นค้างอยู่" และยังมีข้อมูลอยู่จริง */
export function planRestore(
  saved: SavedView | null,
  monthsWithData: string[],
  now = new Date(),
): RestorePlan {
  const fallback = defaultMonth(monthsWithData, now);
  if (!saved) return { month: fallback, anchorId: null };
  const last = saved.lastMonth;
  // เดือนที่ค้างไว้ไม่มีข้อมูลแล้ว (ถูกลบ/ยังไม่นำเข้า) หรือหมดอายุ → บริบทเดิมหายไปแล้ว เริ่มใหม่
  if (!monthsWithData.includes(last)) return { month: fallback, anchorId: null };
  const lastView = monthView(saved, last, now);
  if (!isNarrowed(lastView)) return { month: fallback, anchorId: null };
  return { month: last, anchorId: lastView!.anchorId };
}

/** ข้อความแจ้งผู้ใช้ — ขึ้นเฉพาะตอนคืนตัวกรองจริง ไม่งั้นเปิดมาแล้วงงว่าทำไมแถวหาย */
export function restoreSummary(
  view: Pick<MonthView, "filters" | "search"> | null,
  monthText: string,
  prefix = "กลับมาที่มุมมองเดิม",
): string | null {
  if (!isNarrowed(view)) return null;
  const parts: string[] = [];
  if (view!.filters.length) parts.push(`ตัวกรอง ${view!.filters.length} คอลัมน์`);
  if (view!.search.trim()) parts.push(`คำค้น "${view!.search.trim()}"`);
  return `${prefix} — ${monthText} · ${parts.join(" · ")}`;
}

/** ประกอบมุมมองปัจจุบัน (ฝั่งเรียกอ่าน state/DOM มาให้ — ไฟล์นี้ไม่แตะ DOM) */
export function buildView(input: {
  filters: Iterable<[string, Iterable<string>]>;
  sort: { col: string; dir: "asc" | "desc" } | null;
  search: string;
  anchorId: number | null | undefined;
}): Omit<MonthView, "savedAt"> {
  return {
    filters: [...input.filters].map(([k, vs]) => [k, [...vs]] as [string, string[]]),
    sort: input.sort,
    search: input.search,
    anchorId: typeof input.anchorId === "number" ? input.anchorId : null,
  };
}

export { emptyView };
