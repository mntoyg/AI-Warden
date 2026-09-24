# AI Warden — Threat Model

เอกสารนี้ระบุอย่างชัดเจนว่า AI Warden ป้องกันอะไรได้ ป้องกันอะไรไม่ได้
และตัดสินใจแลกอะไรกับอะไรไว้บ้าง

---

## 1. Adversary model

**ผู้โจมตี** ที่สมมติไว้คือ **AI agent ที่ถูกยึดการควบคุม** — ไม่ใช่ AI ที่ "ชั่วร้ายโดยกำเนิด"
แต่เป็น agent ปกติที่ทำตามคำสั่งซึ่งฝังมาใน context ของมัน เช่น

- prompt injection ในไฟล์ `README.md`, comment ในโค้ด, หรือ issue บน GitHub
- dependency ที่ถูก compromise แล้ว post-install script รันคำสั่งเอง
- MCP server หรือ tool definition ที่ผู้โจมตีควบคุม
- คำสั่งที่ผู้ใช้เผลอ paste เข้ามาเอง

**ความสามารถของผู้โจมตี** — สมมติว่าเต็มที่ภายใน container:

| ทำได้ | ทำไม่ได้ (จากการออกแบบ) |
|---|---|
| รัน shell command ใด ๆ ในฐานะ uid 1001 | ยกสิทธิ์เป็น root |
| อ่าน/เขียนทุกไฟล์ใน `/workspace` | เห็นไฟล์นอก mount ของโฮสต์ |
| ติดตั้ง package จาก allowlist | ต่อ IP หรือโดเมนนอก allowlist |
| อ่าน environment variable ของตัวเอง (รวม API key) | เขียนทับ binary ของตัวเองใน `/usr/local/bin` |
| ฆ่า process ของ uid 1001 (รวม inline monitor) | แตะ sentinel ที่อยู่คนละ container |

**สิ่งที่ถือว่าเชื่อถือได้ (trusted computing base):**
Linux kernel, Docker daemon และ runtime, image ที่ build จาก repo นี้, และตัวโฮสต์เอง

---

## 2. ผลลัพธ์ที่ต้องไม่เกิดขึ้น

| # | ผลลัพธ์ | มาตรการหลัก | มาตรการรอง |
|---|---|---|---|
| T1 | อ่านคีย์/ข้อมูลลับของโฮสต์ | mount แค่โฟลเดอร์เดียว, `assert_safe_mount()` | canary tripwire |
| T2 | ยกสิทธิ์เป็น root ในกรง | `--cap-drop=ALL`, `no-new-privileges`, uid 1001 | ลบ setuid bit ทั้ง image, ไม่มี sudo |
| T3 | ส่งข้อมูลออกไปปลายทางที่ไม่อนุญาต | network `internal: true` | squid DENY ALL + allowlist |
| T4 | เปิด reverse shell | ไม่มี route ออก, บล็อกพอร์ตที่ไม่ใช่ 80/443 | บล็อก IP literal |
| T5 | ขยับด้านข้างไปยัง LAN / cloud metadata | บล็อก RFC1918 / link-local / metadata ที่ proxy | network `internal` ไม่มีทางไป |
| T6 | หลุดออกไปยังโฮสต์ | ไม่ mount Docker socket, posture check ปฏิเสธถ้าเจอ | แนะนำ rootless Docker / gVisor |
| T7 | ทำลายข้อมูลนอกโปรเจกต์ | `/workspace` คือขอบเขต filesystem ทั้งหมด | ทุกอย่างนอกนั้น read-only ต่อ uid 1001 |
| T8 | ปิดระบบตรวจจับเงียบ ๆ | sentinel แยก container คนละ namespace | entrypoint ตรวจ breach flag ตอนจบเสมอ |

---

## 3. การตัดสินใจแลกเปลี่ยนที่สำคัญ

### 3.1 ไม่ทำ SSL-bump ที่ proxy

**เลือก:** filter ที่ระดับ CONNECT host ปล่อย TLS ทะลุผ่าน ไม่แกะ

