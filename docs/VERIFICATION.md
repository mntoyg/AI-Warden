# AI Warden — Verification Guide

เอกสารนี้บอกวิธี **พิสูจน์** ว่า sandbox ทำงานจริง ไม่ใช่แค่เชื่อตาม README
ทุกข้ออ้างในโปรเจกต์นี้มีวิธีทดสอบที่รันซ้ำได้กำกับไว้

---

## 0. รันทั้งชุดในคำสั่งเดียว

```bash
./scripts/verify-isolation.sh
```

ผลที่ควรได้:

```
================= PHASE A: in-sandbox self-test =================
  [PASS] running as unprivileged ai_user (uid 1001)
  [PASS] all Linux capabilities dropped (CapEff=0000000000000000)
  [PASS] capability bounding set is empty (no regain path)
  [PASS] no_new_privs is set (setuid escalation impossible)
  [PASS] no setuid binaries remain in the image
  ...
  [PASS] canary vault mounted on ext4 (an inotify-capable filesystem)
  [PASS] no direct TCP egress (the sandbox network is internal)
  [PASS] non-allowlisted http://example.com refused with 403
  [PASS] IP-literal destination 1.1.1.1:443 refused
  [PASS] CONNECT to a non-443 port (github.com:22) refused
  [PASS] 7 canary token(s) seeded and in place (checked with stat, never opened)
  [PASS] 4 canary path(s) are genuinely enforced (probed, not assumed)
  PASS phase A: every isolation assertion held

================= PHASE B: live breach drill ====================
[canary 2026-09-26T05:38:49Z] *** [SECURITY BREACH] Canary file accessed by Agent Process!
  PASS phase B: canary trip terminated the sandbox with exit 99
  PASS phase B: forensic incident report written to the workspace

================= PHASE C: fail-closed drill ====================
  PASS phase C: the sandbox refused an unsafe launch posture

================= PHASE D: sentinel drill =======================
  [drill] inline monitor killed; a sentinel monitor survives (root)
  PASS phase D: the sentinel contained a breach after the inline monitor was killed
  PASS phase D: the breach left a single clean incident report (no false tamper alarm from the race)
  PASS phase D: the sentinel's report says its attribution is restricted (no CAP_SYS_PTRACE) instead of implying it saw everything

================= PHASE E: audit regression drills ==============
  PASS phase E1: breach contained (99); report refused the symlink and was preserved as a tamper-tagged fallback
  PASS phase E2: breach contained (99) and the injected escape sequences were neutralised (?[2K) in the log
  PASS phase E3: every unsafe mount target was refused and a legitimate project dir was accepted
  PASS phase E4: the seeder refused to write through the dangling symlink (target never created)
  PASS phase E5: the impersonating reader was contained (99) and named by its open descriptor (attribution=complete)

=========== PHASE F: runtime fail-closed (gVisor plumbing) ==========
  PASS phase F: assert_runtime refuses an unknown runtime and accepts a valid one
  PASS phase F: Docker records the runtime it is handed (HostConfig.Runtime=runc)
  PASS phase F: warden-cli refused an unavailable WARDEN_RUNTIME and started no sandbox
  PASS phase F: warden-cli applies WARDEN_RUNTIME end-to-end (agent HostConfig.Runtime=nvidia)

================= PHASE G: agent launch (codex) ==================
  PASS phase G: warden-cli logs codex in from OPENAI_API_KEY and launches it with sandbox_mode=danger-full-access

================= PHASE H: egress audit trail ====================
  PASS phase H: with a sandbox running, 'up' refused a dead audit trail (rc=1) and left the proxy alone
  PASS phase H: 'up' detected the dead audit trail, recreated the proxy, and the new trail is live

============== PHASE I: local-model session (offline) ============
  PASS phase I (M0): WARDEN_EGRESS=none on a network that reaches the proxy refused to start (78)
  PASS phase I (M0): a truly offline session starts and says so (egress: none)
  PASS phase I (M1): agent and model are offline - neither reaches the proxy nor the internet
  PASS phase I (M3): no cloud API key reached the agent (host had three exported)
  PASS phase I (M4): the model server's web UI, /slots and POST /props are off
  PASS phase I (M6): model server runs as 65534, read-only, no capabilities, no-new-privileges
  PASS phase I: the agent reached the model over the private network (chat completion 200)
  PASS phase I (M5): a clean session (exit 0) left no model container or network behind
  PASS phase I (M5): a breach in a local-model session exits 99 and leaves nothing behind
  PASS phase I (M2): a model file that does not match its manifest sha256 was refused (78), nothing started
  PASS phase I (M2): a model manifest inside the workspace (agent-writable) was refused (78)
  PASS phase I: aider-local launches aider against http://warden-model:8080/v1, and refuses without a manifest

============== PHASE J: GPU model server (opt-in) ================
  PASS phase J: the offload verdict accepts a full GPU offload and rejects CPU fallback, partial and zero offload
  PASS phase J: WARDEN_MODEL_GPU without a local model, or not 0/1, is refused before anything starts
  PASS phase J: the model server runs the pinned CUDA image with a GPU and proved a full offload (offloaded 6/6)
  PASS phase J (M7): the GPU is handed to the model server only - the agent container has no device request
  PASS phase J (M6): the GPU model server keeps 65534, read-only, no capabilities, no-new-privileges
  PASS phase J (M1): a GPU session is still offline for agent and model, and the agent got an answer (200)
  PASS phase J (M5): the GPU session (exit 0) left no model container or network behind
    SKIP phase J: the no-GPU refusal (this host has a GPU; CI runs that side)

=========================== RESULT ==============================
  All phases passed. The sandbox is holding.
```

