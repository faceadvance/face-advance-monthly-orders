import { test } from "node:test";
import assert from "node:assert/strict";
import { PARTIAL, isPaidStatus, validatePartial, partialLabel } from "../src/payment.ts";

test("isPaidStatus: ชำระแล้ว + บางส่วน นับเป็นจ่ายแล้ว", () => {
  assert.equal(PARTIAL, "บางส่วน");
  assert.equal(isPaidStatus("ชำระแล้ว"), true);
  assert.equal(isPaidStatus("บางส่วน"), true);
  for (const s of ["รอชำระ", "ยกเลิก", "error", "ไม่ใช่งานขาย", "", null, undefined]) assert.equal(isPaidStatus(s as string), false);
});

test("validatePartial: ต้อง > 0 และ < ยอดขาย", () => {
  assert.equal(validatePartial(2000, 2490), null);
  assert.equal(validatePartial(0.5, 2490), null);
  assert.equal(validatePartial(2489.99, 2490), null);
  assert.match(validatePartial(null, 2490)!, /กรอกยอด/);
  assert.match(validatePartial(Number.NaN, 2490)!, /กรอกยอด/);
  assert.match(validatePartial(0, 2490)!, /มากกว่า 0/);
  assert.match(validatePartial(-5, 2490)!, /มากกว่า 0/);
  assert.match(validatePartial(2490, 2490)!, /น้อยกว่ายอดขาย/);
  assert.match(validatePartial(3000, 2490)!, /น้อยกว่ายอดขาย/);
});

test("partialLabel: รับจริง ฿X จาก ฿Y", () => {
  assert.equal(partialLabel(2000, 2490), "รับจริง ฿2,000 จาก ฿2,490");
  assert.equal(partialLabel(1234.5, 2490), "รับจริง ฿1,234.5 จาก ฿2,490");
});