**เหตุผล:** การ bump ต้องติดตั้ง CA ของ warden ลงใน trust store ของ sandbox
ผลคือ proxy จะเห็น request body ทุกตัวเป็น cleartext — รวมทั้ง `x-api-key` ของ Anthropic,
`Authorization` ของ OpenAI และ token ของ GitHub
เท่ากับย้ายความลับทั้งหมดไปกองไว้ที่ component เดียว ซึ่งเป็นเป้าที่ใหญ่กว่าเดิม

**สิ่งที่เสียไป:** ตรวจ *เนื้อหา* ที่ส่งออกไม่ได้ ถ้า agent ได้รับอนุญาตให้คุยกับ
`api.anthropic.com` มันก็ส่งซอร์สโค้ดคุณไปในนั้นได้
allowlist ควบคุมได้แค่ "คุยกับใคร" ไม่ใช่ "คุยว่าอะไร"

**ถ้ายอมรับข้อแลกนี้ไม่ได้:** เพิ่ม `ssl_bump` ใน `squid.conf` และ inject CA ใน Dockerfile
แต่ต้องยอมรับว่า proxy กลายเป็นจุดรวมความลับ — และ squid ที่ image นี้ใช้ (Debian 5.7,
`--with-gnutls` ไม่มี `--with-openssl`) **ทำ ssl_bump ไม่ได้เลย** ต้องเปลี่ยน base image ก่อน

**ผลข้างเคียงที่ตามมาจริง:** การไม่เห็น SNI ทำให้ allowlist ถูก front ข้ามได้บน CDN ร่วม —
ดู §4.2 (ยืนยันด้วย exploit แล้ว)

### 3.2 inotify ผ่าน ctypes ไม่พึ่ง library ภายนอกเลย

**เลือก:** เรียก `inotify_init1` / `inotify_add_watch` ตรง ๆ ผ่าน `ctypes`

**เหตุผล:** เป้าหมายคือจับ *การอ่าน* ซึ่งให้ `IN_OPEN` / `IN_ACCESS`
แต่ inotify emitter ของ `watchdog` subscribe แค่ create / modify / delete / move
`cat secrets.json` จึงมองไม่เห็นเลย — `watchdog` แสดงความต้องการหลักของเครื่องมือนี้ไม่ได้
ผลพลอยได้คือ tripwire ไม่มี dependency นอก standard library เลยสักตัว
ซึ่งสำคัญเป็นพิเศษกับ component ที่มีหน้าที่เฝ้าระวัง

**ทางเลือกที่ดีกว่าแต่ใช้ไม่ได้:** `fanotify` ระบุ pid ที่เปิดไฟล์ได้แม่นยำในตัว
แต่ต้อง `CAP_SYS_ADMIN` ซึ่งขัดกับ T2 โดยตรง — จึงสืบย้อนจาก `/proc/*/fd` แทน
ซึ่งเป็น best-effort: ถ้า reader อายุสั้นมาก (`cat` แล้วจบ) จะสืบไม่เจอ
แต่ **การตรวจจับและการฆ่ายังทำงานครบ** — เสียแค่ความแม่นยำของการระบุตัว

### 3.3 canary tripwire สองชั้น

**ปัญหา:** monitor ที่อยู่ใน container เดียวกับ agent รันด้วย uid เดียวกัน
agent จึง `kill` มันได้ตรง ๆ — tripwire ชั้นเดียวจึงไม่ทนต่อผู้โจมตีที่รู้ตัว

**วิธีแก้:** `warden-canary-sentinel` เป็น container แยก
- `--network none` → ไม่มีทาง exfiltrate ผ่านตัวมันเอง
- `--cap-drop=ALL --cap-add=KILL` → capability เดียวในระบบทั้งหมด และให้เฉพาะ component ที่ต้องใช้
- แชร์ PID namespace กับ sandbox → ฆ่า process ของ agent ได้
- `--read-only` rootfs, mount แค่ workspace กับ canary vault
- agent (uid 1001, ไม่มี capability) ส่งสัญญาณหาไม่ได้ และ ptrace ไม่ได้

