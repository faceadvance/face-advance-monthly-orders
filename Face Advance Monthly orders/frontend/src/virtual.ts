// Virtual scrolling (windowing) สำหรับตาราง <table> — วาดลง DOM เฉพาะแถวที่มองเห็น
// ผู้เรียกเก็บข้อมูลครบเอง (count/buildRow อ้างจาก array เต็ม) → กรอง/เรียง/ค้นหา ทำงานบนข้อมูลเต็ม
// รองรับแถวความสูงไม่เท่ากัน (แถวกางรายละเอียด) ผ่าน setRowHeight
import { el } from "./util";

export interface VTable {
  render(force?: boolean): void;             // วาดหน้าต่างปัจจุบัน (force = สร้างใหม่แม้ช่วงเดิม)
  setRowHeight(i: number, h: number | null): void;  // แถว index i ความสูงเปลี่ยน (กาง = h, ยุบ = null) → ปรับ offsets
  detach(): void;                            // ถอด scroll listener (เรียกก่อนสร้างตารางใหม่)
}

function spacerRow(colspan: number): HTMLElement {
  const tr = el("tr", { class: "vspacer", "aria-hidden": "true" });
  tr.append(el("td", { colspan: String(colspan), style: "padding:0;border:0;height:0" }));
  return tr;
}

export function makeVTable(opts: {
  wrap: HTMLElement;                         // scroll container
  tbody: HTMLElement;                        // tbody ที่จะใส่ spacer + แถวหน้าต่าง
  colspan: number;                           // จำนวนคอลัมน์ (สำหรับ spacer)
  count: () => number;                       // จำนวนแถวทั้งหมด (ข้อมูลที่กรองแล้ว)
  buildRow: (i: number) => HTMLElement;      // สร้าง <tr> ของแถว index i
  baseH: number;                             // ความสูงแถวปกติ (วัดจริงมาก่อน)
  overscan?: number;                         // แถวเผื่อบน/ล่าง
  afterWindow?: (tbody: HTMLElement, first: number, last: number) => void;  // หลังวาด (วัด overflow toggle ฯลฯ)
}): VTable {
  const overscan = opts.overscan ?? 8;
  const heights = new Map<number, number>();
  let offsets: number[] = [0];
  let first = -1, last = -1, raf = 0;
  const top = spacerRow(opts.colspan), bot = spacerRow(opts.colspan);
  const rh = (i: number) => heights.get(i) ?? opts.baseH;

  function build() {
    const n = opts.count();
    offsets = new Array(n + 1);
    offsets[0] = 0;
    for (let i = 0; i < n; i++) offsets[i + 1] = offsets[i] + rh(i);
  }
  const total = () => offsets[offsets.length - 1] || 0;
  // index แรกที่ก้นแถว (offsets[i+1]) เลย y ลงไป — binary search
  function idxAt(y: number): number {
    let lo = 0, hi = opts.count() - 1, ans = hi < 0 ? 0 : hi;
    while (lo <= hi) { const m = (lo + hi) >> 1;
      if (offsets[m + 1] > y) { ans = m; hi = m - 1; } else lo = m + 1; }
    return ans;
  }
  function render(force = false) {
    const n = opts.count();
    if (n === 0) { opts.tbody.textContent = ""; first = last = -1; return; }
    const y = opts.wrap.scrollTop, vh = opts.wrap.clientHeight || 600;
    let f = idxAt(y) - overscan, l = idxAt(y + vh) + overscan;
    if (f < 0) f = 0;
    if (l > n - 1) l = n - 1;
    if (!force && f === first && l === last) return;
    first = f; last = l;
    const frag = document.createDocumentFragment();
    for (let i = f; i <= l; i++) frag.append(opts.buildRow(i));
    (top.firstElementChild as HTMLElement).style.height = offsets[f] + "px";
    (bot.firstElementChild as HTMLElement).style.height = Math.max(0, total() - offsets[l + 1]) + "px";
    opts.tbody.textContent = "";
    opts.tbody.append(top, frag, bot);
    opts.afterWindow?.(opts.tbody, f, l);
  }
  function setRowHeight(i: number, h: number | null) {
    if (h == null) heights.delete(i); else heights.set(i, h);
    build(); render(true);
  }
  function onScroll() { if (raf) return; raf = requestAnimationFrame(() => { raf = 0; render(); }); }
  opts.wrap.addEventListener("scroll", onScroll, { passive: true });

  build();
  return {
    render,
    setRowHeight,
    detach() { opts.wrap.removeEventListener("scroll", onScroll); },
  };
}
