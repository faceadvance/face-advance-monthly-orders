import { test } from "node:test";
import assert from "node:assert/strict";
import {
  VIEW_VERSION, MAX_AGE_DAYS, MAX_MONTHS, buildView, parseSaved, planRestore, upsertMonth,
  monthView, isStale, isNarrowed, defaultMonth, restoreSummary, type MonthView, type SavedView,
} from "../src/view_state.ts";

const MONTHS = ["2026-09", "2026-08", "2026-07"];   // get_months คืนใหม่สุดก่อน
const NOW = new Date("2026-09-21T12:00:00+07:00");
const days = (n: number) => new Date(NOW.getTime() - n * 86_400_000).toISOString();

function view(over: Partial<MonthView> = {}): MonthView {
  return { filters: [], sort: null, search: "", anchorId: null, savedAt: NOW.toISOString(), ...over };
}
function blob(lastMonth: string, months: Record<string, MonthView>): SavedView {
  return { v: VIEW_VERSION, lastMonth, months };
}

// ─────────── จำตัวกรองรายเดือน (feedback 2026-09-21) ───────────

test("เก็บแยกรายเดือน: ส.ค. มีตัวกรอง · ก.ย. ไม่มี → ต่างคนต่างอยู่", () => {
  let s = upsertMonth(null, "2026-08", buildView({
    filters: new Map([["delivery_status", new Set(["ตีกลับ"])]]), sort: null, search: "", anchorId: 55,
  }), NOW);
  s = upsertMonth(s, "2026-09", buildView({ filters: new Map(), sort: null, search: "", anchorId: 1 }), NOW);
  assert.equal(s.lastMonth, "2026-09");
  assert.deepEqual(monthView(s, "2026-08", NOW)!.filters, [["delivery_status", ["ตีกลับ"]]]);
  assert.equal(monthView(s, "2026-08", NOW)!.anchorId, 55, "แถวที่ค้างไว้ของ ส.ค. ต้องอยู่ครบ");
  assert.deepEqual(monthView(s, "2026-09", NOW)!.filters, []);
  assert.equal(monthView(s, "2026-06", NOW), null, "เดือนที่ไม่เคยเปิด → ไม่มีมุมมอง");
});

test("กลับมาเดือนเดิม ได้ตัวกรองเดิม แม้สลับไปมาหลายรอบ", () => {
  let s = upsertMonth(null, "2026-08", buildView({
    filters: new Map([["pay", new Set(["รอชำระ"])]]), sort: { col: "total", dir: "desc" }, search: "0812", anchorId: 9,
  }), NOW);
  s = upsertMonth(s, "2026-09", buildView({ filters: new Map(), sort: null, search: "", anchorId: 2 }), NOW);
  s = upsertMonth(s, "2026-07", buildView({ filters: new Map(), sort: null, search: "", anchorId: 3 }), NOW);
  const back = monthView(s, "2026-08", NOW)!;
  assert.deepEqual(back.filters, [["pay", ["รอชำระ"]]]);
  assert.deepEqual(back.sort, { col: "total", dir: "desc" });
  assert.equal(back.search, "0812");
  assert.equal(back.anchorId, 9);
});

test("เขียนทับเดือนเดิมด้วยค่าใหม่ (ล้างตัวกรองแล้วต้องไม่ค้างของเก่า)", () => {
  let s = upsertMonth(null, "2026-08", buildView({
    filters: new Map([["a", new Set(["x"])]]), sort: null, search: "", anchorId: 1,
  }), NOW);
  s = upsertMonth(s, "2026-08", buildView({ filters: new Map(), sort: null, search: "", anchorId: 7 }), NOW);
  assert.deepEqual(monthView(s, "2026-08", NOW)!.filters, []);
  assert.equal(monthView(s, "2026-08", NOW)!.anchorId, 7);
});

