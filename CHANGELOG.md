# Changelog

Plain-English features for each published release. The What's new page is built from this file.
Only GitHub releases are listed here (older README history before v1.3.1 is not a published release zip).

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
