import { test } from "node:test";
import assert from "node:assert/strict";
import * as XLSX from "xlsx";
import { parseWorkbook } from "../src/import.ts";

// สร้างไฟล์แบบ Export Orders ของ GoSell (3 แถวหัวรายงาน + หัวตาราง + ข้อมูล)
const H = ["เลขที่คำสั่งซื้อ", "วันที่สั่งซื้อ", "ลูกค้า", "เบอร์โทร1", "ชื่อโซเชียล", "ที่อยู่", "แขวง/ ตำบล", "เขต/ อำเภอ", "จังหวัด", "รหัสไปรษณีย์", "สถานะคำสั่งซื้อ", "สถานะการจัดส่ง",
  "การชำระเงิน", "สถานะการชำระเงิน", "ขนส่ง", "หมายเลขพัสดุ", "ชื่อสินค้า", "จำนวนสินค้า", "รวมทั้งสิ้น"];
type R = Partial<Record<(typeof H)[number], string | number>>;
function book(rows: R[]): ArrayBuffer {
  const aoa: unknown[][] = [["GoSell", "ส่งออกข้อมูลคำสั่งซื้อ"], ["ข้อมูลเพิ่มเติม"], ["ระยะเวลาของข้อมูล : ", "2026-10-03 ถึง 2026-10-03"], H];
  for (const r of rows) aoa.push(H.map((h) => r[h] ?? null));
  const wb = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(aoa), "Sheet1");
  return XLSX.write(wb, { type: "array", bookType: "xlsx" });
}
const base = (no: string, extra: R = {}): R => ({
  "เลขที่คำสั่งซื้อ": no, "วันที่สั่งซื้อ": "2026-10-03 10:00:00", "ลูกค้า": "คุณทดสอบ m11", "เบอร์โทร1": "0812345678", "ที่อยู่": "1 ม.1", "แขวง/ ตำบล": "ในเมือง", "เขต/ อำเภอ": "เมือง", "จังหวัด": "ขอนแก่น", "รหัสไปรษณีย์": "40000",
  "สถานะคำสั่งซื้อ": "กำลังดำเนินการ", "สถานะการจัดส่ง": "พร้อมจัดส่ง", "การชำระเงิน": "เก็บเงินปลายทาง",
  "สถานะการชำระเงิน": "รอการชำระเงิน", "ขนส่ง": "KEX", "หมายเลขพัสดุ": "GOSH000000001", "ชื่อสินค้า": "Beta Oil กล่อง (10 แคปซูล)",
  "จำนวนสินค้า": 1, "รวมทั้งสิ้น": 690, ...extra,
});

test("มีเลขแทร็กครบ → ไม่บล็อก", () => {
  const p = parseWorkbook(book([base("OD1"), base("OD2", { "หมายเลขพัสดุ": "GOSH000000002" })]));
  assert.equal(p.rows.length, 2);
  assert.deepEqual(p.noTracking, []);
});

test("รอดำเนินการ ไม่มีแทร็ก → บล็อก พร้อมสถานะ", () => {
  const p = parseWorkbook(book([base("OD1"), base("OD2", { "สถานะคำสั่งซื้อ": "รอดำเนินการ", "สถานะการจัดส่ง": "", "หมายเลขพัสดุ": "" })]));
  assert.equal(p.noTracking.length, 1);
  assert.equal(p.noTracking[0].order_no, "OD2");
  assert.equal(p.noTracking[0].status, "รอดำเนินการ");
});

test("กำลังดำเนินการ ไม่มีแทร็ก → บล็อกด้วย (เจ้านาย: บล็อกทุกออเดอร์ที่ไม่มีแทร็ก)", () => {
  const p = parseWorkbook(book([base("OD1", { "สถานะการจัดส่ง": "ที่ต้องจัดส่ง", "หมายเลขพัสดุ": null as unknown as string })]));
  assert.deepEqual(p.noTracking.map((x) => [x.order_no, x.status, x.ship]), [["OD1", "กำลังดำเนินการ", "ที่ต้องจัดส่ง"]]);
});

test("ออเดอร์ยกเลิก ไม่มีแทร็ก → ไม่บล็อก (ข้ามอยู่แล้ว)", () => {
  const p = parseWorkbook(book([base("OD1"), base("OD9", { "สถานะคำสั่งซื้อ": "ยกเลิก", "หมายเลขพัสดุ": "" })]));
  assert.deepEqual(p.noTracking, []);
  assert.equal(p.rows.length, 1);
  assert.ok(p.skipped.some((s) => s.startsWith("OD9")));
});

test("ออเดอร์หลายแถว แทร็กอยู่แถวที่ 2 → ถือว่ามีแทร็ก", () => {
  const p = parseWorkbook(book([base("OD1", { "หมายเลขพัสดุ": "" }), base("OD1", { "ชื่อสินค้า": "ของแถม", "หมายเลขพัสดุ": "GOSH000000001" })]));
  assert.deepEqual(p.noTracking, []);
  assert.equal(p.rows[0].tracking_no, "GOSH000000001");
});

test("แทร็กเป็น \"-\" หรือช่องว่าง → นับว่าไม่มี", () => {
  const p = parseWorkbook(book([base("OD1", { "หมายเลขพัสดุ": "-" }), base("OD2", { "หมายเลขพัสดุ": "   " })]));
  assert.deepEqual(p.noTracking.map((x) => x.order_no), ["OD1", "OD2"]);
});