test("โควต้า/หมดอายุ: ตัดเดือนเก่าทิ้ง เดือนที่เพิ่งเขียนรอดเสมอ", () => {
  let s: SavedView | null = null;
  for (let i = 0; i < MAX_MONTHS + 4; i++) {
    const m = `2026-${String((i % 12) + 1).padStart(2, "0")}`;
    s = upsertMonth(s, m + (i >= 12 ? "" : ""), buildView({ filters: new Map(), sort: null, search: "", anchorId: i }),
      new Date(NOW.getTime() - (MAX_MONTHS + 4 - i) * 1000));
  }
  assert.ok(Object.keys(s!.months).length <= MAX_MONTHS, `เหลือ ${Object.keys(s!.months).length} เดือน`);
  assert.ok(s!.months[s!.lastMonth], "เดือนล่าสุดต้องไม่ถูกตัด");
  // เดือนที่ไม่ได้แตะเกิน 14 วัน ถูกตัดตอนเขียนครั้งถัดไป
  const stale = upsertMonth(blob("2026-08", { "2026-01": view({ savedAt: days(20) }) }),
    "2026-08", buildView({ filters: new Map(), sort: null, search: "", anchorId: 1 }), NOW);
  assert.equal(stale.months["2026-01"], undefined);
});

test("isStale / MAX_AGE_DAYS", () => {
  assert.equal(isStale(view({ savedAt: days(20) }), NOW), true);
  assert.equal(isStale(view({ savedAt: days(13) }), NOW), false);
  assert.equal(isStale(view({ savedAt: "ไม่ใช่วันที่" }), NOW), true, "เวลาอ่านไม่ออก = หมดอายุ");
  assert.equal(MAX_AGE_DAYS, 14);
  assert.equal(monthView(blob("2026-08", { "2026-08": view({ savedAt: days(20) }) }), "2026-08", NOW), null);
});

// ─────────── กติกาเดือนตอนล็อกอิน ───────────

test("มีตัวกรองค้าง → คงเดือนเดิม + คืนแถวที่ค้างไว้", () => {
  const s = blob("2026-08", { "2026-08": view({ filters: [["c", ["v"]]], anchorId: 4242 }) });
  assert.deepEqual(planRestore(s, MONTHS, NOW), { month: "2026-08", anchorId: 4242 });
});

test("มีคำค้น (ไม่มีตัวกรอง) ก็นับว่าทำงานเจาะจงอยู่ · ช่องว่างล้วนไม่นับ", () => {
  assert.equal(planRestore(blob("2026-08", { "2026-08": view({ search: " 0839 ", anchorId: 7 }) }), MONTHS, NOW).month, "2026-08");
  assert.equal(planRestore(blob("2026-08", { "2026-08": view({ search: "   " }) }), MONTHS, NOW).month, "2026-09");
});

test("🔴 ไม่มีตัวกรองเลย → เด้งกลับเดือนล่าสุด + ไม่คืน scroll (กันคีย์ผิดเดือน)", () => {
  const s = blob("2026-07", { "2026-07": view({ anchorId: 999 }) });
  assert.deepEqual(planRestore(s, MONTHS, NOW), { month: "2026-09", anchorId: null });
});

test("การเรียงอย่างเดียวไม่นับว่า 'ทำงานเจาะจง'", () => {
  assert.equal(isNarrowed(view({ sort: { col: "total", dir: "desc" } })), false);
  assert.equal(planRestore(blob("2026-07", { "2026-07": view({ sort: { col: "total", dir: "desc" } }) }), MONTHS, NOW).month, "2026-09");
});

test("หมดอายุ / เดือนไม่มีข้อมูลแล้ว / ไม่มีค่าเก็บไว้ → เริ่มค่าเริ่มต้น", () => {
  assert.equal(planRestore(blob("2026-08", { "2026-08": view({ filters: [["c", ["v"]]], savedAt: days(20) }) }), MONTHS, NOW).month, "2026-09");
  assert.equal(planRestore(blob("2025-12", { "2025-12": view({ filters: [["c", ["v"]]], anchorId: 5 }) }), MONTHS, NOW).month, "2026-09");
  assert.deepEqual(planRestore(null, MONTHS, NOW), { month: "2026-09", anchorId: null });
  assert.equal(defaultMonth([], NOW), NOW.toISOString().slice(0, 7));
  assert.equal(planRestore(null, [], NOW).month, "2026-09");
});

// ─────────── กันข้อมูลเสีย ───────────

