# Changelog

Plain-English features for each published release. The What's new page is built from this file.
Only GitHub releases are listed here (older README history before v1.3.1 is not a published release zip).

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
