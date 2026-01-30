# CTE Reference – VMware Disk Utilization Query

Dokumen ini menjelaskan setiap CTE secara terstruktur:
Tujuan, input, output, dan dependency.

---

## 1. time_param
**Purpose:** Menentukan window waktu analisis  
**Outputs:** start_ts, end_ts, is_rolling_30  
**Dependency:** parameter dashboard

---

## 2. threshold_param
**Purpose:** Mapping threshold string → numeric range  
**Outputs:** lower_bound, upper_bound  
**Used by:** Final SELECT filter

---

## 3. grup
**Purpose:** Menentukan scope group VM  
**Outputs:** groupid

---

## 4. list_server
**Purpose:** Daftar VM target  
**Outputs:** hostid, vm_name  
**Notes:** Exclusion berdasarkan naming convention

---

## 5. items_used
**Purpose:** Item disk used per VM + partition  
**Outputs:** itemid, hostid, partition_name

---

## 6. items_free
**Purpose:** Item disk free per VM + partition  
**Outputs:** itemid, hostid, partition_name

---

## 7. item_pair
**Purpose:** Pair used & free item per partition  
**Outputs:** used_itemid, free_itemid  
**Critical:** Jika pairing gagal → partition hilang

---

## 8. detail
**Purpose:** Hitung disk usage per clock  
**Outputs:** used_gib, free_gib, usage_pct  
**Notes:** Clock used & free harus sinkron

---

## 9. daily
**Purpose:** Rata-rata disk usage harian  
**Outputs:** daily usage_pct

---

## 10. monthly
**Purpose:** Rata-rata disk usage periode  
**Outputs:** avg_usage_pct  
**Key Metric:** Threshold filtering

---

## 11. need_itemids
**Purpose:** Kumpulan item untuk current state

---

## 12. last_clock
**Purpose:** Timestamp terbaru per item

---

## 13. las_val
**Purpose:** Latest value per item

---

## 14. current_disk
**Purpose:** Current disk usage (%)

---

## 15. ordered_daily
**Purpose:** Ranking harian untuk percentile

---

## 16. p95
**Purpose:** Hitung 95th percentile disk usage

---

## 17. power_state
**Purpose:** Status power VM terkini
