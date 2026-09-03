// Parse ไฟล์ Export Orders ของ GoSell (.xlsx) ในเบราว์เซอร์ → rows พร้อมส่งเข้า RPC app_import_orders
// ลอจิก map ยกมาจาก database/seed/import_gosell_orders.py (ยืนยันกับ boss 2026-08-28) ให้ตรงกันเป๊ะ
import * as XLSX from "xlsx";

// map ค่าตายตัว (GoSell → schema เรา)
const PAYMENT_METHOD: Record<string, string> = {
  "เก็บเงินปลายทาง": "เก็บเงินปลายทาง",
  "การโอนเงิน": "โอนเงิน",
  "ตัดบัตรเครดิต": "ตัดบัตรเครดิต",
  "บัตรเครดิต": "ตัดบัตรเครดิต",
};
// นำเข้าทำแค่ 2 ค่า: รอชำระ / ชำระแล้ว — "ยกเลิก" เป็นลอจิกเฟสถัดไป ไม่ทำตอนนำเข้า
// (ยืนยันกับ boss 2026-09-01) · canceled/ยกเลิก จาก GoSell → รอชำระ (ยังไม่เก็บเงิน)
const PAYMENT_STATUS: Record<string, string> = {
  "รอการชำระเงิน": "รอชำระ",
  "ยืนยันแล้ว": "ชำระแล้ว",
  "canceled": "รอชำระ",
  "ยกเลิก": "รอชำระ",
};
const DELIVERY_STATUS: Record<string, string> = {
  "กำลังแพ็ค": "รอส่ง",   // ยังไม่ส่ง = รอส่ง (ยืนยันกับ boss 2026-08-31)
  "พร้อมจัดส่ง": "รอส่ง",
  "จัดส่งแล้ว": "ส่งแล้ว",
  "จัดส่งสำเร็จ": "ส่งสำเร็จ",
  "ตีกลับ": "ตีกลับ",
  "ยกเลิก": "ยกเลิก",
};

const COLS = [
  "เลขที่คำสั่งซื้อ", "ลูกค้า", "เบอร์โทร1", "ที่อยู่", "แขวง/ ตำบล", "เขต/ อำเภอ",
  "จังหวัด", "รหัสไปรษณีย์", "ขนส่ง", "หมายเลขพัสดุ", "การชำระเงิน", "สถานะการชำระเงิน",
  "สถานะการจัดส่ง", "ชื่อสินค้า", "จำนวนสินค้า", "รวมทั้งสิ้น", "วันที่สั่งซื้อ",
  "สถานะคำสั่งซื้อ", "ชื่อโซเชียล",
] as const;

export interface ImportItem { product_name: string; quantity: number; }
export interface ImportRow {
  order_no: string | null;
  ordered_at: string;
  customer_name: string | null;
  phone: string;
  addr_detail: string | null;
  subdistrict: string | null;
  district: string | null;
  province: string | null;
  postal_code: string | null;
  seller_code: string | null;
  carrier: string | null;
  tracking_no: string | null;
  total_sales: number;
  payment_method: string | null;
  payment_status: string;
  delivery_status: string;
  note: string | null;
  items: ImportItem[];
}
export interface ParseResult { rows: ImportRow[]; warnings: string[]; skipped: string[]; }

function clean(v: unknown): string | null {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  if (s === "" || s === "-") return null;
  return s;
}
function normPhone(v: unknown): string | null {
  const s = clean(v);
  return s === null ? null : s.replace(/\D/g, "");
}
function sellerCode(name: string | null): string | null {
  if (!name) return null;
  const m = name.trim().match(/([A-Za-z]{1,4}\d{1,4})$/);
  return m ? m[1] : null;
}
function toInt(v: unknown): number | null {
  const s = clean(v);
  if (s === null) return null;
  const n = Number(s.replace(/[^\d.-]/g, ""));
  return Number.isFinite(n) ? Math.round(n) : null;
}
const pad = (n: number) => String(n).padStart(2, "0");

// แปลงค่าวันที่: ถ้าเป็น serial ของ Excel → ใช้ SSF (ได้ค่า wall-clock ตรงๆ ไม่พึ่ง timezone)
function excelDate(v: unknown): string | null {
  if (v === null || v === undefined || v === "") return null;
  if (typeof v === "number") {
    const d = XLSX.SSF.parse_date_code(v);
    if (!d) return null;
    return `${d.y}-${pad(d.m)}-${pad(d.d)} ${pad(d.H)}:${pad(d.M)}:${pad(d.S)}`;
  }
  return clean(v);
}

