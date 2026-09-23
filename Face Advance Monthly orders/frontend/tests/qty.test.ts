import { test } from "node:test";
import assert from "node:assert/strict";
import { qtyTxt, itemLine } from "../src/qty.ts";

test("qtyTxt: 0/ว่าง = ไม่ทราบจำนวน → ?", () => {
  assert.equal(qtyTxt(0), "?");
  assert.equal(qtyTxt(null), "?");
  assert.equal(qtyTxt(undefined), "?");
});

test("qtyTxt: จำนวนปกติแสดงตามจริง", () => {
  assert.equal(qtyTxt(1), "1");
  assert.equal(qtyTxt(24), "24");
});

test("itemLine: ชื่อ ×จำนวน (0 → ×?)", () => {
  assert.equal(itemLine({ name: "LYO SHAMPOO", qty: 2 }), "LYO SHAMPOO ×2");
  assert.equal(itemLine({ name: "Beta Oil กล่อง (10 แคปซูล)", qty: 0 }), "Beta Oil กล่อง (10 แคปซูล) ×?");
});
