# Changelog

Plain-English features for each published release. The What's new page is built from this file.
Releases from v1.3.1 on have a published release zip. Earlier history (v1.0.0–v1.3.0) is listed at the end for completeness; those versions were not published as a release zip.

## 1.8.1

Released 28 Nov 2026 (IST).

- The old `rds_patch_compliance_report.conf.example` file has been removed. Use the shipped `rds_patch_compliance_report.conf`. The release zip no longer includes the old example.
- The README is now a short user guide. The full reference lives in `REFERENCE.md`, which is also included in the release zip.
- An unused sample image (`samples/sample_summary_merged.png`) has been removed

## 1.8.0

Released 27 Nov 2026 (IST).

- One settings file for both scripts: `rds_patch_compliance_report.conf` sits next to them and is loaded automatically (the same way as the backup tool). Every value is in it, each with a short comment saying what it does, the allowed values and an example; nothing is hardcoded in the scripts any more
- If a setting is missing the run stops before any AWS call and names it. `--config FILE` runs with another complete copy; a command line option still overrides one value. The startup output says which file was used
- The summary script reads the same file (accounts, regions, rule, formats, e-mail and webhook settings); its own options override it
- The alert e-mail is now HTML with a plain-text copy: a status banner, count cards, and tables of the NON-COMPLIANT and UNKNOWN servers and AWS errors (Account, Server and region, Engine, Current to target, Reason). Pending maintenance is only a count. Report paths are not in the e-mail (they still print on the screen)
- With `sendmail` the HTML report and the per-server CSV are attached with short names (`patch_compliance_YYYY-MM-DD.html` / `.csv`); with only `mail` / `mailx` the text summary alone is sent. New settings and options: `attach_html`, `attach_csv`, `attach_prefix`, `mail_timeout` (`--attach-html`, `--attach-csv`, `--attach-prefix`, `--mail-timeout`)
- Other values that used to be fixed are now settings: `webhook_timeout`, `webhook_retries`, `aws_retry_mode`, `exception_warn_days`
- Slack and webhook payloads, and the text and CSV reports, are unchanged for the same values (checked byte for byte against 1.7.1). The HTML report and the JSON file differ only in the tool version (footer and version field)
- Upgrading: an old partial conf now stops with `missing required setting(s)`; start from the shipped `rds_patch_compliance_report.conf`. The release zip now includes it. `rds_patch_compliance_report.conf.example` is superseded and kept for now
- The shipped values write csv, html and txt files into `./reports` (created if missing) and log to `./reports/run.log`; `-o ''` prints one format on the screen

## 1.7.1
- Pending maintenance tab: the Action dropdown always lists the standard AWS types (system-update, db-upgrade, os-upgrade, hardware-maintenance, ca-certificate-rotation) with a count each; types with 0 are greyed out, and any other type found is added at the end
- A one-line "Actions by type" strip above the table; click a count to show only that type (Reset clears it)
- Text report: a "By type" line at the top of PENDING MAINTENANCE. CSV and JSON unchanged; summary script is 1.7.1 (no other change)

## 1.7.0
- The HTML report has two tabs: **Patch compliance** and **Pending maintenance**. Each piece of information now appears once
- Patch compliance no longer has the Pending card, the Pending column (badge you had to click), the maintenance window columns, the pending counts in the per account / per region tables, or the Pending option in Flag
- Pending maintenance is one flat table, one row per action, soonest first: server, account, region, engine / version, action, applies to, auto-apply and forced dates in IST, maintenance window in IST, description. Overdue or within 7 days is red, within 30 days amber
- Pending maintenance has cards (due within 7 days, within 30 days, optional), filters (account, region, engine, action, applies to, due, Global / Standalone), search and Reset
- Export CSV uses one layout on both tabs: one row per server with 26 columns, ending with `pending_count`, `next_due`, `next_action` and `pending_actions` (every action soonest first, with IST dates and the full description). Tab 1 saves the filtered servers; tab 2 saves the servers that have visible actions
- Servers link between the tabs: **N pending** opens that server's actions; the server name in Pending maintenance jumps back to its row
- Members of one Aurora global database sit together (primary first) in the HTML, text, CSV and JSON
- Text report: no `pending:` line under each server; a PENDING MAINTENANCE section lists every action, soonest first
- Command-line CSV and JSON keep the same columns; `--merge` still reads older data files; no new AWS calls
- Summary script is 1.7.0 (no other change)

## 1.6.0
- Compliance exceptions (`--exceptions FILE` / `compliance_exceptions.conf`) applied at report and merge time; `--save-data` is unchanged
- An unexpired exception turns NON-COMPLIANT into COMPLIANT (EXCEPTION) and counts as compliant; the evaluated status is kept in `actual_status`
- UNKNOWN stays UNKNOWN even with an exception (the exception is still listed against the server)
- Expiring soon / no longer needed / expired flags; HTML Exception column, Exceptions quick filter and Compliant card pop-up; CSV and JSON get 5 columns at the end; text gets an EXCEPTIONS section
- With no exceptions file the outputs are unchanged
- Summary script is 1.6.0 and gains `--exceptions FILE`, passed through to the full report (including with `--merge`)
- README documents `--exceptions` and `--tz` in the options table, and `rds:DescribeGlobalClusters` in the IAM policy

## 1.5.1
- Global / Standalone checkboxes replace the Global cluster dropdown (Aurora only)
- Collapsible Global databases section with a mismatch count and amber badge
- Search covers global DB name, account, engine and version, and opens matching sections
- Search fixes: trim, case-insensitive restore, literal special characters, clear empty state

