# notebook/ — โมเดลของเราเอง

เป้าหมาย: fine-tune โมเดลโค้ดตัวเล็กของเราเอง (Qwen2.5-Coder-1.5B, LoRA) แล้วรันใน AI Warden
ผ่าน `aider-local` แบบ offline — ไม่ต้องจ่ายค่า API ภายนอก ฝั่ง AI Warden พร้อมแล้วตั้งแต่ v1.1.0/v1.2.0
(`WARDEN_MODEL_MANIFEST=... ./scripts/warden-cli.sh run <ws> aider-local`, GPU ด้วย `WARDEN_MODEL_GPU=1`)

[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/mntoyg/AI-Warden/blob/main/notebook/collect_data.ipynb)
— คลิกแล้ว Runtime → Run all ได้เลย (ค่าเริ่มต้นไม่ต้องแก้: repo AI-Warden + Magicoder 3000 ตัวอย่าง → Google Drive)

| ขั้น | ไฟล์ | สถานะ |
|---|---|---|
| 1. เก็บข้อมูล | [`collect_data.ipynb`](collect_data.ipynb) + [`collect/`](collect/) | **พร้อมใช้** (2026-10-08) |
| 2. เทรน LoRA → merge → GGUF + manifest | [`train.ipynb`](train.ipynb) + [`train_utils.py`](train_utils.py) ([Open in Colab](https://colab.research.google.com/github/mntoyg/AI-Warden/blob/main/notebook/train.ipynb), T4 GPU) | **เขียนแล้ว ยังไม่เคยรันบน GPU** (2026-10-08) |
| 3. รันใน AI Warden | `aider-local` | พร้อมแล้ว |

## กฎความเป็นส่วนตัว (repo นี้เป็น public)

- โค้ดใน `notebook/` commit ได้ — **ข้อมูลห้าม commit** `notebook/.gitignore` กัน `data/`, `outputs/`,
  `*.jsonl`, `*.gguf`, `conversations.json` ไว้แล้ว ถ้า `git status` เห็นไฟล์ข้อมูล ให้หยุดก่อน
- บน Colab ให้เก็บผลลัพธ์ใน Google Drive (`USE_DRIVE = True` เป็นค่าเริ่มต้น)
- ทุก record ผ่าน `redact()` ก่อนเขียน: OpenAI/Anthropic/GitHub/AWS/Stripe/Slack/HF/Google key, JWT,
  private key, email และค่าที่เป็น literal ของ `password = "..."` / `API_KEY=...`
  — เพราะอะไรที่อยู่ในข้อมูลเทรน โมเดลพ่นออกมาคำต่อคำได้ ขั้นที่ 6 ของ notebook สแกนผลอีกรอบ
- token ของ GitHub (สำหรับ repo private) ถามด้วย `getpass` ไม่แสดงบนจอ ไม่ถูกเก็บ และถูกลบออกจาก
  remote ของ clone ทันที
- dataset สาธารณะ: licence อ่านจาก dataset card **ตอนรัน** และต้องอยู่ใน allow-list
  (`apache-2.0`, `mit`, `bsd-*`, `cc0-1.0`, `cc-by-4.0`, `odc-by`) ไม่งั้นปฏิเสธ

## รูปแบบข้อมูล

หนึ่งบรรทัด = หนึ่งตัวอย่าง แบบ chat (ใช้กับ chat template ของ Qwen และ `SFTTrainer` ของ TRL ได้ตรง ๆ):

```json
{"messages": [{"role": "system", "content": "You are a careful coding assistant. ..."},
              {"role": "user", "content": "Repository: AI-Warden\nMake this change:\nfix(cli): ..."},
              {"role": "assistant", "content": "```diff\n...\n```"}],
 "source": "git:AI-Warden", "meta": {"commit": "60b530c1a2b3", "files": ["scripts/warden-cli.sh"], "redactions": 0}}
```

ผลลัพธ์: `train.jsonl`, `val.jsonl` (5%) และ `manifest.json` (จำนวนต่อแหล่ง, ที่ซ้ำแล้วทิ้ง, sha256 ของแต่ละไฟล์)

## แหล่งข้อมูล

| โมดูล | input | ตัวอย่างที่ได้ |
|---|---|---|
| `collect/from_git.py` | git repo | commit message (ไม่มี trailer, ไม่มีชื่อ/อีเมลผู้เขียน) → diff ของไฟล์โค้ด (≤ 6000 ตัวอักษร) |
| `collect/from_files.py` | โฟลเดอร์โปรเจกต์ | หัวข้อ Markdown → เนื้อหา; docstring ของ Python / comment เหนือฟังก์ชัน bash → โค้ด |
| `collect/from_chats.py` | `conversations.json` | บทสนทนาจาก export ของ Claude หรือ ChatGPT (เฉพาะที่มีโค้ดเป็นค่าเริ่มต้น) |
| `collect/from_hf.py` | dataset id บน Hub | คู่คำถาม–คำตอบ กรองภาษาได้ (preset: Magicoder-OSS-Instruct-75K, self-oss-instruct-sc2) |

## รันนอก notebook

```bash
cd notebook
python3 -m collect.build --out data --git ~/code/AI-Warden --files ~/code/AI-Warden \
    --chats ~/exports/claude/conversations.json \
    --hf ise-uiuc/Magicoder-OSS-Instruct-75K --hf-limit 3000 --hf-langs python,shell
python3 -m unittest discover -s . -p 'test_*.py'      # stdlib only, no network
```

## เทรน (`train.ipynb`)

- Qwen2.5-Coder-1.5B-Instruct (Apache-2.0), LoRA r=16 บนทุก projection, float32 + fp16 autocast (T4 ไม่มี bf16),
  ตัวอย่างที่ยาวเกิน `MAX_LEN` ถูก**ทิ้ง** (ไม่ตัด เพราะตัดแล้วคำตอบหาย)
- `SMOKE = True` (ค่าเริ่มต้น) = 30 step บน 200 ตัวอย่าง เพื่อลองท่อทั้งเส้น → ผ่านแล้วค่อย `SMOKE = False`
- ตรวจ sha256 ของข้อมูลกับ `manifest.json` ของตอนเก็บก่อนเทรน (`verify_dataset`)
- ผลลัพธ์: `<ชื่อ>-q8_0.gguf` + `manifest.json` ที่ AI Warden ตรวจ — test อ่าน manifest ด้วยบรรทัด `sed` **ตัวจริง**
  จาก `scripts/warden-cli.sh` ถ้าฝั่งใดเปลี่ยน test จะพัง ไม่ใช่การรันครั้งแรกของคุณ
- argument ของ TRL ที่เปลี่ยนชื่อระหว่างเวอร์ชัน (`max_seq_length`/`max_length`, `tokenizer`/`processing_class`,
  `evaluation_strategy`/`eval_strategy`) ส่งตามที่เวอร์ชันที่ติดตั้งรับ — ไม่ pin เวอร์ชันที่อาจเน่า

## ผลที่วัดแล้ว (2026-10-08, session 13)

- test 18 ข้อผ่าน (collect 14 + train_utils 4) และ **ล้มเมื่อทำให้ `redact()` ไม่ทำอะไร** (4 ข้อ FAIL) หรือเปลี่ยนชื่อ
  `gguf_sha256` ใน manifest (FAIL) — test มีฟันจริง
- รัน notebook ทุก cell กับ repo นี้ (นอก Colab, ปิด HF): 215 record (docs 142, code 57, git 16 —
  clone นี้เป็น shallow 84 commit), สแกนรอบสอง `secret-shaped strings left: 0`
- **ยังไม่ได้ลอง:** `train.ipynb` บน GPU จริง (ไม่มี GPU ใน session คลาวด์) — รันครั้งแรกด้วย `SMOKE = True`;
  ดาวน์โหลดจาก Hugging Face จริง (session คลาวด์ถูก proxy ปฏิเสธ huggingface.co) และ
  export แชทจริง (ทดสอบด้วยไฟล์จำลองรูปแบบเดียวกัน) — ลองครั้งแรกบน Colab แล้วดูขั้นที่ 4 และ 6
