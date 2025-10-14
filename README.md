# Docker Compose Service Catalog

![Docker Compose](https://img.shields.io/badge/Docker_Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white) ![PostgreSQL](https://img.shields.io/badge/PostgreSQL-316192?style=for-the-badge&logo=postgresql&logoColor=white) ![MySQL](https://img.shields.io/badge/MySQL-4479A1?style=for-the-badge&logo=mysql&logoColor=white)

Koleksi file Docker Compose untuk meluncurkan layanan yang umum dipakai dalam pengembangan. Saat ini tersedia database PostgreSQL dan MySQL, dan repo ini siap diperluas ke layanan lain seperti Consul, Redis, atau message broker.

---

## Sebelum Mulai

- Docker Engine 20.10+ sudah terinstal.
- Plugin Docker Compose v2 tersedia (`docker compose version`).
- Port default 5432 (PostgreSQL) dan 3306 (MySQL) tidak dipakai aplikasi lain.

---

## Ringkasan Layanan

| Layanan | Tipe | File | Port Host | Kredensial/Info bawaan | Volume |
| --- | --- | --- | --- | --- | --- |
| ![PostgreSQL Badge](https://img.shields.io/badge/-PostgreSQL-316192?logo=postgresql&logoColor=white) | Database | `docker-compose-postgres.yml` | `5432` | user: `dudung`<br>password: `dudung123`<br>database: `dudungdb` | `pgdata` |
| ![MySQL Badge](https://img.shields.io/badge/-MySQL-4479A1?logo=mysql&logoColor=white) | Database | `docker-compose-mysql.yml` | `3306` | root password: `root` | `mysqldata` |

> Volume memastikan data bertahan walau kontainer dihentikan. Hapus volume hanya jika kamu ingin memulai dari nol.

---

## Cara Cepat

```bash
docker compose -f docker-compose-postgres.yml up -d
```

1. Ganti nama file dengan layanan pilihan (`postgres` atau `mysql`).
2. Tunggu kontainer running, lalu sambung menggunakan klien SQL favoritmu.
3. Gunakan `docker ps` atau `docker compose -f <file> ps` untuk memeriksa status.

---

## Perintah Umum

| Tujuan | Perintah |
| --- | --- |
| Jalankan dalam mode detached | `docker compose -f <file> up -d` |
| Lihat log berjalan | `docker compose -f <file> logs -f` |
| Hentikan dan lepaskan kontainer | `docker compose -f <file> down` |
| Hentikan & hapus volume | `docker compose -f <file> down -v` |

> Ganti `<file>` dengan `docker-compose-postgres.yml` atau `docker-compose-mysql.yml`.

---

## Penyesuaian

- Ganti kredensial di bagian `environment` sebelum menjalankan pertama kali.
- Sesuaikan mapping port pada blok `ports` bila bentrok dengan layanan lain.
- Tambahkan file `.env` untuk menyimpan nilai sensitif, lalu referensikan pada compose file.
- Gunakan `docker volume ls` dan `docker volume inspect <volume>` untuk melihat lokasi penyimpanan data.

---

## Menambah Layanan Baru

1. Duplikasi salah satu file compose yang ada atau buat file baru dengan pola penamaan `docker-compose-<service>.yml`.
2. Tambahkan layanan baru di bawah key `services`, set `image`, `ports`, dan variabel lingkungan yang dibutuhkan.
3. Bila perlu persistensi, definisikan volume baru di bagian `volumes`.
4. Perbarui tabel ringkasan di atas dengan menambahkan baris layanan lengkap dengan ikon/shield bila tersedia.

---

## Saran Penggunaan

- Cadangkan volume secara berkala bila data penting.
- Nonaktifkan layanan yang tidak digunakan dengan `down` agar resource tidak terpakai.
- Simpan catatan koneksi (host, port, user, password) di password manager supaya mudah dibagikan ke tim.
- Pisahkan file compose untuk tiap lingkungan (dev/staging/prod) agar konfigurasi khusus tidak tercampur.
