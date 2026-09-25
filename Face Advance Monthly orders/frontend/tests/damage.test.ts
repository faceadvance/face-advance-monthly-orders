import { test } from "node:test";
import assert from "node:assert/strict";
import { kindsFor, maxQty, toggleDamage, clampQty, damageOk, canBoth, type DamageItem } from "../src/damage.ts";

const SET = "LYO MINI SET";
const oq = (n: number) => () => n;

test("kindsFor: ผลตรวจ → หัวข้อ", () => {
  assert.deepEqual(kindsFor("สินค้าเสียหาย"), ["damaged"]);
  assert.deepEqual(kindsFor("สินค้าไม่ครบ"), ["missing"]);
  assert.deepEqual(kindsFor("สินค้าไม่ครบและเสียหาย"), ["damaged", "missing"]);
  assert.deepEqual(kindsFor("สินค้าครบ ไม่เสียหาย"), []);
});

test("สินค้าชนิดเดียว ×2: เลือกได้ทั้งเสียหายและขาด อย่างละ 1", () => {
  let it: DamageItem[] = [];
  it = toggleDamage(it, SET, "damaged", 2)!;
  it = toggleDamage(it, SET, "missing", 2)!;
  assert.equal(it.length, 2);
  assert.equal(damageOk("สินค้าไม่ครบและเสียหาย", it, oq(2)), true);
});

test("จำนวน sync: เสียหาย 2 จาก 2 → ฝั่งขาดเลือกไม่ได้", () => {
  const it: DamageItem[] = [{ name: SET, qty: 2, kind: "damaged" }];
  assert.equal(maxQty(it, SET, "missing", 2), 0);
  assert.equal(toggleDamage(it, SET, "missing", 2), null);
});

test("จำนวน sync: เสียหาย 1 จาก 3 → ขาดใส่ได้สูงสุด 2 · ใส่ 5 ถูกปัดเหลือ 2", () => {
  const it: DamageItem[] = [{ name: SET, qty: 1, kind: "damaged" }, { name: SET, qty: 1, kind: "missing" }];
  assert.equal(maxQty(it, SET, "missing", 3), 2);
  assert.equal(clampQty(it, SET, "missing", 5, 3), 2);
  assert.equal(clampQty(it, SET, "missing", 0, 3), 1);
  assert.equal(clampQty(it, SET, "missing", 1.7, 3), 1);
  assert.equal(clampQty(it, SET, "missing", NaN, 3), 1);
});

test("damageOk: รวมเกินจำนวนในออเดอร์ = ไม่ผ่าน", () => {
  const it: DamageItem[] = [{ name: SET, qty: 2, kind: "damaged" }, { name: SET, qty: 1, kind: "missing" }];
  assert.equal(damageOk("สินค้าไม่ครบและเสียหาย", it, oq(2)), false);
});

test("damageOk: ไม่ครบ+เสียหาย แต่มีแค่หัวข้อเดียว = ไม่ผ่าน", () => {
  const it: DamageItem[] = [{ name: SET, qty: 1, kind: "damaged" }];
  assert.equal(damageOk("สินค้าไม่ครบและเสียหาย", it, oq(2)), false);
  assert.equal(damageOk("สินค้าเสียหาย", it, oq(2)), true);
});

test("toggle ซ้ำ = เอาออกเฉพาะหัวข้อนั้น", () => {
  let it: DamageItem[] = [{ name: SET, qty: 1, kind: "damaged" }, { name: SET, qty: 1, kind: "missing" }];
  it = toggleDamage(it, SET, "damaged", 2)!;
  assert.deepEqual(it, [{ name: SET, qty: 1, kind: "missing" }]);
});

test("canBoth: สินค้ารวม 1 ชิ้น เลือกทั้งสองอย่างไม่ได้ · 2 ชิ้นขึ้นไปได้", () => {
  assert.equal(canBoth([{ qty: 1 }]), false);
  assert.equal(canBoth([{ qty: 2 }]), true);
  assert.equal(canBoth([{ qty: 1 }, { qty: 1 }]), true);
  assert.equal(canBoth([{ qty: 0 }]), false);   // จำนวนไม่ทราบ (0)
});