**ทำไมต้อง `--group-add 1001`:** root ที่ถูก `--cap-drop=ALL` **ไม่มี `CAP_DAC_OVERRIDE`**
จึงไม่ได้สิทธิ์ข้าม file permission เลยแม้แต่น้อย และ `inotify_add_watch()` ต้องการสิทธิ์
อ่านไฟล์ที่จะเฝ้า ตอนแรก sentinel จึงอ่าน canary โหมด `0400` ของ uid 1001 ไม่ได้
และได้ `enforced=0/5` เงียบ ๆ
vault จึงเป็น `0770` เจ้าของ `1001:1001` canary เป็น `0440` และ sentinel เข้าร่วมกลุ่ม 1001
— ใช้ group permission ธรรมดา ซึ่ง least-privilege กว่าการแจก `CAP_DAC_READ_SEARCH`
ที่จะทำให้ sentinel อ่านได้ทุกไฟล์ใน container ตัวเอง

**ทำไมต้องรันเป็น uid 0:** การส่งสัญญาณข้าม uid ต้องมี `CAP_KILL` อยู่ใน *effective set*
แต่ `--cap-add` ของ Docker ให้แค่ *bounding set* — process ที่ไม่ใช่ root จึงมี effective set ว่าง
และ `no-new-privileges` ก็ปิดทาง file capability ไปแล้ว
sentinel ที่รันเป็น uid 1002 จะได้ `EPERM` ตอนที่จำเป็นต้องฆ่าพอดี
ทางเลือกจึงเป็น "root ที่ถือ capability เดียว" ซึ่งแลกมาด้วยพื้นที่โจมตีที่กว้างขึ้นเล็กน้อย
แต่ container นี้ไม่มี network ไม่มี shell ที่รันอยู่ และ rootfs เป็น read-only

ถ้ารับข้อแลกนี้ไม่ได้ ให้เปลี่ยนเป็นโหมด audit อย่างเดียว: `--action=log` กับ `user: "1002:1002"`
และไม่ต้อง `cap_add` เลย — การ *บันทึก* breach ไม่ต้องใช้สิทธิ์ใด ๆ
แต่การฆ่าจะเหลือแค่ tripwire ใน container

**ข้อจำกัดที่เหลือ:** ถ้าปิด sentinel (`WARDEN_SENTINEL=0`) จะเหลือ tripwire ชั้นเดียว
และ entrypoint ยังตรวจ breach flag ตอนจบ session อยู่ แต่การฆ่าแบบทันทีจะหายไป

**sentinel ระบุตัวผู้อ่านได้ไม่ครบ — และรายงานบอกตรง ๆ (v1.0.4):** ด้วยเหตุผลเดียวกับข้างบน
(root ที่ไม่มี `CAP_DAC_OVERRIDE`/`CAP_SYS_PTRACE`) sentinel อ่าน `/proc/<pid>/fd` และ
`/proc/<pid>/exe` ของ process uid 1001 **ไม่ได้** จึงไม่เห็นหลักฐาน "ถือ file descriptor ของ
canary อยู่" และไม่รู้ path ของ exe เห็นได้แค่ argv ซึ่งเป็นแค่ *เบาะแส* ในทางปฏิบัติ sentinel
มักเป็นฝ่ายชนะการแข่งเขียน `WARDEN_SECURITY_INCIDENT.json` ดังนั้นรายงานบนดิสก์จึงมักเป็นมุมมอง
ที่แคบกว่าของ inline monitor ก่อน v1.0.4 รายงานไม่ได้บอกเรื่องนี้เลย: process ที่ถือ fd อยู่แต่ argv
ไม่มีชื่อ canary จะออกมาเป็น `"suspects": []` ซึ่งอ่านแล้วเหมือน "ไม่มีใครทำ"

ตั้งแต่ v1.0.4 ทุกรายงานมี `attribution` บอกว่า `suspects` เชื่อได้แค่ไหน

| `attribution` | ความหมาย |
|---|---|
| `complete` | monitor ตัวที่เขียนตรวจได้ทุก process — `suspects` คือทั้งหมดที่เห็น (fd = หลักฐาน, argv = เบาะแส) |
| `restricted` | ถูกปฏิเสธการอ่าน fd/exe ของ process อย่างน้อยหนึ่งตัว — `suspects` อาจไม่ครบหรือว่างทั้งที่มีคนถือ canary อยู่ (ปกติของ sentinel) มุมมองเต็มอยู่ในบรรทัด log `[SECURITY BREACH] suspect` ของ inline monitor |
| `unavailable` | ตรวจได้ทุก process แต่ไม่มีใครถือ canary หรือมีชื่อใน argv แล้ว — ผู้อ่านอายุสั้น (เช่น `cat`) หมายถึง "ระบุตัวไม่ได้" ไม่ใช่ "ไม่มีใครอ่าน" |

