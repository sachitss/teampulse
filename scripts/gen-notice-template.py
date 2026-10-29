#!/usr/bin/env python3
"""Regenerate web/lib/notice-template.ts from docs/monitoring-notice.md."""
import re, json, pathlib
root = pathlib.Path(__file__).resolve().parent.parent
s = (root / 'docs/monitoring-notice.md').read_text()
en = s.split('## English', 1)[1].split('---', 1)[0].strip()
ne = s.split('## नेपाली (समीक्षाका लागि मस्यौदा)', 1)[1].strip()
plain = lambda t: re.sub(r'\*\*(.+?)\*\*', r'\1', t).strip()
title, en_body = plain(en).split('\n', 1)
ne_body = plain(ne).split('\n', 1)[1]
(root / 'web/lib/notice-template.ts').write_text(
    "// GENERATED from docs/monitoring-notice.md — edit the document, then regenerate:\n"
    "//   python3 scripts/gen-notice-template.py\n"
    "// PEACE edits the bracketed parts in Settings before publishing.\n"
    f"export const NOTICE_TITLE = {json.dumps(title, ensure_ascii=False)};\n"
    f"export const NOTICE_EN = {json.dumps(en_body.strip(), ensure_ascii=False)};\n"
    f"export const NOTICE_NE = {json.dumps(ne_body.strip(), ensure_ascii=False)};\n")
print('wrote web/lib/notice-template.ts')
