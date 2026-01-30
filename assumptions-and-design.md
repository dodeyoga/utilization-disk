# Assumptions & Design Decisions

## Key Assumptions

1. Setiap partition memiliki item used & free
2. Clock `trends_uint` untuk used/free sinkron
3. Naming convention VMware konsisten
4. Data history tersedia dalam window waktu

---

## Design Decisions

### Why AVG instead of MAX?
- AVG lebih stabil untuk capacity trend
- MAX cenderung noise (spike sesaat)

### Why P95?
- Menggambarkan peak wajar
- Lebih representatif daripada MAX

### Why 6 Hours Window (Current Disk)?
- Kompromi antara freshness & availability

### Why LEFT JOIN on enrichment?
- Historical data tetap ditampilkan meski current missing

---

## Known Limitations

- Tidak menghitung interpolated percentile
- Tidak menangani clock drift otomatis
- Partition tanpa pairing akan hilang
