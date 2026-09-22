import { test } from "node:test";
import assert from "node:assert/strict";
import {
  axisLabel, rangeLabel, growth, yTicks, shortMoney,
  barRatio, brandSplit, shares, defaultRange, clampRange, isPartial,
} from "../src/dashboard_calc.ts";

test("axisLabel: ปี/เดือน/วัน", () => {
  assert.equal(axisLabel("2026", "year"), "2026");
  assert.equal(axisLabel("2026-01", "month"), "ม.ค.");
  assert.equal(axisLabel("2026-12", "month"), "ธ.ค.");
  assert.equal(axisLabel("2026-09-01", "day"), "1 ก.ย.");
  assert.equal(axisLabel("2026-09-30", "day"), "30 ก.ย.");
});

test("rangeLabel: ช่วงเดียว vs หลายช่วง", () => {
  assert.equal(rangeLabel("2026-01-01", "2026-09-16", "month"), "ม.ค. 2026 – ก.ย. 2026");
  assert.equal(rangeLabel("2026-03-01", "2026-03-31", "month"), "มี.ค. 2026");
  assert.equal(rangeLabel("2026-09-01", "2026-09-08", "day"), "1 ก.ย. – 8 ก.ย. 2026");
  assert.equal(rangeLabel("2026-09-08", "2026-09-08", "day"), "8 ก.ย. 2026");
  assert.equal(rangeLabel("2026-01-01", "2026-12-31", "year"), "2026");
});

test("growth: ช่วงก่อนเป็น 0 ต้องได้ null ไม่ใช่ Infinity", () => {
  assert.equal(growth(100, 0), null);
  assert.equal(growth(0, 0), null);
  assert.equal(growth(150, 100), 50);
  assert.equal(growth(50, 100), -50);
  // เคสจริง: 1-8 ก.ย. 3,461,077 เทียบ 24-31 ส.ค. 3,293,671
  const g = growth(3461077, 3293671)!;
  assert.ok(Math.abs(g - 5.08) < 0.01, `ได้ ${g}`);
});

test("yTicks: ขั้นสวย ครอบค่าสูงสุด และไม่เหลือที่ว่างเกินจำเป็น", () => {
  // เคสจริง เม.ย. 14,764,566 → เดิมได้แกน 20 ล้าน (ใช้พื้นที่ 74%) · ต้องได้ 16 ล้าน (92%)
  const a = yTicks(14764566);
  assert.equal(a.top, 16000000);
  assert.deepEqual(a.ticks, [16000000, 12000000, 8000000, 4000000, 0]);
  // ทุกเคสต้อง: ครอบค่าสูงสุดได้ · ไม่เหลือที่ว่างเกิน 40% · ขีดเรียงลดหลั่นถึง 0
  for (const v of [14764566, 9600000, 3461077, 661568, 498108, 1027990, 82890, 1]) {
    const { top, ticks } = yTicks(v);
    assert.ok(top >= v, `top ${top} ต้องครอบ ${v}`);
    assert.ok(v / top >= 0.6, `${v} ใช้พื้นที่แค่ ${((v / top) * 100).toFixed(0)}% ของแกน — เปลืองเกินไป`);
    assert.equal(ticks.length, 5);
    assert.equal(ticks[0], top);
    assert.equal(ticks[4], 0);
    for (let i = 1; i < ticks.length; i++) assert.ok(ticks[i] < ticks[i - 1], "ขีดต้องลดหลั่น");
  }
  // ค่า 0 / ลบ ต้องไม่พัง
  assert.equal(yTicks(0).top, 1);
  assert.equal(yTicks(-5).top, 1);
});

test("shortMoney", () => {
  assert.equal(shortMoney(2000000), "2 ล้าน");
  assert.equal(shortMoney(14764566), "14.8 ล้าน");
  assert.equal(shortMoney(950000), "950,000");
  assert.equal(shortMoney(0), "0");
});

test("barRatio: กันหาร 0 · กันเกิน 1 · กันค่าลบ", () => {
  assert.equal(barRatio(5, 10), 0.5);
  assert.equal(barRatio(5, 0), 0);
  assert.equal(barRatio(15, 10), 1);
  assert.equal(barRatio(-5, 10), 0);
});

test("brandSplit: total 0 ต้องไม่เป็น NaN", () => {
  const z = brandSplit(0, 0);
  assert.equal(z.h, 0); assert.equal(z.o, 0);
  assert.ok(!Number.isNaN(z.h));
  // เคสจริง: ทีม C-ลำพูน มี HOPEFUL 0 ทั้งก้อน
  const only = brandSplit(0, 135756);
  assert.equal(only.h, 0); assert.equal(only.o, 1);
  const s = brandSplit(2574185, 886892);
  assert.ok(Math.abs(s.h + s.o - 1) < 1e-9, "สองส่วนรวมต้องได้ 1");
  assert.ok(Math.abs(s.h - 0.7437) < 0.001, `ได้ ${s.h}`);
});

