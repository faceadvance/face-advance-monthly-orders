import { test } from "node:test";
import assert from "node:assert/strict";
import { dateRanges, thaiDow } from "../src/date_gap.ts";

test("วันติดกันรวมเป็นช่วง · วันเดี่ยวแยก", () => {
  assert.deepEqual(dateRanges(["2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-04"]), [
    { from: "2026-09-29", to: "2026-10-02", days: 4 },
    { from: "2026-10-04", to: "2026-10-04", days: 1 },
  ]);
});

test("ข้ามเดือน/ข้ามปี/ปีอธิกสุรทิน ยังนับว่าติดกัน", () => {
  assert.deepEqual(dateRanges(["2025-12-31", "2026-01-01"]), [{ from: "2025-12-31", to: "2026-01-01", days: 2 }]);
  assert.deepEqual(dateRanges(["2028-02-28", "2028-02-29", "2028-03-01"]), [{ from: "2028-02-28", to: "2028-03-01", days: 3 }]);
});

test("ไม่เรียง/ซ้ำ/ค่าเพี้ยน → เรียงให้ ตัดซ้ำ ข้ามค่าเพี้ยน", () => {
  assert.deepEqual(dateRanges(["2026-10-02", "", "2026-10-01", "2026-10-02", "x", "2026-10-01 "]), [
    { from: "2026-10-01", to: "2026-10-02", days: 2 },
  ]);
});

test("ว่าง → []", () => {
  assert.deepEqual(dateRanges([]), []);
});

test("วันในสัปดาห์", () => {
  assert.equal(thaiDow("2026-09-27"), "อา.");
  assert.equal(thaiDow("2026-09-29"), "อ.");
  assert.equal(thaiDow("1969-12-31"), "พ.");
  assert.equal(thaiDow("bad"), "");
});
