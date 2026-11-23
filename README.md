<div><img src="ThinkpadAssistant/Assets.xcassets/AppIcon.appiconset/appIcon-64-min.png" width="48" height="48" align="left"/><h1>Thinkpad Assistant</h1></div>

Aplikasi menu bar untuk ThinkPad X260 (dan seri T lain) yang dijalankan di macOS / Hackintosh.
Fokus utamanya adalah **Battery Threshold 20–100%** lewat YogaSMC, dikombinasikan dengan
pemulihan tombol fungsi keyboard dan pembaruan otomatis via Sparkle 2.

> **macOS Ventura 13 ke atas • Universal (x86_64 + arm64) • Ad-hoc signed**

---

## Tampilan Menu Bar

Ikon kecil di menu bar (di dekat ikon baterai) adalah status item aplikasi. Klik untuk membuka menu:

```
Tentang Thinkpad Assistant
Pantau Capslock ✓
Nyala pas Login ✓
Batas Ngecas >
Cek Update...
Cek Update Otomatis ✓
Keluar
```

Submenu **Batas Ngecas**:

```
Baterai - 86% - Lagi Ngisi
Daya: 21.3 W · 1.95 A — Lagi ngisi
BAT0 - 73% - Detail EC
BAT1 - 99% - Detail EC
Batas: Mulai 75% → Stop 85%
EC langsung: MATI (cuma BCCS/BCSS)

Atur Mulai Ngecas Di  >
Atur Stop Ngecas Di   >

[✓] Nyalain Batas
Refresh Batas
EC Langsung (ACPI WE1B)      ← advanced, default MATI
Atur Offset EC…
```

> Baris **Daya** otomatis hilang kalau charger dicabut. Saat threshold berhenti
> (atau baterai sudah penuh), angkanya jadi `0.0 W · 0.00 A — Stop, nggak ngisi`.
> Seluruh teks UI memakai bahasa Indonesia sehari-hari.

---

## Fitur

### Battery Threshold 20–100%

- Mengatur batas **Start** dan **Stop** pengisian (0–100%, langkah 5%) lewat properti
  `ThinkVPC` milik YogaSMC 1.5.3.
- `setCMstart` → ACPI `BCCS`, `setCMstop` → ACPI `BCSS`, `setCMInhibitCharge` → `BICS`.
- Tidak memakai SMC key `B0St`/`B0Sp`/`B0En` yang sering disebut di internet
  (audit detail ada di [`SUMMARY.md`](SUMMARY.md)).
- Saat **Enable Threshold** dimatikan, nilai dikirim `start=0`, `stop=0`,
  `inhibit=0` (pengisian penuh seperti semula; `0` = 100% sesuai YogaSMCPane).
- **Direct EC (ACPI WE1B)** — opsi advanced (default OFF) yang menulis byte EC
  lewat `YogaSMCUserClient` → method ACPI `WE1B` dari `SSDT-EC.aml`, lalu
  diverifikasi dengan `RE1B`. Offset EC harus diisi manual lewat
  **Set EC Offsets…** karena tidak ada offset threshold di folder `ACPI/`.
  Detail, kemungkinan, dan risiko: [`EC_DIRECT_SUMMARY.md`](EC_DIRECT_SUMMARY.md).

### Monitor Baterai / Status Sistem

- **Persen utama diambil dari `IOPowerSources` (`IOPSCopyPowerSourcesInfo` +
  `IOPSGetPowerSourceDescription`)** — sumber yang sama persis dengan ikon baterai
  bawaan macOS. Di X260 ini sudah menggabungkan BAT0 + BAT1, jadi angkanya selalu
  sama dengan ikon macOS (mis. 86%, bukan 73% dari EC).
- Tampilan utama: `Baterai - 86% - Lagi Ngisi`.
- **Daya masuk baterai (baru):** `kIOPSVoltageKey` (mV) × `kIOPSCurrentKey` (mA)
  ÷ 1.000.000 → Watt, dengan fallback `AppleSmartBattery` (`InstantAmperage`)
  kalau arus dari IOPowerSources nol. Di-refresh tiap 2 detik, pakai format titik
  (mis. `21.3 W · 1.95 A`). Baris ini **hilang** saat charger nggak nyolok,
  dan menunjukkan `0.0 W` saat threshold stop / arus ≈ 0.
- Di bawahnya, detail EC kecil (opsional): `BAT0 - 73% - Detail EC`,
  `BAT1 - 99% - Detail EC`. Ini **hanya info**, bukan persen utama.
- Persen di-refresh tiap 5 detik. Saat charger dicabut/dicolok, observer IOKit
  langsung memperbarui tampilan dan menulis ulang threshold EC setelah 2 detik
  (mengatasi bug cabut-colok bablas).
- Console debug mencetak: `macOS Percent: 86% | App Display: 86% | Match: YES`.
  Jika `NO` selama >10 detik, muncul warning di log.
- Untuk metrik CPU/RAM, gunakan `Activity Monitor.app`; status item aplikasi ini
  difokuskan pada baterai dan threshold.

### Menu Bar Icon & Tombol Fungsi

