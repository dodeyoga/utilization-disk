# Troubleshooting Guide

## No Rows Returned
- Periksa `${threshold}` mapping
- Cek apakah `monthly` menghasilkan data

---

## current_disk_pct NULL
- Tidak ada data history 6 jam terakhir
- Item used/free tidak lengkap

---

## percentile_95th_pct NULL
- Data daily kosong
- Periode terlalu sempit

---

## Partition Missing
- Pairing gagal di item_pair
- Nama partition used ≠ free

---

## PowerState = Unknown
- Tidak ada history power state 1 jam terakhir

---

## Debug Checklist

1. SELECT * FROM monthly LIMIT 10
2. SELECT * FROM item_pair WHERE hostid = ?
3. SELECT * FROM last_clock WHERE itemid = ?
4. Validasi item.key_ format
