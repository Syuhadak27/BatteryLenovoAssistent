# Ringkasan: Battery Threshold → EC langsung (ACPI + YogaSMC)

Dokumen ini adalah hasil audit untuk permintaan: **"pakai folder ACPI untuk komunikasi
battery threshold supaya benar-benar menulis ke EC secara realtime"**.
Folder `ACPI/` dan `Kexts/` **tidak diubah** (semua analisis hanya dibaca/didekompilasi
ke folder sementara di luar keduanya, lalu dibersihkan).

---

## 1. Apa yang ada di folder ACPI (hasil dekompilasi AML → DSL)

| File | Isi yang relevan |
|---|---|
| `SSDT-EC.aml` | Method `RE1B(offset)` = baca 1 byte EC, `WE1B(offset, value)` = tulis 1 byte EC, plus `RECB`/`WECB` untuk blok. Ini **jalur EC paling langsung** yang tersedia. |
| `SSDT-THINK.aml` | Method `CSSI`, `CFSP`, `CFNI`, `CRST` di `HKEY`; field EC `EST0..ESTF` (0x78–0x7F, 0xC0–0xC7). **Bukan** threshold baterai. |
| `SSDT-BATX.aml` | Aggregator BAT0+BAT1 (`_BIX`, `_BST`, `_BSS`, `GBIX`, `CBST`, …). **Hanya pembacaan**, tidak ada setter threshold. |
| SSDT lain (DTGP, DYTC, HRTF, KBRD, PLUG, PMCR, PNLF, PTWK, VDEV, XDSM, XHCI) | Tidak ada method `BCCS`/`BCSS`/`BICS`. |

**Kesimpulan penting:** tidak ada SSDT lokal yang menyimpan offset RAM EC untuk
charge start/stop. Offset itu ada di firmware/DSDT OEM (atau di driver Windows),
bukan di folder `ACPI/` yang diberikan.

DSDT OEM (dari dump lokal X260, bukan folder proyek) menunjukkan:

```
BCCS(arg) -> PSIF(0x06, arg) -> SMI(0x14, 0x05, 0x06, arg, 0)
BCSS(arg) -> PSIF(0x08, arg) -> SMI(0x14, 0x05, 0x08, arg, 0)
BICS(arg) -> PSIF(0x04, arg) ...
SMI()     -> tulis 0xF5 ke port APM 0xB2, tunggu flag ERR di memory
```

Jadi jalur lama (YogaSMC `setCMstart`/`setCMstop`) **tidak menulis byte EC langsung**;
ia memicu SMI. Di Hackintosh, SMI bisa diterima firmware dengan baik, bisa juga
tidak (tergantung BIOS/OC/quirk). Kalau SMI tidak diproses, nilai "berhasil" dari
`evaluateInteger` tidak berarti EC berubah — inilah penjelasan paling mungkin
kenapa threshold terasa "tidak nulis ke EC".

---

## 2. Apa yang ada di folder KEXT (YogaSMC 1.5.3)

`YogaSMC-VENTURA.kext` dan `YogaSMC-SEQUOIA.kext` berisi binary yang sama (md5 identik).
`Info.plist` mendaftarkan `ThinkVPC` dengan `IOUserClientClass = YogaSMCUserClient`.

Dari disassembli `YogaSMCUserClient::getTargetAndMethodForIndex()` dan source
`YogaSMCUserClient.cpp` upstream, tabel external method-nya:

| Selector | Method | Tipe | Pemakaian |
|---|---|---|---|
| 0 | `userClientOpen` | ScalarIScalarO | wajib dipanggil setelah `IOServiceOpen` |
| 1 | `userClientClose` | ScalarIScalarO | – |
| 2 | `readEC(offset)` | ScalarIStructO | panggil `method_re1b()` → ACPI `RE1B` |
| 3 | `writeEC(offset, byte)` | ScalarIStructI | panggil `method_we1b()` → ACPI `WE1B` |
| 4 | `readECName(name)` | StructIStructO | evaluasi method ACPI 4 karakter tanpa argumen |

Batasan di kext: `writeEC` menerima **tepat 1 byte**, offset **≤ 0x99**, dan
menolak kalau provider belum di-open oleh client. Ini sudah dipatuhi implementasi baru.

---

## 3. Perubahan yang dilakukan (HANYA di `ThinkpadAssistant/AppDelegate.swift`)

1. **`YogaSMCECBridge`** (baru): buka `ThinkVPC` user client, panggil selector 0,
   lalu `readByte`/`writeByte` lewat selector 2/3. Ini memakai `RE1B`/`WE1B`
   dari `SSDT-EC.aml` — bukan SMC key, bukan menebak alamat port.
2. **Jalur tulis ganda** di `BatteryThresholdManager.apply()`:
   - Jalur utama tetap `Battery → setCMstart/setCMstop` (BCCS/BCSS lewat SMI).
   - Jalur opsional **Direct EC**: `WE1B` ke offset yang user isi, lalu `RE1B`
     untuk verifikasi. Byte ditulis hanya kalau berbeda (idempotent).
3. **Perbaikan urutan dictionary**: `Battery` sekarang dikirim dalam dictionary
   terpisah **sebelum** threshold. `NSDictionary` tidak berurutan; sebelumnya
   `setCMstart` bisa diproses sebelum indeks baterai di-set.
