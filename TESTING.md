# Panduan Testing delucyx

## Persiapan

### 1. Cek IP & Gateway jaringan kamu

```bash
# Cek alamat IP dan gateway
ifconfig en0 | grep "inet "
route -n get default | grep gateway

# Cek interface yang aktif (biasanya en0 untuk WiFi)
ifconfig en0 | grep status
```

### 2. Cari target (device lain di jaringan yang sama)

```bash
# Scan semua device lokal (gunakan IP subnet kamu)
# Misal subnet 192.168.1.x:
for i in {1..254}; do ping -c1 -W1 192.168.101.$i &>/dev/null && echo "192.168.101.$i UP"; done

# Atau cek ARP table (device yang sudah dikenal)
arp -a
```

### 3. Pastikan sudah build

```bash
make clean && make
```

---

## Mode Testing

### Level 1: Dry Run (tanpa sudo)

Cek apakah deteksi interface/gateway jalan dengan benar:

```bash
build/delucyx --help

# Test deteksi otomatis
build/delucyx -v 192.168.101.50
```

Output yang diharapkan:
```
Gateway: 192.168.101.1
Our IP: 192.168.101.71
Our MAC: xx:xx:xx:xx:xx:xx
Victim: 192.168.101.50
Error opening BPF: BPF open failed: open /dev/bpf*: Permission denied
Try running with sudo
```

Kalau data di atas benar (IP, MAC, gateway sesuai), lanjut ke Level 2.

### Level 2: Single Shot (verifikasi ARP spoof bisa dikirim)

Untuk satu kali kirim tanpa loop (kita tidak punya fitur `--once`, jadi jalankan dan Ctrl+C cepat):

```bash
# Pilih target yang tidak krusial (misal IP kosong/padam)
sudo build/delucyx -i en0 -g 192.168.101.1 -r 10 192.168.101.50
```

Tekan Ctrl+C dalam 1-2 detik setelah melihat "Spoof #1".

Cek apakah serangan berhasil:

```bash
# Dari komputer lain, cek ARP table
arp -a | grep 192.168.101.1
# Kalau MAC gateway berubah jadi MAC kamu -> spoof berhasil!
```

Atau:

```bash
# Dari komputer kamu sendiri, lihat apakah paket ARP terkirim
sudo tcpdump -i en0 arp -c 10
```

### Level 3: Full Test (device nyata)

**⚠️ PERINGATAN:** Ini akan MEMOTONG akses internet device target.

```bash
# Pilih device target yang kamu punya akses fisik
sudo build/delucyx 192.168.101.50
```

Pada device target:
- Coba buka website apa saja
- **Seharusnya:** halaman tidak bisa dimuat (koneksi terputus)
- **Catatan:** kalau device target menggunakan VPN/HTTPS, koneksi mungkin tetap jalan tapi lambat

### Level 4: Bidirectional + Forward (MITM penuh)

Untuk mencegat lalu lintas (bukan sekedar motong koneksi):

```bash
sudo build/delucyx -b -f 192.168.101.50
```

Dengan `-f` (IP forwarding), lalu lintas target akan melewati komputer kamu.
Dengan `-b` (bidirectional), kamu juga menipu gateway.

---

## Yang Perlu Diperhatikan

### ARP Spoof Tidak Bekerja (macOS 15.4+)

Kalau kamu di macOS 15.4+ (Sequoia), ada kemungkinan ARP spoof **tidak bekerja** di WiFi karena Apple menambahkan proteksi. Tandanya:
- Paket ARP terkirim (tcpdump melihatnya)
- Tapi ARP table device target tidak berubah
- Koneksi target tetap jalan normal

Solusi: belum ada untuk pure macOS. Project ini masih eksperimental.

### Keamanan

- Hanya test di jaringan yang kamu miliki
- Jangan test di jaringan kantor/kampus tanpa izin
- Gunakan IP forwarding hanya untuk riset

### Restore

Program akan mengirim ARP restore otomatis saat Ctrl+C ditekan.
Kalau program crash, jalankan manual:

```bash
# Cari tau MAC asli gateway dari device lain
# Lalu restore manual via ARP
sudo arp -s 192.168.101.1 xx:xx:xx:xx:xx:xx
```

---

## Skenario Test Lengkap

```bash
# 1. Build
make clean && make

# 2. Test deteksi (tanpa root)
build/delucyx -v 192.168.101.50

# 3. Cek ARP target masih normal (dari komputer lain)
arp -a | grep 192.168.101.50

# 4. Jalankan serangan (2 detik lalu Ctrl+C)
sudo build/delucyx -r 1 192.168.101.50
# ^C setelah 2 detik

# 5. Verifikasi ARP sudah direstore
arp -a | grep 192.168.101.1
# MAC gateway harus kembali normal (bukan MAC kamu)
```

---

## Testing TUI (OpenTUI) — tanpa root

TUI tidak butuh sudo: dia cuma client daemon lewat Unix socket.

### 1. Dependency dan test otomatis

```bash
make tui-deps      # bun install di tui/
make tui-test      # bun test (headless, pakai createTestRenderer + stub client)
```

### 2. TUI tanpa daemon (layar onboarding)

```bash
./build/delucyx tui
```

Harus muncul layar onboarding berisi perintah `sudo delucyx install`; tekan `q` → keluar bersih
(terminal kembali normal, tidak ada error).