**ไม่แก้ด้วยการให้ `CAP_SYS_PTRACE` กับ sentinel** เพราะจะทำให้ชั้น anti-tamper อ่าน memory
และ fd ของทุก process ใน container ได้ และไม่แก้ด้วยการให้ sentinel "รอ" รายงานของ inline ก่อน
เพราะลำดับเวลาของ kill/SIGUSR1 ผูกกับ exit code 99 และการที่ PID 1 ออกจะฆ่า sentinel
(ซึ่งอยู่ใน PID namespace เดียวกัน) ก่อนมันได้เขียนรายงาน — การบอกข้อจำกัดตรง ๆ ปลอดภัยกว่า
การเพิ่ม race ใหม่ใน monitor

**argv เป็นเบาะแส ไม่ใช่ตัวตน:** monitor ไม่ชี้ process ของ warden เองด้วยการกรอง argv
(`canary_monitor.py`, `/opt/warden/`, `warden-entrypoint`) แต่ process ตั้ง argv เองได้
ก่อน v1.0.4 ตัวกรองนี้ข้าม process ทั้งตัว ผู้อ่านที่ `exec -a /opt/warden/canary_monitor.py`
จึงหายจากรายงาน ตอนนี้ตัวกรองปิดแค่เบาะแส argv ส่วนหลักฐาน fd ตรวจทุก process
(process ของ warden จริงไม่เคยถือ fd ของ canary — inotify watch ไม่เปิดไฟล์) และถูกระบุเป็น
`argv impersonates a warden process` (drill E5)

การระบุตัวไม่มีผลกับการ **ควบคุม** เลย: การ kill เลือกเป้าตาม uid ของ agent ไม่ใช่ตามรายชื่อ `suspects`
จึงทำงานเหมือนเดิมไม่ว่าจะระบุตัวได้หรือไม่ (กรณี PID 1 ออกแล้ว sentinel ตายตาม ตรวจด้วยการรันจริง:
container ที่ `--pid container:<A>` หายไปทันทีเมื่อ PID 1 ของ A ตาย)

### 3.4 canary payload ที่ scanner ไม่จับ

ค่าปลอมทุกตัวใส่ prefix จริงไว้ (`AKIA`, `sk_live_`, `ghp_`, `sk-ant-`)
แต่ตามด้วยตัวคั่นที่ charset ของผู้ให้บริการนั้นไม่อนุญาต
ทำให้ GitHub push protection, gitleaks และ trufflehog ไม่ alarm ทั้งใน repo นี้
และใน workspace ของผู้ใช้ที่เผลอ commit canary ติดไป

**ไม่กระทบการตรวจจับ:** tripwire ยิงตอน `IN_OPEN` คือ *ก่อน* ที่ผู้โจมตีจะอ่าน byte แรกด้วยซ้ำ
ความสมจริงของเนื้อไฟล์จึงไม่มีผลต่อการตรวจจับเลย

### 3.5 agent รันใน foreground ไม่ใช่ background

entrypoint รัน agent เป็น foreground process แทนที่จะ background แล้ว `wait`
เพราะ background job จะไม่ได้เป็นเจ้าของ controlling terminal — TUI อย่าง `claude`
และ `aider` จะโดน `SIGTTIN` ตอนอ่าน stdin และ Ctrl-C จะไม่ทำงาน

ผลข้างเคียงคือ entrypoint ไม่สามารถ "ฆ่า agent เอง" ได้ระหว่างที่รออยู่
จึงให้ monitor เป็นคนฆ่า process แล้วส่ง `SIGUSR1` มาที่ PID 1
(หมายเหตุ: kernel ป้องกัน PID 1 ใน namespace จาก signal ที่มี default action —
`SIGKILL` จากภายในจึงใช้ไม่ได้ ต้องเป็น signal ที่ PID 1 ดักไว้เองเท่านั้น)

### 3.6 codex: ปิด sandbox ของตัวมันเอง เพราะ AI Warden คือ sandbox

