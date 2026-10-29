# NAMLoader (iOS 17+, termasuk iPhone XS / iOS 18)

Fitur: tombol daya, meter IN/OUT, trim input, master, model `.nam` (NeuralAmpModelerCore),
cabinet IR `.wav` (konvolusi vDSP, maks 4096 sampel), pelindung feedback, impor lewat Files.

## Cara A — ada Mac
1. `./setup.sh` (mengunduh NAM Core, membuat proyek Xcode, membukanya)
2. Ganti bundle ID di `project.yml` (`com.contoh.namloader`) dengan milikmu, jalankan `./setup.sh` lagi bila diubah.
3. Xcode → target NAMLoader → Signing & Capabilities → pilih Team (Apple ID).
4. Colok iPhone XS → Run. (Apple ID gratis: aplikasi berlaku 7 hari.)

## Cara B — tanpa Mac
1. Upload folder ini ke repositori GitHub baru.
2. Tab Actions → "Build IPA" → Run workflow → unduh artifact `NAMLoader.ipa`.
3. IPA ini belum ditandatangani. Pasang ke iPhone dengan Sideloadly atau AltStore memakai Apple ID
   (gratis = 7 hari; Developer Program USD 99/tahun = 1 tahun).

## App Store
Perlu Apple Developer Program, ikon 1024px, screenshot, URL kebijakan privasi, lalu Product → Archive →
Distribute App → App Store Connect.

## Bila build gagal
API NAM Core berubah antar versi. Cek `NAMProcessor.mm` (get_dsp, Reset, process, NAM_SAMPLE) dan
Header Search Paths di `project.yml`.
