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
แต่ต้องยอมรับว่า proxy กลายเป็นจุดรวมความลับ

### 3.2 inotify ผ่าน ctypes แทน watchdog อย่างเดียว

**เลือก:** เรียก `inotify_init1` / `inotify_add_watch` ตรง ๆ ผ่าน `ctypes`

**เหตุผล:** เป้าหมายคือจับ *การอ่าน* ซึ่งให้ `IN_OPEN` / `IN_ACCESS`
แต่ inotify emitter ของ `watchdog` subscribe แค่ create / modify / delete / move
`cat secrets.json` จึงมองไม่เห็นเลยถ้าใช้ watchdog อย่างเดียว
`watchdog` ยังถูกติดตั้งไว้และใช้เป็น detector สำรอง แต่ไม่ใช่ทางหลัก

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
- `--read-only` rootfs, mount แค่ workspace
- agent (uid 1001, ไม่มี capability) ส่งสัญญาณหาไม่ได้ และ ptrace ไม่ได้

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

---

## 4. สิ่งที่ AI Warden ป้องกันไม่ได้

### 4.1 Container escape ระดับ kernel
sandbox นี้ยืนอยู่บน Linux namespace ถ้ามี CVE ที่หลุดจาก namespace ได้ ก็จบ
**บรรเทา:** รัน rootless Docker (หลุดออกมาก็ไม่ได้ root ของโฮสต์),
ใช้ gVisor `--runtime=runsc` หรือ Kata Containers, และอัปเดต kernel สม่ำเสมอ

### 4.2 การรั่วผ่านช่องทางที่อนุญาต
ดู §3.1 — allowlist ควบคุมปลายทาง ไม่ควบคุมเนื้อหา
**บรรเทา:** ให้ token ที่แคบที่สุด, ตัด `deb.debian.org` ออกถ้าไม่ต้องติดตั้ง OS package,
และอ่าน `make logs` เป็นระยะ

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
ขณะที่ `/workspace/.secrets/credentials` (tmpfs) และ `/home/ai_user/probe.txt` (overlayfs)
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

2. **มี canary ที่บังคับใช้ได้จริงในทุกแพลตฟอร์ม** — `/workspace/.secrets` ถูก mount เป็น
   tmpfs ทับลงไปในโฟลเดอร์โปรเจกต์ เป็น Linux filesystem แท้ ๆ ที่ส่ง event ได้
   canary ที่นั่นทำงานเหมือนกันหมดทุกที่

3. **ยังมี canary ใน `$HOME` ของ container** ซึ่งอยู่บน overlayfs และทำงานได้เสมอ

**สิ่งที่ยังเหลือ:** `warden-canary-sentinel` มองเห็น workspace ผ่าน bind mount เดียวกัน
บน Docker Desktop มันจึงเฝ้า canary ใน workspace ไม่ได้ (tmpfs ของ agent เป็นของ
mount namespace นั้นตัวเดียว) — sentinel จะรายงานสถานะ degraded ของตัวเองตอนเริ่ม
บน Linux sentinel ทำงานเต็มรูปแบบ

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
