# Progress log

บันทึกสิ่งที่ทำจริงในแต่ละวัน แบบย่อ — รายละเอียดเต็มอยู่ใน [`.ai/HANDOFF.md`](.ai/HANDOFF.md)
(Status / Next steps / Gotchas / Session log) และ [`CHANGELOG.md`](CHANGELOG.md)
เอกสารนี้เป็นสรุปสำหรับอ่านไว ๆ ไม่ใช่แหล่งความจริง — ถ้าขัดกับ git/CI ให้เชื่อ git/CI

---

## 2026-10-10 · session 16 (Windows box) — mount guard: ปฏิเสธ volume ของสื่อถอดได้ทั้งลูก

### 🔴 ค้างอยู่ตรงนี้ — ทำต่อคืนนี้ (RESUME HERE)

**v1.2.11 อยู่บน `main` แล้ว (merge PR #10, commit `e0b93f6`) แต่ยัง "ไม่ได้ตัด tag"** — เป็น
**security fix** จึงต้องปล่อยเป็น release ตามกฎของโปรเจกต์ ("security fixes sitting on main ship to nobody")
ขั้นตอนที่เหลือ ตามลำดับ:

1. รอ/เช็ก CI ของ push บน main ให้เขียวครบ 5 job ก่อน — `gh run view 38032013326 --json jobs`
   (ตอนหยุด: static ผ่านแล้ว, ext4/gVisor/Kata/CVE ยังรัน; PR #10 เขียวครบ 5 job มาแล้วบน commit เดียวกัน)
2. `git tag -a v1.2.11 -F <ข้อความ>` แล้ว `git push origin v1.2.11` (ร่างข้อความได้จาก CHANGELOG `[1.2.11]`
   ซึ่งเขียนครบแล้ว — ภาษาไทย + คำสั่ง/ผลลัพธ์อังกฤษ)
3. `gh release create v1.2.11 --latest` พร้อม notes (ดู CHANGELOG `[1.2.11]` และ `docs/THREAT_MODEL.md` §3.8)
4. **ติด superseded note บน release v1.2.10** — รอบนี้เป็น security fix จริง ต่างจาก v1.2.9/v1.2.10
   ที่เป็น verification + docs (สองตัวนั้น**ไม่ต้อง**ติด)
5. รอ CI ของ tag ให้เขียว แล้วปิดงาน: อัปเดต `.ai/HANDOFF.md` (Status/Tags/Session log) + `progress.md`
   + rewrite `.ai/NEXT_PROMPT.md` (v22, bump + log ใน HANDOFF §8)

### ทำอะไรไปแล้ว

- **ช่องที่เจอ:** `assert_safe_mount()` ดูแค่ *ชื่อ* ของ parent จึงจับได้แค่ `/media/<label>` แต่ udisks
  auto-mount ลึกกว่านั้นหนึ่งชั้น (`/media/<user>/<label>`) parent ของมันคือ `/media/alice` ซึ่งไม่ตรงกฎใด ๆ
  → **mount USB stick / ดิสก์ภายนอกทั้งลูกเข้า sandbox ได้เงียบ ๆ** และ macOS ไม่เคยถูกครอบเลย
  (`/Volumes` และ `/Volumes/<label>`)
- **ทางแก้:** ชื่อพาธบอกไม่ได้ว่าอะไรคือ volume จึงถาม kernel — `is_mount_point()` (`mountpoint -q`
  ถ้ามี, ไม่มีก็เทียบ device number กับ parent ด้วย `stat -c %d` / BSD `stat -f %d`) ถ้าพาธอยู่ใต้
  `/media`, `/run/media`, `/cygdrive`, `/Volumes` **และเป็น mountpoint ของตัวเอง** → ปฏิเสธ
  พร้อมบอกทางออก; เพิ่ม `/Volumes` เข้ารายการ shared parent + กฎ parent ของไดรฟ์
- **ไม่ปฏิเสธเหมารวม:** `/media/alice/USB-STICK/project` และ `/media/alice/notes` (ไม่ใช่ mountpoint)
  ยัง mount ได้ — เป็น accept-test ใน drill; `/data` ที่มีดิสก์ของตัวเอง (mountpoint นอก media prefix) ก็ผ่าน
- **drill E3 ขยาย:** mount tmpfs จริง 3 ลูก และ**ยืนยันว่าเป็น mountpoint ก่อนทดสอบ**
  พิสูจน์ย้อนทางบนโค้ดเก่าแล้ว: `LEAK:/Volumes`, `LEAK:/media/alice/USB-STICK`,
  `LEAK:/run/media/bob/DATA`, `LEAK:/Volumes/BACKUP` → 4 ปัญหา, ไม่มี `SETUP:`, ไม่มี `REGRESSION:`
- **CI รอบแรกของ PR #10 แดงทั้ง 3 drill job — และ drill แดงถูกต้อง:** positive control นับเป็น 3 ปัญหา
  เพราะ tmpfs mount ไม่ติดบน runner `--cap-add SYS_ADMIN` **ไม่พอ** บนโฮสต์ที่มี **AppArmor**
  (profile `docker-default` ปฏิเสธ `mount` ตรง ๆ) ซึ่งเป็นเหตุผลที่ผ่านบน Docker Desktop (WSL2 ไม่มี AppArmor)
  → เพิ่ม `--security-opt apparmor=unconfined` ให้ container ของ **drill** (ไม่ใช่ sandbox),
  ให้ drill พิมพ์เหตุผลที่ `mount` เฟล, และแก้บรรทัดรายงานของ E3 ให้โชว์ `SETUP:` ไม่ใช่ซ่อนไว้
- **หลักฐาน:** local suite **A–M exit 0** บน v1.2.11 (60 PASS, `enforced=4/7`, SKIP เดียวคือฝั่ง no-GPU
  ของ phase J) · PR #10 **เขียวครบ 5 job** (E3 ผ่านบนเคอร์เนล Linux แท้ทั้ง ext4/gVisor/Kata) ·
  shellcheck clean · branch `mount-guard-removable-volume` ลบแล้ว
- เอกสารที่อัปเดตแล้ว: `CHANGELOG.md` `[1.2.11]`, `docs/THREAT_MODEL.md` **§3.8** (กฎทั้งชุด + ช่องที่ปิด +
  ตาราง 4 กรณี + ข้อจำกัดที่ยอมรับ) และแถว T1 ชี้ไปที่มัน, README (ส่วน Host Isolation + แถว phase E),
  `docs/DEMO.md`

### ติดฝั่งผู้ใช้ (ถามแล้ว 2026-10-10 — ยังเหมือนเดิมทั้งสาม)
ไม่มีวันถ่าย demo · เครดิต OpenAI ยังไม่เติม · Colab ยังไม่ได้รัน (เครื่องนี้มีแค่ GGUF base)

---

## 2026-10-08 · session 15 (Windows box) — เลิกเชื่อ label เรื่องเพดานทรัพยากร

ปล่อย 2 release: **v1.2.9** และ **v1.2.10** (ทั้งคู่เป็น verification + docs ไม่ใช่ security fix
จึง **ไม่** มี superseded note บน v1.2.8/v1.2.9)

### โจทย์ตั้งต้น
Next steps #0 ค้างคำถามจาก session 13 ไว้ว่า "`--memory` ใต้ Kata ยังไม่ถูกวัด" — และ phase A
ตอบไม่ได้ เพราะมันแค่ *อ่าน* `/sys/fs/cgroup/memory.max` แล้วบอกว่า `memory is capped`
ซึ่งคือ **รูปทรงบั๊กประจำของโปรเจกต์นี้**: ตัวควบคุมที่รายงานว่าตัวเอง armed ทั้งที่ไม่ได้บังคับอะไร

### ทำอะไร
1. **phase M ใหม่** (`scripts/drill-alloc-memory.py`) — จองหน่วยความจำทะลุ `--memory` ทีละ 16 MiB
   และ **แตะทุกหน้า** (`bytearray(n)` อาจไม่แตะจริง) บรรทัด `alloc N MiB` สุดท้ายคือผลวัด เพราะ cgroup
   ฆ่าด้วย SIGKILL — process ไม่มีโอกาสรายงานการตายของตัวเอง ใบ **ไม่มี cap รันก่อน** เป็น positive control
2. **พิสูจน์ย้อนทางก่อนเสมอ** (scratch harness เฉพาะ phase M): ถอด cap ออก → capped 768 MiB,
   `exit=0 OOMKilled=false`, `memory.max=max` → **FAIL, exit 1**; ใส่ cap → 240 MiB,
   `exit=137 OOMKilled=true` → PASS
3. **วัดบน runtime ที่เครื่องนี้รันไม่ได้** ผ่าน branch ชั่วคราว `kata-memcap-probe`
   (run 37749560187, 37751167935 — เขียวครบ 5 job ทั้งสองรอบ) แล้วลบ branch ทิ้ง
4. **ship v1.2.9**: bump เวอร์ชัน **ก่อน** → rebuild จาก cache (ไม่ `--pull`, CLI ไม่ขยับ) → รัน suite
   A–M ใหม่บน label ใหม่ → รอ CI บน main เขียว → tag + release
5. **ขยาย phase M ให้ครบ resource section** (`scripts/drill-fork-count.py`) — swap + จำนวน process
   ส่งผ่าน **PR #9** (ไม่ต้องแก้ ci.yml เลย: `pull_request` รันทั้ง 5 job อยู่แล้ว) → merge → **ship v1.2.10**

### ผลที่วัดได้ (ของจริง ไม่ใช่ label)

| วัด | runc (Docker Desktop) | gVisor (CI) | Kata (CI) |
|---|---|---|---|
| `--memory 256m` ใช้ได้จริง | 240 MiB | 208–224 MiB | **144 MiB** |
| `--memory 1024m` ใช้ได้จริง | 1008 MiB | 976 MiB | 896 MiB |
| overhead | ~16 MiB | ~48 MiB | ~112–128 MiB (**คงที่** ไม่ใช่สัดส่วน) |
| `.State.OOMKilled` ตอน cap ฆ่า | `true` | `true` | **`false`** |
| `memory.max` ในกรง | ตรงกับ cap | **ไม่มีไฟล์เลย** | ตรงกับ cap |
| `--ulimit nproc=64` | 63 แล้ว EAGAIN | 63 | 63 |
| `--pids-limit 64` | 63 (`pids.max=64`) | SKIP (นับ host task) | SKIP (ไม่บังคับใน guest) |

เรื่องที่โป๊ะเพิ่ม 4 ข้อ (เขียนลง `docs/THREAT_MODEL.md` §4.1/§4.4 แล้ว):

- **`--memory` บังคับจริงใต้ Kata** → ปิดคำถามที่ค้างจาก session 13 Kata ตั้งขนาด VM = cap + 32 MiB
  (`-m 288M` เมื่อ cap 256m, `-m 1056M` เมื่อ 1024m, ไม่ใส่ cap ได้ `-m 2G` ซึ่งเป็น default ของ Kata)
  เพราะ overhead คงที่ เพดาน default `4g` ของ CLI จึงยังเหลือให้ agent ~3.9 GiB
- **ใต้ Kata `exit=137` แต่ `OOMKilled=false`** — guest kernel เป็นคนฆ่า โฮสต์ไม่เห็น
  **ห้ามตัดสินว่าเป็น OOM จาก flag นี้**
- **ใต้ gVisor ไม่มี `/sys/fs/cgroup/memory.max` ในกรงเลย** phase A จึงได้แค่ `skip` —
  การวัดจากข้างนอกเป็นหลักฐานเดียวที่พิสูจน์ได้
- **swap เป็นช่องเลี่ยงจริง**: `--memory 256m --memory-swap 512m` จองได้ **496 MiB** (เทียบ 240 MiB
  เมื่อตั้งเท่ากัน) → สิ่งที่กั้นคือการตั้งสองค่าให้ **เท่ากัน** ไม่ใช่ตัว label `memory.swap.max=0`

### รอบที่ CI แดงแล้วได้กำไร
PR #9 รอบแรกทำให้ job ext4 แดง: `--ulimit nproc=64` ด้วย uid 1001 บน runner ได้ `exit=255`, fork 0
(python ไม่ได้สตาร์ตเลย) ขณะที่ gVisor/Kata ผ่าน วัดต่อจนได้คำตอบ:

- runner ของ GitHub **รัน job เป็น uid 1001 เอง** → เพดานเดียวกันให้ uid 4242 fork 63 แต่ uid 1001 ได้แค่ **4**
- บน Docker Desktop: 100 process ของ uid 1001 ใน container อื่น **ไม่ถูกนับ** (fork 63 ตามปกติ)
- สรุป: `RLIMIT_NPROC` เป็นงบของ uid และ**ขอบเขตการนับขึ้นกับโฮสต์** ทิศทางคือ "แน่นกว่าที่ขอ"
  ไม่ใช่หลวมกว่า และเพดานจริงของ CLI (`nproc=512`) เหลือ headroom พอ — มีแค่เลข 64 ของ drill ที่ไปชน
- แก้: วัด *กลไก* ด้วย uid ที่ไม่มีใครใช้ (4242) + ยิง uid 1001 ซ้ำแบบ **note อย่างเดียว**
  และเพิ่ม guard ว่า "probe ไม่ได้รันเลย" ต้องรายงานว่า **วัดไม่ได้** ไม่ใช่ปล่อยให้ดูเหมือนเพดานทำงาน
- สมมติฐานแรกของผมผิด และการทดสอบรอบแรก (target 20 < cap 64) เล็กเกินกว่าจะแยกแยะ — เสียเวลา ~10 นาที
  สิ่งที่กู้ไว้คือลงมือทดลองด้วยมือ ไม่ใช่เดาต่อ

### หลักฐาน (done means run)
- Local, Docker Desktop: `verify-isolation.sh` **A–M exit 0** ทั้ง v1.2.9 และ v1.2.10
  (v1.2.10: 60 PASS, self-test 35/35, `enforced=4/7`, SKIP เดียวคือฝั่ง no-GPU ของ phase J)
- CI เขียวครบ 5 job: PR #9 (37764437022), push บน main (37753123954, 37768546207), tag v1.2.9
- README เคยบอก "11 เฟส" และตารางหยุดที่ **K** (phase L จาก v1.2.6 ไม่เคยถูกเพิ่ม) → แก้เป็น 13 เฟส ครบ L และ M

### ค้างอยู่ / ติดฝั่งผู้ใช้ (ถามแล้ววันนี้)
- **วันถ่าย demo:** ยังไม่มีวัน (ยังไม่ freeze อะไร)
- **เครดิต OpenAI:** ยังไม่เติม → demo act 4 (codex) และ real-codex path ยัง block (`Quota exceeded`)
- **`notebook/train.ipynb` บน Colab:** ยังไม่ได้รัน (ตรวจเองแล้ว: `D:\code-project\warden-model-lab`
  มีแค่ GGUF **base** ที่ไม่ได้ fine-tune จาก 26 ก.ย. ไม่มี `manifest/` ไม่มีไฟล์ใหม่เดือน ต.ค.)
- งานต่อที่เหลือใน Next steps #0: **detect-only runc witness ใต้ Kata** (ยังเป็น "ideas, decide first")
- prompt สำหรับแชทใหม่: [`.ai/NEXT_PROMPT.md`](.ai/NEXT_PROMPT.md) **v21**
