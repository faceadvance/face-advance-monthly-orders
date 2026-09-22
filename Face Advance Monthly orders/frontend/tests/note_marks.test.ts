import { test } from "node:test";
import assert from "node:assert/strict";
import { addMark, compact, hasMarks, okColor, parseMarks, segments, type Mark } from "../src/note_marks.ts";

const Y = "#fef08a", YT = "#713f12";   // เหลือง
const P = "#fbcfe8", PT = "#831843";   // ชมพู
const T = "ติดต่อหาลูกค้า 3 สายไม่รับสายเลยค่ะ";   // 35 ตัวอักษร

test("segments: ไม่มีไฮไลท์ → ชิ้นเดียว ไม่มีสี", () => {
  const s = segments(T, []);
  assert.equal(s.length, 1);
  assert.equal(s[0].text, T);
  assert.equal(s[0].bg, undefined);
  assert.equal(segments("", []).length, 0);
});

test("segments: ไฮไลท์ช่วงกลาง → 3 ชิ้น และต่อกันได้ข้อความเดิมเป๊ะ", () => {
  const s = segments(T, [{ s: 8, e: 16, bg: Y, fg: YT }]);
  assert.equal(s.length, 3);
  assert.equal(s[0].bg, undefined);
  assert.equal(s[1].bg, Y);
  assert.equal(s[1].fg, YT);
  assert.equal(s[2].bg, undefined);
  assert.equal(s.map((x) => x.text).join(""), T, "ต่อกลับต้องได้ข้อความเดิม ไม่ตกไม่เกิน");
});

test("🔴 ทับกัน: อันที่ขีดหลังชนะในช่วงที่ทับ (เหมือนปากกาไฮไลท์จริง)", () => {
  const marks: Mark[] = [{ s: 0, e: 20, bg: Y, fg: YT }, { s: 10, e: 30, bg: P, fg: PT }];
  const s = segments(T, marks);
  assert.equal(s.map((x) => x.text).join(""), T);
  // 0–9 เหลือง · 10–29 ชมพู · 30+ ไม่มีสี
  const at = (i: number) => { let p = 0; for (const g of s) { const l = [...g.text].length; if (i < p + l) return g; p += l; } return null; };
  assert.equal(at(5)!.bg, Y);
  assert.equal(at(15)!.bg, P, "ช่วงที่ทับต้องเป็นสีของอันที่ขีดหลัง");
  assert.equal(at(25)!.bg, P);
  assert.equal(at(32)!.bg, undefined);
});

test("segments: ไฮไลท์ทับกันจนอันเก่าหายหมด", () => {
  const s = segments(T, [{ s: 5, e: 10, bg: Y, fg: YT }, { s: 0, e: 35, bg: P, fg: PT }]);
  assert.equal(s.length, 1);
  assert.equal(s[0].bg, P);
});

test("addMark: ลากกลับหลัง (จากขวาไปซ้าย) ก็ต้องได้ช่วงเดียวกัน", () => {
  const a = addMark([], { s: 20, e: 8, bg: Y, fg: YT });
  assert.deepEqual(a, [{ s: 8, e: 20, bg: Y, fg: YT }]);
});

test("addMark: ช่วงยาว 0 หรือสีไม่ถูกรูป → ไม่เพิ่ม", () => {
  assert.equal(addMark([], { s: 5, e: 5, bg: Y, fg: YT }).length, 0);
  assert.equal(addMark([], { s: 0, e: 5, bg: "yellow", fg: YT }).length, 0);
  assert.equal(addMark([], { s: 0, e: 5, bg: Y, fg: "#fff" }).length, 0);
  // ของเดิมต้องไม่ถูกแก้ (คืนอาร์เรย์ใหม่)
  const orig: Mark[] = [{ s: 0, e: 3, bg: Y, fg: YT }];
  addMark(orig, { s: 4, e: 9, bg: P, fg: PT });
  assert.equal(orig.length, 1);
});

test("okColor: รับแค่ #rrggbb", () => {
  for (const ok of ["#fef08a", "#FFFFFF", "#000000"]) assert.equal(okColor(ok), true);
  for (const bad of ["#fff", "yellow", "rgb(1,2,3)", "", null, 5, "#gggggg", "#fef08a "]) assert.equal(okColor(bad), false);
});

