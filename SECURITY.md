# Security Policy

> **English summary.** AI Warden is a sandbox for running autonomous AI coding
> agents. If you find a way out of it — a container escape, an egress-filter
> bypass, a way to disarm the canary tripwire, or a way to make it report itself
> armed while enforcing nothing — please open an issue at
> <https://github.com/mntoyg/AI-Warden/issues> with a reproduction. Do not
> include real credentials. Thai text follows.

---

## สิ่งที่นับว่าเป็นช่องโหว่

โปรเจกต์นี้อ้างสี่อย่าง อะไรก็ตามที่ทำให้ข้อใดข้อหนึ่งไม่จริงคือช่องโหว่:

1. **Host isolation** — agent เห็นได้แค่โฟลเดอร์ที่ mount ให้ ถ้ามีทางเข้าถึงไฟล์อื่น
   ของโฮสต์ หรือทางทำให้ `assert_safe_mount()` ยอม mount path ที่ควรปฏิเสธ
2. **Privilege containment** — ทางยกสิทธิ์เป็น root ในกรง หรือเรียก capability คืน
   หลัง `--cap-drop=ALL` + `no-new-privileges`
3. **Egress filtering** — ทางส่ง traffic ออกไปยังปลายทางที่ไม่อยู่ใน allowlist
   (รวมถึงเลี่ยงด้วย IP literal, DNS tunnel, พอร์ตที่ไม่ใช่ 80/443 หรือ relay)
4. **Canary tripwire** — ทางอ่าน canary โดยไม่ถูกจับ หรือปิดการทำงานของทั้งสองชั้น

### ชนิดที่ให้ความสำคัญสูงเป็นพิเศษ

**การรายงานเท็จว่าป้องกันอยู่** — บั๊กร้ายแรงที่สุดของโปรเจกต์นี้ทุกตัวที่ผ่านมา
เป็นแบบเดียวกันหมด: control ที่บอกว่า "armed" ทั้งที่ไม่ได้บังคับใช้อะไรเลย
(`inotify_add_watch()` สำเร็จบน 9p แล้วไม่เคยส่ง event, sentinel ที่ไม่มีสิทธิ์ฆ่า,
breach ที่จบด้วย exit 0) อะไรก็ตามที่ทำให้ AI Warden **ดูเหมือน** ทำงานทั้งที่ไม่ได้ทำ
ถือว่าร้ายแรงกว่าการที่มันล้มเหลวแบบส่งเสียงดัง

## สิ่งที่ **ไม่** นับ (ระบุไว้ตรง ๆ ใน [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md))

- **Container escape ระดับ kernel** — sandbox นี้ยืนบน Linux namespace
  ถ้ามี CVE ที่หลุดจาก namespace ได้ AI Warden หยุดไม่ได้ (ใช้ rootless Docker /
  gVisor เพิ่มถ้าต้องการชั้นนี้)
- **การรั่วผ่านช่องทางที่อนุญาตไว้เอง** — ถ้า agent คุยกับ `api.anthropic.com` ได้
  มันก็ส่งซอร์สโค้ดไปในนั้นได้ allowlist คุม "คุยกับใคร" ไม่ใช่ "คุยว่าอะไร"
  (จงใจไม่ทำ SSL-bump เพราะจะทำให้ proxy เห็น API key ทุกตัวเป็น cleartext)
- **โค้ดที่ agent เขียนแล้วคุณเอาไปรันบนโฮสต์** — อยู่นอกขอบเขตของกรง
- **canary ที่บังคับใช้ไม่ได้บน bind mount ของ Docker Desktop** — เป็นข้อจำกัดที่รู้อยู่
  ถูกวัดและรายงานเป็น `enforced=N/M` ตอนรัน ไม่ได้ปิดบัง

## วิธีรายงาน

เปิด issue ที่ <https://github.com/mntoyg/AI-Warden/issues> พร้อม:

- ขั้นตอน reproduce ที่รันซ้ำได้ (ควรเป็นคำสั่งที่รันใน `warden-cli.sh run ... bash`)
- ผลลัพธ์ของ `./scripts/verify-isolation.sh` บนเครื่องคุณ
- OS, Docker version, และผลของ `awk '$2=="/workspace"{print $3}' /proc/mounts` ในกรง

**อย่าใส่ credential จริงลงใน issue** — canary ทั้งหมดในโปรเจกต์นี้เป็นของปลอมโดยตั้งใจ
และตั้งใจให้ secret scanner ไม่จับด้วย

