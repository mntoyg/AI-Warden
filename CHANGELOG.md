# Changelog

รูปแบบตาม [Keep a Changelog](https://keepachangelog.com/) และ [SemVer](https://semver.org/)

---

## [1.2.3] — 2026-09-26

### Fixed

- `warden-cli.sh status` แสดงเฉพาะไฟล์ชื่อ `WARDEN_SECURITY_INCIDENT.json` ตั้งแต่ v1.2.1 breach ใน workspace ที่มี
  report อยู่แล้วเขียนไฟล์ชื่อ `WARDEN_SECURITY_INCIDENT.<mode>....json` ของตัวเอง status จึงเห็นแค่ report เก่า
  และไม่เห็นอันใหม่ (regression ที่ผมใส่เองใน v1.2.1) ตอนนี้แสดง report ทุกไฟล์ (drill E6 เพิ่มเงื่อนไข — FAIL กับ v1.2.2)

## [1.2.2] — 2026-09-26

**hardening: log ของ monitor ปลอมบรรทัดไม่ได้อีก**

### Security

- `sanitize()` ของ monitor ปล่อย newline กับ tab ผ่าน: process ที่ exe path มี newline (ไดเรกทอรีชื่อมี
  newline) ทำให้ monitor พิมพ์บรรทัด `[canary ...] *** [SECURITY BREACH] file=... mode=sentinel` ปลอม
  **ทั้งบรรทัด** ลง log ได้ ซึ่งเป็นรูปแบบที่พยาน sentinel ของ v1.2.1 อ่าน — ตอนนี้ยังใช้โจมตีพยานไม่ได้
  (sentinel อ่าน exe ของ uid 1001 ไม่ได้) แต่ log ต้องปลอมแบบนี้ไม่ได้เลย ตอนนี้ control char ทุกตัว
  รวม newline และ tab กลายเป็น `?` (drill E2b — FAIL กับ v1.2.1: บรรทัดปลอมโผล่จริง)

### Fixed

- `status`: แถวของ sentinel ไม่มีย่อหน้า (docker `--format` ตัดช่องว่างนำหน้าทิ้ง)
- `doctor` (`setup-host.sh`): ถ้า `df` ไม่ให้ตัวเลข สคริปต์ (`set -euo pipefail`) **ตายเงียบ ๆ ตรงนั้น** — ไม่ตรวจ
  host posture / repository integrity และไม่มี summary แค่ rc=1 และถ้ารอดมาได้ก็จะ pass disk check ทั้งที่ไม่ได้วัด
  ตอนนี้ pass เฉพาะเมื่อวัดได้ (บอกจำนวน GB) ไม่งั้น warn ว่าวัดไม่ได้ แล้วตรวจต่อจนจบ (drill E8 — FAIL กับโค้ดเดิม)

## [1.2.1] — 2026-09-26

**security: incident records ที่เชื่อได้ — อัปเกรดจาก v1.2.0 และก่อนหน้า**

### Security

- **report ของ breach ครั้งใหม่ถูกกลืนโดยไฟล์ที่มีอยู่แล้ว** — monitor เขียน `WARDEN_SECURITY_INCIDENT.json`
  ด้วย `O_TRUNC` ไฟล์ 0444 ที่มีอยู่ (จาก breach ครั้งก่อน หรือ agent วางไว้เอง) ทำให้เขียนไม่ได้ แล้ว
  monitor ก็เดาว่า "peer monitor เขียนไปแล้ว" — breach ครั้งที่สองใน workspace เดิมจึง **ไม่มี record เลย**
  และ CLI ชี้ไปที่ report เก่า (ทดลองจริง: breach 2 ครั้งติด report ยังเป็นของครั้งแรก) ตอนนี้เขียนด้วย
  `O_EXCL` และถ้ามีไฟล์อยู่แล้ว monitor เขียน record ของตัวเองแยก (`report_path_preexisting`)
  CLI แสดงเฉพาะ report ที่เกิดใน session นี้ (drill E6 — FAIL กับ v1.2.0)
- **agent ปลอมสัญญาณ tripwire ได้** — PID 1 ใช้ uid เดียวกับ agent `kill -USR1 1` จึงได้ log ว่า "from the
  canary tripwire" และ CLI ชี้ไปที่ report ที่ไม่มีอยู่จริง ยัง exit 99 (fail closed) แต่ entrypoint บอก
  `no breach record found` และ CLI บอก `NO incident report ... possibly forged` (drill E7 — FAIL กับ v1.2.0)
  handler ของ `SIGUSR1` ทำงานครั้งเดียวต่อ session แล้ว
- **พยานที่ agent ปลอมไม่ได้** — log ของ container sentinel เป็น record เดียวที่ agent เขียนไม่ได้ แต่เดิม sentinel
  รันแบบ `--rm` log จึงหายไปพร้อมมัน ตอนนี้ CLI อ่านก่อนลบ แล้วพิมพ์ `Confirmed by the sentinel (outside the
  agent's reach): <canary> was opened.` หรือ `recorded no breach` (พร้อมบอกว่ามันเฝ้าอะไร) รับเฉพาะบรรทัดที่
  sentinel พิมพ์เองแบบเป๊ะและ path ที่มันเฝ้าจริง (drill D ต้องเห็นการยืนยัน, E7 ต้องไม่เห็น — FAIL กับ v1.2.0)

### Fixed

- `warden-cli.sh status` ไม่เคยแสดง model server: CLI ที่ถูก kill แรง ๆ (ไม่มี trap) ทิ้ง model server
  ไว้กิน RAM 2.2 GB (และ GPU ในโหมด GPU) ขณะที่ status บอก `none running` — ตอนนี้มีส่วน
  "Local model servers" บอก cpu/GPU และ `ORPHANED` พร้อมคำสั่งเก็บกวาด (ทดลองกับ `kill -9` จริง)
- `aider-local` ไม่พิมพ์ ProxyError ตอนเริ่มอีก: CLI ส่ง metadata ของ `openai/warden-local`
  (context = `WARDEN_MODEL_CTX`, cost 0) ให้ aider จึงไม่ไปดึงรายการโมเดลจาก GitHub และรู้ขนาด
  context จริง (เดิม aider เห็น metadata เป็น `{}`)

### Tests

- phase I: model server ที่ถูกทิ้งต้องขึ้นใน `status` ว่า `ORPHANED` (ต้องพิสูจน์ว่ามันมีอยู่จริงด้วย),
  aider-local ต้องเห็น `max_input_tokens` ของ session และไม่มี GitHub fetch; phase J: status ของ session
  GPU ที่กำลังรันต้องบอก GPU และผูกกับ sandbox — ทั้งสามข้อ FAIL กับ v1.2.0 ก่อนแก้
- `--no-breach` ข้าม breach check ของ phase I ด้วย (เดิมยังรัน exit 99)

## [1.2.0] — 2026-09-26

**ฟีเจอร์: รันโมเดลในเครื่องบน GPU แบบพิสูจน์ได้ — offload ครบ หรือปฏิเสธ**

### Added

- `WARDEN_MODEL_GPU=1` (สั่งต่อครั้งเท่านั้น ไม่อ่านจาก `.env`) — model server ของ session
  `aider-local` ใช้ `llama.cpp:server-cuda` build เดียวกับตัว CPU (b10991, pin digest) และได้
  `--gpus all` **เฉพาะ model container** agent ไม่ได้ device ใด ๆ
- หลัง health check CLI อ่าน log การโหลดของ server เองและต้องเห็น `offloaded N/N layers to GPU`
  ไม่งั้นหยุด model แล้วปฏิเสธ: image CUDA ที่มองไม่เห็น GPU จะพิมพ์ `no usable GPU found,
  --gpu-layers option will be ignored` แล้วขึ้น healthy และรันบน CPU เงียบ ๆ (ทดลองแล้ว) —
  เป็น "โหมด GPU" ที่ไม่ใช่ GPU แบบที่โปรเจกต์นี้ตามล่ามาตลอด
- เครื่องที่ Docker ส่ง `--gpus` ไม่ได้ → ปฏิเสธ **ก่อน** pull image CUDA หลาย GB;
  `WARDEN_MODEL_GPU` ที่ไม่ใช่ 0/1 หรือใช้โดยไม่มี `WARDEN_MODEL_MANIFEST` → ปฏิเสธ

### Tests

- phase **J** ใหม่: ตัวตัดสินกับบรรทัด log จริงของ b10991 (offload ครบ / CPU fallback / บางส่วน /
  ศูนย์), config guard, และแยกตามเครื่อง — มี GPU: session จริงผ่าน CLI (image CUDA pin, offload ครบ,
  agent ไม่มี device request, offline, hardening เดิม, ไม่เหลืออะไรค้าง); ไม่มี GPU (CI): ต้องปฏิเสธ
  โดยไม่สร้างอะไร อีกฝั่งพิมพ์ SKIP ไม่ใช่ PASS — **FAIL 3 ข้อกับโค้ด v1.1.0** (CLI เก่าเมิน
  `WARDEN_MODEL_GPU` แล้วรัน CPU พร้อมบอกว่า `local model ready`)
- ฝั่งไม่มี GPU ถูกรันบนเครื่องพัฒนาด้วย docker shim ที่ทำให้ `--gpus` ล้ม และ shim ที่ตัด `--gpus`
  ทิ้งเงียบ ๆ ก็พิสูจน์ guard บน CLI จริง: ปฏิเสธ rc=1 ไม่มีอะไรค้าง
- วัดจริงด้วย Qwen2.5-Coder-1.5B-Instruct `q8_0` ที่ ctx 8192 (ตารางใน README): CPU gen 11–14 tok/s,
  RAM สูงสุด 2.29 GB (เพดาน `4g` พอ); GPU (RTX 3050 4 GB) gen 54–71 tok/s, prompt 3060 tok/s,
  VRAM 1.95 GB; aider แก้บั๊กได้ทั้งสองโหมด

## [1.1.0] — 2026-09-26

**ฟีเจอร์: ใช้โมเดลของตัวเองในเครื่อง แบบ offline ล้วน**

### Added

- `WARDEN_MODEL_MANIFEST=<manifest.json> warden-cli.sh run <folder> aider-local` — aider คุยกับ
  llama.cpp server (`ghcr.io/ggml-org/llama.cpp:server` pin ด้วย digest) บน network `internal`
  ส่วนตัวของ session ที่มีแค่ agent + model: ไม่มี proxy ไม่มี route ออก ไม่มี cloud key ไม่มี
  `.env` ไฟล์ GGUF ต้องตรงกับ sha256 ใน manifest และ manifest ต้องอยู่นอก workspace ไม่งั้น
  exit 78 ก่อนสร้างอะไร model server รันเป็น 65534 / read-only / ไม่มี capability / ปิด web UI
  และ `/slots` และถูกลบพร้อม network ทุกทางออก (THREAT_MODEL §3.7, `.ai/design-local-model.md`)
- entrypoint: posture `WARDEN_EGRESS=none` — session ที่อ้างว่า offline ต้องพิสูจน์ว่า proxy และ
  route ตรงต่อไม่ได้ ไม่งั้น exit 78 (ไม่ขึ้นกับ `WARDEN_STRICT`)
- `warden-cli.sh stop` เก็บ model server และ network ที่ค้างจาก session ที่ถูก kill ด้วย

### Tests

- phase **I** ใหม่ 12 ข้อ ด้วยโมเดลสาธารณะ `stories260K.gguf` (1.2 MB, sha256 pin) ให้ CI รันได้:
  M0 (posture offline ทั้งสองทาง), M1, M2 (ไฟล์ถูกแก้ + manifest ใน workspace), M3, M4, M5
  (exit 0 และ 99 — ต้องเห็นว่า model เคยขึ้นจริง ไม่งั้นนับว่าผ่านแบบว่างเปล่า), M6, และ agent
  เรียกโมเดลได้ — **FAIL 5 ข้อกับโค้ด v1.0.6** แล้วผ่านทั้งหมด
- เส้นทางจริง: `aider-local` กับ GGUF ที่เทรนจาก notebook (SmolLM2-135M smoke) ได้คำตอบ,
  `egress: none`, ไม่เหลืออะไรค้าง; codex จริงบน image ใหม่ยังตอบได้และโดนฆ่า 99 เมื่ออ่าน honeypot

---

## [1.0.6] — 2026-09-26

**Integrity fix ของ audit trail ฝั่ง egress — ทุกคนควรอัปเกรด**

การเปลี่ยนแปลงทั้งหมดอยู่ใน `scripts/warden-cli.sh` (entrypoint กับ monitor เปลี่ยนแค่ version string)

### Fixed

- **audit trail ของ egress ตายเงียบได้** — `docker logs warden-egress-proxy` คือบันทึก request ขาออก
  ทุกตัว (README) แต่ถ้า Docker ปิดแบบไม่สะอาด ไฟล์ json log ของ proxy จะมี NUL byte ค้าง และหลังจากนั้น
  `docker logs` คืน**ไม่มีอะไรใหม่เลย** ทั้งที่ squid ยังเขียนอยู่และ proxy ยัง `healthy` — เครื่องทดสอบ
  เป็นแบบนี้มา **10 วัน** (NUL 519 byte หลัง 2026-09-16 16:01 UTC) พบเพราะ CONNECT ไป
  `api.openai.com` ที่ยิงเป็น control ไม่ขึ้นใน log `docker restart` ไม่ช่วย เพราะใช้ไฟล์เดิม
  ตอนนี้ `warden-cli.sh up` (และ `run` ซึ่งเรียก `up`) **พิสูจน์** ว่า trail มีชีวิต: เขียน nonce ลง stderr
  ของ proxy แล้วต้องอ่านกลับจาก `docker logs` ได้ ถ้าไม่ได้และไม่มี sandbox ใช้ proxy อยู่ → สร้าง proxy
  container ใหม่ (ได้ไฟล์ log ใหม่) แล้วพิสูจน์ซ้ำ ถ้ามี sandbox ใช้อยู่ → **ปฏิเสธ** (ไม่ตัด egress ของ
  session ที่กำลังรัน และไม่ยอมรันแบบไม่มี audit) `status` แสดง `audit trail live/DEAD` และ
  `logs proxy` เตือนเมื่อ output ถูกตัด

### Tests

- phase **H** ใหม่: ทำไฟล์ log ของ proxy เสียด้วย NUL แบบเดียวกับที่เจอจริง (เช็คก่อนว่าทำให้ trail ตายจริง)
  แล้ว H1 มี sandbox วิ่งอยู่ → `up` ต้อง exit ≠ 0 และไม่แตะ proxy, H2 ไม่มี sandbox → `up` ต้องสร้าง
  proxy ใหม่และ trail ต้องกลับมามีชีวิต — **FAIL ทั้งสองข้อกับโค้ด v1.0.5** (`up` ตอบ rc=0
  "already running")

---

## [1.0.5] — 2026-09-24

**Usability/trust fix ของ launcher — ผู้ใช้ที่รัน `codex` ด้วย API key ควรอัปเกรด**

การเปลี่ยนแปลงทั้งหมดอยู่ในสคริปต์ฝั่งโฮสต์ (ไม่มีการแก้ entrypoint หรือ monitor) เลื่อนออก tag
มาจนถึงวันนี้เพราะการ tag ต้อง rebuild image ซึ่งจะดึง agent CLI รุ่นใหม่ ตอนนั้นใกล้วันถ่ายเดโม
(เดโม 2026-09-21 ถูกเลื่อน จึง rebuild + ปล่อยได้แล้ว)

### Fixed

- **`warden-cli.sh run <folder> codex` ใช้งานไม่ได้จริงกับ API key** — codex-cli 0.154.0 ไม่อ่าน
  `OPENAI_API_KEY` จาก environment ("Not logged in" แล้ว 401 วนซ้ำ) และ sandbox ของ codex เอง
  (ต้องมี bubblewrap + user namespace) ทำงานไม่ได้ภายใต้ `--cap-drop=ALL`: ทุกคำสั่ง shell ล้ม
  "due to sandbox permissions" แต่ `codex exec` ยัง exit 0 ตอนนี้ launcher pipe key จาก
  environment เข้า `codex login --with-api-key` (ไม่ผ่าน argv) และเปิด codex ด้วย
  `-c sandbox_mode="danger-full-access"` อย่างชัดแจ้ง — AI Warden คือ sandbox (THREAT_MODEL §3.6)
- **`demo.sh` องก์ 4 ข้ามการส่งต่อ agent ทั้งที่มี key** — เช็คแค่ key ที่ `export` ไว้ ขณะที่ที่เก็บ key
  ที่แนะนำคือ `.env` และไม่มีการเช็คเลยสำหรับ codex ตอนนี้เช็คทั้งสองที่ (ไม่อ่านค่า) และ agent ที่
  ขอไว้ต้องพิสูจน์ว่า login + ตอบ `READY` ผ่าน sandbox ได้จริง ไม่อย่างนั้นองก์ 4 FAIL

### Tests

- phase **G** ใหม่: ด้วย key ปลอม launcher ต้อง login codex ได้ (`Logged in using an API key`) และเปิด
  codex ด้วย `sandbox_mode="danger-full-access"` — fail กับโค้ดก่อนแก้ (`Not logged in`)
- rebuild ของ release นี้ดึง **codex-cli 0.156.1** (จาก 0.154.0) จึงรันเส้นทางจริงซ้ำด้วย key จริง:
  login ผ่าน, `sandbox: danger-full-access`, คำสั่ง shell ทำงาน, และ codex ที่อ่าน honeypot ถูกฆ่า
  **exit 99** พร้อม report ของ sentinel (`attribution: restricted`, `warden_version: 1.0.5`)

### Docs

- runbook เดโมเปลี่ยนเป็น codex + `OPENAI_API_KEY` ใน `.env`, **ห้าม build ใหม่วันถ่าย**, และต้องรัน
  จาก Git Bash เท่านั้น (`bash` ใน PowerShell บนเครื่องทดสอบคือ WSL ไม่ใช่ Git Bash)
- `docs/THREAT_MODEL.md` §3.6 อธิบายว่าทำไม sandbox ของ codex ถูกปิดใน AI Warden

---

## [1.0.4] — 2026-09-16

**Forensic honesty fix — ควรอัปเกรด โดยเฉพาะก่อนโชว์/บันทึกวิดีโอ**

incident report บนดิสก์มักเป็นของ out-of-band sentinel (ชนะการแข่งเขียน) ซึ่งถือแค่
`CAP_KILL` จึงอ่าน `/proc/<pid>/fd` และ `/proc/<pid>/exe` ของ agent ไม่ได้ แต่รายงานไม่เคย
บอกเรื่องนี้ — process ที่ถือ fd ของ canary อยู่ออกมาเป็น `"canary named in argv"` โดย `exe`
ว่าง หรือถ้า argv ไม่มีชื่อ canary ก็เป็น `"suspects": []` ที่อ่านแล้วเหมือน "ไม่มีใครทำ"
ทั้งที่ inline monitor ใน breach เดียวกันเห็นหลักฐานครบ นี่คือ bug shape ประจำโปรเจกต์ในเวอร์ชัน
นิติวิทยา: control ที่รายงานว่าทำงาน แต่ไม่บอกอะไรมนุษย์เลย

### Fixed

- **รายงานระบุว่า attribution เชื่อได้แค่ไหน** — ทุก incident report มีฟิลด์ใหม่
  `attribution` (`complete` / `restricted` / `unavailable`) และ `attribution_note` ที่อธิบาย
  เป็นประโยค monitor นับ `EACCES`/`EPERM` ตอนอ่าน fd table และ exe link ของแต่ละ process
  (process ที่ออกไประหว่างสแกน = `ENOENT` ไม่นับ) sentinel จึงรายงาน `restricted` ตามจริง
  และ reader อายุสั้นอย่าง `cat` ได้ `unavailable` แทน list ว่างที่ไม่มีคำอธิบาย
  บรรทัด log `[SECURITY BREACH]` บอกสถานะเดียวกัน schema ยังเป็น `ai-warden/breach/1`
  (เพิ่มฟิลด์อย่างเดียว)
- **หลบการระบุตัวด้วย argv ปลอมเป็น warden ไม่ได้อีกแล้ว** — monitor ข้าม process ที่ argv มี
  marker ของ warden (`canary_monitor.py`, `/opt/warden/`, `warden-entrypoint`) เพื่อไม่ชี้ตัวเอง
  แต่ argv เป็นสิ่งที่ process ตั้งเองได้: ผู้อ่านที่ถือ canary ไว้ภายใต้
  `exec -a /opt/warden/canary_monitor.py sleep 25` หายไปจากการระบุตัวทั้งสอง monitor และ log
  บอกว่า "no process still holds the file open" ซึ่งเป็นเท็จ (พบระหว่างทดสอบ verdict ใหม่ผ่าน
  `warden-cli.sh run` — การควบคุมยังทำงาน exit 99) ตอนนี้ marker ปิดได้แค่ *เบาะแส argv*
  ส่วนหลักฐาน fd ตรวจทุก process และ process ที่ปลอมตัวถูกระบุเป็น
  `"open file descriptor (argv impersonates a warden process)"`
- **ไม่เปลี่ยน** ลำดับ/เวลาของ kill และ SIGUSR1 และ**ไม่เพิ่ม capability** ให้ sentinel —
  เหตุผลอยู่ใน `docs/THREAT_MODEL.md` §3.3

### Tests

- phase D (sentinel drill ผ่าน `warden-cli.sh run`) **fail ถ้า** รายงานของ sentinel ไม่มี
  `"attribution": "restricted"` — ตรวจแล้วว่า assertion นี้ fail กับ image v1.0.3 จริง
- phase **E5** ใหม่: ผู้อ่าน canary ที่ปลอม argv เป็น warden ต้องถูกควบคุม (99), ถูกระบุตัวด้วย fd
  และรายงานต้องไม่บอกว่าระบุตัวไม่ได้
- `scripts/demo.sh` act 3 ตรวจว่ารายงานมี attribution verdict ที่ใช้ได้

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