export function parseWorkbook(buf: ArrayBuffer): ParseResult {
  let wb: XLSX.WorkBook;
  try {
    wb = XLSX.read(new Uint8Array(buf), { type: "array" });
  } catch {
    throw new Error("เปิดไฟล์ไม่ได้ — ต้องเป็นไฟล์ .xlsx จาก GoSell");
  }
  const ws = wb.Sheets[wb.SheetNames[0]];
  if (!ws) throw new Error("ไฟล์ไม่มีชีตข้อมูล");
  const aoa = XLSX.utils.sheet_to_json<any[]>(ws, { header: 1, raw: true, defval: null, blankrows: false });

  // หา header row (แถวที่มี 'เลขที่คำสั่งซื้อ') ใน 8 แถวแรก
  let hdrIdx = -1;
  let H: any[] = [];
  for (let r = 0; r < Math.min(8, aoa.length); r++) {
    if ((aoa[r] || []).includes("เลขที่คำสั่งซื้อ")) { hdrIdx = r; H = aoa[r]; break; }
  }
  if (hdrIdx < 0) throw new Error("หาหัวตาราง (เลขที่คำสั่งซื้อ) ไม่เจอ — ตรวจว่าเป็นไฟล์ Export Orders ของ GoSell");

  const ci: Record<string, number> = {};
  const missing: string[] = [];
  for (const n of COLS) { const i = H.indexOf(n); ci[n] = i; if (i < 0) missing.push(n); }
  if (missing.length) throw new Error("ไฟล์ขาดคอลัมน์: " + missing.join(", "));

  // แถวข้อมูล (ตัดแถวว่างล้วน)
  const dataRows: any[][] = [];
  for (let r = hdrIdx + 1; r < aoa.length; r++) {
    const v = aoa[r] || [];
    if (v.every((x) => x === null || x === undefined || x === "")) continue;
    dataRows.push(v);
  }

  // group by เลขที่คำสั่งซื้อ (รักษาลำดับในไฟล์)
  const groups = new Map<string, any[][]>();
  for (const v of dataRows) {
    const key = String(v[ci["เลขที่คำสั่งซื้อ"]] ?? "");
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(v);
  }

  const warnings: string[] = [];
  const skipped: string[] = [];
  const rows: ImportRow[] = [];

  for (const [okey, lines] of groups) {
    const first = lines[0];
    const firstStr = (col: string): string | null => {
      for (const l of lines) { const x = clean(l[ci[col]]); if (x !== null) return x; }
      return null;
    };
    const firstRaw = (col: string): unknown => {
      for (const l of lines) { const x = l[ci[col]]; if (x !== null && x !== undefined && x !== "") return x; }
      return null;
    };

    // ข้ามออเดอร์ที่ยกเลิก (คอลัม สถานะคำสั่งซื้อ) — เอาเฉพาะออเดอร์ส่งจริง
    if (firstStr("สถานะคำสั่งซื้อ") === "ยกเลิก") { skipped.push(`${okey}: สถานะคำสั่งซื้อ = ยกเลิก`); continue; }

    const cust = firstStr("ลูกค้า");
    const phone = normPhone(first[ci["เบอร์โทร1"]]);
    if (phone === null) { skipped.push(`${okey}: ไม่มีเบอร์โทร`); continue; }
    if (!/^\d{8,15}$/.test(phone)) { skipped.push(`${okey}: เบอร์ผิดรูป (${phone})`); continue; }

    const dtStr = excelDate(firstRaw("วันที่สั่งซื้อ"));
    if (dtStr === null) { skipped.push(`${okey}: ไม่มีวันที่สั่งซื้อ`); continue; }
    const orderedAt = `${dtStr}+07`;

    const pmRaw = firstStr("การชำระเงิน");
    let pm: string | null = null;
    if (pmRaw) { pm = PAYMENT_METHOD[pmRaw] ?? null; if (pm === null) warnings.push(`${okey}: ช่องทางชำระไม่รู้จัก "${pmRaw}" → เว้นว่าง`); }

    const psRaw = firstStr("สถานะการชำระเงิน");
    let ps = psRaw ? PAYMENT_STATUS[psRaw] : undefined;
    if (!ps) { if (psRaw) warnings.push(`${okey}: สถานะชำระไม่รู้จัก "${psRaw}" → รอชำระ`); ps = "รอชำระ"; }

    const dsRaw = firstStr("สถานะการจัดส่ง");
    let ds = dsRaw ? DELIVERY_STATUS[dsRaw] : undefined;
    if (!ds) { if (dsRaw) warnings.push(`${okey}: สถานะจัดส่งไม่รู้จัก "${dsRaw}" → รอส่ง`); ds = "รอส่ง"; }

    let total = toInt(firstStr("รวมทั้งสิ้น")) ?? 0;
    if (total < 0) { warnings.push(`${okey}: ยอดติดลบ → 0`); total = 0; }

    let pc = firstStr("รหัสไปรษณีย์");
    if (pc !== null) { pc = pc.replace(/\D/g, ""); if (!/^\d{5}$/.test(pc)) { warnings.push(`${okey}: ไปรษณีย์ผิดรูป → เว้นว่าง`); pc = null; } }

    const items: ImportItem[] = [];
    for (const l of lines) {
      const pname = clean(l[ci["ชื่อสินค้า"]]);
      if (pname === null) continue;
      const qty = toInt(l[ci["จำนวนสินค้า"]]) ?? 0;
      if (qty <= 0) { warnings.push(`${okey}: ${pname} จำนวน <= 0`); continue; }
      items.push({ product_name: pname, quantity: qty });
    }

    // note (ช่วงนี้): เก็บค่าคอลัม ชื่อโซเชียล เฉพาะแถวที่มี "SO20"
    const social = firstStr("ชื่อโซเชียล");
    const note = social && social.toUpperCase().includes("SO20") ? social : null;

    rows.push({
      order_no: clean(okey),
      ordered_at: orderedAt,
      customer_name: cust,
      phone,
      addr_detail: firstStr("ที่อยู่"),
      subdistrict: firstStr("แขวง/ ตำบล"),
      district: firstStr("เขต/ อำเภอ"),
      province: firstStr("จังหวัด"),
      postal_code: pc,
      seller_code: sellerCode(cust),
      carrier: firstStr("ขนส่ง"),
      tracking_no: firstStr("หมายเลขพัสดุ"),
      total_sales: total,
      payment_method: pm,
      payment_status: ps,
      delivery_status: ds,
      note,
      items,
    });
  }

  return { rows, warnings, skipped };
}

