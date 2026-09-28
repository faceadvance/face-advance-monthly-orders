// ตัวกรองหัวคอลัมน์ในตารางออเดอร์: ตัวกรองจำ "ค่าที่ติ๊กไว้" ตอนกดใช้
// ปัญหา (เจ้านายแจ้ง 2026-09-28): พนักงานบันทึกค่าใหม่ที่ไม่เคยมีในเดือนนั้น (เช่น รายละเอียดปัญหาคำใหม่)
//   → ค่าใหม่ไม่อยู่ในชุดที่ติ๊ก → แถวที่เพิ่งแก้หายจากตาราง และในตัวกรองขึ้นแบบไม่ได้ติ๊ก
// แก้: หลังบันทึก ถ้าค่าของแถวนั้นเป็น "ค่าใหม่จริงๆ" (ไม่มีแถวอื่นในข้อมูลที่มีค่านี้) → เติมเข้าชุดที่ติ๊กให้เลย
//   ไม่เติมถ้าค่านั้นมีอยู่แล้วในแถวอื่น (ผู้ใช้อาจตั้งใจไม่ติ๊กค่านั้น เช่น กรองให้เห็นแค่ "กำลังส่ง")

export function includeNewValues<O, K extends string>(
  filters: Map<K, Set<string>>,
  orders: readonly O[],
  changed: O,
  valueOf: (o: O, col: K) => string,
): K[] {
  const added: K[] = [];
  for (const [col, set] of filters) {
    const v = valueOf(changed, col);
    if (set.has(v)) continue;
    const existsElsewhere = orders.some((o) => o !== changed && valueOf(o, col) === v);
    if (!existsElsewhere) { set.add(v); added.push(col); }
  }
  return added;
}
