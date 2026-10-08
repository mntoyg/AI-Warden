"""Public instruction datasets on the Hugging Face Hub -> examples.

The licence is read from the dataset card at run time and checked against
an allow-list - never trusted from memory. A dataset whose card has no
licence, or one outside the list, is refused.
"""
from __future__ import annotations

from typing import Iterable, Iterator

from .common import make_record

ALLOWED_LICENSES = {"apache-2.0", "mit", "bsd-2-clause", "bsd-3-clause", "cc0-1.0",
                    "cc-by-4.0", "odc-by"}

# Column names as published; check them with the notebook's preview cell.
PRESETS = {
    "ise-uiuc/Magicoder-OSS-Instruct-75K": {"user": "problem", "assistant": "solution",
                                             "lang": "lang"},
    "bigcode/self-oss-instruct-sc2-exec-filter-50k": {"user": "instruction",
                                                      "assistant": "response"},
}


class LicenseRefused(RuntimeError):
    pass


def card_license(dataset_id: str) -> str | None:
    from huggingface_hub import dataset_info  # installed in the notebook
    data = dataset_info(dataset_id).card_data
    lic = getattr(data, "license", None) if data else None
    if isinstance(lic, list):
        lic = lic[0] if len(lic) == 1 else None
    return lic.lower() if isinstance(lic, str) else None


def check_license(dataset_id: str, license_id: str | None,
                  allowed: set[str] = ALLOWED_LICENSES) -> str:
    if not license_id or license_id not in allowed:
        raise LicenseRefused(f"{dataset_id}: card licence {license_id!r} is not in {sorted(allowed)}")
    return license_id


def rows_to_records(rows: Iterable[dict], user_field: str, assistant_field: str, source: str,
                    license_id: str, lang_field: str | None = None,
                    langs: set[str] | None = None, limit: int | None = None) -> Iterator[dict]:
    made = 0
    for row in rows:
        if lang_field and langs and str(row.get(lang_field, "")).lower() not in langs:
            continue
        rec = make_record(str(row.get(user_field) or ""), str(row.get(assistant_field) or ""),
                          source, {"license": license_id})
        if rec:
            yield rec
            made += 1
            if limit and made >= limit:
                return


def collect(dataset_id: str, split: str = "train", limit: int | None = 5000,
            langs: set[str] | None = None, user_field: str | None = None,
            assistant_field: str | None = None, lang_field: str | None = None) -> Iterator[dict]:
    from datasets import load_dataset  # installed in the notebook
    preset = PRESETS.get(dataset_id, {})
    user_field = user_field or preset.get("user")
    assistant_field = assistant_field or preset.get("assistant")
    lang_field = lang_field or preset.get("lang")
    if not user_field or not assistant_field:
        raise ValueError(f"{dataset_id}: name user_field and assistant_field (no preset)")
    license_id = check_license(dataset_id, card_license(dataset_id))
    rows = load_dataset(dataset_id, split=split, streaming=True)
    yield from rows_to_records(rows, user_field, assistant_field, f"hf:{dataset_id}", license_id,
                               lang_field, langs, limit)
