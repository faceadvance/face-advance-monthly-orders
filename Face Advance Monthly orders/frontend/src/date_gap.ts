// นำเข้าออเดอร์: วันที่ขาดช่วง (เจ้านายขอ 2026-09-29)
// DB (app_import_orders) คำนวณ missing_dates = วันที่ข้ามไประหว่างออเดอร์ล่าสุดในระบบ ถึงวันสุดท้ายของไฟล์
// หน้าเว็บถามยืนยัน "ต้องการข้ามวันที่ … เพราะวันนั้นไม่มีข้อมูลใช่ไหม" → รวมวันติดกันเป็นช่วงให้อ่านง่าย

export interface DateRange { from: string; to: string; days: number }

const DOW = ["อา.", "จ.", "อ.", "พ.", "พฤ.", "ศ.", "ส."];

function dayNum(iso: string): number {
  const [y, m, d] = iso.split("-").map(Number);
  return Date.UTC(y, m - 1, d) / 86400000;
}

/** วันในสัปดาห์แบบย่อ "2026-09-27" → "อา." · รูปแบบไม่ถูก → "" */
export function thaiDow(iso: string): string {
  const n = dayNum(iso);
  return Number.isFinite(n) ? DOW[((n + 4) % 7 + 7) % 7] : "";   // 1970-01-01 = พฤหัส
}

/** รวมวันที่ติดกันเป็นช่วง (รับ ISO yyyy-mm-dd · เรียง/ตัดซ้ำ/ข้ามค่าเพี้ยนให้เอง) */
export function dateRanges(dates: readonly string[]): DateRange[] {
  const uniq = [...new Set(dates.filter((d) => /^\d{4}-\d{2}-\d{2}$/.test(d) && Number.isFinite(dayNum(d))))].sort();
  const out: DateRange[] = [];
  for (const d of uniq) {
    const last = out[out.length - 1];
    if (last && dayNum(d) - dayNum(last.to) === 1) { last.to = d; last.days++; }
    else out.push({ from: d, to: d, days: 1 });
  }
  return out;
}
