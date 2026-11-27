#!/usr/bin/env python3
"""Validate a message captured from a fake sendmail (alert e-mail tests of the patch compliance scripts).

  check_alert_mime.py mixed MESSAGE [REPORTS_DIR] [--status S] [--nc N] [--prefix P] [--date YYYY-MM-DD] [--parts html,csv|html|csv|none] [--csv-glob GLOB]
  check_alert_mime.py part MESSAGE text|html     (print the decoded body)
  check_alert_mime.py escape LIB_JQ
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from email import policy
from email.parser import BytesParser
from pathlib import Path


def load(path: Path):
    return BytesParser(policy=policy.default).parsebytes(path.read_bytes())


def part_text(p) -> str:
    body = p.get_content()
    return body if isinstance(body, str) else body.decode("utf-8", "replace")


def fail(msg: str) -> None:
    raise SystemExit(msg)


def check_mixed(a) -> None:
    msg = load(Path(a.message))
    want = [] if a.parts == "none" else a.parts.split(",")
    if want:
        if msg.get_content_type() != "multipart/mixed":
            fail(f"expected multipart/mixed, got {msg.get_content_type()}")
        parts = list(msg.iter_parts())
        if len(parts) != 1 + len(want):
            fail(f"expected {1 + len(want)} mixed parts, got {[p.get_content_type() for p in parts]}")
        alt, atts = parts[0], parts[1:]
    else:
        alt, atts = msg, []
    if alt.get_content_type() != "multipart/alternative":
        fail(f"expected alternative, got {alt.get_content_type()}")
    bodies = list(alt.iter_parts())
    types = [b.get_content_type() for b in bodies]
    if types != ["text/plain", "text/html"]:
        fail(f"expected text then html, got {types}")
    text, html = part_text(bodies[0]), part_text(bodies[1])
    if not text.startswith(f"RDS patch compliance: {a.status}"):
        fail(f"text start: {text.splitlines()[:1]}")
    if a.nc > 0:
        if f"NON-COMPLIANT servers ({a.nc}):" not in text:
            fail("missing NON-COMPLIANT table in text")
        if "background:#b3261e" not in html or "<table" not in html:
            fail("HTML body missing the red banner or the failures table")
        heads = ["Account", "Server", "Engine", "Current → target", "Reason"]
        if not all(f">{h}</th>" in html for h in heads):
            fail("HTML failures table lacks one of: " + ", ".join(heads))
        if "No NON-COMPLIANT servers." in html:
            fail("unexpected empty-failures sentence")
    else:
        if "background:#137333" not in html:
            fail("HTML body missing the green banner")
        if "No NON-COMPLIANT servers." not in html or "No NON-COMPLIANT servers." not in text:
            fail("missing 'No NON-COMPLIANT servers.'")
        if "NON-COMPLIANT servers (" in html or "NON-COMPLIANT servers (" in text:
            fail("failures table present on a compliant run")
    short = re.compile(rf"^{re.escape(a.prefix)}_{re.escape(a.date) if a.date else r'[0-9]{4}-[0-9]{2}-[0-9]{2}'}\.(html|csv)$")
    got = {}
    for att in atts:
        name = att.get_filename() or ""
        if not short.fullmatch(name):
            fail(f"attachment name not {a.prefix}_YYYY-MM-DD.ext: {name}")
        got[name.rsplit(".", 1)[1]] = att
    if sorted(got) != sorted(want):
        fail(f"attachments {sorted(got)} != expected {sorted(want)}")
    if "html" in got and got["html"].get_content_type() != "text/html":
        fail("html attachment content type")
    if "csv" in got and got["csv"].get_content_type() != "text/csv":
        fail("csv attachment content type")
    for body in (text, html):
        low = body.lower()
        if "is attached" in low or "report files" in low or "attachments:" in low:
            fail("attachment list or report file paths in the e-mail body")
        if re.search(r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.(html|csv|txt)", body):
            fail("a report file path is in the e-mail body")
    if a.reports:
        rd = Path(a.reports)
        if "html" in got:
            hf = next(p for p in sorted(rd.glob("*.html")))
            if got["html"].get_payload(decode=True) != hf.read_bytes():
                fail("HTML attachment does not match the written report")
        if "csv" in got:
            cf = next(p for p in sorted(rd.glob(a.csv_glob)) if not p.name.endswith("_regions.csv"))
            if got["csv"].get_payload(decode=True) != cf.read_bytes():
                fail("CSV attachment does not match the written per-server CSV")
            if b"_regions" in got["csv"].get_filename().encode():
                fail("regions CSV attached")
    print("mime ok")


def show_part(path: Path, which: str) -> None:
    """Print the decoded text or html body (the alternative part), for grep in the shell tests."""
    msg = load(path)
    alt = next(msg.iter_parts()) if msg.get_content_type() == "multipart/mixed" else msg
    bodies = {b.get_content_type(): b for b in alt.iter_parts()}
    sys.stdout.write(part_text(bodies["text/html" if which == "html" else "text/plain"]))


def check_escape(lib: Path) -> None:
    row = {"account_id": "111111111111", "account_name": "<b>x</b>", "identifier": "<img src=x onerror=alert(1)>", "region": "us-east-1",
           "engine": "postgres", "current_version": "1<2", "latest_minor_version": "9&9", "compliance_status": "NON-COMPLIANT",
           "versions_behind": 5, "note": "a <script>x</script> b", "support_flag": "ok"}
    doc = {"summary": {"total": 1, "compliant": 0, "non_compliant": 1, "unknown": 0, "pct_compliant": 0, "with_pending": 0, "pending_total": 0,
                       "max_behind": 2, "errors": 1},
           "meta": {"accounts": [{"account": "111111111111", "name": ""}]},
           "rows": [row],
           "errors": [{"account": "111111111111", "region": "us-east-1", "call": "rds <x>", "message": "<iframe src=y>"}]}
    out = subprocess.check_output(["jq", "-r", "-f", str(lib), "--arg", "mode", "html", "--arg", "host", "h", "--arg", "tool", "t", "--arg", "when", "now"],
                                  input=json.dumps(doc), text=True)
    for raw in ("<img", "<script", "<iframe", "<b>x"):
        if raw in out:
            fail(f"raw {raw} leaked into the e-mail HTML")
    for esc in ("&lt;img src=x onerror=alert(1)&gt;", "1&lt;2", "9&amp;9", "&lt;script&gt;"):
        if esc not in out:
            fail(f"expected escaped text not found: {esc}")
    print("escape ok")


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("mixed")
    m.add_argument("message")
    m.add_argument("reports", nargs="?")
    m.add_argument("--status", default="NON-COMPLIANT")
    m.add_argument("--nc", type=int, default=8)
    m.add_argument("--prefix", default="patch_compliance")
    m.add_argument("--date", default="")
    m.add_argument("--parts", default="html,csv")
    m.add_argument("--csv-glob", default="*.csv")
    sp = sub.add_parser("part")
    sp.add_argument("message")
    sp.add_argument("which", choices=["text", "html"])
    e = sub.add_parser("escape")
    e.add_argument("jqfile")
    a = ap.parse_args()
    if a.cmd == "mixed":
        check_mixed(a)
    elif a.cmd == "part":
        show_part(Path(a.message), a.which)
    else:
        check_escape(Path(a.jqfile))
    return 0


if __name__ == "__main__":
    sys.exit(main())
