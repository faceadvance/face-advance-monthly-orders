// รัน: npm test  (node --test · Node ≥22 strip types)
import { test } from "node:test";
import assert from "node:assert/strict";
import { computeDockLayout, dockHitBox, DOCK, DOCK_WIDTH, ITEM_RIGHT, MAX_ITEM, GROW } from "../src/dock.ts";

const { B, G, P, PV, DOCK_RIGHT, OUT } = DOCK;
const near = (a: number, b: number, eps = 0.01) => assert.ok(Math.abs(a - b) <= eps, `${a} ≠ ${b}`);
const VH = 902;
const restCenter = (n: number, i: number) => VH / 2 - (n * B + (n - 1) * G) / 2 + B / 2 + i * (B + G);
const frameLeft = DOCK_RIGHT + DOCK_WIDTH;   // ระยะขอบซ้ายกรอบ จากขอบขวาจอ

test("ตอนพัก: ไอคอน = B · ขอบกรอบ→ไอคอน (บน/ล่าง = PV = 2×P · ซ้าย/ขวา = P) · กรอบกึ่งกลางจอ", () => {
  const L = computeDockLayout(4, null, VH);
  assert.deepEqual(L.sizes, [B, B, B, B]);
  near(PV, 2 * P);                                                   // บน/ล่าง = 2 เท่าของแนวนอน
  near(L.dockWidth, DOCK_WIDTH);
  near(L.dockHeight, 4 * B + 3 * G + 2 * PV);
  near(L.dockTop + L.dockHeight / 2, VH / 2);
  near(L.tops[0] - L.dockTop, PV);                                   // บน
  near(L.dockTop + L.dockHeight - (L.tops[3] + L.sizes[3]), PV);     // ล่าง
  for (const r of L.rights) {
    near(r - DOCK_RIGHT, P);                                         // ขวา
    near(frameLeft - (r + B), P);                                    // ซ้าย
  }
});

test("ข้อ 1: ชี้ตรงกลางไอคอน → ตัวนั้น = MAX_ITEM · โผล่พ้นขอบซ้ายกรอบ 25% ของตัวเอง · wave ลดหลั่น", () => {
  const L = computeDockLayout(4, restCenter(4, 1), VH);
  near(L.sizes[1], MAX_ITEM);
  near(MAX_ITEM, B + GROW);
  assert.ok(L.sizes[0] < L.sizes[1] && L.sizes[2] < L.sizes[1] && L.sizes[3] < L.sizes[2], "wave");
  const iconLeft = L.rights[1] + L.sizes[1];
  near(iconLeft - frameLeft, OUT * L.sizes[1]);                      // โผล่พ้น 25% พอดี
});

test("🔴 ขอบขวา: ไอคอนชิดขวาตรงกันทุกตัว ทุกสถานะ · ระยะกรอบ→ไอคอน (ขวา) = P คงที่", () => {
  for (let y = 0; y <= VH; y += 5) {
    const L = computeDockLayout(4, y, VH);
    for (const r of L.rights) {
      near(r, ITEM_RIGHT);              // ขอบขวาไอคอนไม่ขยับเลย
      near(r - DOCK_RIGHT, P);          // ระยะจากขอบขวากรอบ = P เท่าตอนพัก
    }
  }
});

test("ข้อ 2: ทุกช่วง cursor ระยะขอบถึงขอบระหว่างไอคอน = G เสมอ (ไม่ทับ)", () => {
  for (let y = 0; y <= VH; y += 7) {
    const L = computeDockLayout(4, y, VH);
    for (let i = 1; i < 4; i++) near(L.tops[i] - (L.tops[i - 1] + L.sizes[i - 1]), G);
  }
});

test("ข้อ 3: กรอบยืดแค่บน-ล่าง (ขอบ→ไอคอน = PV คงที่) · **ความกว้างคงที่ ไม่ขยายออกซ้าย**", () => {
  for (let y = 0; y <= VH; y += 7) {
    const L = computeDockLayout(4, y, VH);
    near(L.dockWidth, DOCK_WIDTH);                                   // กว้างคงที่เสมอ
    near(L.tops[0] - L.dockTop, PV);
    near(L.dockTop + L.dockHeight - (L.tops[3] + L.sizes[3]), PV);
    L.sizes.forEach((s, i) => {
      const over = (L.rights[i] + s) - frameLeft;                    // ส่วนที่โผล่พ้นซ้าย
      assert.ok(over <= OUT * s + 0.01, `โผล่เกิน 25% @${y}`);
      assert.ok(L.rights[i] >= 0, `ไอคอนทะลุขอบขวาจอ @${y}`);        // ไม่ล้นขอบจอ
    });
  }
});

test("ความต่อเนื่อง: ขยับเมาส์ 1px ขนาด/ตำแหน่งเปลี่ยนน้อย (ไม่กระตุก)", () => {
  let prev = computeDockLayout(4, 0, VH);
  for (let y = 1; y <= VH; y++) {
    const L = computeDockLayout(4, y, VH);
    L.sizes.forEach((s, i) => assert.ok(Math.abs(s - prev.sizes[i]) < 1.5, `jump size @${y}`));
    L.rights.forEach((r, i) => assert.ok(Math.abs(r - prev.rights[i]) < 1.5, `jump right @${y}`));
    prev = L;
  }
});

test("hit-area: ขนาดคงที่ · มีขนาดจริง (>0 กัน translateX(100%) ไม่พ้นจอ) · ครอบ dock+ไอคอนได้ทุกสถานะ", () => {
  const n = 4;
  const hit = dockHitBox(n);
  assert.ok(hit.width > 0 && hit.height > 0, "ต้องมีขนาดจริง");
  const hitTop = VH / 2 - hit.height / 2;
  const hitBottom = hitTop + hit.height;
  for (let y = 0; y <= VH; y += 5) {
    const L = computeDockLayout(n, y, VH);
    L.sizes.forEach((s, i) => {
      assert.ok(L.tops[i] >= hitTop - 0.01 && L.tops[i] + s <= hitBottom + 0.01, `icon ${i} นอกกล่อง @${y}`);
      assert.ok(L.rights[i] + s <= hit.width + 0.01, `icon ${i} กว้างเกินกล่อง @${y}`);
    });
    assert.ok(L.dockTop >= hitTop - 0.01 && L.dockTop + L.dockHeight <= hitBottom + 0.01, `frame นอกกล่อง @${y}`);
  }
  assert.deepEqual(dockHitBox(0), { width: 0, height: 0 });
});

test("edge: n=0 / n=1 / cursor NaN / cursor นอกจอ ไม่พัง", () => {
  assert.deepEqual(computeDockLayout(0, 100, VH).sizes, []);
  const one = computeDockLayout(1, VH / 2, VH);
  near(one.sizes[0], MAX_ITEM); near(one.dockHeight, MAX_ITEM + 2 * PV);
  assert.deepEqual(computeDockLayout(3, NaN, VH).sizes, [B, B, B]);
  assert.deepEqual(computeDockLayout(3, -9999, VH).sizes, [B, B, B]);
  const two = computeDockLayout(2, VH / 2, VH);
  assert.ok(two.sizes.every(Number.isFinite) && two.rights.every(Number.isFinite));
});