## เรื่อง CVE ของ dependency

`trivy` บนอิมเมจจะรายงาน HIGH/CRITICAL ประมาณ 70 รายการ — แทบทั้งหมดอยู่ใน
**dependency tree ของตัว agent เอง** (`litellm`, `GitPython`, `pillow` จาก aider,
และ `tar`/`minimatch` ที่ npm bundle มา) ไม่ใช่โค้ดของ AI Warden

**จุดยืน:** CVE เหล่านั้นไม่ได้ทำให้ sandbox อ่อนลง เพราะ threat model ตั้งต้นว่า
**agent รันโค้ดอะไรก็ได้ในฐานะ uid 1001 อยู่แล้ว** การกักกันมาจาก capability set,
ขอบเขต mount และ egress allowlist ซึ่ง package เหล่านั้นแตะไม่ได้เลยสักอย่าง
RCE ใน litellm ให้สิ่งที่ agent มีอยู่แล้ว

**สิ่งที่เรารับผิดชอบและ gate ไว้ใน CI:**

| ขอบเขต | นโยบาย |
|---|---|
| OS package ของทั้งสองอิมเมจ | HIGH/CRITICAL = build fail (ตอนนี้ **0**) |
| `/opt/warden/*` (โค้ดและ runtime ของ warden) | HIGH/CRITICAL = build fail (ตอนนี้ **0**) |
| dependency ของ agent ที่ bundle มา | รายงานให้เห็น ไม่ gate — เราไม่ได้คุม tree นั้น |

venv ของ warden สร้างด้วย `--without-pip` จึงไม่มี package manager ติดมาเลย
(ตัดทั้ง CVE ของ `pip`/`setuptools` และตัดเครื่องมือที่จะใช้ติดตั้งอะไรก็ตาม)
ตัว monitor import แต่ standard library

## ผลการ review ล่าสุด

audit เมื่อ 2026-09-06 แก้ไปแล้ว ทดสอบด้วย exploit จริงทุกข้อ:

- **Symlink redirection** — monitor เขียน incident report ลงไดเรกทอรีที่ agent เขียนได้
  agent วาง symlink ดักไว้ได้ และในโหมด sentinel คนเขียนคือ root
  แก้ด้วย `O_NOFOLLOW` ทุกจุดที่เขียน + **ยังเก็บหลักฐานไว้** ใต้ชื่อที่ agent เดาล่วงหน้าไม่ได้
  พร้อมบันทึก `report_path_tampered` (การพยายาม redirect เองก็คือหลักฐาน)
- **Log / terminal injection** — `/proc/<pid>/cmdline` เป็นข้อมูลที่ผู้โจมตีกำหนดเอง
  ตั้งชื่อ process ให้มี ANSI escape เพื่อลบบรรทัดจริงแล้วปลอมบรรทัด `[canary] all clear` ได้
  แก้ด้วยการกรอง control character ก่อนเข้ารายงานและก่อน log
- **Mount guard rails** — เพิ่ม `/home`, `/Users`, `/mnt`, `/media`, `/srv`, `/mnt/<drive>`
  และ `/cygdrive/<drive>` (เดิมจับแค่ `$HOME` กับ `/mnt/c`)
- **Dangling symlink บน path ของ canary** — `[ -e ]` มองไม่เห็น symlink ที่ชี้ไปที่ว่าง
  ทำให้ `cat >` เขียนทะลุไปยังปลายทาง เพิ่มการเช็ค `-L` ก่อน

## ก่อนใช้กับงานจริง

```bash
./scripts/setup-host.sh --check      # ต้องไม่มี FAIL
./scripts/verify-isolation.sh        # ต้องผ่านครบทั้ง 4 เฟส
./scripts/warden-cli.sh allowlist list   # ทบทวนเหมือนทบทวน firewall rule
```

ดู checklist เต็มที่ [docs/THREAT_MODEL.md §5](docs/THREAT_MODEL.md)

## เมื่อเจอ exit code 99

canary ถูกแตะ = ถือว่า session นั้นเป็นศัตรู:

1. rotate ทุก API key ที่ส่งเข้า session นั้น
2. อ่าน `<workspace>/WARDEN_SECURITY_INCIDENT.json`
3. `git diff` / `git log` ใน workspace ก่อนจะเชื่ออะไรที่ agent เขียนไว้
4. ตรวจ `./scripts/warden-cli.sh logs proxy` ว่ามันคุยกับที่ไหนไปบ้างก่อนโดนจับ