## 1.5.0
- Engine compliance table under the cards (collapsible majors, sortable, clickable counts)
- Clickable status and risk cards with the active card highlighted
- Flag dropdown (Extended Support, support ending, auto minor off, pending, not returned)
- Account names from config or IAM alias; `account_name` column at the end of CSV / JSON

## 1.4.1
- Security fix: compliance fields are HTML-escaped (stored XSS via a tampered merge file)
- In-page filters coerce the pending count to a number
- Releases publish a `.sha256` checksum verified before unzip
- Release workflow pins Actions to commit SHAs with least-privilege permissions

## 1.4.0
- Aurora global database awareness with role columns, badge and Global cluster filter
- Global databases section shows overall status, region mismatches and NOT SCANNED members
- Tag columns, ARN, upgrade command and Copy button removed from displayed outputs
- CSV settled at 27 columns; older save-data files still merge

## 1.3.2
- Release zip contains only runtime files (scripts, lib, README, EXAMPLES, conf example)
- docs, samples and tests excluded from the zip and from GitHub source archives
- No report behaviour changes

## 1.3.1
- Removed the "Top N most behind" section from HTML and text
- Shorter header; long explanations moved into a collapsed About this report section
- `--merge` reads both v1.3.0 and v1.3.1 save-data files


## Earlier history (before v1.3.1 release zips)

These notes were previously only in the README. They are kept here so the history is not lost. Longer technical wording is also in [REFERENCE.md](REFERENCE.md#version-notes).

## summary 1.3.0
- `--save-data [FILE]` and offline `--merge FILE|DIR...` (delegated to the full report, so the data format, exit 3 and Git Bash handling are identical)
- PER ACCOUNT table and MERGED INPUTS list in txt / html; `*_accounts.csv`; account number in single-account file names; all jq output made LF-only for Git Bash
- Full report: `--merge --oracle-any-patch-line` now recounts Oracle rows from the saved targets (previously the flag was ignored in merge mode)

## 1.3.0
- `--save-data [FILE.json]` (raw data, `rds_patch_<ACCOUNTID>_<YYYYMMDD>.json`) and `--merge FILE|DIR... -o combined.html`: offline (jq only, 0 AWS calls), Git Bash safe (CRLF, Windows paths, spaces), newest `collected_at` wins per account, days recomputed at merge time, exit 3 on a bad input
- Account number in single-account file names and in the header, tables and every row; new Per account table; Merged inputs note
- HTML filters (account, region, engine, status, DB-name search) that recompute the cards and tables, and Export CSV of the filtered rows
- CSV adds `next_maintenance` and `days_until_maintenance` (30 columns)

## 1.2.1 / summary 1.1.1
- No region names at the top of the HTML report or summary: the report header `<details>` list (with databases / errors / empty) and the summary header list of every enabled region are gone; the header keeps one count line (`Regions: N checked, M with databases, K empty, E errors`)
- Empty regions are no longer listed anywhere in txt / HTML / CSV: no `Empty :` line, no collapsible empty list, no 0-rows in the per-region table or `*_regions.csv` (counts only)
- Text header shows region names only for `-r`. JSON unchanged (keeps empty regions and `empty_regions`)

## 1.2.0 / summary 1.1.0
- `--all-regions` discovery: per region two parallel one-page probes (`--max-records 20 --query length(...) --no-paginate`, `--probe-parallel`, default 8); full scan only where databases are found; a failed probe is an error and the region is still scanned; `--no-discover` / `discover = no`; `-r` regions are never probed; probes in `--dry-run` and `aws_calls`
- Header `Regions  : N checked, M with databases, K empty, E errors` + empty-region list
- Region-wise breakdown (account x region + All regions) in text, HTML (sortable, colour-coded), JSON, `*_regions.csv` and the summary script (txt / html / `*_regions.csv`)

## summary 1.0.0
- New `rds_patch_compliance_summary.sh` (+ `lib/summary.jq`, `tests/run_summary_tests.sh`): high-level summary and the NON-COMPLIANT servers only; reuses the full report for the scan and all counting

## 1.1.1
- Oracle: upgrade targets count only on the SAME patch line as the current version (mrp/rur/plain RU/spb; numeric ru date, line date, rN ordering); other lines are excluded with a note
- Fixes `...mrp-2026-07.r1` showing `...spb-2026-07.r1` as latest (console offers `...mrp-2026-07.r2`)
- Same-major safety net for every engine (a target AWS marks as minor but in another major line is excluded and noted)
- New `--oracle-any-patch-line` / `oracle_any_patch_line`. JSON rows gain `excluded_targets`, `version_warnings`; meta gains `oracle_any_patch_line`
- Shared logic in `lib/versions.jq` (same file in RDS_Pending_Maintenance and RDS_Patch_Runner). Mock scenario `oracle`

## 1.1.0
- Counting source is now RDS metadata only: per server `describe-db-engine-versions --engine E --engine-version <current>`, `ValidUpgradeTarget[]` with `IsMajorVersionUpgrade=false` (no more full-list counting or own derivation)
- New column `default_auto_upgrade_target`; current version not returned → UNKNOWN + deprecated note; cache per engine+version+region; summary latest minor = highest valid target seen
- Pending maintenance is now `pending_actions_count` + readable `pending_actions` (action, on cluster / member, auto-apply / forced dates, opt-in status, short description), HTML badge with expandable list and IST tooltip, summary by action type, legend

## 1.0.0
- First version
