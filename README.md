[README.md](https://github.com/user-attachments/files/34208871/README.md)
# NAMLoader (iOS 17+, termasuk iPhone XS / iOS 18)

Fitur: tombol daya, meter IN/OUT, trim input, master, model `.nam` mono (NeuralAmpModelerCore),
cabinet IR `.wav` (konvolusi vDSP, maks 4096 sampel), pelindung feedback, impor lewat Files.

## Struktur repositori
```
.github/workflows/build-ipa.yml   ← satu-satunya workflow (hapus main.yml & objective-c-xcode.yml lama)
NAMLoader/                        ← kode Swift + Objective-C++
scripts/fetch_nam_core.sh         ← mengunduh NAM Core pada commit yang sudah diuji
project.yml  setup.sh  README.md
```

## Cara B — tanpa Mac (GitHub Actions)
1. Upload seluruh isi folder ini ke repositori GitHub (branch `main`).
2. **Hapus** `.github/workflows/main.yml` (kosong) dan `.github/workflows/objective-c-xcode.yml` (template bawaan, selalu gagal).
3. Tab Actions → "Build IPA" → Run workflow. Build memakan ±10–20 menit.
4. Unduh artifact `NAMLoader.ipa` dari halaman run yang selesai.
5. IPA belum ditandatangani. Pasang ke iPhone XS dengan Sideloadly atau AltStore memakai Apple ID
   (gratis = 7 hari; Developer Program USD 99/tahun = 1 tahun).

## Cara A — ada Mac
1. `./setup.sh` (mengunduh NAM Core, membuat proyek Xcode, membukanya)
2. Ganti bundle ID di `project.yml` (`com.pradea26.namloader`) bila perlu, jalankan `./setup.sh` lagi.
3. Xcode → target NAMLoader → Signing & Capabilities → pilih Team (Apple ID).
4. Colok iPhone XS → Run.

## Fitur
- **TONE3000**: tombol "Buka TONE3000" membuka beranda tone3000.com langsung di dalam app (tanpa Client ID/OAuth).
  Login di website, ketuk Download pada tone: file `.nam` / `.wav` / `.zip` otomatis disimpan dan dipasang ke slot.
  Menu blok › "Ambil dari website TONE3000" (AMP, PEDAL, SIM, CAB, GATE, COMP, REVERB, CHORUS, MOD, DELAY, EQ, FX).
- **Preset**: tombol Simpan di tab Rig menyimpan ke daftar preset pengguna dan/atau salah satu dari **10 bank**.
  Bank tersimpan di Files › NAMLoader › `Banks.json`, preset pengguna di `presets/`.
- **Mode jalur**: 1 JALUR, 2 JALUR (paralel, stereo), atau GABUNG (jalur A + B dijumlahkan jadi 1 output mono).
- **MIDI eksternal** (tab Setup › MIDI): USB atau Bluetooth LE MIDI. Program Change 0–9 atau Note 36–45 → Bank 1–10;
  CC 80 = bank berikut, CC 81 = bank sebelum (bisa diubah dengan tombol Pelajari).

## Lisensi pihak ketiga
NAMLoader memakai Neural Amp Modeler Core (MIT, © Steven Atkinson) dan Eigen (MPL 2.0). Teks lisensi aslinya ada di
folder hasil unduhan `NeuralAmpModelerCore/` (`LICENSE`) dan wajib tetap disertakan bila kode/biner dibagikan.

## Catatan
- Model `.nam` harus mono (1 input, 1 output) — hampir semua model amp/pedal memenuhi ini.
- File impor tersimpan di Files → On My iPhone → NAMLoader (`tones/`, `irs/`).
- Versi NAM Core dipin di `scripts/fetch_nam_core.sh`. Bila ingin memperbarui, ubah `NAM_COMMIT`
  dan cek `NAMProcessor.mm` (`get_dsp`, `Reset`, `process`).
