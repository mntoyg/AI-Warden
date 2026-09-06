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
