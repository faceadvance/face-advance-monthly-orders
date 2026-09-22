// ไฮไลท์ข้อความในโน้ต — ตรรกะล้วน ไม่พึ่ง DOM (เทสด้วย node --test)
// เจ้านายสั่ง 2026-09-22: "พนักงานอยากได้ฟีเจอร์ไฮไลท์ข้อความ ลักษณะเหมือนเอาปากกาไฮไลท์ไปขีดเลย"
//
// สเปกที่เจ้านายเคาะ:
//   · แสดงเฉพาะใน sidebar (ไม่โชว์ในตาราง/ค้นหา/ปุ่มคัดลอก/export)
//   · เป็นของ "แต่ละคน" — เห็นแค่คนที่ไฮไลท์เอง · ข้ามเครื่องได้ (เก็บใน DB ต่อ user)
//   · เลือกสีพื้น/สีตัวอักษรอิสระจากถาดสี (จอแต่ละเครื่องไม่เหมือนกัน)
//   · แก้ไขข้อความโน้ต → ล้างไฮไลท์ทิ้งทั้งหมด รวมของคนอื่น (ตำแหน่งจะเพี้ยน)
//   · มีปุ่มย้อนกลับตอนยังไม่ยืนยัน · มีปุ่มลบไฮไลท์ทั้งหมด
//
// 🔴 เก็บเป็น "ช่วงตัวอักษร" ไม่ใช่ HTML — โน้ตตัวเดียวกันถูกใช้อีก 4 ที่
//    (คอลัมน์โน๊ตล่าสุด · หน้าค้นหา · ปุ่มคัดลอก · ไฟล์ export) ถ้าเก็บ HTML จะเลอะทุกที่

/** ช่วงที่ไฮไลท์: s = ตำแหน่งเริ่ม (นับตัวอักษร, รวม) · e = ตำแหน่งจบ (ไม่รวม) */
export interface Mark {
  s: number;
  e: number;
  bg: string;
  fg: string;
}

/** ชิ้นข้อความสำหรับเรนเดอร์ — bg/fg ว่าง = ไม่ไฮไลท์ */
export interface Segment {
  text: string;
  bg?: string;
  fg?: string;
}

const HEX = /^#[0-9a-fA-F]{6}$/;

/** สีต้องเป็น #rrggbb เท่านั้น — กันค่าแปลกจาก DB/ผู้ใช้หลุดไปเป็น inline style */
export function okColor(c: unknown): c is string {
  return typeof c === "string" && HEX.test(c);
}

/** อ่านช่วงจากข้อมูลที่ไม่เชื่อใจ (มาจาก DB) — ทิ้งอันที่รูปไม่ตรง ไม่ทิ้งทั้งก้อน */
export function parseMarks(raw: unknown, textLen: number): Mark[] {
  if (!Array.isArray(raw)) return [];
  const out: Mark[] = [];
  for (const x of raw) {
    if (!x || typeof x !== "object") continue;
    const d = x as Record<string, unknown>;
    const s = Math.trunc(Number(d.s)), e = Math.trunc(Number(d.e));
    if (!Number.isFinite(s) || !Number.isFinite(e)) continue;
    if (!okColor(d.bg) || !okColor(d.fg)) continue;
    // หนีบให้อยู่ในข้อความ — ข้อความอาจสั้นลงถ้าใครแก้โน้ตแล้วไฮไลท์ยังค้าง
    const a = Math.max(0, Math.min(s, textLen));
    const b = Math.max(0, Math.min(e, textLen));
    if (b - a < 1) continue;
    out.push({ s: a, e: b, bg: d.bg, fg: d.fg });
  }
  return out;
}

/** เพิ่มช่วงใหม่ — คืนอาร์เรย์ใหม่ (ไม่แก้ของเดิม) · ช่วงที่ยาว 0 หรือกลับหัวถูกทิ้ง */
export function addMark(marks: Mark[], m: { s: number; e: number; bg: string; fg: string }): Mark[] {
  const s = Math.min(m.s, m.e), e = Math.max(m.s, m.e);
  if (e - s < 1 || !okColor(m.bg) || !okColor(m.fg)) return marks;
  return [...marks, { s, e, bg: m.bg, fg: m.fg }];
}

/** แตกข้อความเป็นชิ้นๆ พร้อมสี
 *  กติกาทับกัน: **อันที่ขีดหลังชนะ** ในช่วงที่ทับ — เหมือนเอาปากกาไฮไลท์ขีดทับของเดิมจริงๆ
 *  วิธี: ไล่ทีละตัวอักษรแล้วรวมชิ้นที่สีเหมือนกัน (โน้ตยาวสุดในระบบ 651 ตัว เร็วพอเหลือเฟือ) */
export function segments(text: string, marks: Mark[]): Segment[] {
  const chars = [...text];
  const n = chars.length;
  if (!n) return [];
  const bg: (string | undefined)[] = new Array(n);
  const fg: (string | undefined)[] = new Array(n);
  for (const m of marks) {
    for (let i = Math.max(0, m.s); i < Math.min(n, m.e); i++) { bg[i] = m.bg; fg[i] = m.fg; }
  }
  const out: Segment[] = [];
  let i = 0;
  while (i < n) {
    const b = bg[i], f = fg[i];
    let j = i + 1;
    while (j < n && bg[j] === b && fg[j] === f) j++;
    const seg: Segment = { text: chars.slice(i, j).join("") };
    if (b) { seg.bg = b; seg.fg = f; }
    out.push(seg);
    i = j;
  }
  return out;
}

/** เก็บให้สะอาดก่อนบันทึก: ทิ้งช่วงที่ถูกทับจนหมด + รวมช่วงติดกันที่สีเดียวกัน
 *  ทำให้ก้อนที่เก็บใน DB ไม่บวมจากการขีดซ้ำไปมา */
export function compact(text: string, marks: Mark[]): Mark[] {
  const segs = segments(text, marks);
  const out: Mark[] = [];
  let pos = 0;
  for (const g of segs) {
    const len = [...g.text].length;
    if (g.bg && g.fg) {
      const last = out[out.length - 1];
      if (last && last.e === pos && last.bg === g.bg && last.fg === g.fg) last.e = pos + len;
      else out.push({ s: pos, e: pos + len, bg: g.bg, fg: g.fg });
    }
    pos += len;
  }
  return out;
}

/** มีไฮไลท์เหลืออยู่จริงไหม (ใช้ตัดสินใจว่าจะบันทึกหรือสั่งลบ) */
export function hasMarks(text: string, marks: Mark[]): boolean {
  return compact(text, marks).length > 0;
}