test("parseMarks: ข้อมูลเสียจาก DB ต้องไม่พัง ทิ้งทีละอัน", () => {
  const raw = [
    { s: 0, e: 5, bg: Y, fg: YT },          // ดี
    { s: 5, e: 5, bg: Y, fg: YT },          // ยาว 0
    { s: 3, e: 9, bg: "yellow", fg: YT },   // สีผิดรูป
    { s: "a", e: 9, bg: Y, fg: YT },        // เริ่มไม่ใช่ตัวเลข
    null, 5, "x", [],                        // ขยะ
    { s: 30, e: 999, bg: P, fg: PT },       // จบเกินข้อความ → หนีบ
    { s: -5, e: 3, bg: P, fg: PT },         // เริ่มติดลบ → หนีบ
  ];
  const m = parseMarks(raw, T.length);
  assert.equal(m.length, 3);
  assert.deepEqual(m[0], { s: 0, e: 5, bg: Y, fg: YT });
  assert.deepEqual(m[1], { s: 30, e: T.length, bg: P, fg: PT }, "ต้องหนีบปลายให้อยู่ในข้อความ");
  assert.deepEqual(m[2], { s: 0, e: 3, bg: P, fg: PT }, "ต้องหนีบต้นเป็น 0");
  assert.deepEqual(parseMarks(null, 10), []);
  assert.deepEqual(parseMarks("x", 10), []);
});

test("parseMarks: ข้อความสั้นลงจนช่วงหลุดหมด → ทิ้ง", () => {
  assert.deepEqual(parseMarks([{ s: 40, e: 50, bg: Y, fg: YT }], 10), []);
});

test("compact: ขีดซ้ำไปมาแล้วเก็บให้สะอาด — ไม่บวม", () => {
  // ขีด 5 ครั้งทับกันเป็นช่วงเดียวยาวติดกัน → ควรเหลือ 1 ช่วง
  let m: Mark[] = [];
  for (let i = 0; i < 5; i++) m = addMark(m, { s: i * 4, e: i * 4 + 4, bg: Y, fg: YT });
  assert.equal(m.length, 5);
  const c = compact(T, m);
  assert.equal(c.length, 1, `ควรรวมเป็น 1 ช่วง แต่ได้ ${c.length}`);
  assert.deepEqual(c[0], { s: 0, e: 20, bg: Y, fg: YT });
  // ผลการเรนเดอร์ต้องเหมือนกันทั้งก่อนและหลัง compact
  assert.deepEqual(segments(T, c), segments(T, m));
});

test("compact: ช่วงที่ถูกทับจนหมดต้องหายไป", () => {
  const m: Mark[] = [{ s: 5, e: 10, bg: Y, fg: YT }, { s: 0, e: 35, bg: P, fg: PT }];
  const c = compact(T, m);
  assert.equal(c.length, 1);
  assert.deepEqual(c[0], { s: 0, e: 35, bg: P, fg: PT });
});

test("compact: คนละสีติดกัน ต้องไม่รวมเข้าด้วยกัน", () => {
  const c = compact(T, [{ s: 0, e: 5, bg: Y, fg: YT }, { s: 5, e: 10, bg: P, fg: PT }]);
  assert.equal(c.length, 2);
});

test("hasMarks: ไว้ตัดสินใจว่าจะบันทึกหรือสั่งลบ", () => {
  assert.equal(hasMarks(T, []), false);
  assert.equal(hasMarks(T, [{ s: 0, e: 4, bg: Y, fg: YT }]), true);
  assert.equal(hasMarks("", [{ s: 0, e: 4, bg: Y, fg: YT }]), false, "ข้อความว่าง = ไม่มีไฮไลท์");
});

test("ข้อความไทยหลายบรรทัด: ต่อกลับต้องได้เดิมเป๊ะ (รวม \\n)", () => {
  const multi = "8/1/2024 ติดต่อหาลูกค้า 3 สายไม่รับสาย\n9/1/2024 ลูกค้าแจ้งว่าให้ส่งใหม่";
  const s = segments(multi, [{ s: 9, e: 25, bg: Y, fg: YT }, { s: 40, e: 55, bg: P, fg: PT }]);
  assert.equal(s.map((x) => x.text).join(""), multi);
  assert.ok(s.some((x) => x.bg === Y) && s.some((x) => x.bg === P));
});
