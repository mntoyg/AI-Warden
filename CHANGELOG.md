# Changelog

รูปแบบตาม [Keep a Changelog](https://keepachangelog.com/) และ [SemVer](https://semver.org/)

---

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

[1.0.0]: https://github.com/mntoyg/AI-Warden/releases/tag/v1.0.0
