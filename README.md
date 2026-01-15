# Docker Compose Service Catalog

![Docker Compose](https://img.shields.io/badge/Docker_Compose-2496ED?style=for-the-badge&logo=docker&logoColor=white) ![PostgreSQL](https://img.shields.io/badge/PostgreSQL-316192?style=for-the-badge&logo=postgresql&logoColor=white) ![MySQL](https://img.shields.io/badge/MySQL-4479A1?style=for-the-badge&logo=mysql&logoColor=white) ![Oracle](https://img.shields.io/badge/Oracle-F80000?style=for-the-badge&logo=oracle&logoColor=white) ![Greenplum](https://img.shields.io/badge/Greenplum-00693C?style=for-the-badge&logoColor=white)

Koleksi file Docker Compose untuk meluncurkan layanan yang umum dipakai dalam pengembangan. Saat ini tersedia database PostgreSQL, MySQL, Oracle, dan Greenplum, dan repo ini siap diperluas ke layanan lain seperti Consul, Redis, atau message broker.

---

## Sebelum Mulai

- Docker Engine 20.10+ sudah terinstal.
- Plugin Docker Compose v2 tersedia (`docker compose version`).
- Port default 5432 (PostgreSQL), 3306 (MySQL), 1521 (Oracle), dan 6432 (Greenplum) tidak dipakai aplikasi lain.

---

## Ringkasan Layanan

| Layanan | Tipe | File | Port Host | Kredensial/Info bawaan | Volume |
| --- | --- | --- | --- | --- | --- |
| ![PostgreSQL Badge](https://img.shields.io/badge/-PostgreSQL-316192?logo=postgresql&logoColor=white) | Database | `docker-compose-postgres.yml` | `5432` | user: `dudung`<br>password: `dudung123`<br>database: `dudungdb` | `pgdata` |
| ![MySQL Badge](https://img.shields.io/badge/-MySQL-4479A1?logo=mysql&logoColor=white) | Database | `docker-compose-mysql.yml` | `3306` | root password: `root` | `mysqldata` |
| ![Oracle Badge](https://img.shields.io/badge/-Oracle_12c-F80000?logo=oracle&logoColor=white) | Database | `docker-compose-oracle-12c.yml` | `1521` | password: `sapassword`<br>SID: `ORCL`<br>PDB: `ORAGIRIPDB` | `oracle-data` |
| ![Oracle Badge](https://img.shields.io/badge/-Oracle_19c-F80000?logo=oracle&logoColor=white) | Database | `docker-compose-oracle-19c.yml` | `1521` | password: `sapassword`<br>SID: `ORCL`<br>PDB: `ORAGIRIPDB` | `oracle-data-19c` |
| ![Oracle Badge](https://img.shields.io/badge/-Oracle_21c-F80000?logo=oracle&logoColor=white) | Database | `docker-compose-oracle-21c.yml` | `1521` | password: `sapassword`<br>SID: `ORCL`<br>PDB: `ORAGIRIPDB` | `oracle-data-21c` |
| Greenplum 6.x | Database MPP | `docker-compose-greenplum-db.yml` | `6432` | user: `tester`<br>password: `pivotal`<br> database: `testdb` | `greenplum-data` |
| Greenplum 7.x | Database MPP | `docker-compose-greenplum-db-v7.yml` | `6432` | user: `gpadmin`<br>password: `postgres`<br> database: `postgres` | `greenplum-data` |

> Volume memastikan data bertahan walau kontainer dihentikan. Hapus volume hanya jika kamu ingin memulai dari nol.

---

## Cara Cepat

```bash
docker compose -p postgres -f docker-compose-postgres.yml up -doracle-12c`, `oracle-19c`, `oracle-21c`, `
```

1. Ganti nama file dengan layanan pilihan (`postgres`, `mysql`, `greenplum-db`, atau `greenplum-db-v7`).
2. Tunggu kontainer running, lalu sambung menggunakan klien SQL favoritmu.
3. Gunakan `docker ps` atau `docker compose -f <file> ps` untuk memeriksa status.
4. Bila ingin menjalankan beberapa layanan database sekaligus (mis. PostgreSQL + Greenplum), pakai flag `-p <nama-project>` berbeda untuk tiap file agar network & volume terpisah.

---

## Perintah Umum

| Tujuan | Perintah |
| --- | --- |
| Jalankan dalam mode detached | `docker compose -p <project> -f <file> up -d` |
| Lihat log berjalan | `docker compose -p <project> -f <file> logs -f` |
| Hentikan dan lepaskan kontainer | `docker compose -p <project> -f <file> down` |oracle-12c.yml`, `docker-compose-oracle-19c.yml`, `docker-compose-oracle-21c.yml`, `docker-compose-
| Hentikan & hapus volume | `docker compose -p <project> -f <file> down -v` |

> Ganti `<file>` dengan `docker-compose-postgres.yml`, `docker-compose-mysql.yml`, `docker-compose-greenplum-db.yml`, atau `docker-compose-greenplum-db-v7.yml`. `project` adalah nama bebas (mis. `postgres`, `greenplum7`) dan wajib unik saat beberapa layanan berjalan bersamaan.

---

## Penyesuaian

- Ganti kredensial di bagian `environment` (mis. `GP_USER`, `GP_PASSWORD`, `GP_DB`) sebelum menjalankan pertama kali. Pilih file compose yang sesuai versi Greenplum yang ingin dipakai (6.x vs 7.x).
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
