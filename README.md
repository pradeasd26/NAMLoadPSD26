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

## Catatan
- Model `.nam` harus mono (1 input, 1 output) — hampir semua model amp/pedal memenuhi ini.
- File impor tersimpan di Files → On My iPhone → NAMLoader (`tones/`, `irs/`).
- Versi NAM Core dipin di `scripts/fetch_nam_core.sh`. Bila ingin memperbarui, ubah `NAM_COMMIT`
  dan cek `NAMProcessor.mm` (`get_dsp`, `Reset`, `process`).
