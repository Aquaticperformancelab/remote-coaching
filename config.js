// =============================================================
//  Isi 2 baris di bawah dengan data dari Supabase (Langkah 4):
//  Supabase → Project Settings → API Keys
//
//  supabaseKey = PUBLISHABLE key (diawali sb_publishable_)
//               atau "anon public" key di tab Legacy.
//  JANGAN pernah memakai "secret" atau "service_role" key di sini.
//  File ini dibaca publik, dan keamanannya dijaga oleh aturan RLS.
// =============================================================
window.DEVILRAYS_CONFIG = {
  supabaseUrl: https://izxapsjnqkujeuuvdwul.supabase.co/rest/v1/
  supabaseKey: sb_publishable_c1boKhvViEkYyvM-EV-54w_DbjYGtis
  googleLogin: false   // ubah ke true setelah mengikuti bagian Opsional: login Google
};
