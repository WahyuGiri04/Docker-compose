# Rangkuman Belajar Replikasi PostgreSQL

Panduan praktis setup Physical dan Logical Replication (tabel hingga kolom) menggunakan Docker.

## 1) Ikhtisar Konsep: Physical vs Logical Replication

PostgreSQL menyediakan dua pendekatan utama untuk replikasi data ke server sekunder (replica):

| Karakteristik | Physical (Streaming) Replication | Logical Replication |
| --- | --- | --- |
| Mekanisme | Menyalin perubahan berbasis WAL secara level fisik (cluster-level). | Mengirim perubahan data logis (INSERT/UPDATE/DELETE) via Publisher-Subscriber. |
| Cakupan Data | Seluruh cluster database (struktur + data). | Selektif: bisa tabel tertentu, bahkan kolom tertentu. |
| Sifat Replica | Read-only untuk data hasil replika. | Read-only untuk tabel replikasi, tetap bisa punya tabel lokal writeable. |
| Kustomisasi Index | Tidak fleksibel (mengikuti struktur fisik primary). | Fleksibel, bisa tambah index khusus di subscriber. |
| Versi PostgreSQL | Idealnya major version sama. | Mendukung skenario lintas versi (berguna saat upgrade). |

Ringkasnya:
- Pilih Physical untuk HA/DR (cadangan server siap pakai).
- Pilih Logical untuk kebutuhan seleksi data, beban reporting, atau pemisahan data sensitif.

---

## 2) Prasyarat

- Docker Engine dan Docker Compose aktif.
- Port host tidak bentrok:
  - 5432 untuk primary/publisher
  - 5433 untuk replica/subscriber
- Siapkan folder kerja, misalnya: `replikasi-db-postgres-basic`.
- Jika menggunakan script shell, jalankan:

```bash
chmod +x init-primary.sh
```

---

## 3) Setup Physical (Streaming) Replication

### 3.1 File Compose (Physical)

```yaml
version: '3.8'
services:
  pg_primary:
    image: postgres:15-alpine
    container_name: pg_primary
    environment:
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
      POSTGRES_DB: mydb
    ports:
      - "5432:5432"
    volumes:
      - pg_primary_data:/var/lib/postgresql/data
      - ./init-primary.sh:/docker-entrypoint-initdb.d/init-primary.sh

  pg_replica:
    image: postgres:15-alpine
    container_name: pg_replica
    environment:
      PGPASSWORD: mypassword
    ports:
      - "5433:5432"
    depends_on:
      - pg_primary
    entrypoint: >
      bash -c "
      until pg_isready -h pg_primary -p 5432 -U myuser; do echo 'Waiting for primary...'; sleep 1; done;
      if [ ! -s /var/lib/postgresql/data/PG_VERSION ]; then
        pg_basebackup -h pg_primary -D /var/lib/postgresql/data -U replication_user -v -P -X stream -Fp -R
      fi;
      exec docker-entrypoint.sh postgres
      "
    volumes:
      - pg_replica_data:/var/lib/postgresql/data

volumes:
  pg_primary_data:
  pg_replica_data:
```

### 3.2 Script Inisialisasi Primary (`init-primary.sh`)

```bash
#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  CREATE ROLE replication_user WITH REPLICATION LOGIN PASSWORD 'mypassword';
EOSQL

echo "host replication replication_user all md5" >> "$PGDATA/pg_hba.conf"
```

### 3.3 Jalankan Container

```bash
docker compose -f docker-compose-physical.yml up -d
```

### 3.4 Verifikasi Replikasi Physical

Cek dari sisi primary:

```sql
SELECT client_addr, state, sync_state
FROM pg_stat_replication;
```

Cek status read-only di replica:

```sql
SHOW transaction_read_only;
```

Ekspektasi:
- Query `pg_stat_replication` menampilkan koneksi replica dalam state streaming.
- `transaction_read_only` di replica bernilai `on`.

---

## 4) Setup Logical Replication

### 4.1 File Compose (Logical)

```yaml
version: '3.8'
services:
  pg_publisher:
    image: postgres:15-alpine
    container_name: pg_publisher
    environment:
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
      POSTGRES_DB: mydb
    ports:
      - "5432:5432"
    command: postgres -c wal_level=logical

  pg_subscriber:
    image: postgres:15-alpine
    container_name: pg_subscriber
    environment:
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
      POSTGRES_DB: mydb
    ports:
      - "5433:5432"
    depends_on:
      - pg_publisher
```

Jalankan:

```bash
docker compose -f docker-compose-logical.yml up -d
```

### 4.2 Buat Tabel di Kedua Sisi (wajib)

Logical replication tidak menyalin skema otomatis, jadi buat tabel manual di publisher dan subscriber:

```sql
CREATE TABLE produk (
  id SERIAL PRIMARY KEY,
  nama_produk VARCHAR(100),
  harga NUMERIC
);
```

### 4.3 (Opsional) Tambah Index Khusus di Subscriber

```sql
CREATE INDEX idx_harga_produk ON produk(harga);
```

### 4.4 Aktifkan Publication (Publisher)

```sql
CREATE PUBLICATION pub_produk FOR TABLE produk;
```

### 4.5 Aktifkan Subscription (Subscriber)

```sql
CREATE SUBSCRIPTION sub_produk
CONNECTION 'host=pg_publisher port=5432 user=myuser password=mypassword dbname=mydb'
PUBLICATION pub_produk;
```

### 4.6 Verifikasi Replikasi Logical

Di publisher:

```sql
SELECT pubname, schemaname, tablename
FROM pg_publication_tables;
```

Di subscriber:

```sql
SELECT subname, status
FROM pg_stat_subscription;
```

Uji data:
- Insert data di publisher pada tabel `produk`.
- Pastikan data muncul di subscriber.

---

## 5) Manajemen Lanjutan Logical Replication

### 5.1 Menambahkan Tabel Baru ke Publication yang Sudah Ada

Langkah:
1. Buat tabel baru di subscriber.
2. Buat tabel yang sama di publisher.
3. Tambahkan tabel ke publication lama:

```sql
ALTER PUBLICATION pub_produk ADD TABLE kategori;
```

4. Refresh subscription agar subscriber mulai menarik data tabel baru:

```sql
ALTER SUBSCRIPTION sub_produk REFRESH PUBLICATION;
```

### 5.2 Kapan Alter vs Buat Publication Baru

- Gunakan `ALTER PUBLICATION` jika tabel baru masih satu domain bisnis yang sama.
- Buat publication baru jika:
  - domain data berbeda,
  - target subscriber berbeda,
  - ingin isolasi kegagalan antar-aliran replikasi.

---

## 6) Replikasi Tingkat Kolom (Column Filter)

Tujuan: mencegah kolom sensitif ikut direplikasi (misalnya `password_hash`).

### 6.1 Definisi Tabel di Publisher

```sql
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  username VARCHAR(50),
  email VARCHAR(100),
  password_hash VARCHAR(255)
);
```

### 6.2 Definisi Tabel di Subscriber (tanpa kolom sensitif)

```sql
CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  username VARCHAR(50),
  email VARCHAR(100)
);
```

### 6.3 Publication dengan Daftar Kolom Aman

```sql
CREATE PUBLICATION pub_users_aman FOR TABLE users (id, username, email);
```

### 6.4 Subscription di Subscriber

```sql
CREATE SUBSCRIPTION sub_users_aman
CONNECTION 'host=pg_publisher port=5432 user=myuser password=mypassword dbname=mydb'
PUBLICATION pub_users_aman;
```

Catatan penting:
- Kolom Primary Key wajib disertakan dalam daftar kolom publikasi.
- Jika PK tidak disertakan, operasi UPDATE/DELETE dapat gagal direplikasi.

---

## 7) Tambahan Praktis (Rekomendasi)

### 7.1 Hardening Dasar

- Gunakan password kuat, jangan pakai contoh default di lingkungan produksi.
- Batasi akses network hanya subnet yang dibutuhkan.
- Simpan kredensial via file `.env` atau secret manager.

### 7.2 Monitoring Cepat

- Physical:

```sql
SELECT now() - pg_last_xact_replay_timestamp() AS replay_lag;
```

- Logical (subscriber):

```sql
SELECT subname, received_lsn, latest_end_lsn, latest_end_time
FROM pg_stat_subscription;
```

### 7.3 Skenario Uji Minimal Setelah Setup

1. Insert 1 baris di primary/publisher.
2. Update baris tersebut.
3. Delete baris tersebut.
4. Validasi hasil akhir di replica/subscriber.

---

## 8) Troubleshooting Singkat

### Masalah: subscription tidak jalan

- Cek `wal_level=logical` di publisher.
- Cek koneksi host/port/user/password.
- Cek role memiliki privilege yang cukup.
- Cek log container:

```bash
docker logs pg_publisher
docker logs pg_subscriber
```

### Masalah: replica physical gagal clone awal

- Pastikan user `replication_user` memiliki hak REPLICATION.
- Pastikan rule `pg_hba.conf` untuk replication sudah ditambahkan.
- Hapus volume replica lalu bootstrap ulang jika basebackup korup.

---

## 9) Ringkasan Keputusan

- Pilih Physical jika target utama adalah failover cepat dan keseragaman penuh cluster.
- Pilih Logical jika target utama adalah fleksibilitas skema, filtering data, dan workload reporting.

Dokumen ini dapat dijadikan baseline lab lokal maupun fondasi desain replikasi untuk environment non-produksi.