// ===== COD รับเงินแล้ว (.xlsx ตาม template) =====
const COD_COLS = ["หมายเลขพัสดุ", "จำนวนเงิน", "ได้รับจาก", "หมายเหตุ"] as const;

export interface CodRow {
  tracking_out: string;
  amount: number | null;
  received_from: string | null;
  note: string | null;
}
export interface CodParseResult { rows: CodRow[]; skipped: string[] }

function toNum(v: unknown): number | null {
  const s = clean(v);
  if (s === null) return null;
  const n = Number(s.replace(/[^\d.-]/g, ""));
  return Number.isFinite(n) ? n : null;
}

export function parseCodWorkbook(buf: ArrayBuffer): CodParseResult {
  let wb: XLSX.WorkBook;
  try {
    wb = XLSX.read(new Uint8Array(buf), { type: "array" });
  } catch {
    throw new Error("เปิดไฟล์ไม่ได้ — ต้องเป็นไฟล์ .xlsx ตาม template COD");
  }
  const ws = wb.Sheets[wb.SheetNames[0]];
  if (!ws) throw new Error("ไฟล์ไม่มีชีตข้อมูล");
  const aoa = XLSX.utils.sheet_to_json<any[]>(ws, { header: 1, raw: true, defval: null, blankrows: false });

  // หา header row (มี 'หมายเลขพัสดุ') ใน 8 แถวแรก
  let hdrIdx = -1;
  let H: any[] = [];
  for (let r = 0; r < Math.min(8, aoa.length); r++) {
    if ((aoa[r] || []).includes("หมายเลขพัสดุ")) { hdrIdx = r; H = aoa[r]; break; }
  }
  if (hdrIdx < 0) throw new Error("ไฟล์ไม่ตรง template COD — หาหัวตาราง (หมายเลขพัสดุ) ไม่เจอ");

  const ci: Record<string, number> = {};
  const missing: string[] = [];
  for (const n of COD_COLS) { const i = H.indexOf(n); ci[n] = i; if (i < 0) missing.push(n); }
  if (missing.length) throw new Error("ไฟล์ไม่ตรง template COD — ขาดคอลัมน์: " + missing.join(", "));

  const rows: CodRow[] = [];
  const skipped: string[] = [];
  for (let r = hdrIdx + 1; r < aoa.length; r++) {
    const v = aoa[r] || [];
    if (v.every((x) => x === null || x === undefined || x === "")) continue;   // แถวว่างล้วน
    const tracking = clean(v[ci["หมายเลขพัสดุ"]]) ?? "";
    const note = clean(v[ci["หมายเหตุ"]]);
    // ข้ามแถวตัวอย่างใน template (EX000000001TH / โน้ต "ตัวอย่าง")
    if (tracking === "EX000000001TH" || (note && note.includes("ตัวอย่าง"))) {
      skipped.push(`แถวตัวอย่าง (${tracking || "—"})`);
      continue;
    }
    rows.push({
      tracking_out: tracking,
      amount: toNum(v[ci["จำนวนเงิน"]]),
      received_from: clean(v[ci["ได้รับจาก"]]),
      note,
    });
  }
  return { rows, skipped };
}