test("parseSaved: ข้อมูลเสียทุกแบบต้องได้ null ไม่ใช่ throw", () => {
  for (const bad of [null, undefined, "", "ไม่ใช่ json", "{", "[]", "123", '"x"', '{"v":2}',
                     '{"v":1,"lastMonth":"2026-08","months":{}}',
                     '{"v":2,"lastMonth":"2026-8","months":{}}',
                     '{"v":2,"lastMonth":"2026-08"}']) {
    assert.equal(parseSaved(bad as string | null), null, `ควรได้ null: ${bad}`);
  }
  // months เป็น array: typeof 'object' ผ่านด่าน แต่ไม่มีคีย์รูปเดือน → ได้ก้อนว่าง (= ไม่มีมุมมองเก็บไว้)
  // ไม่ throw และ planRestore ตกไปเดือนเริ่มต้น ซึ่งปลอดภัยพอ ไม่ต้องรีเจกต์ทั้งก้อน
  const arr = parseSaved('{"v":2,"lastMonth":"2026-08","months":[]}')!;
  assert.deepEqual(arr.months, {});
  assert.deepEqual(planRestore(arr, MONTHS, NOW), { month: "2026-09", anchorId: null });
});

test("parseSaved: แถว/เดือนที่รูปเพี้ยน ทิ้งทีละอัน ไม่ทิ้งทั้งก้อน", () => {
  const raw = JSON.stringify({
    v: 2, lastMonth: "2026-08",
    months: {
      "2026-08": { savedAt: NOW.toISOString(), filters: [["ok", ["a", "b"]], ["บาด"], [1, ["x"]], ["ว่าง", []], ["ปน", ["a", 5, null]]],
                   sort: { col: "x", dir: "ขึ้น" }, search: 42, anchorId: "12" },
      "ไม่ใช่เดือน": { savedAt: NOW.toISOString() },
      "2026-07": { filters: [] },                       // ไม่มี savedAt → ทิ้ง
      "2026-06": { savedAt: NOW.toISOString() },        // ว่างแต่ถูกรูป → เก็บ
    },
  });
  const s = parseSaved(raw)!;
  assert.deepEqual(Object.keys(s.months).sort(), ["2026-06", "2026-08"]);
  const v = s.months["2026-08"];
  assert.deepEqual(v.filters, [["ok", ["a", "b"]], ["ปน", ["a"]]]);
  assert.equal(v.sort, null, "dir ไม่ถูกต้อง → ทิ้งการเรียง");
  assert.equal(v.search, "", "search ไม่ใช่สตริง → ว่าง");
  assert.equal(v.anchorId, null, "anchorId ไม่ใช่ตัวเลข → null");
});

test("เขียน → อ่านกลับ ได้ของเดิม (Map/Set ลง JSON ตรงๆ ไม่ได้)", () => {
  const s = upsertMonth(null, "2026-08", buildView({
    filters: new Map([["delivery_status", new Set(["ตีกลับ", "ส่งสำเร็จ"])], ["pay", new Set(["รอชำระ"])]]),
    sort: { col: "ordered_at", dir: "asc" },
    search: "สมหญิง",
    anchorId: 16545,
  }), NOW);
  const back = parseSaved(JSON.stringify(s))!;
  const v = back.months["2026-08"];
  assert.deepEqual(v.filters, [["delivery_status", ["ตีกลับ", "ส่งสำเร็จ"]], ["pay", ["รอชำระ"]]]);
  assert.deepEqual(v.sort, { col: "ordered_at", dir: "asc" });
  assert.equal(v.search, "สมหญิง");
  assert.equal(v.anchorId, 16545);
  assert.equal(back.lastMonth, "2026-08");
  // anchorId undefined (ยังไม่มีแถว) ต้องกลายเป็น null ไม่ใช่หาย
  assert.equal(buildView({ filters: new Map(), sort: null, search: "", anchorId: undefined }).anchorId, null);
});

test("ข้อความแจ้งผู้ใช้: ขึ้นเฉพาะตอนมีตัวกรอง/คำค้นจริง · เปลี่ยนคำนำหน้าได้", () => {
  assert.equal(restoreSummary(null, "สิงหาคม 2026"), null);
  assert.equal(restoreSummary(view(), "สิงหาคม 2026"), null);
  assert.equal(restoreSummary(view({ sort: { col: "a", dir: "asc" } }), "สิงหาคม 2026"), null);
  const msg = restoreSummary(view({ filters: [["a", ["x"]]], search: "0839" }), "สิงหาคม 2026",
    "ใส่ตัวกรองเดิมของเดือนนี้ให้แล้ว")!;
  assert.match(msg, /^ใส่ตัวกรองเดิมของเดือนนี้ให้แล้ว/);
  assert.match(msg, /สิงหาคม 2026/);
  assert.match(msg, /ตัวกรอง 1 คอลัมน์/);
  assert.match(msg, /0839/);
});