4. **Perbaikan encoding stop=100**: YogaSMCPane resmi mengirim `0` untuk 100%,
   bukan `100`. Kode lama mengirim `100` saat Enable dimatikan.
5. **Realtime**: timer 3 detik + observer charger menulis ulang threshold
   (semua akses IOKit/EC lewat serial queue). EC_byte dibaca dulu, jadi tidak
   ada tulisan berulang yang tidak perlu.
6. **Menu baru** di submenu Battery Threshold:
   - `Direct EC (ACPI WE1B)` — default **OFF**.
   - `Set EC Offsets…` — isi offset Start/Stop/Inhibit dalam hex (0x01–0x99).
   - Baris status `EC direct: ON · S 0x.. · P 0x.. · I 0x..`.
7. Log Console memakai prefix `[BatteryEC]`, `[BatterySync]`, `[BatteryThreshold]`.

Tidak ada file di `ACPI/` maupun `Kexts/` yang disentuh. Tidak ada file Swift baru
(jadi `project.pbxproj` juga tidak perlu diubah).

---

## 4. Cara pakai Direct EC

1. Jalankan app, buka menu **Battery Threshold → Set EC Offsets…**.
2. Isi offset Start/Stop (dan Inhibit kalau ada) dalam hex yang **sudah anda
   verifikasi untuk X260 anda**. Kosongkan / isi `0` untuk tidak memakai offset itu.
3. Aktifkan **Direct EC (ACPI WE1B)**.
4. Pantau log:

   ```bash
   log stream --style compact --predicate 'eventMessage CONTAINS "[BatteryEC]"'
   ```

   Sukses terlihat seperti:

   ```
   [BatteryEC] WE1B start 0xNN <- 0x4B (was 0x32, readback 0x4B)
   [BatteryEC] WE1B stop  0xNN <- 0x55 (was 0x32, readback 0x55)
   ```

   Kalau `readback != desired` atau muncul `YogaSMC writeEC failed`, berarti
   offset salah / kext menolak / EC tidak mengizinkan write.

---

## 5. Kemungkinan-kemungkinan setelah ini

### A. SMI (BCCS/BCSS) ternyata bekerja normal
Threshold sudah masuk EC lewat jalur OEM. **Direct EC tidak perlu aktif** —
biarkan OFF. Perbaikan urutan `Battery` + encoding stop=100 + reapply 3 detik
tetap membantu (nilai tidak-loss saat charger dicolok lagi).

### B. SMI tidak diproses firmware Hackintosh
Ini cocok dengan keluhan "tidak nulis ke EC". Jalur lama kembali `success`
tapi EC tidak berubah. Solusinya ya **Direct EC lewat WE1B**, tapi offsetnya
harus diketahui. Karena tidak ada bukti offset di folder `ACPI/`, aplikasi
sengaja tidak menebak: user harus mengisi sendiri (menu `Set EC Offsets…`).

### C. Offset belum diketahui / belum diverifikasi
Ini kondisi saat ini. Cara mendapatkannya (di luar cakupan patch ini):
- Ambil DSDT/EC dump mesin dan cari method/field threshold (di X260 lewat SMI,
  jadi biasanya tidak ada field EC bernama jelas).
- Amati driver Windows Lenovo Power Management (`ChargeThreshold.exe` →
  service + `.sys`) saat `on 80`: IOCTL apa yang dikirim, byte EC mana yang berubah.
- Bandingkan `RE1B` seluruh 0x00–0x99 sebelum/sesudah set threshold 75/85
  untuk melihat byte mana yang ikut berubah (hati-hati: banyak byte berubah
  karena aktivitas EC normal).

**Jangan mengisi offset berdasarkan tebakan.** Salah offset bisa mengubah fan, LED,
trackpoint, atau sleep/wake behaviour.

### D. YogaSMC tidak ter-load / `ThinkVPC` tidak ada
Kedua jalur gagal (`serviceNotFound`). Pastikan `YogaSMC-VENTURA.kext` (Ventura)
atau `YogaSMC-SEQUOIA.kext` (Sequoia) aktif di `config.plist`, dan device
`LEN0268`/`LEN0068` cocok (SSDT-YVPC). Cek:

```bash
ioreg -lw0 | grep -i ThinkVPC
```

### E. EC menolak write
`writeEC` mengembalikan `kIOReturnIOError` / `kIOReturnNotReady`. Cek property
`ECAccessCap` di `ioreg`, dan apakah SSDT-EC benar-benar ter-load (method `WE1B`
harus ada di namespace ACPI). Kalau `WE1B` tidak ada, `method_we1b` gagal walaupun
user client terbuka.

---

## 6. Risiko & catatan

- Direct EC **default OFF** sampai offset diisi. Ini disengaja supaya patch tidak
  pernah menulis byte EC sembarangan di mesin orang lain.
- Reapply 3 detik hanya menulis kalau byte berbeda; jadi tidak membanjiri EC.
- `stop = 100` dikirim sebagai `0` ke YogaSMC (sesuai YogaSMCPane). UI tetap
  menampilkan 100%.
- Perubahan ini **tidak menjamin** threshold bekerja kalau masalahnya ada di
  SMM/firmware atau di desain EC X260 yang memang hanya bisa diatur lewat SMI.
  Itu sebabnya andalnya tetap verifikasi dengan `RE1B` dan perilaku pengisian
  sungguhan di baterai.
