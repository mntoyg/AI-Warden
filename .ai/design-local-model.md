# Design — local self-trained model for aider (implemented v1.1.0, 2026-09-26)

> **สถานะ 2026-09-26 (session 10): GPU (M7) เปิดแล้วใน v1.2.0** — `WARDEN_MODEL_GPU=1` ใช้
> `server-cuda-b10991` (`sha256:d4bdfe78…`) + `--gpus all` เฉพาะ model container; ต้องเห็น
> `offloaded N/N layers to GPU` ใน log (`-lv 4`) ไม่งั้นปฏิเสธ เพราะ image CUDA ที่ไม่เห็น GPU ขึ้น healthy
> แล้วรัน CPU เงียบ ๆ (phase J) วัดด้วย Qwen2.5-Coder-1.5B-Instruct `q8_0` ทางการ (untuned, 1.89 GB) ที่ ctx
> 8192: CPU gen 11–14 tok/s, prompt 41–83 tok/s, RAM สูงสุด 2.29 GB → **`WARDEN_MODEL_MEMORY=4g` พอ**
> (ตอบคำถามใน HANDOFF ที่ให้วัด); GPU gen 54–71 tok/s, prompt 3060 tok/s, VRAM 1.95/4 GB → 1.5B q8_0 +
> 8k ctx **พอดี RTX 3050 4 GB** (ประมาณการใน §3 ถูก) ยังเหลือ: โมเดลที่เทรนจริงจาก Colab

> **สถานะ 2026-09-26 (session 9): ฝั่ง AI Warden สร้างแล้ว** — `WARDEN_MODEL_MANIFEST=... warden-cli.sh
> run <ws> aider-local`, entrypoint `WARDEN_EGRESS=none`, drills = phase I (12 ข้อ, โมเดลสาธารณะ
> `stories260K.gguf`) ต่างจากแบบข้างล่าง: (1) **offline ล้วน** — agent ไม่อยู่บน `warden_internal`;
> (2) network เป็น **ของแต่ละ session** (`<container>-net`, internal) ไม่ใช่ `warden_model` ตัวเดียว
> เพื่อให้ session ไม่เห็นโมเดลของกันและกัน; (3) alias = `warden-local`; (4) **CPU เท่านั้น** (M7/GPU
> ยังไม่ได้พิสูจน์ จึงยังไม่เปิด); (5) เพิ่ม guard: manifest ต้องอยู่นอก workspace (agent แก้ทั้งโมเดล
> และ hash ได้ถ้าอยู่ข้างใน) ส่วนที่ยังเป็นของผู้ใช้: เทรนจริงบน Colab T4 แล้ววาง GGUF + manifest ไว้นอก workspace