ตัวเลือก:

```bash
./scripts/verify-isolation.sh --keep         # เก็บ workspace ที่ใช้ทดสอบไว้ดู
./scripts/verify-isolation.sh --no-breach    # ข้ามทุกเฟสที่ต้องทำให้ container ตาย (B, D, E1, E2, E5, breach ใน I)
./scripts/verify-isolation.sh --no-sentinel  # ข้ามเฉพาะเฟส D (E1/E2 ยังรัน)
```

---

## 1. ทดสอบด้วยมือ

เปิด shell ในกรง:

```bash
./scripts/warden-cli.sh run ./workspaces/default bash
```

### 1.1 Privilege containment

```bash
id
# uid=1001(ai_user) gid=1001(ai_user) groups=1001(ai_user)
```

```bash
grep -E 'CapEff|CapBnd|NoNewPrivs' /proc/self/status
# CapEff:  0000000000000000
# CapBnd:  0000000000000000      <-- ค่านี้คือหลักฐานว่า --cap-drop=ALL ทำงาน
# NoNewPrivs: 1
```

> `CapEff` เป็น 0 อยู่แล้วสำหรับ process ที่ไม่ใช่ root **แม้จะไม่ได้ drop capability เลย**
> ค่าที่ต้องดูจริง ๆ คือ `CapBnd` ซึ่ง `--cap-drop=ALL` เป็นตัวเคลียร์

```bash
sudo -i                 # bash: sudo: command not found
su root                 # su: Authentication failure (และ setuid bit ถูกลบไปแล้ว)
find / -perm -4000 -type f 2>/dev/null | wc -l     # 0
echo x > /etc/passwd    # Permission denied
```

### 1.2 Host isolation

```bash
ls /workspace           # โปรเจกต์ของคุณเท่านั้น
ls ~/.ssh               # ไม่มีคีย์จริง (มีแต่ canary)
ls /root                # Permission denied
cat /etc/shadow         # Permission denied
ls /var/run/docker.sock # No such file or directory
```

ตรวจว่ามี bind mount เดียวจริง:

```bash
awk '$3 !~ /^(proc|sysfs|tmpfs|devpts|mqueue|cgroup2?|overlay|shm|devtmpfs)$/ {print $2, $3}' /proc/mounts
# /                    overlay
# /workspace           <fs ของโฮสต์ - 9p บน Docker Desktop>
# /workspace/.secrets  ext4   <- canary vault (named volume)
# /etc/hosts /etc/hostname /etc/resolv.conf  <- Docker ใส่ให้เองเสมอ
```

