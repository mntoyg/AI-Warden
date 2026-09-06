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
  [PASS] no direct TCP egress (the sandbox network is internal)
  [PASS] non-allowlisted host was blocked
  [PASS] IP-literal destination 1.1.1.1:443 refused
  [PASS] CONNECT to a non-443 port (github.com:22) refused
  [PASS] 7 canary token(s) seeded and in place

================= PHASE B: live breach drill ====================
  [SECURITY BREACH] Canary file accessed by Agent Process!
  PASS phase B: canary trip terminated the sandbox with exit 99

================= PHASE C: fail-closed drill ====================
  PASS phase C: the sandbox refused an unsafe launch posture

=========================== RESULT ==============================
  All phases passed. The sandbox is holding.
```

ตัวเลือก:

```bash
./scripts/verify-isolation.sh --keep         # เก็บ workspace ที่ใช้ทดสอบไว้ดู
./scripts/verify-isolation.sh --no-breach    # ข้ามเฟส B (เร็วขึ้น)
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
# /                overlay
# /workspace       <fs ของโฮสต์>
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

### 1.4 Canary tripwire

ก่อนอื่น ดูว่า path ไหน "บังคับใช้ได้จริง" บนเครื่องคุณ — monitor รายงานไว้ตอนเริ่ม container:

```
[canary] watchable  : /workspace/.secrets (tmpfs)  - inotify delivers events
[canary] *** DEGRADED : /workspace (9p) does NOT deliver inotify events.
[canary] watchable  : /home/ai_user/.aws (overlay) - inotify delivers events
[canary] v1.0.0 mode=inline action=kill enforced=4/7
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
| posture ไม่ครบ = ไม่ยอมเริ่ม | `docker run` โดยไม่ใส่ `--cap-drop` | exit `78` |
| ไม่มี proxy = ไม่ยอมเริ่ม | `docker stop warden-egress-proxy` แล้ว run | exit `78` |

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