### 3. Test protokol IPC tanpa BPF/root

Daemon bisa dijalankan non-root dengan socket alternatif; BPF akan gagal (wajar), tapi protokol
dan state machine tetap bisa diverifikasi:

```bash
mkdir -p /tmp/delucyx-test
DELUCYX_SOCKET=/tmp/delucyx-test/delucyx.sock ./build/delucyx --daemon &

# status: harus memuat protocol=3, mode, ssid (+ ch/band/signal), nearby[], devices, targets
printf '{"cmd":"status"}\n' | nc -U /tmp/delucyx-test/delucyx.sock

# wi-fi yang sedang tersambung + tetangga yang terdengar
DELUCYX_SOCKET=/tmp/delucyx-test/delucyx.sock ./build/delucyx status | head -12

# hold → status mode harus "hold"; resume → "auto"
printf '{"cmd":"hold"}\n'   | nc -U /tmp/delucyx-test/delucyx.sock
printf '{"cmd":"resume"}\n' | nc -U /tmp/delucyx-test/delucyx.sock

# start target yang ada di ARP cache → {"ok":true,"targets":[...]}
printf '{"cmd":"start","targets":["192.168.1.18"],"mode":"cut"}\n' | nc -U /tmp/delucyx-test/delucyx.sock

# command tak dikenal → {"error":"unknown command: ..."}
printf '{"cmd":"frobnicate"}\n' | nc -U /tmp/delucyx-test/delucyx.sock
```

Catatan: kalau BPF gagal (non-root), daemon tetap menerbitkan daftar device dari ARP cache dan
melaporkan `Gateway MAC unknown — cannot spoof` di log. Storm rescan dicegah dengan backoff 30 detik.

Yang diverifikasi dari Wi-Fi:

- `status.ssid` + `ssidChannel` + `ssidBand` + `ssidSignal` — jaringan yang sedang tersambung,
  terbaca walau BPF gagal (daemon memakai `system_profiler SPAirPortDataType`, bukan scan ARP).
- `status.nearby[]` — tetangga yang terdengar tapi belum tersambung (SSID, channel, band, security,
  signal dBm), paling kuat dulu, maksimum 24, satu baris per SSID+band.
- IP/MAC/hostname tidak dipakai untuk baris tetangga: mereka memang bukan target cut.

### 4. Cek mode aman (tidak ada cutting otomatis)

```bash
DELUCYX_SOCKET=/tmp/delucyx-test/delucyx.sock ./build/delucyx --daemon &
sleep 8
DELUCYX_SOCKET=/tmp/delucyx-test/delucyx.sock ./build/delucyx status   # Mode hold — idle
grep -c "Spoofing" /var/log/delucyx.log                                # 0 (atau tidak ada file)
```

Harus `hold`, `Targets 0`, log cuma `scanning only` — bukti daemon tidak menyerang sendiri.
Cutting baru jalan setelah perintah eksplisit: `resume` (auto) atau `start` (target terpilih).

### 5. Cek chart di dashboard

```bash
# daemon asli: counter frames hanya naik kalau BPF dipakai (butuh root untuk scan aktif)
DELUCYX_SOCKET=/tmp/delucyx-test/delucyx.sock ./build/delucyx --daemon &
DELUCYX_SOCKET=/tmp/delucyx-test/delucyx.sock delucyx
```

Panel **TELEMETRY** menampilkan `tx/s` (block chart) + `peak`/`avg` dan chart `targets`
(rasio target vs jumlah device). Nilai diambil dari `status.framesSent` (counter kumulatif
di dalam binary), jadi tanpa root (BPF gagal) chart memang datar di 0.0/s — itu benar.

Untuk melihat chart bergerak tanpa root, jalankan stub protokol-3 (bukan daemon asli, tidak
menyentuh ARP):

```bash
python3 /tmp/delucyx_stub_daemon.py &        # socket /tmp/delucyx-stub.sock
DELUCYX_SOCKET=/tmp/delucyx-stub.sock delucyx
```

### 6. Test TUI dengan daemon sungguhan

```bash
sudo ./build/delucyx install    # daemon root + BPF
delucyx                         # TUI (tanpa sudo)
```

Yang diverifikasi: daftar device muncul, `space` menandai target, `c` + `y` mulai cut,
`s` menghentikan (mode `hold`), `u` kembali `auto`, `r` rescan.

Wi-Fi / signal:

- Header: `en0 · <SSID> ████· -47 dBm · <IP> · gw <IP>` — meter + dBm jaringan yang tersambung.
- Tabel: baris `nearby wifi <n>` di bawah device, tiap tetangga punya meter
  (`█████` kuat → `····` lemah; hijau ≥4 blok, kuning 3, merah di bawahnya), dBm, channel+band,
  SSID, security. Baris ini tidak bisa dipilih/di-cut.
- `w` menukar pane ke tabel tetangga (`SIGNAL / CHANNEL / NETWORK / SEC`); cursor bisa mencapai
  semua network yang terdengar walau layar pendek. `c`/`m`/`space` sengaja ditolak di view ini.
- Nilai RSSI datang dari daemon (survey tiap 30 s), jadi meter bergerak mengikuti pergerakan
  device, bukan animasi UI.