`codex` มี sandbox ของตัวเองสำหรับคำสั่ง shell ที่มันรัน ซึ่งต้องใช้ `bubblewrap` และ user
namespace ภายใต้ `--cap-drop=ALL` ของ AI Warden สิ่งนี้ใช้ไม่ได้ ทดสอบกับ codex-cli 0.154.0 (และยืนยันซ้ำกับ 0.156.1 ใน v1.0.5)
แล้วพบว่า **คำสั่ง shell ทุกคำสั่งล้ม "due to sandbox permissions" แต่ `codex exec` ยัง exit 0**
แปลว่า agent ดูเหมือนทำงาน แต่จริง ๆ ทำอะไรไม่ได้ ซึ่งเป็น bug shape เดียวกับที่โปรเจกต์นี้ตามล่า

`warden-cli.sh run <folder> codex` จึงเปิด codex ด้วย `-c sandbox_mode="danger-full-access"`
อย่างชัดแจ้ง ขอบเขตจริงคือ container ของ AI Warden (uid 1001, ไม่มี capability, mount
แค่ workspace, ออกเน็ตได้แค่ผ่าน allowlist, มี canary) ซึ่งเป็นสิ่งเดียวกับที่ `claude` และ
`aider` ได้อยู่แล้ว การขออนุมัติคำสั่ง (approval prompt) ของ codex ไม่ได้ถูกปิด

codex (0.154.0 และ 0.156.1) ไม่อ่าน `OPENAI_API_KEY` จาก environment ด้วย (ได้ "Not logged in" แล้ว 401 วนซ้ำ)
launcher จึง pipe key จาก environment เข้า `codex login --with-api-key` ก่อนเปิด —
key ไม่เคยอยู่บน argv (ที่ `ps` และ monitor อ่าน `/proc/<pid>/cmdline` ได้) และไฟล์ auth
อยู่ใน home ของ container ที่ถูกลบตอนจบ (`--rm`) ทั้งสองข้อตรวจโดย phase G ด้วย key ปลอม

---

## 4. สิ่งที่ AI Warden ป้องกันไม่ได้

### 4.1 Container escape ระดับ kernel
sandbox นี้ยืนอยู่บน Linux namespace ถ้ามี CVE ที่หลุดจาก namespace ได้ ก็จบ
**บรรเทา:** รัน rootless Docker (หลุดออกมาก็ไม่ได้ root ของโฮสต์),
ใช้ gVisor `--runtime=runsc` หรือ Kata Containers, และอัปเดต kernel สม่ำเสมอ

**รองรับใน tooling แล้ว:** ตั้ง `WARDEN_RUNTIME=runsc` (หรือ runtime อื่นที่ daemon
ลงทะเบียนไว้) แล้ว `warden-cli.sh` และ compose จะส่ง `--runtime` ให้ทั้ง agent และ
sentinel `assert_runtime` เช็คกับรายชื่อ runtime ของ daemon **ก่อน** สร้าง container
ถ้าไม่มี runtime นั้นจะ **ปฏิเสธที่จะเริ่ม** ไม่ตกไป runc เงียบ ๆ (phase F ใน
verify-isolation.sh พิสูจน์: fail-closed + ส่ง runtime ผ่านจริง e2e).
**ยังไม่ทดสอบบน gVisor จริง** — เครื่องพัฒนา/CI ยังไม่มี `runsc` ติดตั้ง จึงพิสูจน์ได้แค่
ว่า runtime ถูกส่งผ่านถูกต้อง (ใช้ runtime อื่นเป็น stand-in) ยังไม่ยืนยันว่า gVisor +
shared PID namespace ของ sentinel (`--pid container:`) ทำงานเข้ากันได้ — gVisor มี
ข้อจำกัดเรื่องนี้ ต้องรันบน host ที่มี gVisor เพื่อยืนยัน (Next-steps ใน HANDOFF)

### 4.2 การรั่วผ่านช่องทางที่อนุญาต
ดู §3.1 — allowlist ควบคุมปลายทาง ไม่ควบคุมเนื้อหา
**บรรเทา:** ให้ token ที่แคบที่สุด, ตัด `deb.debian.org` ออกถ้าไม่ต้องติดตั้ง OS package,
และอ่าน `make logs` เป็นระยะ

