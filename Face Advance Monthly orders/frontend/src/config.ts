// ค่าสาธารณะ (ปลอดภัยที่จะอยู่ใน frontend) — anon key ออกแบบมาให้เปิดเผยได้
// service key / DB url ไม่อยู่ที่นี่เด็ดขาด (อยู่แค่ Edge Function)
export const SUPABASE_URL = "https://xfayguljywhjwqcuimvw.supabase.co";
export const ANON_KEY =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhmYXlndWxqeXdoandxY3VpbXZ3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc4ODIyMjMsImV4cCI6MjEwMzQ1ODIyM30.WnE1z_GP8pI9grJ0mA_p9ar9hfklMqa_W4K5BaC1VyE";
export const FUNCTIONS_URL = `${SUPABASE_URL}/functions/v1`;
