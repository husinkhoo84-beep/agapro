# AGA Pro Member (website)

Aplikasi data member "1 orang rekrut 5". Database dan login memakai Supabase, website di-host di Vercel.

## 1. Supabase (database + login)
1. Daftar di https://supabase.com, klik **New project** (region Singapore). Simpan password database.
2. Buka **SQL Editor**, tempel seluruh isi `supabase/schema.sql`, klik **Run**.
3. **Authentication > Sign In / Providers > Email**: matikan "Confirm email" kalau tidak mau member harus klik email konfirmasi.
4. **Project Settings > API**: salin **Project URL** dan **anon public key**, isi ke `public/config.js`.
   Jangan pernah memasang `service_role` key di website.

## 2. Vercel (website)
1. Masuk https://vercel.com dengan akun GitHub, klik **Add New > Project**, pilih repo `agapro`.
2. Framework: **Other**. Output directory sudah diatur oleh `vercel.json` (`public`). Klik **Deploy**.

## 3. Jadikan diri sendiri pemilik
1. Buka website, klik **Daftar**, buat akun dengan email kamu.
2. Di Supabase SQL Editor jalankan: `select make_owner('emailkamu@contoh.com');`
3. Muat ulang website. Sekarang kamu pemilik dan bisa memberi akses master ke email lain dari panel Akses
   (orangnya harus sudah daftar akun dulu).

## Pindah data dari aplikasi lama
Di aplikasi lama klik **Export Excel**, lalu di website klik **Import Excel**.