**ยืนยันแล้ว (2026-09-15): SNI domain fronting ข้าม allowlist ได้บน CDN ที่แชร์ IP.**
squid filter ที่ระดับ CONNECT host เท่านั้น (ไม่ทำ SSL-bump — §3.1) จึงเห็นแค่ชื่อในบรรทัด
CONNECT ไม่เห็น SNI/Host ที่อยู่ใน TLS agent จึง CONNECT ไปโฮสต์ที่อยู่ใน allowlist ซึ่งอยู่
บน CDN ร่วม แล้วตั้ง SNI เป็นโฮสต์อื่นบน CDN เดียวกัน เพื่อไปถึง origin ที่ไม่อยู่ใน allowlist
ได้ พิสูจน์จากในกรง:

```bash
# CONNECT ไป raw.githubusercontent.com (อยู่ใน allowlist, Fastly 185.199.108.0/22)
# แต่ TLS SNI/Host = octocat.github.io (ไม่อยู่ใน allowlist, Fastly เดียวกัน)
curl -x http://warden-egress-proxy:3128 \
     --connect-to octocat.github.io:443:raw.githubusercontent.com:443 \
     https://octocat.github.io/
# -> HTTP 200, <title>Octocat.github.io</title>  (ได้เนื้อหา origin ที่ไม่อนุญาต)
# squid access.log: TCP_TUNNEL/200 CONNECT raw.githubusercontent.com:443  (นึกว่าอนุญาตถูก)
# ขณะที่ CONNECT octocat.github.io:443 ตรง ๆ -> TCP_DENIED/403
```

ขอบเขตที่พิสูจน์: เข้าถึง `*.github.io` (GitHub Pages) ใด ๆ ได้ ทั้งที่ allowlist ตั้งใจให้แค่
raw content การ front ไปหา origin ของผู้โจมตีเองขึ้นกับว่า Fastly จัดผู้เช่ารายนั้นไว้ IP pool
เดียวกับ GitHub หรือไม่ (ไม่ทดสอบ เพื่อไม่ยิงบุคคลที่สาม) — แต่กลไก bypass เป็นจริง

**บรรเทา (เรียงตามความเข้ม):**
1. อย่าใส่โฮสต์บน CDN ร่วม (เช่น `.githubusercontent.com`) ถ้าต้องการ egress เข้ม — ทุก
   entry บน CDN ร่วมเปิดทางให้ front ไปทุก origin ที่ CDN นั้นเสิร์ฟบน IP เดียวกัน
2. ถ้าต้องใช้โฮสต์ CDN จริง ๆ ต้องกรองที่ระดับ **SNI**: squid ที่ build มากับ OpenSSL แล้วทำ
   peek-and-splice (`ssl_bump peek step1` + `acl … ssl::server_name` + splice/terminate) —
   อ่าน SNI จาก ClientHello โดย **ไม่ decrypt** payload จึงไม่ใช่ SSL-bump เต็มรูปแบบตาม §3.1
   **แต่ squid ของ Debian (5.7, `--with-gnutls` ไม่มี `--with-openssl`) ทำ ssl_bump ไม่ได้**
   (`squid -k parse` ตอบ `FATAL: Invalid ACL type 'at_step'`) ต้องเปลี่ยน base image หรือใช้
   egress ที่รู้จัก SNI (SNI proxy / L7 firewall) — เป็น **การตัดสินใจ** เพราะกระทบเส้น
   "ไม่ทำ SSL-bump" ใน §3.1 ไม่ใช่แค่แก้ config

### 4.3 โค้ดที่ agent เขียนแล้วเอาไปรันบนโฮสต์
กรงคุ้มครองแค่ตอน agent รันอยู่ข้างใน `git diff` ก่อน merge เสมอ
**บรรเทา:** ตั้ง pre-commit hook สแกน secret และ review diff ทุกครั้ง

### 4.4 Side channel และ resource exhaustion
`--memory`, `--cpus`, `--pids-limit` จำกัดผลกระทบไว้แล้ว แต่ไม่ได้ป้องกัน
timing side channel หรือการอ่านข้อมูลข้าม container บนโฮสต์เดียวกัน

### 4.5 inotify ใช้ไม่ได้บน bind mount ของ Docker Desktop

นี่คือข้อจำกัดที่ต้องอ่านให้จบ เพราะมันกระทบ canary โดยตรง

bind mount ของ Docker Desktop บน Windows/macOS ไม่ใช่ filesystem ปกติ
บน Windows มันคือ 9p/drvfs:

