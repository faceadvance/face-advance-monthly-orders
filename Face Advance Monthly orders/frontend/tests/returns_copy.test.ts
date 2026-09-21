import { test } from "node:test";
import assert from "node:assert/strict";
import { itemLines, rowToText, rowsToText, ROW_SEP, type CopyRow } from "../src/returns_copy.ts";

const nf = (n: number) => n.toLocaleString("en-US");

// เคสจริงจากระบบ: WA155231029TH (OD260804174105) — items มาจาก RPC เรียงตาม order_items.id
const real: CopyRow = {
  phone: "0839498392",
  customer_name: "คุณสร้อย สีดารักษ์ C006",
  total_sales: 3290,
  tracking_out: "WA155231029TH",
  items: [
    "Beta Oil กล่อง (10 แคปซูล) ×5",
    "Beta Oil ซอง (5 แคปซูล) ×2",
    "Beta Herb (10 เเคปซูล) ×3",
    "Beta Life (10 เเคปซูล) ×1",
    "Hopeful กล่องยา ×1",
  ].join("\n"),
};

test("ตรงกับตัวอย่างที่เจ้านายกำหนดทุกตัวอักษร", () => {
  const want =
    "เบอร์โทร : 0839498392\n" +
    "ชื่อลูกค้า : คุณสร้อย สีดารักษ์ C006\n" +
    "ยอดขาย : 3,290\n" +
    "เลขแทร็ค : WA155231029TH\n" +
    "รายการสินค้า : Beta Oil กล่อง (10 แคปซูล) ×5\n" +
    "Beta Oil ซอง (5 แคปซูล) ×2\n" +
    "Beta Herb (10 เเคปซูล) ×3\n" +
    "Beta Life (10 เเคปซูล) ×1\n" +
    "Hopeful กล่องยา ×1";
  assert.equal(rowToText(real, nf), want);
});

test("ชิ้นแรกต้องต่อท้ายหัวข้อ · ที่เหลือบรรทัดละชิ้น ไม่เยื้อง", () => {
  const lines = rowToText(real, nf).split("\n");
  assert.equal(lines.length, 9, "4 หัวข้อ + สินค้า 5 ชิ้น = 9 บรรทัด");
  assert.ok(lines[4].startsWith("รายการสินค้า : Beta Oil กล่อง"));
  for (const l of lines.slice(5)) assert.equal(l, l.trimStart(), "ห้ามมีช่องว่างนำหน้า");
});

test("itemLines: กันข้อมูลสกปรก — null · ว่าง · \\r\\n · บรรทัดว่าง · ช่องว่างหัวท้าย", () => {
  assert.deepEqual(itemLines(null), []);
  assert.deepEqual(itemLines(undefined), []);
  assert.deepEqual(itemLines(""), []);
  assert.deepEqual(itemLines("   \n  \n"), []);
  assert.deepEqual(itemLines("A ×1\r\nB ×2"), ["A ×1", "B ×2"]);
  assert.deepEqual(itemLines("\n A ×1 \n\n B ×2 \n"), ["A ×1", "B ×2"]);
});

test("ออเดอร์ที่ไม่มีรายการสินค้า → ขึ้น - ไม่ใช่บรรทัดว่าง", () => {
  const t = rowToText({ ...real, items: null }, nf);
  assert.ok(t.endsWith("รายการสินค้า : -"), t);
  assert.equal(t.split("\n").length, 5);
  // สตริงว่าง/มีแต่ช่องว่าง ต้องได้ผลเดียวกัน
  assert.equal(rowToText({ ...real, items: "" }, nf), t);
  assert.equal(rowToText({ ...real, items: "  \n " }, nf), t);
});

test("ฟิลด์อื่นว่าง → ขึ้น - · ยอด 0 ต้องเป็น 0 ไม่ใช่ -", () => {
  const t = rowToText(
    { phone: null, customer_name: "   ", total_sales: 0, tracking_out: "", items: "X ×1" },
    nf,
  );
  assert.equal(t, "เบอร์โทร : -\nชื่อลูกค้า : -\nยอดขาย : 0\nเลขแทร็ค : -\nรายการสินค้า : X ×1");
});

test("หลายแถว: คั่นด้วย บรรทัดว่าง/---/บรรทัดว่าง และไม่มีตัวคั่นห้อยท้าย", () => {
  assert.equal(rowsToText([], nf), "");
  assert.equal(rowsToText([real], nf), rowToText(real, nf));
  const two = rowsToText([real, { ...real, items: null }], nf);
  assert.equal(two.split(ROW_SEP).length, 2);
  assert.ok(!two.endsWith(ROW_SEP));
  // ตัวคั่นต้องแยกออกจากบรรทัดสินค้าได้ (สินค้าหลายบรรทัดต้องไม่ทำให้ --- หลงไปติดแถวบน)
  assert.ok(two.includes("Hopeful กล่องยา ×1\n\n---\n\nเบอร์โทร : 0839498392"));
});
