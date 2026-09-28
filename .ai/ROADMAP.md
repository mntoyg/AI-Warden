# AI Warden — แผนงานเป็น phase (เขียน 2026-09-28, session 12)

แผนนี้เรียงตามลำดับที่ควรทำ แต่ละ phase มี **เงื่อนไข "เสร็จ"** ที่ต้องรันจริงให้ผ่าน ไม่ใช่แค่เขียนโค้ดเสร็จ
(CLAUDE.md: *Done means run*) ถ้าเหตุผลของ phase ไหนไม่จริงแล้ว ให้ลบ phase นั้นทิ้งแทนที่จะทำต่อ
`.ai/HANDOFF.md` ยังคงเป็นที่เก็บสถานะปัจจุบัน ส่วนไฟล์นี้บอกทิศทาง

---

## Phase 0 — Demo ครั้งแรก (2026-09-29) · FREEZE

**เป้าหมาย:** อัดวิดีโอ 4 องก์บนเครื่อง Windows + Docker Desktop ด้วย **v1.2.5** (ไม่ rebuild)

| ขั้น | คำสั่ง / การกระทำ | เสร็จเมื่อ |
|---|---|---|
| เติมเครดิต OpenAI | (ผู้ใช้) | ข้อ 5 ด้านล่างไม่เจอ `Quota exceeded` |
| Pre-flight | `docs/DEMO.md` §1 ข้อ 1–6 | ทุกข้อผ่านตามคอลัมน์ Pass condition |
| ซ้อมอัตโนมัติ | `./scripts/demo.sh --auto --agent codex` | `READY` และ `DEMO COMPLETE` |
| ซ้อมแบบโต้ตอบ | `./scripts/demo.sh --agent codex` ใน Windows Terminal | องก์ 4 ส่งเทอร์มินัลให้ codex ได้, honeypot → exit 99 |
| พูดข้อจำกัดออกกล้อง | `docs/DEMO.md` §3 | รวมข้อใหม่: DNS exfiltration ใน v1.2.5 (แก้แล้ว รอ v1.2.6) |
| อัดจริง | `./scripts/demo.sh --agent codex` | วิดีโอ + บันทึกผลลงใน HANDOFF (อะไรผิดคาด) |

ห้ามในช่วงนี้: `build`, `build --pull`, merge branch ที่แก้ `core/` หรือ `scripts/` เข้า main

---

## Phase 1 — ออก v1.2.6 (security) · หลัง demo ทันที

**ทำไม:** v1.2.5 มีช่อง DNS exfiltration ผ่าน proxy (ยืนยันบน Squid 5.7 จริง) และ tripwire เงียบเมื่อคิว
inotify ล้น ตัวแก้อยู่บน branch `claude/wizardly-edison-9pzqzk` และผ่าน CI บน image จริงแล้ว
(run 36364368300; negative proof 36365091898)

| ขั้น | เสร็จเมื่อ |
|---|---|
| merge branch เข้า main, bump เป็น 1.2.6 (monitor, CLI, entrypoint, CHANGELOG) | `grep -rn 1.2.5` เหลือแต่ประวัติ |
| `./scripts/warden-cli.sh build --pull` บนเครื่อง Windows | build ผ่าน, จดเวอร์ชัน codex/claude/aider |
| path agent จริง: `warden-cli.sh run <ws> codex -- exec ...` + อ่าน honeypot | ตอบได้ และ honeypot → exit 99 |
| `./scripts/verify-isolation.sh` บน Docker Desktop | A–L ผ่าน exit 0, `enforced=4/7`, **3b2 ผ่าน** (ครั้งแรกที่เจอ DNS ของ Docker Desktop) |
| `docs/VERIFICATION.md` quote ใหม่จาก run เดียว | ตรวจทีละบรรทัดด้วยสคริปต์ |
| tag `v1.2.6` + release + superseded note บน v1.2.5 | CI เขียวบน tag, อ่าน release กลับมาตรวจ |
| ลบ branch ชั่วคราว `kata-probe`, `verify-s12` | `git ls-remote --heads origin` ไม่เหลือ |

---

## Phase 2 — ความซื่อตรงของรายงาน (ต้องตัดสินใจก่อน)

สองข้อนี้เป็นรูปแบบบั๊กประจำ ("บอกว่าทำงานทั้งที่ไม่ได้ทำ") แต่การแก้จะเปลี่ยนข้อความที่ผู้ใช้เห็น
จึงต้องให้ผู้ใช้ตัดสินใจก่อน (ถามด้วย AskUserQuestion พร้อมหลักฐาน)