```
/workspace 9p rw,noatime,aname=drvfs;path=D:\;...
```

`inotify_add_watch()` บน path นี้ **คืนค่าสำเร็จ** แต่ **ไม่เคยส่ง event ออกมาเลย**
วัดมาแล้วในการทดสอบจริง: `/workspace/secrets.json` → `NO EVENTS`
ขณะที่ `/workspace/.secrets/credentials` (named volume บน ext4) และ `/home/ai_user/probe.txt` (overlayfs)
→ `OPEN|ACCESS(read)` ทั้งคู่
`noatime` ยังปิดทางเลือกสำรองอย่างการ poll atime ไปด้วย

**ผลกระทบ:** canary ที่วางไว้ใน bind mount ตรง ๆ (`/workspace/secrets.json`,
`/workspace/.env.vault`, `/workspace/.secrets.canary`) **บังคับใช้ไม่ได้บน Docker Desktop**
บน Linux ที่รัน Docker ตรง ๆ (ext4/xfs/overlayfs) canary เหล่านี้ทำงานครบ

**สิ่งที่ทำไว้แล้ว:**

1. **วัด ไม่เดา** — ตอน arm monitor สร้างไฟล์ probe ชั่วคราวในแต่ละไดเรกทอรี
   อ่านมันเอง แล้วดูว่ามี event มาไหม จากนั้นรายงานตรง ๆ ว่า path ไหน `watchable`
   path ไหน `DEGRADED` และสรุปเป็น `enforced=N/M`
   (ใช้ไฟล์ probe ไม่ใช่ canary จริง เพราะการอ่าน canary จะไปทริกเกอร์ monitor
   ตัวอื่นที่เฝ้าไฟล์เดียวกันอยู่คนละ container)

2. **มี canary ที่บังคับใช้ได้จริงในทุกแพลตฟอร์ม** — `/workspace/.secrets` เป็น
   **named volume** ที่ mount ทับลงไปในโฟลเดอร์โปรเจกต์ อยู่บน ext4 จริงในตัว VM
   จึงส่ง event ได้ตามปกติ
   เลือก named volume แทน tmpfs เพราะ tmpfs เป็นของ mount namespace เดียว
   sentinel ที่อยู่คนละ container จะมองไม่เห็น — named volume ให้ inode ชุดเดียวกัน
   กับทั้งสอง container และ inotify เฝ้าที่ inode ทั้งสองชั้นจึงเห็นเหตุการณ์เดียวกัน

3. **ยังมี canary ใน `$HOME` ของ container** ซึ่งอยู่บน overlayfs และทำงานได้เสมอ

**สิ่งที่ยังเหลือ:** canary ที่วางใน bind mount ตรง ๆ (3 ใน 7 path) ยังบังคับใช้ไม่ได้
บน Docker Desktop และ monitor จะรายงานตรง ๆ ว่า `enforced=4/7`
ทั้ง inline monitor และ sentinel เฝ้า vault ได้ทั้งคู่แล้ว บน Linux จะได้ `7/7`

---

## 5. Checklist ก่อนใช้งานจริง

- [ ] `./scripts/setup-host.sh --check` ผ่านทั้งหมด ไม่มี FAIL
- [ ] `./scripts/verify-isolation.sh` ผ่านครบ 3 เฟส
- [ ] `.env` เป็น mode 600 และไม่ถูก commit
- [ ] token ทุกตัวเป็นแบบ fine-grained จำกัด scope แคบที่สุด
- [ ] ทบทวน `whitelist_domains.txt` แล้ว ไม่มีโดเมนที่ relay traffic ได้
- [ ] `WARDEN_SENTINEL=1` (ค่าเริ่มต้น)
- [ ] ใช้ rootless Docker ถ้าสภาพแวดล้อมรองรับ
- [ ] มีขั้นตอน rotate key ที่พร้อมใช้เมื่อเจอ exit 99

---

## 6. รายงานช่องโหว่

เจอวิธีหลุดออกจากกรงนี้? เปิด issue ที่
<https://github.com/mntoyg/AI-Warden/issues> พร้อม reproduction ที่รันซ้ำได้
กรุณาอย่าใส่ข้อมูลลับจริงลงใน issue