> **สถานะ:** ออกแบบเท่านั้น (2026-09-16, session 7) — **ห้ามเขียนโค้ดฝั่ง AI Warden ก่อนถ่ายเดโม
> 2026-09-21** และห้ามแตะ `ai-warden/agent:latest` ของเดโม ทุกข้อด้านล่างที่ไม่ได้ติดป้าย
> **verified** ยังเป็นสมมติฐานที่ต้องรันพิสูจน์
>
> **อัปเดต 2026-09-16 (ภายหลัง):** ผู้ใช้อยากเทรนผ่าน **OpenAI fine-tuning API** ด้วย credit ที่มี
> แทน Colab แต่เอกสารทางการของ OpenAI ระบุว่า platform นี้ "no longer accessible to new users"
> และบัญชีนี้มี 0 fine-tuning job — **รอผู้ใช้ตัดสินใจ** (ดู HANDOFF Next steps #2) แบบใน
> เอกสารนี้ยังเป็นทางเลือกสำรองที่สร้างและ smoke-test ฝั่ง notebook ไว้แล้ว
>
> **ตัดสินใจแล้ว 2026-09-26 (session 9):** ผู้ใช้เลือก **(b) Colab LoRA → GGUF ในเครื่อง** ตามเอกสารนี้
> เดโมเลื่อนแบบไม่มีวัน จึงไม่มี freeze — เริ่มฝั่ง AI Warden ได้ตาม §5 โดย phase A–G และ
> `demo.sh --auto --agent codex` ต้องเขียวตลอด (ดู HANDOFF Next steps #1)
>
> **เปลี่ยนจาก §3 (user call 2026-09-26, หลังทดลอง):** agent **ไม่อยู่บน `warden_internal`** แล้ว —
> session โหมด local อยู่บนเครือข่าย internal ส่วนตัวที่มีแค่ agent + model **offline ล้วน** โค้ดออก
> นอกเครื่องไม่ได้เชิงโครงสร้าง (M3 ไม่ต้องพึ่ง log ของ squid อีก) ทดลองแล้ว: aider → llama-server
> ตอบใน 5 วินาที ขณะที่ proxy และ `1.1.1.1:443` ต่อไม่ได้ทั้งคู่; ผลข้างเคียงที่ยอมรับ: pip/npm/git
> ในโหมดนี้ออกเน็ตไม่ได้ ที่ยืนยันแล้วอีก: `docker run` รับ `--network` สองตัวได้ (Docker 29.8),
> llama-server รันเป็น `65534:65534` + `--read-only --cap-drop=ALL` ได้, `--no-webui --no-slots`
> ทำให้ `GET /` = 404, `/slots` = 501, `POST /props` = 501 (`GET /props` ยัง 200 — อ่านอย่างเดียว)

## 1. การตัดสินใจ (user call 2026-09-16)

| Question | Decision |
|---|---|
| โมเดลรันที่ไหน | **B: บนเครื่องนี้** ใน container `warden-model` ที่ไม่มีทางออกเน็ต — ไม่ใช่ endpoint บน Colab ผ่าน tunnel |
| agent ตัวไหน | **aider** (OpenAI-compatible base URL) |
| เมื่อไร | ออกแบบตอนนี้ โค้ดหลังเดโม |
| notebook + ข้อมูลเทรน | repo **private** แยก (ชื่อและ path อยู่ใน memory ของผู้ใช้ ไม่ใส่ใน repo public นี้) |

ทางเลือก A (Colab + tunnel) ถูกตัดเพราะ URL เปลี่ยนทุก session, โค้ดใน workspace ออกนอกเครื่อง
และ **wildcard ของบริการ tunnel (`.ngrok-free.app`, `.trycloudflare.com`) ใน allowlist =
เปิดช่อง exfiltration ไปยัง tunnel ของใครก็ได้** ถ้าวันหน้ากลับมาทำ A ต้องมี guard ที่ปฏิเสธ
wildcard เหล่านี้ใน `whitelist_domains.txt` ก่อน

## 2. ข้อเท็จจริงของเครื่องนี้ (verified 2026-09-16)

- GPU: `NVIDIA GeForce RTX 3050 Laptop GPU, 4096 MiB`, driver 610.88; Docker runtimes มี `nvidia`
- Docker VM: 12 CPU, RAM ~15.5 GiB
- ใน agent image: `aider 0.86.2`, `codex-cli 0.156.1` (v1.0.5 build); `NO_PROXY=localhost,127.0.0.1,::1,warden-egress-proxy`
- pipeline ฝั่ง lab (**verified ด้วย smoke บน CPU**): notebook ทั้งไฟล์รันผ่าน (smoke รอบล่าสุด: LoRA 3 step,
  loss 2.2305) → merge → GGUF `q8_0` 144.8 MB → `ghcr.io/ggml-org/llama.cpp:server`
  (`sha256:79903855d3de…`) โหลดไฟล์ได้ภายใต้ `--read-only --cap-drop=ALL
  --security-opt no-new-privileges:true` + model mount `:ro` แล้วตอบ `/health` และ
  `/v1/chat/completions`
- image `llama.cpp:server` รันเป็น **root** (`Config.User` ว่าง), entrypoint `/app/llama-server`
- ค่าเริ่มต้นของ `llama-server --help` (digest ข้างบน): Web UI **เปิด**, `/slots` **เปิด**,
  `POST /props` ปิด, `--slot-save-path` ปิด, `--tools` ไม่มี (มี `read_file`,
  `file_glob_search`, `grep_search`, … — "do not enable in untrusted environments"),
  MCP proxy ปิด, router mode (`--models-dir`) ปิด

## 3. สถาปัตยกรรม

```
                 warden_internal (internal: true)          warden_model (internal: true, NEW)
 squid proxy ◄──────────── agent (aider) ───────────────────────► warden-model (llama-server)
    │                        uid 1001                                 no proxy, no route out
    ▼ allowlist only         NO_PROXY += warden-model                 model *.gguf mounted :ro
```

- `warden-model` อยู่บนเครือข่ายใหม่ `warden_model` **เท่านั้น** — ไม่อยู่บน `warden_internal`
  จึงคุยกับ squid ไม่ได้เลย (ถ้าอยู่เครือข่ายเดียวกับ proxy และถูกเจาะ มันจะออกเน็ตได้เท่ากับ agent)
- agent อยู่สองเครือข่าย (Docker 29.8 ควรรับ `--network` หลายตัวใน `docker run` — **ต้องพิสูจน์**)
- flag ของ server ต้องระบุตรง ๆ: `--no-webui --no-slots` และ **ห้าม** `--tools`,
  `--mcp-servers-*`, `--ui-mcp-proxy`, `--props`, `--slot-save-path`, `--models-dir`, `--lora`
  ห้ามส่ง env `LLAMA_ARG_*` จากภายนอกเข้า container
- hardening เหมือน sentinel: `--read-only --cap-drop=ALL --security-opt no-new-privileges:true`,
  ลองรันเป็น non-root (`--user 65534:65534`) — **ต้องพิสูจน์ว่า llama-server ยังทำงาน**,
  memory/pids limit, GPU ผ่าน `--gpus all` + image `:server-cuda` (หรือ CPU ถ้าไม่มี GPU)
- **pin image ด้วย digest** ไม่ใช้ tag ลอย
- ก่อน start: sha256 ของ GGUF ต้องตรงกับ `gguf_sha256` ใน manifest ที่ notebook สร้าง
  ไม่ตรง = ไม่ start ทั้ง model และ agent (exit 78) — parser ของ GGUF เคยมีช่องโหว่
- lifecycle เหมือน sentinel: start ต่อ session, `docker rm -f` ตอนจบทั้ง exit 0, 78 และ 99
- aider: `aider --model openai/warden-coder --openai-api-base http://warden-model:8080/v1`
  ขนาด 1.5B `q8_0` (~1.6 GB) + context 8192 ควรพอดี VRAM 4 GB (**ประมาณการ ต้องวัด**)

## 4. Threat model ที่เพิ่มขึ้น

| # | Threat | Control | Drill (เขียนก่อน ต้อง FAIL กับของเดิม) |
|---|---|---|---|
| M1 | agent เจาะ llama-server แล้วใช้มันออกเน็ต | `warden-model` อยู่บน `warden_model` เท่านั้น ไม่มี proxy ไม่มี route | จาก netns ของ `warden-model`: ต่อ `warden-egress-proxy:3128` และ IP ภายนอกต้องล้มทั้งคู่ |
| M2 | ไฟล์ GGUF ถูกสลับหรือเป็นไฟล์อันตราย | sha256 ต้องตรงกับ manifest ก่อน start | แก้ 1 byte ในไฟล์ → exit 78, ไม่มี container ถูกสร้าง |
| M3 | **ตั้งว่าใช้โมเดลในเครื่อง แต่ส่งโค้ดไป cloud แบบเงียบ ๆ** (bug shape ประจำโปรเจกต์) — `api.openai.com` อยู่ใน allowlist และ aider ใช้ `OPENAI_API_KEY` | session โหมด local **ไม่ forward** `OPENAI_API_KEY`/`ANTHROPIC_API_KEY`/`GEMINI_API_KEY` | export key จริงบนโฮสต์ → รัน session local ที่ได้คำตอบจริง → access log ของ squid ต้องไม่มี CONNECT ไป `api.openai.com`, `api.anthropic.com`, `generativelanguage.googleapis.com` เลย |
| M4 | agent ใช้ endpoint ของ server อ่านไฟล์/เปลี่ยนค่า/สลับโมเดล | flag ใน §3 + model mount `:ro` | จาก agent: `POST /props`, `GET /slots`, `GET /` (Web UI) ต้องถูกปฏิเสธหรือ 404 |
| M5 | model container ค้างหลังจบ session (โดยเฉพาะหลัง breach 99) | ลบใน trap เหมือน sentinel | หลัง exit 0 และ 99 ต้องไม่เหลือ container `warden-model` |
| M6 | llama-server ได้สิทธิ์เกินจำเป็น | flag hardening + non-root | `CapEff=0`, `NoNewPrivs=1`, rootfs read-only, uid ≠ 0 |
| M7 | GPU passthrough เพิ่มพื้นที่โจมตีถึง driver ของโฮสต์ | ยอมรับและเขียนไว้; opt-in ต่อครั้ง, GPU เฉพาะ model; CPU เป็นค่าเริ่มต้น | phase J (v1.2.0): offload ครบหรือปฏิเสธ, agent ไม่มี device |

ข้อสังเกต: traffic ระหว่าง agent กับ model **ไม่ผ่าน squid** จึงไม่อยู่ใน access log —
log ของ llama-server คือบันทึกเดียวของเส้นทางนี้ และ canary ยังทำงานเหมือนเดิม
(model container ไม่ได้ mount workspace)

## 5. ลำดับงานหลังเดโม

1. เขียน drill M1–M6 ลง `verify-isolation.sh` เป็น phase ใหม่ → รันกับของเดิม ต้อง FAIL
2. พิสูจน์สมมติฐานใน §3 ทีละข้อด้วยการทดลองเล็กที่สุด (หลาย `--network`, non-root, GPU + VRAM จริง,
   aider ↔ llama-server) ก่อนเขียน `warden-cli.sh`
3. `warden-cli.sh run <ws> aider-local --model-manifest <path>`: ตรวจ sha256 → start model →
   start agent (ไม่ forward cloud keys) → cleanup
4. THREAT_MODEL + VERIFICATION + README (ภาษาไทย) — output ที่ยกมาต้องมาจากการรันครั้งเดียว
5. เป็นฟีเจอร์ → **v1.1.0** (ไม่ใช่ patch) หลัง CI เขียวบน tag