### 1.3 Egress filtering

```bash
# ไม่มี route ออกเน็ตเลย — ต้อง timeout/refused ทุกอัน
nc -z -w 3 1.1.1.1 443    ; echo "exit=$?"    # exit=1
nc -z -w 3 8.8.8.8 53     ; echo "exit=$?"    # exit=1
curl --noproxy '*' -m 5 https://example.com   # connection failed
```

```bash
# โดเมนที่ไม่อยู่ใน allowlist -> 403 จาก squid
curl -s -o /dev/null -w '%{http_code}\n' http://example.com/     # 403
curl -m 10 https://example.com/                                   # CONNECT ถูกปฏิเสธ
```

```bash
# IP ตรง ๆ ก็ไม่ผ่าน แม้จะเป็นพอร์ต 443
curl -m 10 https://1.1.1.1/                                       # ถูกปฏิเสธ
```

```bash
# พอร์ตอื่นที่ไม่ใช่ 80/443 ก็ไม่ผ่าน แม้โดเมนจะอยู่ใน allowlist
curl -m 10 https://github.com:22/                                 # ถูกปฏิเสธ
```

```bash
# โดเมนที่อยู่ใน allowlist ผ่านได้ (401 คือผ่าน — แค่ไม่มีคีย์)
curl -s -o /dev/null -w '%{http_code}\n' https://api.anthropic.com/v1/models
```

ดู audit trail ฝั่งโฮสต์พร้อมกัน:

```bash
./scripts/warden-cli.sh logs proxy -f
```

บรรทัด `TCP_DENIED/403` คือคำขอที่ถูกปฏิเสธ `TCP_TUNNEL/200` คือ CONNECT ที่อนุญาต

ความเงียบใน log นี้เป็นหลักฐานได้ก็ต่อเมื่อ trail ยังมีชีวิต: ถ้า Docker ปิดแบบไม่สะอาด ไฟล์ log ของ
proxy อาจมี NUL ค้าง แล้ว `docker logs` จะไม่คืนอะไรใหม่เลยทั้งที่ squid ยังเขียนอยู่ เช็คด้วย

```bash
./scripts/warden-cli.sh status     # แถว "audit trail" ต้องเป็น live
```

ถ้าขึ้น `DEAD` ให้รัน `./scripts/warden-cli.sh up` — มันจะสร้าง proxy ใหม่ (ถ้าไม่มี sandbox ใช้อยู่)
แล้วพิสูจน์ซ้ำ `run` ทำขั้นนี้ให้อัตโนมัติ (phase H ของชุดทดสอบ)

### 1.4 Canary tripwire

ก่อนอื่น ดูว่า path ไหน "บังคับใช้ได้จริง" บนเครื่องคุณ — monitor รายงานไว้ตอนเริ่ม container:

```
[canary] watchable  : /workspace/.secrets (ext4)   - inotify delivers events
[canary] *** DEGRADED : /workspace (9p) does NOT deliver inotify events.
[canary] watchable  : /home/ai_user/.aws (overlay) - inotify delivers events
[canary] v1.0.3 mode=inline action=kill enforced=4/7
[canary] *** 3 canary path(s) are NOT enforced on this host: /workspace/.secrets.canary, ...
```

บน Linux ที่รัน Docker ตรง ๆ จะได้ `enforced=7/7`
บน Docker Desktop (Windows/macOS) จะได้ `4/7` เพราะ bind mount เป็น 9p/virtiofs
ซึ่ง `inotify_add_watch()` สำเร็จแต่ไม่เคยส่ง event — รายละเอียดใน
[THREAT_MODEL.md §4.5](THREAT_MODEL.md)

> คำสั่งต่อไปนี้ **จะฆ่า container ของคุณทันที** — นั่นคือผลลัพธ์ที่ถูกต้อง

```bash
cat /workspace/.secrets/credentials
```

สิ่งที่จะเห็น (ผลจริงจากการทดสอบ):