1. **CLI เชื่อรายงานที่โผล่มาระหว่าง session** — agent เขียน `WARDEN_SECURITY_INCIDENT.json` เองแล้ว
   `kill -USR1 1` ได้ พาดหัวว่า "the canary tripwire terminated this sandbox" ข้อเสนอ: พาดหัวแบบนั้น
   เฉพาะเมื่อ sentinel ยืนยัน ที่เหลือบอกว่า "unconfirmed (written inside the agent's reach)"
   **เสร็จเมื่อ:** drill ใหม่ (เขียนก่อน, FAIL บนโค้ดเดิม) ผ่าน และ E7 ยังผ่าน
2. **probe ที่ตอบ "unknown" ถูกนับเป็น enforced** — ถ้า monitor เขียนไดเรกทอรีไม่ได้ มันไม่รู้ว่า
   inotify ส่ง event หรือไม่ แต่ยังนับ path นั้นใน `enforced=N/M` ข้อเสนอ: นับเป็น `unverified`
   ต้องวัดก่อนว่าบนโฮสต์ไหนเกิดจริง (sentinel บน Linux ที่ workspace เป็นของ uid อื่น?)
   **เสร็จเมื่อ:** มีการวัดทั้งสองทาง และ CI (`enforced=7/7`) ยังสอดคล้อง

---

## Phase 3 — Kata Containers

**สถานะ:** วัดแล้วบางส่วน (Kata 4.2.0 บน runner, `.ai/kata-probe.yml`): session ใช้ได้, sentinel บอก
`NOT armed` อย่างซื่อตรง, breach → 99 ที่ยังเหลือ:

| ขั้น | เสร็จเมื่อ |
|---|---|
| อ่านผล probe P1–P4 (DNS, `--pid`, inotify ข้าม container, pids) | ตารางใน THREAT_MODEL §4.1 แบบเดียวกับ gVisor |
| หาสาเหตุที่ suite ค้างใน phase I (aider-local) ใต้ Kata | รู้ว่าคำสั่งไหนค้าง และมี timeout |
| ตัดสินใจ: ประกาศรองรับ Kata แบบมีข้อจำกัด หรือไม่ | บันทึกใน HANDOFF "Decided" |

ข้อควรระวัง: ใน workflow ใช้ `rc=0; cmd || rc=$?` (steps รัน `bash -e`) และ `docker build -q` ให้ log สั้น

---

## Phase 4 — โมเดลที่เทรนเอง (รอผู้ใช้)

ขึ้นกับ GGUF จาก Colab (lab notebook) — ฝั่ง AI Warden เสร็จแล้ว (offline `aider-local`, GPU พิสูจน์ได้)
**เสร็จเมื่อ:** `WARDEN_MODEL_GPU=1 WARDEN_MODEL_MANIFEST=<manifest> ./scripts/warden-cli.sh run <ws> aider-local`
แก้งานจริงได้ และเทียบคำตอบกับ base model ใน `outputs/qwen-base/`

---

## Phase 5 — ไอเดียที่ยังต้องตัดสินใจ (ต่ำ)

- **witness แบบตรวจจับอย่างเดียวใต้ gVisor** — sentinel แบบ runc ข้าง agent ที่เป็น runsc ได้ยินการอ่าน canary
  แต่หยุดไม่ได้ ได้บันทึกที่ agent ปลอมไม่ได้กลับมา แลกกับการให้ sentinel อยู่นอกขอบ gVisor
- **mount guard สำหรับ `/media/<user>/<label>`** (udisks) — ต้องใช้ heuristic ว่าเป็น mountpoint หรือไม่
- **egress เข้มขึ้น** — SNI peek-and-splice (ต้องใช้ squid ที่ build กับ OpenSSL) ยังเป็นการตัดสินใจเรื่อง §3.1

---

## วิธีใช้ไฟล์นี้

- เริ่ม session: ดู phase แรกที่ยังไม่เสร็จ แล้วตรวจกับ HANDOFF Next steps (ถ้าขัดกัน HANDOFF ชนะ แล้วแก้ไฟล์นี้)
- จบ phase: ขีดทับด้วยวันที่ + run id ที่พิสูจน์ ไม่ลบ เพื่อให้เห็นประวัติ