test("shares: สัดส่วนหลายก้อน (การ์ดแยกตามฝ่าย) — รวมได้ 1 · ไม่ NaN · ค่าลบไม่พัง", () => {
  // เคสจริง 2026-09-22: แอดมิน 66,697,620 · CRM 38,696,180 · อื่นๆ 2,047,255 = 107,441,055
  const s = shares([66697620, 38696180, 2047255]);
  assert.ok(Math.abs(s.reduce((a, b) => a + b, 0) - 1) < 1e-9, "รวมต้องได้ 1");
  assert.ok(Math.abs(s[0] - 0.6208) < 0.001, `แอดมินได้ ${s[0]}`);
  assert.ok(Math.abs(s[1] - 0.3601) < 0.001, `CRM ได้ ${s[1]}`);
  assert.ok(Math.abs(s[2] - 0.0191) < 0.001, `อื่นๆ ได้ ${s[2]}`);
  // ช่วงที่ยังไม่มียอดเลย → 0 ทุกก้อน ไม่ใช่ NaN (การ์ดต้องไม่โชว์ NaN%)
  for (const v of shares([0, 0, 0])) { assert.equal(v, 0); assert.ok(!Number.isNaN(v)); }
  assert.deepEqual(shares([]), []);
  // ค่าลบ/NaN/Infinity ถูกปัดเป็น 0 แล้วก้อนที่เหลือยังรวมได้ 1
  const g = shares([-5, 10, NaN, Infinity]);
  assert.deepEqual(g, [0, 1, 0, 0]);
  // ก้อนเดียวมีค่า → ได้ 1 เต็ม
  assert.deepEqual(shares([0, 7, 0]), [0, 1, 0]);
});

test("defaultRange: ยึดขอบข้อมูลจริง ไม่หลุดออกนอกช่วง", () => {
  const min = "2026-01-01", max = "2026-09-16";
  assert.deepEqual(defaultRange("year", min, max), { from: min, to: max });
  assert.deepEqual(defaultRange("month", min, max), { from: "2026-01-01", to: max });
  assert.deepEqual(defaultRange("day", min, max), { from: "2026-09-01", to: max });
  // ข้อมูลเริ่มกลางเดือน → ต้องไม่ย้อนไปก่อน min
  const r = defaultRange("day", "2026-09-10", "2026-09-16");
  assert.equal(r.from, "2026-09-10");
});

test("clampRange: สลับลำดับผิด + เลือกเกินขอบ", () => {
  const min = "2026-01-01", max = "2026-09-16";
  assert.deepEqual(clampRange("2026-09-08", "2026-09-01", min, max), { from: "2026-09-01", to: "2026-09-08" });
  assert.deepEqual(clampRange("2025-01-01", "2027-01-01", min, max), { from: min, to: max });
  assert.deepEqual(clampRange("2026-05-05", "2026-05-05", min, max), { from: "2026-05-05", to: "2026-05-05" });
});

test("isPartial: เดือน/ปีที่ยังไม่จบ", () => {
  assert.equal(isPartial("2026-09", "month", "2026-09-16"), true);
  assert.equal(isPartial("2026-08", "month", "2026-09-16"), false);
  assert.equal(isPartial("2026", "year", "2026-09-16"), true);
  assert.equal(isPartial("2025", "year", "2026-09-16"), false);
  assert.equal(isPartial("2026-09-16", "day", "2026-09-16"), false);
});

test("ข้อมูลจริง: ผลบวก series ต้องเท่ายอดรวม และแบรนด์ต้องบวกลงตัวทุกจุด", () => {
  const series = [
    { k: "2026-01", total: 10492314, hope: 5221720, other: 5270594, orders: 6633 },
    { k: "2026-02", total: 13081271, hope: 8489010, other: 4592261, orders: 8298 },
    { k: "2026-03", total: 14471397, hope: 10741070, other: 3730327, orders: 8761 },
    { k: "2026-04", total: 14764566, hope: 11532240, other: 3232326, orders: 8461 },
    { k: "2026-05", total: 13835620, hope: 10890419, other: 2945201, orders: 8079 },
    { k: "2026-06", total: 11678224, hope: 8002630, other: 3675594, orders: 6698 },
    { k: "2026-07", total: 9677924, hope: 6585270, other: 3092654, orders: 5418 },
    { k: "2026-08", total: 11215117, hope: 7781810, other: 3433307, orders: 6585 },
    { k: "2026-09", total: 6816525, hope: 5116795, other: 1699730, orders: 3941 },
  ];
  for (const p of series) {
    assert.equal(p.hope + p.other, p.total, `${p.k}: ${p.hope}+${p.other} ≠ ${p.total}`);
  }
  assert.equal(series.reduce((t, p) => t + p.total, 0), 106032958);
  assert.equal(series.reduce((t, p) => t + p.orders, 0), 62874);
  // แกน Y ต้องครอบค่าสูงสุดได้
  const { top } = yTicks(Math.max(...series.map((p) => p.total)));
  assert.ok(top >= 14764566);
  for (const p of series) assert.ok(barRatio(p.total, top) <= 1);
});