```
[canary ...] *** [SECURITY BREACH] Canary file accessed by Agent Process!
[canary ...] *** [SECURITY BREACH] file=/workspace/.secrets/credentials event=OPEN mode=inline
[canary ...] *** [SECURITY BREACH] suspect pid=86 uid=1001 exe=/usr/bin/bash cmd='...'
[canary ...] *** [SECURITY BREACH] SIGKILL delivered to 2 process(es): [86, 88]
[canary ...] *** [SECURITY BREACH] SIGUSR1 sent to PID 1 - container will exit 99
```

ฝั่งโฮสต์:

```bash
echo $?     # 99
cat ./workspaces/default/WARDEN_SECURITY_INCIDENT.json
```

ทดสอบว่า tripwire จับ **การเขียนทับ** และ **การลบ** ด้วย (ทั้งสองอย่างคือการพยายาม disarm):

```bash
echo "x" > /workspace/.secrets/id_rsa      # trip
rm /home/ai_user/.aws/credentials          # trip
```

การ `stat` เฉย ๆ ต้องไม่ trip เพราะ `stat(2)` ไม่ได้ `open()`:

```bash
test -f /workspace/.secrets/credentials && echo "still alive"   # still alive
ls -la /workspace/.secrets                                       # still alive
```

ตรวจว่า filesystem ไหนส่ง inotify event ได้บ้างบนเครื่องคุณ:

```bash
awk '$2=="/workspace" || $2=="/workspace/.secrets" || $2=="/" {print $2, $3, $4}' /proc/mounts
```

---

## 2. ทดสอบ fail-closed

sandbox ต้อง **ปฏิเสธที่จะเริ่ม** ถ้า posture ไม่ครบ ไม่ใช่เริ่มแบบอ่อนแอเงียบ ๆ

```bash
# ตั้งใจไม่ใส่ --cap-drop=ALL และ no-new-privileges
docker run --rm --network warden_internal --user 1001:1001 \
  -v "$(pwd)/workspaces/default:/workspace" \
  ai-warden/agent:latest bash -c 'echo this must never run'
echo "exit=$?"   # exit=78
```

```bash
# ปิด egress proxy แล้วลองรัน — ต้องไม่ยอมเริ่มเช่นกัน
docker stop warden-egress-proxy
./scripts/warden-cli.sh run ./workspaces/default bash
# FATAL egress proxy warden-egress-proxy:3128 unreachable ... Failing closed.
docker start warden-egress-proxy
```

---

## 3. ตรวจ configuration แบบ static

```bash
make lint
```

ตรวจ:
- `shellcheck` ทุกสคริปต์ (fallback เป็น `bash -n` ถ้าไม่มี shellcheck)
- byte-compile `monitors/canary_monitor.py`
- `squid -k parse` ยืนยันว่า ruleset ถูกต้อง

ตรวจว่า allowlist ยังปิดท้ายด้วย default-deny:

```bash
grep -n 'http_access deny all' core/network/squid.conf
```

ดู allowlist ที่มีผลจริง:

```bash
./scripts/warden-cli.sh allowlist list
```

---

## 4. ตารางสรุป: ข้ออ้าง ↔ วิธีพิสูจน์

