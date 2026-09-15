# Changelog

รูปแบบตาม [Keep a Changelog](https://keepachangelog.com/) และ [SemVer](https://semver.org/)

---

## [1.0.3] — 2026-09-15

**Correctness/trust fix — ควรอัปเกรด โดยเฉพาะก่อนโชว์/บันทึกวิดีโอ**

การซ้อมเดโมจริง (`warden-cli run`, sentinel เปิด) บน Docker Desktop เผยว่า breach
ที่ถูกต้องกลับพิมพ์ false alarm ว่า incident report ถูก symlink เปลี่ยนเส้นทาง ทั้งที่
ไม่มีการ tamper — tripwire ร้องหมาป่า ซึ่งเป็น bug shape ประจำโปรเจกต์ (control ที่
รายงานผิด)

### Fixed

- **False "report redirected by a symlink" alarm บน race ปกติ** — inline monitor กับ
  out-of-band sentinel เฝ้า canary vault เดียวกัน พอ breach ทั้งคู่ยิงแล้ว **แข่งกันเขียน**
  `WARDEN_SECURITY_INCIDENT.json` ตัวชนะเขียน 0444 ตัวแพ้ `O_TRUNC` เจอ EACCES เดิม
  v1.0.1 ตีความ error ทุกชนิดว่า "ถูก symlink เปลี่ยนเส้นทาง" + ทิ้ง fallback ไฟล์ว่าง
  ตอนนี้ **เฉพาะ errno ELOOP** (O_NOFOLLOW โดน symlink จริง) ถึงนับเป็น tamper; error
  อื่นถ้ามี report ปกติอยู่แล้ว = peer เขียนไปแล้ว → log เงียบ ไม่มี false alarm/ไฟล์ว่าง
  การจับ symlink redirection จริงไม่เปลี่ยน (phase E1 ยังเขียว)
- ตัด directive `dns_v4_first` ที่ obsolete ใน squid 5 ซึ่งพิมพ์ `ERROR: ... is obsolete`
  ตอน build proxy ทุกครั้ง

### Tests

- phase D ตรวจ incident report หลัง breach: **fail ถ้า** benign breach เกิด
  `report_path_tampered` หรือ fallback ไฟล์ว่าง (การเช็คที่จะจับบั๊กนี้ได้)
- phase A–F เขียวครบ (local exit 0); dry-run breach เหลือ report เดียวสะอาด

---

## [1.0.2] — 2026-09-15

**Security release — ผู้ใช้ v1.0.1 ควรอัปเกรด**

ตอนเปลี่ยน exploit ของ audit ให้เป็น drill ถาวร (phase E) การ *เขียน* drill E3
เผยว่า `assert_safe_mount` — guard rail เดียวที่ตัดสินว่า mount อะไรได้ —
รายงานตัวว่าทำงานแต่จริง ๆ ยัง "รับ" เป้าหมายอันตราย 3 กลุ่ม (คือ bug shape
ประจำโปรเจกต์: control ที่บอกว่า armed แต่ไม่บังคับใช้อะไร) v1.0.1 changelog
เคลม coverage ของ mount guard ไว้เกินจริง — รุ่นนี้แก้ให้ตรง

### Security

- **usrmerge symlink หลุด (`/bin`, `/sbin`, `/lib`)** — guard resolve ด้วย
  `cd; pwd -P` ซึ่งตาม symlink ไปเป็น `/usr/bin` ฯลฯ และ refuse list มีแค่ `/usr`
  path จริงจึงหลุด mount ทั้ง system dir ได้ ตอนนี้ตรวจทั้ง physical (`pwd -P`)
  และ logical (`pwd -L`) — ชื่อที่ผู้ใช้พิมพ์ก็ถูกจับด้วย โดยไม่ false-positive
  กับโปรเจกต์จริงอย่าง `/var/www`
- **ไดรฟ์ทั้งลูกใต้ `/media`, `/run/media`, `/cygdrive` หลุด** — pattern
  `/media/*/` และ `/cygdrive/*/` เดิมเป็น dead code (`pwd` ไม่เคยลงท้ายด้วย `/`
  จึงไม่มีทาง match) `/media/usb` และ `/cygdrive/c` (ไดรฟ์ Windows ทั้งลูก) จึง
  mount ได้ ตอนนี้ refuse โดยดูจาก parent เป็น `/media`/`/run/media`/`/cygdrive`
  ส่วนโปรเจกต์ที่ซ้อนในไดรฟ์ (`/media/usb/app`) ยังอนุญาต และ `/mnt` คงกฎ
  drive-letter เดิมไว้ (มือทำ `/mnt/project` ยังใช้ได้)
- เพิ่ม `/run` และ bare `/run/media`, `/cygdrive` เข้า refuse list

### Tests

- phase E3 ป้อน 23 path อันตรายข้างต้น + accept-test 2 อัน (โปรเจกต์ปกติ และ
  โปรเจกต์ซ้อนในไดรฟ์) ล็อกไว้กันทั้ง over- และ under-refusal
- `verify-isolation.sh` phase A–E เขียวครบ (local exit 0, `enforced=4/7` บน
  Docker Desktop 9p; CI บน ext4 `enforced=7/7`)

### Known limitation

- ไดรฟ์รูปแบบ udisks สองชั้น `/media/<user>/<label>` ยังไม่ครอบคลุม (แยกจาก
  project ที่ซ้อนในไดรฟ์ไม่ได้แบบ structural) — บันทึกไว้ใน `.ai/HANDOFF.md`

---

## [1.0.1] — 2026-09-14

**Security release — ผู้ใช้ v1.0.0 ทุกคนควรอัปเกรด**

การแก้ด้านความปลอดภัยทั้งสี่ข้อด้านล่างเข้าไปใน `main` หลังจาก tag v1.0.0 แล้ว
ใครที่ใช้ release v1.0.0 อยู่จึงยังไม่ได้รับการแก้ รุ่นนี้รวมมาไว้ใน tag ที่ใช้ได้

### Security

- **Symlink redirection ของ incident report (medium)** — monitor เขียนลงไดเรกทอรีที่
  agent เขียนได้ (`/run/warden`, `/workspace`) agent จึงวาง symlink ดักให้การเขียน
  ไปลงไฟล์อื่นได้ ในโหมด sentinel คนเขียนคือ root
  ตอนนี้ทุกการเขียนใช้ `O_NOFOLLOW` และถ้าเจอ symlink จะเก็บหลักฐานไว้ใต้ชื่อที่
  agent เดาไม่ได้ พร้อมบันทึก `report_path_tampered` แทนที่จะทิ้งรายงาน
- **Terminal / log injection (low-medium)** — ชื่อ process ใน `/proc/<pid>/cmdline`
  ผู้โจมตีตั้งเองได้ ใส่ ANSI escape เพื่อลบบรรทัดจริงแล้วปลอมบรรทัด
  `[canary] all clear` ได้ ตอนนี้กรอง control character ก่อนเข้า log และรายงาน
- **Mount guard rails รั่ว (low)** — เดิมกัน `$HOME` แต่ไม่กัน `/home`
  ตอนนี้ปฏิเสธ `/home`, `/Users`, `/mnt`, `/media`, `/srv`, `/mnt/<drive>`,
  `/cygdrive/<drive>` ด้วย
- **เขียนทะลุ dangling symlink บน path ของ canary (low)** — เพิ่มการเช็ค `-L`
  ก่อน seed
- **libpcre2 10.42-1 ในทั้งสองอิมเมจ (HIGH ×2: CVE-2026-86145, CVE-2026-89161)** —
  ต้นเหตุจริงคือ Dockerfile ไม่เคยสั่ง `apt-get upgrade` อิมเมจจึงได้ security fix
  ก็ต่อเมื่อ Docker Hub rebuild base tag ให้เท่านั้น ตอนนี้ทุก build ติดตั้ง
  security update ที่ค้างอยู่ → `10.42-1+deb12u1` และ gate ของ CI กลับมาเป็น 0

### Changed

- venv ของ warden สร้างด้วย `--without-pip` — monitor ใช้แต่ standard library
  จึงไม่ต้องมี package manager เลย ตัด CVE ของ `pip`/`setuptools` ซึ่งเป็น
  component เดียวที่ AI Warden เป็นเจ้าของแล้วมี CVE → เหลือ **0**
- CI: เพิ่ม gitleaks (สแกนทั้ง history) และ trivy (fail เมื่อเจอ HIGH/CRITICAL
  ใน OS package หรือ `/opt/warden`; ส่วน dependency ของ agent รายงานให้เห็นแต่ไม่ gate)
- CI: `actions/checkout@v5` แทน v4 ที่ใช้ runtime Node 20 ซึ่งถูกเลิกใช้แล้ว

### Fixed

- `docs/VERIFICATION.md` ยังแสดงผลลัพธ์ที่คาดไว้แค่ 3 เฟส ขาดเฟส D (sentinel drill)
  และตัวเลือก `--no-sentinel`
- comment ใน monitor ยังอ้าง `chmod 0400` ทั้งที่ canary เป็น `0440` แล้ว

## [1.0.0] — 2026-09-06

รุ่นแรก Zero-Trust sandbox สำหรับรัน AI coding agent โดยไม่เสี่ยงกับเครื่องโฮสต์

### Added

- **Hardened agent image** (`core/Dockerfile`) — Debian bookworm-slim + Node 20 +
  Python 3.11 พร้อม Claude Code, Codex CLI และ Aider ติดตั้งมาให้
  รันเป็น `ai_user` (uid 1001) ที่ล็อกรหัสผ่านไว้ ไม่มี `sudo` ในอิมเมจ
  และ **ลบ setuid/setgid bit ออกทั้งอิมเมจ**
- **Egress allowlist proxy** (`core/network/`) — Squid นโยบาย DENY ALL
  บล็อก IP literal, ปลายทาง RFC1918/link-local, cloud metadata และพอร์ตที่ไม่ใช่ 80/443
  ตั้งใจไม่ทำ SSL-bump เพื่อไม่ให้ proxy กลายเป็นจุดรวม API key
- **Network topology** (`docker-compose.yml`) — sandbox อยู่บน network ที่
  `internal: true` จึงไม่มี route ออกเน็ตในระดับ kernel ไม่ใช่แค่ถูกกรอง
- **Canary tripwire สองชั้น** (`monitors/canary_monitor.py`) — inotify(7) ผ่าน `ctypes`
  ไม่พึ่ง library ภายนอกเลย จับ `IN_OPEN`/`IN_ACCESS` ซึ่ง `watchdog` ทำไม่ได้
  ชั้นที่สองคือ `warden-canary-sentinel` container แยก ไม่มี network มี `CAP_KILL`
  อย่างเดียว และรอด แม้ agent จะฆ่า monitor ตัวในไปแล้ว
- **Capability probing** — วัดจริงว่า filesystem ส่ง inotify event ได้ไหมตอน arm
  แล้วรายงาน `enforced=N/M` ตามความจริง แทนที่จะสมมติว่าเฝ้าอยู่
- **Host CLI** (`scripts/warden-cli.sh`) — `assert_safe_mount()` ปฏิเสธ root ของ
  filesystem, ไดรฟ์ทั้งลูก, `$HOME` และตัว warden เอง
  API key ส่งด้วย `docker run -e NAME` จึงไม่เคยผ่าน argv, `ps` หรือ shell history
- **Verification suite** (`scripts/verify-isolation.sh`) — 4 เฟส:
  self-test 31 ข้อ, breach drill (คาด exit 99), fail-closed drill (คาด exit 78)
  และ sentinel drill (ฆ่า monitor ตัวในก่อน แล้วยังต้องถูกจับ)
- **Cursor / VS Code Dev Container** (`devcontainer/devcontainer.json`)
- **ไฟล์ ignore ครบทุกเครื่องมือ** — `.aiignore` เป็นต้นฉบับ mirror ไปยัง
  `.claudeignore`, `.cursorignore`, `.aiderignore`, `.hermesignore`,
  `.cometignore`, `.codexignore` (`make sync-ignores`)
- **CI** (`.github/workflows/ci.yml`) — shellcheck, hadolint, ตรวจว่า
  `warden_internal` ยัง `internal` อยู่, ตรวจว่า allowlist ไม่มี exfiltration relay,
  ตรวจว่า ignore mirror ไม่ drift และรันชุดทดสอบทั้งหมดบน ext4 จริง
  ซึ่งพิสูจน์ข้ออ้าง `enforced=7/7` บน Linux ที่เครื่อง Docker Desktop พิสูจน์ไม่ได้

### Fixed ระหว่างพัฒนา

บั๊กเหล่านี้ถูกพบเพราะ **รันจริง** ไม่ใช่จากการอ่านโค้ด และทุกตัวเป็นชนิดเดียวกัน:
control ที่รายงานว่าทำงานอยู่ทั้งที่ไม่ได้บังคับใช้อะไร

- tripwire ทำงานเงียบ ๆ ไม่ได้เลยบน bind mount ของ Docker Desktop —
  `inotify_add_watch()` สำเร็จบน 9p แล้วไม่เคยส่ง event และ `noatime` ก็ตัดทาง
  atime fallback แก้ด้วย vault บน named volume + การวัดความสามารถจริง
- sentinel ไม่มี `CAP_KILL` ใน effective set (`--cap-add` ให้แค่ bounding set)
  จึงจะได้ `EPERM` พอดีตอนที่ต้องฆ่า
- sentinel ไม่มีสิทธิ์อ่าน canary เพราะ root ที่ `--cap-drop=ALL` ไม่มี
  `CAP_DAC_OVERRIDE` แก้ด้วย group permission ไม่ใช่การแจก capability เพิ่ม
- sentinel arm ช้ากว่า agent ราว 10 วินาที เปิดช่องให้ agent ที่ฆ่า monitor ตัวใน
  ทำอะไรก็ได้โดยไม่มีใครดู แก้ด้วย handshake สองทางผ่าน vault
- breach ที่ sentinel เป็นคนจับ จบด้วย exit code ของ agent ไม่ใช่ 99
  ทำให้ contract "99 = breach" ไม่จริงพอดีตอนที่ชั้นที่สองทำงาน
- รายงาน incident ชี้ไปที่ process ของ warden เอง เพราะ argv ของ sentinel
  มีชื่อ canary อยู่
- `die` ใน `$(...)` ออกแค่ subshell ทำให้ guard rail ของ mount ถูกข้ามได้เงียบ ๆ
- squid ไม่ยอมสตาร์ทเมื่อ allowlist มีทั้ง wildcard และ subdomain ของตัวเอง
- compose ไม่ยอมรับ network ที่สร้างด้วย `docker network create` (ไม่มี label)
- path ของ Git Bash ไปถึง daemon เป็น `D:\d\...`
- `watchdog` ถูกติดตั้งและถูกประกาศว่าเป็น "secondary detector" ทั้งที่ไม่เคยถูกใช้เลย

### Known limitations

ระบุไว้ตรง ๆ ใน [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) §4 — ไม่ได้ปิดบัง:

- ไม่ป้องกัน container escape ระดับ kernel (ใช้ rootless Docker / gVisor เสริม)
- ไม่ป้องกันการรั่วผ่านปลายทางที่อยู่ใน allowlist เอง
- บน Docker Desktop canary ที่อยู่ใน bind mount ตรง ๆ บังคับใช้ไม่ได้
  (`enforced=4/7`) — วัดและรายงานตามจริงตอนรัน บน Linux ได้ `7/7`

[1.0.1]: https://github.com/mntoyg/AI-Warden/releases/tag/v1.0.1
[1.0.0]: https://github.com/mntoyg/AI-Warden/releases/tag/v1.0.0
