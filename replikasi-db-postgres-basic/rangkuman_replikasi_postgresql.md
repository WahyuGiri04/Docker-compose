# Rangkuman Belajar Replikasi PostgreSQL

> **Stack:** PostgreSQL 15 + Docker Compose | **Bahasa:** Indonesia

Panduan praktis setup **Physical (Streaming)** dan **Logical Replication** PostgreSQL — dari konsep WAL, setup Docker, replikasi tingkat kolom, monitoring lag, hingga failover & troubleshooting.

---

## Daftar Isi

1. [Ikhtisar Konsep: Physical vs Logical Replication](#1-ikhtisar-konsep-physical-vs-logical-replication)
2. [Cara Kerja WAL (Write-Ahead Log)](#2-cara-kerja-wal-write-ahead-log)
3. [Prasyarat](#3-prasyarat)
4. [Setup Physical (Streaming) Replication](#4-setup-physical-streaming-replication)
5. [Setup Logical Replication](#5-setup-logical-replication)
6. [Replikasi Tingkat Kolom (Column Filter)](#6-replikasi-tingkat-kolom-column-filter)
7. [Manajemen Lanjutan Logical Replication](#7-manajemen-lanjutan-logical-replication)
8. [Replikasi Sinkron (Synchronous Replication)](#8-replikasi-sinkron-synchronous-replication)
9. [Monitoring & Observabilitas](#9-monitoring--observabilitas)
10. [Failover & Switchover (Physical)](#10-failover--switchover-physical)
11. [Hardening & Keamanan](#11-hardening--keamanan)
12. [Troubleshooting](#12-troubleshooting)
13. [Ringkasan Keputusan Arsitektur](#13-ringkasan-keputusan-arsitektur)

---

## 1. Ikhtisar Konsep: Physical vs Logical Replication

PostgreSQL menyediakan dua pendekatan utama untuk replikasi data ke server sekunder:

| Karakteristik | Physical (Streaming) Replication | Logical Replication |
| --- | --- | --- |
| Mekanisme | Menyalin perubahan WAL secara level fisik (cluster-level). | Mengirim perubahan data logis (INSERT/UPDATE/DELETE) via Publisher-Subscriber. |
| Cakupan Data | Seluruh cluster database (struktur + data). | Selektif: bisa tabel tertentu, bahkan kolom tertentu. |
| Sifat Replica | Read-only untuk semua data (hot standby). | Read-only untuk tabel replikasi; bisa punya tabel lokal writeable. |
| Kustomisasi Index | Tidak fleksibel (ikut struktur fisik primary). | Fleksibel, bisa tambah index khusus di subscriber. |
| Versi PostgreSQL | Idealnya major version sama. | Mendukung lintas versi (berguna saat upgrade major). |
| Schema Otomatis | ✅ Ya (seluruh skema ikut) | ❌ Tidak, harus dibuat manual di subscriber. |
| Failover | ✅ Siap digunakan langsung | ❌ Perlu konfigurasi tambahan |
| Use Case Utama | HA / Disaster Recovery | Reporting, Filtering data, Upgrade DB |

### 1.1 Diagram Perbandingan Arsitektur

```mermaid
flowchart LR
    subgraph PHYSICAL["Physical (Streaming) Replication"]
        direction LR
        PRI[("Primary\nPostgreSQL")]
        WAL_P[/"WAL Stream\n(binary)"/]
        REP[("Replica\nRead-Only")]
        PRI -->|"WAL sender"| WAL_P
        WAL_P -->|"WAL receiver"| REP
    end

    subgraph LOGICAL["Logical Replication"]
        direction LR
        PUB[("Publisher\nPostgreSQL")]
        WAL_L[/"Logical\nDecoding"/]
        SLOT["Replication\nSlot"]
        SUB[("Subscriber\nPostgreSQL")]
        PUB --> WAL_L
        WAL_L --> SLOT
        SLOT -->|"Publication"| SUB
    end

    style PHYSICAL fill:#0d2137,color:#fff
    style LOGICAL fill:#1a3a00,color:#fff
```

### 1.2 Kapan Memilih Masing-masing?

```mermaid
flowchart TD
    START["Butuh Replikasi PostgreSQL?"]

    START --> Q1{"Target utama?"}
    Q1 -->|"Failover / HA / DR"| PHYS["✅ Physical Replication\n(Streaming)"]
    Q1 -->|"Seleksi data / Reporting"| Q2{"Butuh filter\ntabel/kolom?"}
    Q1 -->|"Upgrade major version"| LOGI["✅ Logical Replication"]

    Q2 -->|"Ya"| LOGI
    Q2 -->|"Tidak, tapi beda versi PG"| LOGI
    Q2 -->|"Tidak, versi sama"| Q3{"Butuh replica\nbisa write lokal?"}

    Q3 -->|"Ya"| LOGI
    Q3 -->|"Tidak"| PHYS

    style PHYS fill:#1e3a5f,color:#fff
    style LOGI fill:#1a3a00,color:#fff
```

---

## 2. Cara Kerja WAL (Write-Ahead Log)

**WAL (Write-Ahead Log)** adalah mekanisme inti PostgreSQL untuk durabilitas dan replikasi. Setiap perubahan data ditulis ke WAL **sebelum** diterapkan ke data page, memastikan konsistensi meski terjadi crash.

### 2.1 Alur WAL di Physical Replication

```mermaid
sequenceDiagram
    participant APP as Aplikasi
    participant PG_PRI as PostgreSQL Primary
    participant WAL_BUF as WAL Buffer
    participant WAL_FILE as WAL File (Disk)
    participant WAL_SND as WAL Sender
    participant WAL_RCV as WAL Receiver (Replica)
    participant PG_REP as PostgreSQL Replica

    APP->>PG_PRI: INSERT / UPDATE / DELETE
    PG_PRI->>WAL_BUF: Tulis ke WAL buffer
    WAL_BUF->>WAL_FILE: Flush ke disk (fsync)
    PG_PRI-->>APP: Commit berhasil

    WAL_SND->>WAL_FILE: Baca WAL records
    WAL_SND->>WAL_RCV: Kirim via TCP stream
    WAL_RCV->>PG_REP: Apply WAL (redo)
    WAL_RCV-->>WAL_SND: Konfirmasi LSN
```

### 2.2 Alur WAL di Logical Replication

```mermaid
sequenceDiagram
    participant APP as Aplikasi
    participant PG_PUB as Publisher (PostgreSQL)
    participant WAL as WAL (wal_level=logical)
    participant DECODE as Logical Decoding\n(pgoutput plugin)
    participant SLOT as Replication Slot
    participant PG_SUB as Subscriber (PostgreSQL)

    APP->>PG_PUB: INSERT / UPDATE / DELETE
    PG_PUB->>WAL: Tulis WAL record
    DECODE->>WAL: Decode ke format logis
    DECODE->>SLOT: Simpan perubahan logis
    PG_SUB->>SLOT: Pull changes
    PG_SUB->>PG_SUB: Apply (INSERT/UPDATE/DELETE)
    PG_SUB-->>SLOT: Konfirmasi LSN
```

### 2.3 Konfigurasi WAL Level

| `wal_level` | Deskripsi | Mendukung |
|-------------|-----------|-----------|
| `minimal` | Hanya recovery dasar | Tidak bisa replikasi |
| `replica` | Default sejak PG 9.6 | Physical replication |
| `logical` | Level tertinggi | Physical + Logical replication |

```ini
# postgresql.conf
wal_level = logical          # untuk logical; 'replica' cukup untuk physical
max_wal_senders = 10         # jumlah max koneksi WAL sender
max_replication_slots = 10   # jumlah max replication slot
wal_keep_size = 512          # MB WAL yang disimpan untuk replica lambat
```

---

## 3. Prasyarat

- **Docker Engine** dan **Docker Compose** aktif.
- Port host tidak bentrok:
  - `5432` untuk primary/publisher
  - `5433` untuk replica/subscriber
- Folder kerja: `replikasi-db-postgres-basic/`
- Jika menggunakan script shell, beri permission eksekusi:

```bash
chmod +x init-primary.sh
```

### 3.1 Diagram Topologi Docker

```mermaid
flowchart LR
    subgraph HOST["Host Machine"]
        subgraph DC["Docker Network: pg-net"]
            PRI["pg_primary\nPostgreSQL 15\n:5432"]
            REP["pg_replica\nPostgreSQL 15\n:5433"]
            PRI -->|"WAL stream\n(internal)"| REP
        end
        V1[/"Volume:\npg_primary_data"/]
        V2[/"Volume:\npg_replica_data"/]
        PRI --- V1
        REP --- V2
    end

    CLIENT["psql / App\n(host)"] -->|":5432"| PRI
    CLIENT -->|":5433 (read-only)"| REP

    style DC fill:#1a1a2e,color:#fff
    style HOST fill:#0f3460,color:#fff
```

---

## 4. Setup Physical (Streaming) Replication

Physical replication menyalin **seluruh cluster** PostgreSQL secara binary. Replica bersifat read-only (hot standby).

### 4.1 Alur Setup Physical Replication

```mermaid
flowchart TD
    S1["1. Buat docker-compose-physical.yml"]
    S2["2. Buat init-primary.sh\n(buat replication_user + pg_hba.conf)"]
    S3["3. docker compose up -d\n(primary start & init)"]
    S4["4. Replica tunggu primary siap\n(pg_isready loop)"]
    S5["5. pg_basebackup dari primary\n(clone data directory)"]
    S6["6. Replica mulai streaming WAL\n(standby.signal + primary_conninfo)"]
    S7["7. Verifikasi:\npg_stat_replication di primary"]

    S1 --> S2 --> S3 --> S4 --> S5 --> S6 --> S7
```

### 4.2 File `docker-compose-physical.yml`

```yaml
version: '3.8'

networks:
  pg-net:
    driver: bridge

volumes:
  pg_primary_data:
  pg_replica_data:

services:
  pg_primary:
    image: postgres:15-alpine
    container_name: pg_primary
    networks: [pg-net]
    environment:
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
      POSTGRES_DB: mydb
    ports:
      - "5432:5432"
    volumes:
      - pg_primary_data:/var/lib/postgresql/data
      - ./init-primary.sh:/docker-entrypoint-initdb.d/init-primary.sh
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U myuser -d mydb"]
      interval: 5s
      timeout: 5s
      retries: 10

  pg_replica:
    image: postgres:15-alpine
    container_name: pg_replica
    networks: [pg-net]
    environment:
      PGPASSWORD: mypassword
    ports:
      - "5433:5432"
    depends_on:
      pg_primary:
        condition: service_healthy
    entrypoint: >
      bash -c "
      until pg_isready -h pg_primary -p 5432 -U myuser; do
        echo 'Waiting for primary...'; sleep 2;
      done;
      if [ ! -s /var/lib/postgresql/data/PG_VERSION ]; then
        echo 'Running pg_basebackup...'
        pg_basebackup -h pg_primary -D /var/lib/postgresql/data \
          -U replication_user -v -P -X stream -Fp -R
        echo 'pg_basebackup done.'
      fi;
      exec docker-entrypoint.sh postgres
      "
    volumes:
      - pg_replica_data:/var/lib/postgresql/data
```

### 4.3 Script Inisialisasi Primary (`init-primary.sh`)

```bash
#!/bin/bash
set -e

# Buat user replikasi
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  CREATE ROLE replication_user WITH REPLICATION LOGIN PASSWORD 'mypassword';
EOSQL

# Izinkan koneksi replikasi dari mana saja (batasi ke subnet di produksi)
echo "host replication replication_user all md5" >> "$PGDATA/pg_hba.conf"

# Reload konfigurasi
pg_ctl reload -D "$PGDATA"
```

### 4.4 Jalankan Stack

```bash
docker compose -f docker-compose-physical.yml up -d

# Pantau log replica saat pertama kali bootstrap
docker logs -f pg_replica
```

### 4.5 Verifikasi Physical Replication

**Di primary** — cek koneksi replica yang sedang streaming:

```sql
SELECT
  client_addr,
  usename,
  state,
  sent_lsn,
  write_lsn,
  flush_lsn,
  replay_lsn,
  sync_state
FROM pg_stat_replication;
```

**Di replica** — konfirmasi mode read-only:

```sql
-- Harus mengembalikan 'on'
SHOW transaction_read_only;

-- Cek lag replikasi saat ini
SELECT now() - pg_last_xact_replay_timestamp() AS replay_lag;

-- Cek apakah sedang dalam standby mode
SELECT pg_is_in_recovery();
```

**Ekspektasi output:**

| Query | Nilai Normal |
|-------|-------------|
| `pg_stat_replication.state` | `streaming` |
| `transaction_read_only` | `on` |
| `pg_is_in_recovery()` | `t` (true) |
| `replay_lag` | < beberapa detik |

---

## 5. Setup Logical Replication

Logical replication menggunakan mekanisme **Publication-Subscription**. Publisher mendeklarasikan apa yang direplikasi; subscriber menarik perubahannya.

### 5.1 Alur Setup Logical Replication

```mermaid
flowchart TD
    subgraph PUBLISHER["Publisher Side"]
        P1["SET wal_level=logical"]
        P2["Buat tabel di publisher"]
        P3["CREATE PUBLICATION pub_x\nFOR TABLE tabel_a, tabel_b"]
    end

    subgraph SUBSCRIBER["Subscriber Side"]
        S1["Buat tabel yang sama\n(skema manual)"]
        S2["CREATE SUBSCRIPTION sub_x\nCONNECTION '...' PUBLICATION pub_x"]
        S3["Initial data sync\n(snapshot)"]
        S4["Streaming perubahan\n(ongoing)"]
    end

    P1 --> P2 --> P3
    P3 -->|"Subscriber pull"| S2
    S1 --> S2 --> S3 --> S4

    style PUBLISHER fill:#1e3a5f,color:#fff
    style SUBSCRIBER fill:#1a3a00,color:#fff
```

### 5.2 File `docker-compose-logical.yml`

```yaml
version: '3.8'

networks:
  pg-net:
    driver: bridge

services:
  pg_publisher:
    image: postgres:15-alpine
    container_name: pg_publisher
    networks: [pg-net]
    environment:
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
      POSTGRES_DB: mydb
    ports:
      - "5432:5432"
    # wal_level=logical WAJIB untuk logical replication
    command: >
      postgres
        -c wal_level=logical
        -c max_replication_slots=10
        -c max_wal_senders=10
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U myuser -d mydb"]
      interval: 5s
      timeout: 5s
      retries: 10

  pg_subscriber:
    image: postgres:15-alpine
    container_name: pg_subscriber
    networks: [pg-net]
    environment:
      POSTGRES_USER: myuser
      POSTGRES_PASSWORD: mypassword
      POSTGRES_DB: mydb
    ports:
      - "5433:5432"
    depends_on:
      pg_publisher:
        condition: service_healthy
```

Jalankan:

```bash
docker compose -f docker-compose-logical.yml up -d
```

### 5.3 Buat Tabel di Kedua Sisi (Wajib)

> [!IMPORTANT]
> Logical replication **tidak menyalin skema secara otomatis**. Tabel harus dibuat secara manual di kedua sisi dengan struktur yang kompatibel.

```sql
-- Jalankan di PUBLISHER dan SUBSCRIBER
CREATE TABLE produk (
  id          SERIAL PRIMARY KEY,
  nama_produk VARCHAR(100) NOT NULL,
  harga       NUMERIC(12,2),
  stok        INTEGER DEFAULT 0,
  created_at  TIMESTAMPTZ DEFAULT NOW()
);
```

### 5.4 (Opsional) Tambah Index Khusus di Subscriber

Salah satu keunggulan logical replication: subscriber bisa punya index yang berbeda dari publisher.

```sql
-- Di SUBSCRIBER saja — tidak mengganggu publisher
CREATE INDEX idx_harga_produk  ON produk(harga);
CREATE INDEX idx_stok_produk   ON produk(stok);
CREATE INDEX idx_created_produk ON produk(created_at DESC);
```

### 5.5 Aktifkan Publication (Publisher)

```sql
-- Publikasikan tabel tertentu
CREATE PUBLICATION pub_produk FOR TABLE produk;

-- Atau publikasikan semua tabel (termasuk tabel yang dibuat nanti)
CREATE PUBLICATION pub_semua FOR ALL TABLES;

-- Cek publication yang ada
SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete
FROM pg_publication;
```

### 5.6 Aktifkan Subscription (Subscriber)

```sql
CREATE SUBSCRIPTION sub_produk
  CONNECTION 'host=pg_publisher port=5432 user=myuser password=mypassword dbname=mydb'
  PUBLICATION pub_produk;
```

### 5.7 Verifikasi Logical Replication

**Di publisher** — cek publication dan replication slot:

```sql
-- Daftar tabel dalam publication
SELECT pubname, schemaname, tablename
FROM pg_publication_tables;

-- Cek replication slot yang dibuat subscriber
SELECT slot_name, active, restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;
```

**Di subscriber** — cek status subscription:

```sql
SELECT
  subname,
  pid,
  received_lsn,
  latest_end_lsn,
  latest_end_time
FROM pg_stat_subscription;
```

**Uji fungsional:**

```sql
-- Di PUBLISHER
INSERT INTO produk (nama_produk, harga, stok) VALUES
  ('Laptop Pro 15', 15000000, 5),
  ('Mouse Wireless', 250000, 50),
  ('Keyboard Mechanical', 800000, 20);

-- Di SUBSCRIBER — data harus muncul
SELECT * FROM produk;

-- Update di publisher
UPDATE produk SET stok = stok - 1 WHERE nama_produk = 'Laptop Pro 15';

-- Delete di publisher
DELETE FROM produk WHERE nama_produk = 'Mouse Wireless';

-- Validasi di subscriber
SELECT * FROM produk ORDER BY id;
```

---

## 6. Replikasi Tingkat Kolom (Column Filter)

Tujuan: mencegah kolom sensitif (password, data PII) ikut direplikasi ke subscriber.

### 6.1 Diagram Alur Column Filter

```mermaid
flowchart LR
    subgraph PUB["Publisher"]
        TBL_PUB["Tabel users\n- id (PK)\n- username\n- email\n- password_hash  ← SENSITIF\n- last_login"]
        PUBDEF["CREATE PUBLICATION\npub_users_aman\nFOR TABLE users\n(id, username, email, last_login)"]
    end

    subgraph WAL["WAL Stream"]
        FILTERED["Hanya kolom:\nid, username,\nemail, last_login"]
    end

    subgraph SUB["Subscriber"]
        TBL_SUB["Tabel users\n- id (PK)\n- username\n- email\n(tanpa password_hash)"]
    end

    PUB --> PUBDEF
    PUBDEF -->|"Kolom password_hash\ndikecualikan"| FILTERED
    FILTERED --> TBL_SUB

    style PUB fill:#1e3a5f,color:#fff
    style WAL fill:#2d1b00,color:#fff
    style SUB fill:#1a3a00,color:#fff
```

### 6.2 Definisi Tabel di Publisher

```sql
-- Di PUBLISHER
CREATE TABLE users (
  id            SERIAL PRIMARY KEY,
  username      VARCHAR(50)  NOT NULL UNIQUE,
  email         VARCHAR(100) NOT NULL,
  password_hash VARCHAR(255) NOT NULL,   -- Kolom sensitif, tidak direplikasi
  last_login    TIMESTAMPTZ,
  created_at    TIMESTAMPTZ DEFAULT NOW()
);
```

### 6.3 Definisi Tabel di Subscriber (Tanpa Kolom Sensitif)

```sql
-- Di SUBSCRIBER — tidak perlu kolom password_hash
CREATE TABLE users (
  id         SERIAL PRIMARY KEY,
  username   VARCHAR(50)  NOT NULL UNIQUE,
  email      VARCHAR(100) NOT NULL,
  last_login TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### 6.4 Publication dengan Daftar Kolom Aman

```sql
-- Tentukan hanya kolom yang aman untuk direplikasi
CREATE PUBLICATION pub_users_aman
  FOR TABLE users (id, username, email, last_login, created_at);
```

### 6.5 Subscription di Subscriber

```sql
CREATE SUBSCRIPTION sub_users_aman
  CONNECTION 'host=pg_publisher port=5432 user=myuser password=mypassword dbname=mydb'
  PUBLICATION pub_users_aman;
```

> [!WARNING]
> - **Kolom Primary Key wajib disertakan** dalam daftar kolom publikasi.
> - Jika PK tidak ada, operasi `UPDATE` dan `DELETE` tidak dapat direplikasi dengan benar karena tidak ada cara mengidentifikasi baris yang berubah.

### 6.6 Verifikasi Column Filter

```sql
-- Di publisher: cek kolom yang direplikasi per tabel
SELECT
  pub.pubname,
  ptrel.schemaname,
  ptrel.tablename,
  ptrel.attnames AS replicated_columns
FROM pg_publication pub
JOIN pg_publication_tables ptrel ON pub.pubname = ptrel.pubname
WHERE pub.pubname = 'pub_users_aman';
```

---

## 7. Manajemen Lanjutan Logical Replication

### 7.1 Menambahkan Tabel Baru ke Publication yang Sudah Ada

```mermaid
flowchart TD
    NEED["Perlu replikasi\ntabel baru: kategori"]

    NEED --> A["Di SUBSCRIBER:\nCREATE TABLE kategori (...)"]
    A --> B["Di PUBLISHER:\nCREATE TABLE kategori (...)"]
    B --> C["Di PUBLISHER:\nALTER PUBLICATION pub_produk\nADD TABLE kategori"]
    C --> D["Di SUBSCRIBER:\nALTER SUBSCRIPTION sub_produk\nREFRESH PUBLICATION"]
    D --> E["Subscriber melakukan\ninitial sync tabel baru"]
    E --> F["✅ Streaming berjalan\nuntuk tabel kategori"]
```

```sql
-- Step 1: Buat tabel di SUBSCRIBER terlebih dahulu
CREATE TABLE kategori (
  id       SERIAL PRIMARY KEY,
  nama     VARCHAR(100) NOT NULL,
  deskripsi TEXT
);

-- Step 2: Buat tabel yang sama di PUBLISHER
CREATE TABLE kategori (
  id       SERIAL PRIMARY KEY,
  nama     VARCHAR(100) NOT NULL,
  deskripsi TEXT
);

-- Step 3: Tambahkan ke publication yang sudah ada (di PUBLISHER)
ALTER PUBLICATION pub_produk ADD TABLE kategori;

-- Step 4: Refresh subscription agar subscriber tahu ada tabel baru (di SUBSCRIBER)
ALTER SUBSCRIPTION sub_produk REFRESH PUBLICATION;
```

### 7.2 Menghapus Tabel dari Publication

```sql
-- Di PUBLISHER
ALTER PUBLICATION pub_produk DROP TABLE kategori;

-- Subscriber otomatis berhenti menerima perubahan tabel tersebut
-- Data yang sudah ada di subscriber tetap ada
```

### 7.3 Kapan ALTER vs Buat Publication Baru

| Situasi | Rekomendasi |
|---------|-------------|
| Tabel baru, domain bisnis sama | `ALTER PUBLICATION ... ADD TABLE` |
| Domain data berbeda (contoh: keuangan vs HR) | Buat publication baru |
| Target subscriber berbeda | Buat publication baru per subscriber |
| Ingin isolasi kegagalan antar-aliran | Buat publication baru |

### 7.4 Manajemen Replication Slot

> [!WARNING]
> Replication slot yang tidak aktif (konektor mati) akan menyebabkan WAL menumpuk di disk karena PostgreSQL tidak akan menghapus WAL hingga semua slot mengkonfirmasi pembacaannya.

```sql
-- Cek semua replication slot
SELECT
  slot_name,
  plugin,
  slot_type,
  active,
  restart_lsn,
  confirmed_flush_lsn,
  pg_size_pretty(
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  ) AS wal_retained
FROM pg_replication_slots;

-- Hapus slot yang tidak aktif (hati-hati!)
SELECT pg_drop_replication_slot('nama_slot');
```

### 7.5 Pause & Resume Subscription

```sql
-- Pause subscription sementara (maintenance)
ALTER SUBSCRIPTION sub_produk DISABLE;

-- Cek status
SELECT subname, subenabled FROM pg_subscription;

-- Resume subscription
ALTER SUBSCRIPTION sub_produk ENABLE;

-- Hapus subscription sepenuhnya
DROP SUBSCRIPTION sub_produk;
```

---

## 8. Replikasi Sinkron (Synchronous Replication)

Secara default, PostgreSQL menggunakan **asynchronous replication** — primary commit langsung tanpa menunggu replica. **Synchronous replication** memastikan setiap commit dikonfirmasi oleh minimal satu replica sebelum dikembalikan ke aplikasi.

### 8.1 Diagram Async vs Sync

```mermaid
flowchart LR
    subgraph ASYNC["Asynchronous (Default)"]
        direction LR
        A1["App"] -->|"Commit"| P1["Primary"]
        P1 -->|"✅ Langsung\nkembali ke app"| A1
        P1 -.->|"Kirim WAL\n(background)"| R1["Replica"]
    end

    subgraph SYNC["Synchronous"]
        direction LR
        A2["App"] -->|"Commit"| P2["Primary"]
        P2 -->|"Tunggu ACK\nreplica"| R2["Replica"]
        R2 -->|"ACK"| P2
        P2 -->|"✅ Kembali ke app\n(setelah ACK)"| A2
    end

    style ASYNC fill:#1e3a5f,color:#fff
    style SYNC fill:#2d1b00,color:#fff
```

### 8.2 Konfigurasi Synchronous Replication

```ini
# Di postgresql.conf (Primary)
synchronous_commit = on                      # default: on
synchronous_standby_names = 'pg_replica'     # nama aplikasi replica
# Atau menggunakan quorum commit (minimal 1 dari N replica):
synchronous_standby_names = 'ANY 1 (pg_replica1, pg_replica2)'
```

```ini
# Di recovery.conf atau postgresql.auto.conf (Replica)
primary_conninfo = 'host=pg_primary port=5432 user=replication_user password=mypassword application_name=pg_replica'
```

### 8.3 Trade-off Sync vs Async

| Aspek | Async | Sync |
|-------|-------|------|
| Latensi Write | Rendah | Lebih tinggi (menunggu ACK) |
| Risk Data Loss | Ada (minimal) jika primary crash | Tidak ada (zero data loss) |
| Availability | Lebih tinggi | Lebih rendah (jika replica down, primary menunggu) |
| Use Case | Reporting replicas, non-critical | Finansial, data kritikal |

---

## 9. Monitoring & Observabilitas

### 9.1 Diagram Monitoring Pipeline

```mermaid
flowchart LR
    subgraph PG["PostgreSQL Views"]
        V1["pg_stat_replication"]
        V2["pg_replication_slots"]
        V3["pg_stat_subscription"]
        V4["pg_publication_tables"]
    end

    subgraph QUERY["DBA Queries"]
        Q1["Lag check"]
        Q2["Slot size check"]
        Q3["Subscription status"]
    end

    subgraph ALERT["Alert Conditions"]
        A1["replay_lag > 30s"]
        A2["WAL retained > 1GB"]
        A3["Subscription inactive"]
    end

    PG --> QUERY --> ALERT
```

### 9.2 Monitoring Physical Replication

```sql
-- ============================================================
-- 1. Status replica aktif (di PRIMARY)
-- ============================================================
SELECT
  client_addr,
  usename,
  application_name,
  state,
  sent_lsn,
  write_lsn,
  flush_lsn,
  replay_lsn,
  sync_state,
  -- Hitung lag dalam bytes
  pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;

-- ============================================================
-- 2. Replay lag di REPLICA (waktu)
-- ============================================================
SELECT
  now() - pg_last_xact_replay_timestamp() AS replay_lag_seconds,
  pg_last_xact_replay_timestamp()          AS last_replayed_at,
  pg_is_in_recovery()                      AS is_standby,
  pg_last_wal_receive_lsn()               AS received_lsn,
  pg_last_wal_replay_lsn()               AS replayed_lsn;

-- ============================================================
-- 3. Ukuran WAL yang tertahan oleh replication slot
-- ============================================================
SELECT
  slot_name,
  active,
  pg_size_pretty(
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  ) AS wal_retained_size
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;
```

### 9.3 Monitoring Logical Replication

```sql
-- ============================================================
-- 1. Status subscription (di SUBSCRIBER)
-- ============================================================
SELECT
  subname,
  pid,
  received_lsn,
  latest_end_lsn,
  latest_end_time,
  (EXTRACT(EPOCH FROM (now() - latest_end_time)))::INT AS lag_seconds
FROM pg_stat_subscription;

-- ============================================================
-- 2. Daftar tabel dalam semua publication (di PUBLISHER)
-- ============================================================
SELECT
  pub.pubname,
  pub.pubinsert,
  pub.pubupdate,
  pub.pubdelete,
  pt.schemaname,
  pt.tablename
FROM pg_publication pub
JOIN pg_publication_tables pt ON pub.pubname = pt.pubname
ORDER BY pub.pubname, pt.tablename;

-- ============================================================
-- 3. Cek subscription yang tidak aktif (lag > 60 detik)
-- ============================================================
SELECT
  subname,
  latest_end_time,
  EXTRACT(EPOCH FROM (now() - latest_end_time)) AS lag_seconds
FROM pg_stat_subscription
WHERE EXTRACT(EPOCH FROM (now() - latest_end_time)) > 60
   OR latest_end_time IS NULL;
```

### 9.4 Checklist Monitoring Harian

| Item | Query / Perintah | Threshold |
|------|-----------------|-----------|
| Replica lag (waktu) | `now() - pg_last_xact_replay_timestamp()` | < 30 detik |
| WAL slot size | `pg_replication_slots` | < 1 GB |
| Subscription aktif | `pg_stat_subscription` | status `streaming` |
| Disk WAL usage | `pg_ls_waldir()` atau `df -h` | < 80% disk |
| Replication slot aktif | `pg_replication_slots WHERE active = false` | 0 slot inactive |

---

## 10. Failover & Switchover (Physical)

### 10.1 Diagram Alur Failover

```mermaid
flowchart TD
    START["Primary Down / Unreachable"]

    START --> DETECT["Deteksi kegagalan:\n- pg_isready gagal\n- Timeout koneksi"]
    DETECT --> DECIDE{"Manual atau\nAuto failover?"}

    DECIDE -->|"Manual"| PROMOTE["Di Replica:\npg_ctl promote\nATAU\nSELECT pg_promote()"]
    DECIDE -->|"Auto (Patroni/repmgr)"| AUTO["Patroni/repmgr\notomatis promote"]

    PROMOTE --> NEW_PRI["Replica menjadi\nPrimary baru"]
    AUTO --> NEW_PRI

    NEW_PRI --> UPDATE_APP["Update connection string\ndi aplikasi ke primary baru"]
    UPDATE_APP --> REBIND["Rebind replica lain\nke primary baru\n(jika ada)"]
    REBIND --> DONE["✅ Cluster kembali normal"]
```

### 10.2 Langkah Failover Manual

```bash
# ── Di REPLICA (yang akan dipromote) ──────────────────────────
# Cek apakah replica siap (sudah catch up dengan primary)
psql -h localhost -p 5433 -U myuser -c "SELECT pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"

# Promote replica menjadi primary baru
# Cara 1: via pg_ctl
docker exec pg_replica pg_ctl promote -D /var/lib/postgresql/data

# Cara 2: via SQL (PostgreSQL 12+)
psql -h localhost -p 5433 -U myuser -c "SELECT pg_promote();"

# Verifikasi sudah tidak lagi dalam recovery mode
psql -h localhost -p 5433 -U myuser -c "SELECT pg_is_in_recovery();"
# Harus: f (false)
```

### 10.3 Langkah Switchover (Terencana)

Switchover adalah failover terencana — primary sengaja diturunkan untuk maintenance.

```mermaid
sequenceDiagram
    participant DBA as DBA
    participant PRI as Primary
    participant REP as Replica

    DBA->>PRI: Tandai primary sebagai read-only
    DBA->>PRI: Tunggu replica catch up
    PRI-->>DBA: LSN primary == LSN replica
    DBA->>REP: pg_promote() → jadi primary baru
    DBA->>PRI: Konfigurasi ulang primary lama\nsebagai replica baru
    DBA->>PRI: pg_basebackup atau pg_rewind
    REP-->>PRI: Kirim WAL ke primary lama (sekarang jadi replica)
    DBA-->>DBA: Update app connection string
```

```bash
# Step 1: Checkpoint di primary agar WAL bersih
psql -h localhost -p 5432 -U myuser -c "CHECKPOINT;"

# Step 2: Pastikan replica sudah fully caught up
psql -h localhost -p 5432 -U myuser -c "
  SELECT sent_lsn = replay_lsn AS is_synced
  FROM pg_stat_replication;"

# Step 3: Promote replica
psql -h localhost -p 5433 -U myuser -c "SELECT pg_promote();"

# Step 4: Rebuild primary lama sebagai replica (menggunakan pg_rewind)
# pg_rewind lebih cepat dari pg_basebackup untuk server yang baru saja turun
docker exec pg_primary pg_rewind \
  --target-pgdata /var/lib/postgresql/data \
  --source-server "host=pg_replica port=5432 user=replication_user password=mypassword"
```

---

## 11. Hardening & Keamanan

### 11.1 Diagram Keamanan Replikasi

```mermaid
flowchart LR
    subgraph SECURITY["Lapisan Keamanan"]
        L1["1. Network\n(pg_hba.conf)"]
        L2["2. Autentikasi\n(md5 / scram-sha-256)"]
        L3["3. Role & Privilege\n(REPLICATION role)"]
        L4["4. SSL/TLS\n(enkripsi transit)"]
        L5["5. Secret Management\n(.env / Vault)"]
    end

    L1 --> L2 --> L3 --> L4 --> L5
```

### 11.2 Rekomendasi Konfigurasi Aman

```ini
# ── pg_hba.conf ────────────────────────────────────────────
# Izinkan replikasi hanya dari subnet tertentu
host  replication  replication_user  192.168.1.0/24  scram-sha-256

# Jangan pakai 'all' atau '0.0.0.0/0' di produksi
```

```sql
-- Buat user replikasi dengan hak minimal
CREATE ROLE replication_user WITH
  REPLICATION
  LOGIN
  PASSWORD 'GuntiPassword!Y@ngKu@t';

-- Untuk logical replication: user subscriber harus bisa login dan SELECT
CREATE ROLE subscriber_user WITH LOGIN PASSWORD 'P@ssSubscriber!';
GRANT SELECT ON ALL TABLES IN SCHEMA public TO subscriber_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO subscriber_user;
```

```yaml
# ── .env file (jangan commit ke git!) ──────────────────────
POSTGRES_USER=myuser
POSTGRES_PASSWORD=P@ssw0rdK0mpl3ks!
REPLICATION_PASSWORD=R3pl!cati0nS3cur3
```

```bash
# ── .gitignore ──────────────────────────────────────────────
echo ".env" >> .gitignore
echo "*.key" >> .gitignore
```

### 11.3 Aktifkan SSL untuk Koneksi Replikasi

```ini
# postgresql.conf
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file  = 'server.key'
ssl_ca_file   = 'ca.crt'
```

```ini
# pg_hba.conf — wajibkan SSL
hostssl  replication  replication_user  192.168.1.0/24  scram-sha-256
```

---

## 12. Troubleshooting

### 12.1 Decision Tree Troubleshooting

```mermaid
flowchart TD
    PROBLEM["Masalah Replikasi?"]

    PROBLEM --> T1{"Tipe replikasi?"}
    T1 -->|"Physical"| P1{"Gejala?"}
    T1 -->|"Logical"| L1{"Gejala?"}

    P1 -->|"Replica tidak connect"| P_CON["Cek:\n- pg_hba.conf\n- replication_user ada?\n- port terbuka?"]
    P1 -->|"pg_basebackup gagal"| P_BB["Cek:\n- REPLICATION privilege\n- Disk space di replica\n- max_wal_senders cukup?"]
    P1 -->|"Lag tinggi"| P_LAG["Cek:\n- Network bandwidth\n- wal_keep_size\n- Beban primary terlalu tinggi"]
    P1 -->|"replica read-write"| P_RW["Pastikan:\n- standby.signal ada\n- primary_conninfo benar"]

    L1 -->|"Subscription tidak aktif"| L_SUB["Cek:\n- wal_level=logical\n- Koneksi host/port/user\n- pg_stat_subscription"]
    L1 -->|"Data tidak sampai"| L_DATA["Cek:\n- Table ada di publication?\n- PK ada di tabel?\n- Refresh subscription?"]
    L1 -->|"WAL disk penuh"| L_WAL["Cek:\n- pg_replication_slots\n- Drop slot inactive\n- wal_keep_size setting"]
    L1 -->|"Conflict / Error row"| L_CONF["Cek:\n- pg_stat_subscription_stats\n- log subscriber\n- Tipe data mismatch"]
```

### 12.2 Masalah: Subscription Tidak Jalan

**Kemungkinan penyebab & solusi:**

```bash
# 1. Cek wal_level di publisher
psql -h localhost -p 5432 -U myuser -c "SHOW wal_level;"
# Harus: logical

# 2. Cek log publisher untuk pesan error
docker logs pg_publisher 2>&1 | grep -E "ERROR|FATAL|WARNING" | tail -30

# 3. Cek log subscriber
docker logs pg_subscriber 2>&1 | grep -E "ERROR|FATAL|WARNING" | tail -30

# 4. Cek koneksi dari subscriber ke publisher
docker exec pg_subscriber psql \
  "host=pg_publisher port=5432 user=myuser password=mypassword dbname=mydb" \
  -c "SELECT 1;"
```

```sql
-- 5. Cek privilege user
SELECT rolreplication, rolsuper, rolcanlogin
FROM pg_roles
WHERE rolname = 'myuser';

-- 6. Cek subscription status detail
SELECT subname, subenabled, subconninfo, subpublications
FROM pg_subscription;
```

### 12.3 Masalah: Replica Physical Gagal Clone Awal

```bash
# Hapus data directory replica yang korup lalu bootstrap ulang
docker compose -f docker-compose-physical.yml down
docker volume rm replikasi-db-postgres-basic_pg_replica_data
docker compose -f docker-compose-physical.yml up -d

# Pantau proses pg_basebackup
docker logs -f pg_replica
```

```sql
-- Pastikan max_wal_senders cukup di primary
SHOW max_wal_senders;
-- Naikan jika perlu di postgresql.conf:
-- max_wal_senders = 10
```

### 12.4 Masalah: WAL Menumpuk / Disk Penuh

```sql
-- Cek slot mana yang menyebabkan WAL tertahan
SELECT
  slot_name,
  active,
  pg_size_pretty(
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
  ) AS wal_lag
FROM pg_replication_slots
ORDER BY pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) DESC;

-- Jika slot tidak aktif dan tidak dibutuhkan lagi, hapus:
SELECT pg_drop_replication_slot('nama_slot_tidak_aktif');
```

### 12.5 Tabel Masalah-Solusi Ringkas

| Gejala | Kemungkinan Penyebab | Solusi |
|--------|---------------------|--------|
| `could not connect to the primary server` | pg_hba.conf tidak mengizinkan | Tambah rule replication di pg_hba.conf |
| `replication slot already exists` | Slot dari percobaan sebelumnya | `pg_drop_replication_slot('nama')` |
| `FATAL: max_wal_senders connections` | Terlalu banyak koneksi | Naikkan `max_wal_senders` |
| Subscription status `disabled` | Subscription di-disable | `ALTER SUBSCRIPTION sub ENABLE` |
| Data tidak terreplikasi | Tabel tidak ada di publication | `ALTER PUBLICATION pub ADD TABLE tbl` + `ALTER SUBSCRIPTION sub REFRESH PUBLICATION` |
| `ERROR: cannot update table without replica identity` | Tidak ada PK/REPLICA IDENTITY | Tambahkan PRIMARY KEY atau `ALTER TABLE SET REPLICA IDENTITY FULL` |
| WAL directory membesar | Replication slot inactive | Drop slot atau restart subscriber |

---

## 13. Ringkasan Keputusan Arsitektur

### 13.1 Matriks Pemilihan Metode

```mermaid
quadrantChart
    title Pemilihan Metode Replikasi PostgreSQL
    x-axis "Kebutuhan Filtering Data" --> "Filtering Penuh"
    y-axis "Kebutuhan Konsistensi" --> "Zero Data Loss"
    quadrant-1 Logical Sync
    quadrant-2 Physical Sync
    quadrant-3 Physical Async
    quadrant-4 Logical Async
    "HA/DR Standar": [0.2, 0.4]
    "Finansial/Kritikal": [0.2, 0.85]
    "Reporting DB": [0.75, 0.3]
    "Upgrade Major Version": [0.8, 0.5]
    "Data Masking/PII": [0.9, 0.4]
    "Multi-Tenant Isolation": [0.85, 0.6]
```

### 13.2 Ringkasan Keputusan

| Kebutuhan | Pilihan | Alasan |
|-----------|---------|--------|
| Failover cepat (HA/DR) | Physical Async | Low overhead, siap promote |
| Zero data loss (kritikal) | Physical Sync | ACK sebelum commit |
| Tabel tertentu saja | Logical | Granularity tinggi |
| Kolom sensitif dikecualikan | Logical + Column Filter | Filter di level publikasi |
| Upgrade major PostgreSQL | Logical | Bisa lintas versi |
| Replica untuk reporting | Physical atau Logical | Tergantung kebutuhan filter |
| Replica bisa write lokal | Logical | Physical = pure read-only |

### 13.3 Skenario Uji Minimal Setelah Setup

```mermaid
flowchart LR
    T1["INSERT baris baru"] --> T2["Verifikasi di replica/subscriber"]
    T2 --> T3["UPDATE baris tersebut"]
    T3 --> T4["Verifikasi perubahan"]
    T4 --> T5["DELETE baris tersebut"]
    T5 --> T6["Verifikasi baris hilang"]
    T6 --> T7["Cek lag: < 5 detik"]
    T7 --> T8["✅ Setup valid"]
```

```sql
-- Uji INSERT
INSERT INTO produk (nama_produk, harga) VALUES ('Test Item', 99000);

-- Di replica/subscriber: verifikasi
SELECT * FROM produk WHERE nama_produk = 'Test Item';

-- Uji UPDATE
UPDATE produk SET harga = 109000 WHERE nama_produk = 'Test Item';

-- Di replica/subscriber: verifikasi perubahan
SELECT harga FROM produk WHERE nama_produk = 'Test Item';
-- Ekspektasi: 109000

-- Uji DELETE
DELETE FROM produk WHERE nama_produk = 'Test Item';

-- Di replica/subscriber: verifikasi baris hilang
SELECT COUNT(*) FROM produk WHERE nama_produk = 'Test Item';
-- Ekspektasi: 0
```

---

> [!TIP]
> **Rekomendasi untuk Production:**
> - Gunakan **password kuat** dan jangan pakai default contoh.
> - Batasi akses `pg_hba.conf` ke subnet spesifik.
> - Monitor `pg_replication_slots` secara berkala — slot inactive = disk WAL membengkak.
> - Gunakan **Patroni** atau **repmgr** untuk manajemen failover otomatis di production.
> - Simpan kredensial di `.env` atau secret manager (Vault, AWS Secrets Manager).

---

*Dokumen ini dapat dijadikan baseline lab lokal maupun fondasi desain replikasi untuk environment non-produksi. Selalu sesuaikan konfigurasi dengan kebutuhan spesifik produksi Anda.*