| ข้ออ้างใน README | คำสั่งพิสูจน์ | ผลที่ต้องได้ |
|---|---|---|
| รันเป็น unprivileged user | `id` | `uid=1001(ai_user)` |
| capability ถูก drop หมด | `grep CapBnd /proc/self/status` | `0000000000000000` |
| ยกสิทธิ์ไม่ได้ | `grep NoNewPrivs /proc/self/status` | `1` |
| ไม่มี setuid binary | `find / -perm -4000 -type f \| wc -l` | `0` |
| เห็นแค่โฟลเดอร์เดียว | `cat /proc/mounts` | มี bind เดียวคือ `/workspace` |
| ไม่มี Docker socket | `ls /var/run/docker.sock` | No such file |
| ไม่มี route ออกเน็ต | `nc -z -w3 1.1.1.1 443` | exit 1 |
| โดเมนนอก allowlist ถูกบล็อก | `curl -w '%{http_code}' http://example.com/` | `403` |
| IP ตรง ๆ ถูกบล็อก | `curl -m10 https://1.1.1.1/` | failed |
| พอร์ตนอก 80/443 ถูกบล็อก | `curl -m10 https://github.com:22/` | failed |
| โดเมนใน allowlist ใช้ได้ | `curl -w '%{http_code}' https://api.anthropic.com/v1/models` | `401` (หรือ 2xx/4xx อื่น) |
| canary ฆ่า container | `cat /workspace/.secrets/credentials` | container exit `99` |
| tripwire รายงานความสามารถจริง | ดูบรรทัด `enforced=N/M` ตอนเริ่ม | ตรงกับ filesystem ของเครื่อง |
| sentinel ยังทำงานแม้ inline monitor ถูกฆ่า | `pkill -9 -f 'canary_mon[i]tor'` แล้วอ่าน canary | sentinel ฆ่า container (`mode=sentinel`) |
| posture ไม่ครบ = ไม่ยอมเริ่ม | `docker run` โดยไม่ใส่ `--cap-drop` | exit `78` |
| ไม่มี proxy = ไม่ยอมเริ่ม | `docker stop warden-egress-proxy` แล้ว run | exit `78` |
| รายงานเหตุ redirect ผ่าน symlink ไม่ได้ (E1) | วาง symlink ที่ `WARDEN_SECURITY_INCIDENT.json` แล้ว trip canary | exit `99` + มี fallback ที่ติด `report_path_tampered` |
| ชื่อ process ปลอมไม่ทำลาย forensic log (E2) | ตั้ง `argv[0]` เป็น escape sequence แล้ว trip canary | บรรทัด suspect เป็น `?[2K` (ไม่ใช่ ESC ดิบ) |
| mount guard ปฏิเสธ path อันตราย (E3) | source `assert_safe_mount` แล้วป้อน `/ /etc /home /mnt/c ...` | refuse ทุกอัน; project dir ปกติ accept |
| seeding ไม่เขียนทะลุ dangling symlink (E4) | วาง symlink ค้างที่ path ของ canary แล้ว seed | target ปลายทางไม่ถูกสร้าง |
| ปลอม argv เป็น warden หลบการระบุตัวไม่ได้ (E5) | `exec -a /opt/warden/canary_monitor.py python3 -c "f = open(...canary...)"` | exit `99` + suspect `argv impersonates a warden process` |
| รายงานบอกว่ามองเห็นได้แค่ไหน (D) | ฆ่า inline monitor แล้วอ่าน canary ผ่าน `warden-cli.sh run` | report `"mode": "sentinel"` + `"attribution": "restricted"` |
| codex ใช้ได้จริงใน sandbox (G) | `OPENAI_API_KEY=<fake> warden-cli.sh run <dir> codex -- login status` | `Logged in using an API key` + บรรทัด launching มี `sandbox_mode="danger-full-access"` |
| โหมด GPU ไม่ตกไป CPU เงียบ ๆ (J) | `WARDEN_MODEL_GPU=1 WARDEN_MODEL_MANIFEST=<m> warden-cli.sh run <dir> aider-local` | มี GPU: `local model ready: ... on GPU (offloaded N/N layers)`; ไม่มี GPU หรือ offload ไม่ครบ: ปฏิเสธ ไม่มีอะไรค้าง |

---

## 5. รหัส exit ที่ใช้

| Code | ความหมาย |
|---|---|
| `0` | agent จบงานปกติ |
| `78` | posture check ล้มเหลว — sandbox ปฏิเสธที่จะเริ่ม (fail closed) |
| `99` | **SECURITY BREACH** — canary ถูกแตะ sandbox ถูกสั่งจบ |
| `143` | ได้รับ SIGTERM (`docker stop`) |
| อื่น ๆ | exit code ของ agent เอง |

**เจอ 99 เมื่อไหร่ ให้ถือว่า session นั้นเป็นศัตรู:** rotate ทุก API key ที่ส่งเข้าไปใน session นั้น
ตรวจ `git log`/`git diff` ของ workspace และอ่าน `WARDEN_SECURITY_INCIDENT.json` ประกอบ
