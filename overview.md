# Overview – VMware Disk Utilization Query

## Purpose

Query ini bertujuan untuk menyediakan **pandangan komprehensif terhadap kondisi disk VM**
dengan menggabungkan data historis, kondisi terkini, dan statistik ekstrem (P95).

Digunakan untuk:
- Monitoring operasional
- Capacity planning
- Identifikasi VM berisiko disk penuh
- Audit dan review performa storage

---

## Data Sources

| Source | Description |
|------|------------|
| hosts / hosts_groups | Metadata VM |
| items | Definisi item disk & power state |
| trends_uint | Data historis agregat |
| history_uint | Data real-time / terbaru |

---

## Time Modes

Query mendukung dua mode:
1. **Rolling 30 Days**
2. **Monthly (YYYY-MM)**

Pemilihan mode dikontrol oleh parameter `${time_range}`.

---

## High-Level Flow

1. Tentukan window waktu
2. Tentukan scope VM berdasarkan group
3. Identifikasi item disk used & free
4. Hitung disk usage historis
5. Agregasi harian dan bulanan
6. Hitung current disk usage
7. Hitung P95 disk usage
8. Tambahkan power state
9. Filter berdasarkan threshold

---

## Why Trends vs History?

| Use Case | Table |
|-------|------|
| Historical average | trends_uint |
| Percentile analysis | trends_uint |
| Current state | history_uint |

Pendekatan ini mengoptimalkan performa query dan akurasi operasional.