Ikon menu bar memakai `menuIcon` (light/dark otomatis). Tombol keyboard yang didukung:

| Tombol | Fungsi |
|---|---|
| **F4** | Bisu / aktifkan mikrofon |
| **F7** | Cerminkan / perpanjang layar |
| **F8** | Wi-Fi on/off |
| **Shift + F8** | Bluetooth on/off |
| **F9** | Pengaturan Sistem |
| **F12** | Launchpad |
| **Fn + Spasi** | Lampu keyboard |

### Update otomatis (Sparkle 2)

- **Check for Updates...** memanggil `SPUStandardUpdaterController.checkForUpdates(nil)`.
- **Automatically Check for Updates** (default ON) mengontrol
  `updater.automaticallyChecksForUpdates`.
- Feed: `https://raw.githubusercontent.com/Syuhadak27/BatteryLenovoAssistent/main/appcast.xml`
- Cek otomatis tiap 86400 detik (24 jam). Tanpa internet, Sparkle menampilkan
  error dialog standar — aplikasi tidak crash.

---

## Instalasi

1. Unduh **`ThinkpadAssistant-X.X.X.dmg`** (atau `.zip`) dari
   [GitHub Releases](https://github.com/Syuhadak27/BatteryLenovoAssistent/releases).
2. Buka DMG lalu drag `ThinkpadAssistant.app` ke folder **Applications**
   (kalau pakai zip, ekstrak dulu).
3. Karena binary ad-hoc signed, jalankan sekali:

   ```bash
   xattr -cr /Applications/ThinkpadAssistant.app
   ```

4. Jalankan aplikasi, centang **Launch on Login** jika ingin otomatis.
5. Buka **Battery Threshold**, pilih Start/Stop, lalu aktifkan **Enable Threshold**.

Persyaratan: YogaSMC 1.5.3 aktif di EFI dan SSDT pendukung terpasang. Aplikasi
tidak disandbox karena harus menulis properti IOKit milik kext.

---

## Cara Update

- Otomatis: Sparkle mengecek tiap 24 jam dan menampilkan dialog saat ada versi baru.
- Manual: klik ikon di menu bar → **Check for Updates...**.
- Matikan/nyalakan otomatis lewat **Automatically Check for Updates** di menu yang sama.

---

## Build dari Source

Butuh **Xcode** (macOS 13+ SDK). Tidak perlu CocoaPods; dependency diambil via
Swift Package Manager (Sparkle 2.10.1).

```bash
git clone https://github.com/Syuhadak27/BatteryLenovoAssistent.git
cd BatteryLenovoAssistent
open ThinkpadAssistant.xcodeproj
# Pilih scheme ThinkpadAssistant → Product > Build (⌘B)
```

Atau lewat CLI:

```bash
xcodebuild -project ThinkpadAssistant.xcodeproj \
  -scheme ThinkpadAssistant \
  -configuration Release \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ARCHS='x86_64 arm64'
```

Hasil: `build/Build/Products/Release/ThinkpadAssistant.app`.

### Build otomatis via GitHub Actions (tidak perlu Mac)

Dua workflow sudah disiapkan:

| Workflow | Trigger | Hasil |
|---|---|---|
| `.github/workflows/build.yml` | pull request / push ke cabang bukan `main` | Artifact `ThinkpadAssistant-macOS`: `.app.zip`, `.dmg`, `SHA256SUMS.txt` |
| `.github/workflows/release.yml` | push ke `main`, tag `v*`, atau manual (Actions → Run workflow) | GitHub Release berisi `ThinkpadAssistant-X.X.X.zip`, `ThinkpadAssistant-X.X.X.dmg`, `SHA256SUMS.txt` |

Keduanya memakai runner `macos-15-intel`, ad-hoc signing (`CODE_SIGN_IDENTITY=-`),
dan build universal `x86_64 + arm64` dengan deployment target macOS 13.
Verifikasi `codesign --verify --deep --strict` dilakukan sebelum packaging.
DMG dibuat dengan `hdiutil` dan berisi shortcut ke `/Applications`.

> Catatan: aplikasi **ad-hoc signed / tidak dinotarisasi**. Setelah install,
> jalankan `xattr -cr /Applications/ThinkpadAssistant.app` sekali. Kalau user
> lebih nyaman tanpa Gatekeeper, diperlukan Developer ID + notarization (secret
> `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD`) — belum dipakai di workflow.

---

## Rilis Versi Baru (ringkasan)

1. Naikkan `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` di Xcode.
2. Push ke `main` (atau tag `vX.X.X`) → `release.yml` otomatis membuild dan
   membuat GitHub Release berisi `.zip` + `.dmg`.
3. Untuk Sparkle: jalankan `./build_release.sh` secara lokal → `edSignature` + `length`.
4. Update `appcast.xml` dengan signature, length, dan URL baru, lalu push ke `main`.

Panduan lengkap ada di [`SUMMARY_SPARKLE.md`](SUMMARY_SPARKLE.md).

---

## Lisensi

MIT — lihat [`LICENSE`](LICENSE).

## Repository

https://github.com/Syuhadak27/BatteryLenovoAssistent
