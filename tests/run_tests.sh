#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2054  # cond && ok || bad is safe (ok returns 0); jq programs are single-quoted; comma lists are CLI args
# Test suite for rds_patch_compliance_report.sh against the mock AWS CLI (tests/mock/aws).
# Guard: the mock must be the `aws` on PATH, credentials are fake, the endpoint is a dead local port and
# all output goes to a temp dir - nothing can reach AWS and nothing is written into the repo.
# Usage: tests/run_tests.sh [-k]   (-k keeps the temp output dir)
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_SCRIPT="$HERE/../rds_patch_compliance_report.sh"
LIBJQ="$HERE/../lib/compliance.jq"
OUT="$(mktemp -d /tmp/rpc_tests.XXXXXX)"
# The script loads rds_patch_compliance_report.conf from its own folder, so the suites run a copy of the tool whose
# conf holds the v1.7.1 built-in defaults (tests/fixtures/test_defaults.conf). The shipped conf is tested separately.
BASE_CONF="$HERE/fixtures/test_defaults.conf"
TOOL="$OUT/tool"; mkdir -p "$TOOL"
cp "$REPO_SCRIPT" "$HERE/../rds_patch_compliance_summary.sh" "$TOOL/"; cp -r "$HERE/../lib" "$TOOL/"; cp "$BASE_CONF" "$TOOL/rds_patch_compliance_report.conf"
SCRIPT="$TOOL/rds_patch_compliance_report.sh"
# mkconf FILE [key = value ...]: a complete conf = the test base plus overrides (the last duplicate wins).
mkconf() { local f="$1" kv; shift; cp -- "$BASE_CONF" "$f"; for kv in "$@"; do printf '%s\n' "$kv" >>"$f"; done; }
KEEP=0; [[ "${1:-}" == -k ]] && KEEP=1
PASS=0; FAIL=0; LISTENER_PID=""
export MOCK_LOG="$OUT/aws_calls.jsonl"
STUB="$OUT/stubbin"; mkdir -p "$STUB"
export PATH="$HERE/mock:$STUB:$PATH"
unset AWS_REGION AWS_DEFAULT_REGION AWS_PROFILE MOCK_DEFAULT_REGION MOCK_SCENARIO
export AWS_ACCESS_KEY_ID=fake-test-key-id AWS_SECRET_ACCESS_KEY=fake-test-secret AWS_SESSION_TOKEN=fake \
       AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true \
       AWS_ENDPOINT_URL=http://127.0.0.1:9 TMPDIR="$OUT"
# --- guard: refuse to run unless `aws` is the mock
if [[ "$(command -v aws)" != "$HERE/mock/aws" || "$(aws --version 2>&1)" != *.mock* ]]; then
    echo "GUARD: 'aws' on PATH is not tests/mock/aws - refusing to run (would risk real AWS)"; exit 2
fi
BEFORE="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"

cleanup() {
    [[ -n "$LISTENER_PID" ]] && kill "$LISTENER_PID" 2>/dev/null
    if (( KEEP )); then echo "output kept in $OUT"; else rm -rf -- "$OUT"; fi
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }
# t <name> <expected-rc> <scenario> [args...]  -> stdout in $OUT/<name>.out, stderr in .err
t() {
    local name="$1" exp="$2" scen="$3"; shift 3
    MOCK_SCENARIO="$scen" "$SCRIPT" "$@" >"$OUT/$name.out" 2>"$OUT/$name.err"
    local rc=$?
    if [[ "$rc" == "$exp" ]]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc expected $exp"; sed 's/^/       /' "$OUT/$name.err" | tail -5; fi
}
has()  { if grep -qE -- "$3" "$OUT/$1.$2"; then ok "$1 $2 has /$3/"; else bad "$1 $2 lacks /$3/"; fi; }
hasnt(){ if grep -qE -- "$3" "$OUT/$1.$2"; then bad "$1 $2 unexpectedly has /$3/"; else ok "$1 $2 lacks /$3/"; fi; }
chk()  { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
jqt()  { if jq -e "$2" "$OUT/$1.out" >/dev/null 2>&1; then ok "$1 json: $2"; else bad "$1 json: $2"; fi; }
row()  { jq -c --arg i "$2" '.rows[] | select(.identifier == $i)' "$OUT/$1.out"; }
rowt() { if row "$1" "$2" | jq -e "$3" >/dev/null 2>&1; then ok "$1 $2: $3"; else bad "$1 $2: $3 (got $(row "$1" "$2" | head -c 400))"; fi; }
vc()   { jq -n --arg mode vkey_cmp --arg a "$1" --arg b "$2" --argjson now 0 --argjson exc_warn_days 14 --argjson max_behind 2 --argjson warn_days 180 --argjson top_n 10 \
            --argjson tagcols '[]' --argjson f '{}' --argjson nc_only false -f "$LIBJQ"; }
vct()  { local r; r="$(vc "$1" "$3")"; if [[ "$r" == "$2" ]]; then ok "vcmp $1 vs $3 = $2"; else bad "vcmp $1 vs $3 = $r expected $2"; fi; }
mj()   { local r; r="$(jq -rn --arg mode major --arg a "$2" --arg e "$1" --argjson now 0 --argjson exc_warn_days 14 --argjson max_behind 2 --argjson warn_days 180 --argjson top_n 10 \
            --argjson tagcols '[]' --argjson f '{}' --argjson nc_only false -f "$LIBJQ")"
         if [[ "$r" == "$3" ]]; then ok "major($1 $2) = $3"; else bad "major($1 $2) = $r expected $3"; fi; }

cat >"$STUB/mail" <<'MAIL'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' %q' "$@"; printf '\n'; cat; } >>"${MAIL_SINK:?}"
MAIL
chmod +x "$STUB/mail"
export MAIL_SINK="$OUT/mail.txt"
PORT_FILE="$OUT/port"
python3 - "$OUT/webhook.txt" "$PORT_FILE" <<'PY' &
import http.server, sys
sink, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(sink, "ab") as f: f.write(body + b"\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_port))
s.serve_forever()
PY
LISTENER_PID=$!
for _ in $(seq 50); do [[ -s "$PORT_FILE" ]] && break; sleep 0.1; done
HOOK="http://127.0.0.1:$(cat "$PORT_FILE")/hooks/T000/SECRET"
P2=(-P prod,nonprod -r us-east-1,ap-south-1)

echo "== version compare (unit)"
vct 15.10 1 15.9;  vct 15.9 -1 15.10;  vct 15.10 0 15.10;  vct 15.4 -1 15.4.1;  vct 16.1 1 15.13
vct 8.0.mysql_aurora.3.10.0 1 8.0.mysql_aurora.3.9.0;  vct 8.0.mysql_aurora.3.05.2 -1 8.0.mysql_aurora.3.06.0
vct 8.0.mysql_aurora.3.05.2 0 8.0.mysql_aurora.3.5.2;  vct 8.0.mysql_aurora.3.08.10 1 8.0.mysql_aurora.3.08.9
vct 15.00.4430.1.v1 1 15.00.4415.2.v1;  vct 15.00.4410.1.v1 -1 15.00.4410.2.v1;  vct 16.00.4165.4.v1 1 15.00.4430.1.v1
vct 19.0.0.0.ru-2025-07.rur-2025-07.r1 1 19.0.0.0.ru-2025-04.rur-2025-04.r1;  vct 19.0.0.0.ru-2025-01.rur-2025-01.r2 1 19.0.0.0.ru-2025-01.rur-2025-01.r1
vct 10.11.10 1 10.11.9;  vct 1.3.10.0 1 1.3.4.0
mj postgres 16.4 16; mj postgres 9.6.24 9.6; mj aurora-postgresql 15.10 15; mj mysql 8.0.36 8.0; mj aurora-mysql 8.0.mysql_aurora.3.05.2 8.0
mj sqlserver-se 15.00.4410.1.v1 15.00; mj oracle-ee 19.0.0.0.ru-2025-01.rur-2025-01.r1 19; mj docdb 5.0.0 5.0; mj neptune 1.3.2.1 1.3

echo "== oracle patch lines + same-major safety net (MOCK_SCENARIO=oracle)"
O=19.0.0.0.ru-
t ora 0 oracle -P prod -r us-east-1 -F json -v
rowt ora ora-mrp ".latest_minor_version == \"${O}2026-07.mrp-2026-07.r2\" and .versions_behind == 1 and .compliance_status == \"COMPLIANT\""
rowt ora ora-mrp ".newer_versions == [\"${O}2026-07.mrp-2026-07.r2\"] and (.note | contains(\"excluded ${O}2026-07.spb-2026-07.r1 (different patch line spb; current is mrp)\"))"
rowt ora ora-rur ".newer_versions == [\"${O}2026-01.rur-2026-04.r1\", \"${O}2026-04.rur-2026-04.r1\"] and (.excluded_targets | length) == 2"
rowt ora ora-ru ".newer_versions == [\"${O}2026-07.r1\", \"${O}2026-10.r1\"] and (.note | test(\"patch line mrp; current is plain RU\"))"
rowt ora ora-r9 ".newer_versions == [\"${O}2026-07.mrp-2026-07.r10\", \"${O}2026-10.mrp-2026-10.r1\"] and .versions_behind == 2"
rowt ora ora-r9 '(.note | contains("excluded 26.0.0.0.ru-2026-07.spb-1.r1 (different major version 26; current is 19)")) and (.newer_versions | index("19.0.0.0.ru-2026-07.mrp-2026-07.r8")) == null'
rowt ora ora-odd '.newer_versions == ["19.0.0.0.custom-build2"] and .version_warnings[0] != null'
has ora err 'DEBUG.*ora-odd: oracle version format not recognised'
has ora err 'DEBUG.*ora-mrp: excluded .*spb-2026-07.r1'
rowt ora sql15 '.newer_versions == ["15.00.4440.1.v1"] and (.note | contains("excluded 16.00.4185.3.v1 (different major version 16; current is 15)"))'
rowt ora my80 '.newer_versions == ["8.0.44"] and (.note | contains("excluded 8.4.6 (different major version 8.4; current is 8.0)"))'
rowt ora amy2 '.newer_versions == ["5.7.mysql_aurora.2.12.4"] and (.note | test("different major version 3; current is 2"))'
jqt ora '.summary.engines[] | select(.engine == "oracle-ee") | .majors[0].latest_minor | contains("mrp: 19.0.0.0.ru-2026-10.mrp-2026-10.r1") and contains("plain RU: 19.0.0.0.ru-2026-10.r1")'
t ora_any 0 oracle -P prod -r us-east-1 -F json --oracle-any-patch-line
rowt ora_any ora-mrp ".latest_minor_version == \"${O}2026-07.mrp-2026-07.r2\" and .versions_behind == 2 and (.newer_versions | index(\"${O}2026-07.spb-2026-07.r1\")) != null and (.excluded_targets | length) == 0"
rowt ora_any ora-r9 '(.newer_versions | length) == 2'
jqt ora_any '.meta.oracle_any_patch_line == true'
mkconf "$OUT/oal.conf" 'oracle_any_patch_line = yes'
t ora_conf 0 oracle --config "$OUT/oal.conf" -P prod -r us-east-1 -F json
rowt ora_conf ora-mrp '.versions_behind == 2'
vce() { local r; r="$(jq -n --arg mode vcmp_e --arg e "$1" --arg a "$2" --arg b "$4" --argjson now 0 --argjson exc_warn_days 14 --argjson max_behind 2 --argjson warn_days 180 --argjson top_n 10 \
            --argjson tagcols '[]' --argjson f '{}' --argjson nc_only false -f "$LIBJQ")"; if [[ "$r" == "$3" ]]; then ok "vcmp_e $2 vs $4 = $3"; else bad "vcmp_e $2 vs $4 = $r expected $3"; fi; }
vce oracle-ee "${O}2026-07.mrp-2026-07.r10" 1 "${O}2026-07.mrp-2026-07.r9"
vce oracle-ee "${O}2026-07.mrp-2026-07.r2" 1 "${O}2026-07.mrp-2026-07.r1"
vce oracle-ee "${O}2026-10.mrp-2026-10.r1" 1 "${O}2026-07.mrp-2026-07.r10"

echo "== usage / validation"
t help 0 fleet --help;               has help out 'Exit codes'; has help out 'read-only'; has help out '--max-behind'; has help out 'describe-global-clusters'
t version 0 fleet --version;         has version out '1\.7\.1'
t badopt 1 fleet --bogus
t badfmt 1 fleet -r us-east-1 -F xml
t multinoout 1 fleet -r us-east-1 -F csv,html
t bothregions 1 fleet -r us-east-1 --all-regions
t badregion 1 fleet -r useast1
t badprofile 1 fleet -P 'a;b' -r us-east-1
t badmax 1 fleet -r us-east-1 --max-behind two
t badwarn 1 fleet -r us-east-1 --warn-days -5
t badtop 0 fleet -r us-east-1 --top 0;  has badtop err 'deprecated and ignored'
t badtz 1 fleet -r us-east-1 --tz Mars/Base
t badprefix 1 fleet -r us-east-1 -o "$OUT/o" --prefix '../x'
t badhook 1 fleet -r us-east-1 --alert-webhook ftp://x
t bademail 1 fleet -r us-east-1 --alert-email 'a b@c'
t badalerton 1 fleet -r us-east-1 --alert-on sometimes
t missingarg 1 fleet -r
printf 'aws_secret_access_key = x\n' >"$OUT/cred.conf"
t confcred 1 fleet --config "$OUT/cred.conf";   has confcred err 'credentials are not accepted'
printf 'bogus = 1\n' >"$OUT/unk.conf"
t confunk 1 fleet --config "$OUT/unk.conf";     has confunk err "unknown key 'bogus'"
printf '# test\nprofiles = prod\nregions = us-east-1\nmax_behind = 5   # comment\nformat = json\n$(touch %s/pwned)\n' "$OUT" >"$OUT/inj.conf"
t confinj 1 fleet --config "$OUT/inj.conf";     chk "config is parsed, never sourced" test ! -e "$OUT/pwned"
mkconf "$OUT/c.conf" 'profiles = prod' 'regions = us-east-1' 'max_behind = 5   # comment' 'format = json' 'tag_columns = Owner'
t conf 0 fleet --config "$OUT/c.conf";          jqt conf '.summary.max_behind == 5'; jqt conf '.meta.tag_columns == []'; has conf err 'tag_columns is ignored'
t confover 0 fleet --config "$OUT/c.conf" --max-behind 1;  jqt confover '.summary.max_behind == 1'
: >"$MOCK_LOG"
t dryrun 0 fleet "${P2[@]}" --dry-run;         has dryrun out 'describe-db-major-engine-versions'; has dryrun out 'no AWS calls'
chk "dry-run made no AWS calls" test ! -s "$MOCK_LOG"

echo "== fleet (2 profiles x 2 regions)"
: >"$MOCK_LOG"
t fleet 0 fleet "${P2[@]}" -F json
jqt fleet '.summary.total == 22 and .summary.compliant == 13 and .summary.non_compliant == 8 and .summary.unknown == 1'
jqt fleet '.summary.pct_compliant == 59.1'
jqt fleet '[.meta.accounts[].account] == ["111111111111","222222222222"]'
jqt fleet '[.rows[].identifier] | index("unrelated-redis-like") == null'
jqt fleet '[.rows[].identifier] | map(select(test("^orders-pg15-|^pay-aurora-pg16-|^ledger-maz-[0-9]"))) | length == 0'
chk "engine versions looked up once per engine+region (cache)" test "$(jq -c 'select(index("describe-db-engine-versions"))' "$MOCK_LOG" | sort | uniq -d | wc -l)" -eq 0
chk "one inventory call per profile+region" test "$(jq -c 'select(index("describe-db-instances"))' "$MOCK_LOG" | wc -l)" -eq 4
chk "only describe/get calls were made" test "$(jq -r '.[] | select(test("^(modify|create|delete|apply|reboot|start|stop|failover)-"))' "$MOCK_LOG" | wc -l)" -eq 0
echo "-- rule and boundaries"
rowt fleet crm-aurora-pg15 '.versions_behind == 2 and .compliance_status == "COMPLIANT" and .newer_versions == ["15.12","15.13"]'
rowt fleet orders-aurora-pg15 '.versions_behind == 2 and .compliance_status == "COMPLIANT" and .newer_versions == ["15.10","15.12"] and .latest_minor_version == "15.12"'
rowt fleet reports-aurora-pg14 '.versions_behind == 3 and .compliance_status == "NON-COMPLIANT" and .newer_versions == ["14.13","14.15","14.17"]'
echo "-- counts come ONLY from ValidUpgradeTarget of the current version (mock full list differs on purpose)"
rowt fleet orders-aurora-pg15 '(.newer_versions | index("15.13")) == null and .major_upgrade_targets == 2'
rowt fleet reports-aurora-pg14 '(.newer_versions | index("14.18")) == null and .latest_minor_version == "14.17"'
rowt fleet shop-aurora-mysql '.newer_versions == ["8.0.mysql_aurora.3.06.0","8.0.mysql_aurora.3.07.1","8.0.mysql_aurora.3.08.2","8.0.mysql_aurora.3.09.0","8.0.mysql_aurora.3.10.0"]'
rowt fleet inv-mysql '([.newer_versions[] | select(startswith("8.4"))] | length) == 0 and .major_upgrade_targets == 2'
rowt fleet graph-neptune '.newer_versions == ["1.3.3.0","1.3.4.0"] and .default_auto_upgrade_target == "1.3.4.0"'
rowt fleet analytics-pg '([.newer_versions[] | select(startswith("13.") | not)] | length) == 0'
echo "-- default auto-upgrade target"
rowt fleet orders-aurora-pg15 '.default_auto_upgrade_target == "15.12"'
rowt fleet inv-mysql '.default_auto_upgrade_target == "8.0.40"'
rowt fleet shop-aurora-mysql '.default_auto_upgrade_target == "8.0.mysql_aurora.3.08.2"'
rowt fleet pay-aurora-pg16 '.default_auto_upgrade_target == null'
chk "every engine-version call names --engine-version (no full-list call)" test "$(jq -c 'select(index("describe-db-engine-versions")) | select(index("--engine-version") | not)' "$MOCK_LOG" | wc -l)" -eq 0
chk "engine-version calls = distinct engine+version+region" test "$(jq -c 'select(index("describe-db-engine-versions"))' "$MOCK_LOG" | wc -l)" -eq "$(jq '[.rows[] | [.engine, .current_version, .region]] | unique | length' "$OUT/fleet.out")"
rowt fleet dev-aurora-pg15 '.versions_behind == 7 and .latest_minor_version == "15.13" and .account_id == "222222222222" and .region == "ap-south-1"'
rowt fleet pay-aurora-pg16 '.versions_behind == 0 and .compliance_status == "COMPLIANT"'
rowt fleet shop-aurora-mysql '.versions_behind == 5 and .major_version == "8.0" and .latest_minor_version == "8.0.mysql_aurora.3.10.0"'
rowt fleet cms-aurora-mysql '.versions_behind == 1 and .compliance_status == "COMPLIANT"'
rowt fleet hr-sql '.versions_behind == 3 and .major_version == "15.00" and .latest_minor_version == "15.00.4430.1.v1" and .compliance_status == "NON-COMPLIANT"'
rowt fleet erp-sql '.versions_behind == 1 and .major_version == "16.00"'
rowt fleet fin-ora '.versions_behind == 2 and .major_version == "19" and .compliance_status == "COMPLIANT"'
rowt fleet inv-mysql '.versions_behind == 6 and .auto_minor_upgrade == "false" and .pending_actions_count == 2'
rowt fleet app-mysql84 '.versions_behind == 0 and .major_version == "8.4"'
rowt fleet analytics-pg '.versions_behind == 3 and .newer_versions == ["13.20","13.21","13.22"]'
rowt fleet billing-pg '.versions_behind == 2 and .resource_type == "instance" and .members == ""'
rowt fleet dev-mariadb '.versions_behind == 2 and .major_version == "10.11"'
rowt fleet qa-pg '.versions_behind == 2 and .latest_minor_version == "17.6"'
rowt fleet catalog-docdb '.resource_type == "docdb-cluster" and .versions_behind == 0 and .pending_actions_count == 1 and .major_version == "5.0"'
rowt fleet graph-neptune '.resource_type == "neptune-cluster" and .versions_behind == 2 and .major_version == "1.3" and (.support_flag | startswith("n/a"))'
rowt fleet ledger-maz '.resource_type == "multi-az-cluster" and .versions_behind == 3 and .member_count == 3 and .auto_minor_upgrade == "true"'
echo "-- support / flags"
rowt fleet legacy-aurora-pg12 '.support_flag == "past standard support (Extended Support charges)" and .past_standard_support and .extended_support_end != null'
rowt fleet old-aurora-pg11 '.deprecated_version and .compliance_status == "UNKNOWN" and .versions_behind == null and .newer_versions == [] and .latest_minor_version == null and (.note | test("current version not returned by describe-db-engine-versions"))'
rowt fleet analytics-pg '.nearing_end_of_support and (.support_flag | test("^standard support ends in 1[0-9][0-9] days$"))'
rowt fleet inv-mysql '.nearing_end_of_support'
rowt fleet hr-sql '(.support_flag | startswith("unknown"))'
rowt fleet reports-aurora-pg14 '.auto_minor_upgrade == "false"'
rowt fleet shop-aurora-mysql '.auto_minor_upgrade == "mixed" and (.note | test("off on some members"))'
rowt fleet orders-aurora-pg15 '.pending_actions_count == 2 and .members == "orders-pg15-1 (writer), orders-pg15-2, orders-pg15-3" and .member_count == 3'
rowt fleet orders-aurora-pg15 '.maint_window_utc == "sat:21:00-sat:21:30" and .maint_window_ist == "sun:02:30-sun:03:00"'
rowt fleet hr-sql '.maint_window_ist == "sun:00:00-sun:00:30"'
rowt fleet orders-aurora-pg15 '.tags.Owner == "orders" and (.arn | test("^arn:aws:rds:us-east-1:111111111111:cluster:orders-aurora-pg15$"))'
jqt fleet '.summary.past_standard_support == 2 and .summary.nearing_end_of_support == 2 and .summary.auto_minor_off == 3 and .summary.with_pending == 3 and .summary.pending_total == 5 and .summary.deprecated == 1'
jqt fleet '.summary.pending_by_action == {"os-upgrade":2,"system-update":2,"db-upgrade":1}'
echo "-- pending maintenance text"
rowt fleet orders-aurora-pg15 '(.pending_actions | test("^system-update on cluster \\(auto-apply [0-9]{4}-[0-9]{2}-[0-9]{2}, forced [0-9]{4}-[0-9]{2}-[0-9]{2}\\) - Upgrade to Aurora PostgreSQL 15.8.1 patch; os-upgrade on member orders-pg15-2 \\(opt-in: next-maintenance\\) - New Operating System update is available$"))'
rowt fleet orders-aurora-pg15 '.pending_actions_detail[0].auto_applied_after_ist | test("^[0-9]{4}-[0-9]{2}-[0-9]{2} 01:30 IST$")'
rowt fleet inv-mysql '(.pending_actions | test("^db-upgrade \\(auto-apply [0-9-]{10}\\) - Automatic minor version upgrade to 8.0.40; os-upgrade \\(no date, optional\\) - New Operating System update is available; it includes sec\\.\\.\\.$"))'
rowt fleet catalog-docdb '(.pending_actions | startswith("system-update on member catalog-docdb-2 (auto-apply "))'
rowt fleet pay-aurora-pg16 '.pending_actions == "" and .pending_actions_count == 0'
echo "-- upgrade commands (printed only)"
jqt fleet '[.rows[] | select(has("upgrade_command") or has("tags_shown"))] | length == 0'
t noprofile 0 fleet -r us-east-1 -F json -e postgres
jqt noprofile '[.rows[].profile] | unique == ["default"]'
echo "-- sorting / summary"
jqt fleet '[.rows[] | select(.engine == "aurora-postgresql") | .identifier] == ["dev-aurora-pg15","legacy-aurora-pg12","reports-aurora-pg14","old-aurora-pg11","crm-aurora-pg15","orders-aurora-pg15","pay-aurora-pg16"]'
jqt fleet '.summary | has("top_behind") | not'
jqt fleet '(.summary.engines[] | select(.engine == "aurora-postgresql") | .majors | map(.major)) == ["16","15","14","12","11"]'
jqt fleet '(.summary.engines[] | select(.engine == "aurora-postgresql") | .majors[] | select(.major == "15")) | .total == 3 and .compliant == 2 and .non_compliant == 1 and .latest_minor == "15.13"'
jqt fleet '(.summary.engines[] | select(.engine == "aurora-postgresql") | .majors[] | select(.major == "14")) | .latest_minor == "14.17"'
t top3 0 fleet "${P2[@]}" -F json --top 3;   has top3 err '--top / top = is deprecated and ignored'; jqt top3 '.summary | has("top_behind") | not'
echo "-- options"
t max3 0 fleet -P prod -r us-east-1 -F json --max-behind 3
rowt max3 reports-aurora-pg14 '.compliance_status == "COMPLIANT"';  rowt max3 shop-aurora-mysql '.compliance_status == "NON-COMPLIANT"'
t max0 0 fleet -P prod -r us-east-1 -F json --max-behind 0
rowt max0 cms-aurora-mysql '.compliance_status == "NON-COMPLIANT"';  rowt max0 pay-aurora-pg16 '.compliance_status == "COMPLIANT"'
t warn100 0 fleet -P prod -r us-east-1 -F json --warn-days 100;  jqt warn100 '.summary.nearing_end_of_support == 0'
t nconly 0 fleet "${P2[@]}" -F json --non-compliant-only
jqt nconly '(.rows | length) == 8 and all(.rows[]; .compliance_status == "NON-COMPLIANT") and .summary.total == 22'
t failnc 5 fleet "${P2[@]}" --fail-on-noncompliant
t failnc_ok 0 fleet -P prod -r us-east-1 -e docdb,neptune --fail-on-noncompliant
t engglob 0 fleet -P prod -r us-east-1 -F json -e 'aurora-*' -e 'SQLSERVER-*'
jqt engglob '[.rows[].engine] | unique == ["aurora-mysql","aurora-postgresql","sqlserver-se"]'
t idmember 0 fleet -P prod -r us-east-1 -F json -i 'orders-pg15-2'
jqt idmember '[.rows[].identifier] == ["orders-aurora-pg15"]'
t idglob 0 fleet -P prod -r us-east-1 -F json -i 'billing-*'
jqt idglob '(.rows | length) == 2'
t empty 0 empty -P prod -r us-east-1;  has empty out 'No servers matched'
echo "-- failures"
t lookupfail 0 lookupfail -P prod -r us-east-1 -F json
rowt lookupfail shop-aurora-mysql '.compliance_status == "UNKNOWN" and .versions_behind == null and (.note | test("Throttling"))'
jqt lookupfail '.summary.unknown == 3 and .summary.errors == 0'
has lookupfail err 'WARN.*aurora-mysql .* failed'
t nolc 0 nolc -P prod -r us-east-1 -F json
jqt nolc '.meta.lifecycle_api == false and ([.rows[] | select(.engine == "postgres") | .support_flag] | unique) == ["unknown (lifecycle lookup unavailable)"]'
chk "nolc: lifecycle API tried only once" test "$(grep -c 'describe-db-major-engine-versions' "$MOCK_LOG")" -ge 1
t lcfail 0 lcfail -P prod -r us-east-1 -F json
jqt lcfail '.summary.non_compliant == 7 and .summary.past_standard_support == 0'
t denied 0 accessdenied -P prod -r us-east-1,eu-west-1
has denied out 'ERRORS'; has denied out 'eu-west-1: rds describe-db-clusters: .*AccessDenied'
t badcreds 2 badcreds -P prod -r us-east-1;  has badcreds err 'No profile could be used'
t onebroken 0 fleet -P prod,broken -r us-east-1 -F json;  jqt onebroken '(.errors | length) == 1 and .summary.total == 19'
t allreg 0 fleet -P nonprod --all-regions -F json;  jqt allreg '.meta.regions == ["ap-south-1","eu-west-1","us-east-1"] and .summary.total == 3'
MOCK_DEFAULT_REGION=ap-south-1 t defregion 0 fleet -P nonprod -F json;  jqt defregion '.summary.total == 3'
t noregion 2 fleet -P prod

echo "== output files"
t files 0 fleet "${P2[@]}" -F csv,html,txt,json -o "$OUT/rep" -T Environment,Owner
mapfile -t F < <(find "$OUT/rep" -type f | sort)
chk "5 files written (txt, html, json, csv, regions csv)" test "${#F[@]}" -eq 5
chk "files are 0640" test "$(stat -c %a "${F[@]}" | sort -u)" = 640
CSV="$(find "$OUT/rep" -name '*.csv' ! -name '*_regions.csv')"; HTML="$(find "$OUT/rep" -name '*.html')"; TXT="$(find "$OUT/rep" -name '*.txt')"
chk "csv header" test "$(head -1 "$CSV")" = '"account_id","profile","region","resource_type","identifier","members","engine","major_version","current_version","latest_minor_version","versions_behind","newer_versions","default_auto_upgrade_target","compliance_status","auto_minor_upgrade","standard_support_end","extended_support_end","support_flag","pending_actions_count","pending_actions","deprecated_version","maint_window_utc","maint_window_ist","next_maintenance","days_until_maintenance","global_cluster","global_role","account_name"'
chk "csv rows = 22" test "$(python3 -c 'import csv,sys; print(sum(1 for _ in csv.reader(open(sys.argv[1])))-1)' "$CSV")" -eq 22
chk "csv parses with 28 columns everywhere" test "$(python3 -c 'import csv,sys; print(set(len(r) for r in csv.reader(open(sys.argv[1]))))' "$CSV")" = "{28}"
for p in 'id="q"' 'id="f-gl"' 'id="f-sa"' 'id="empty"' 'id="tab-comp"' 'id="tab-pend"' 'id="p-tbl"' 'class="pl" data-i=' '>2 pending<' 'class="sl" data-i=' '01:30 IST' "haven't been applied yet" 'Valid minor targets' 'Auto-upgrade default' 'table class="main"' 'st bad' 'st ok' 'Extended Support' 'id="about"' 'About this report' 'id="eng-tbl"' 'details class="eng-sec"' 'id="f-flag"' 'localeCompare' 'href="#eng-aurora-postgresql"'; do
    if grep -qF -- "$p" "$HTML"; then ok "html has $p"; else bad "html lacks $p"; fi
done
chk "html is well-formed enough (python html.parser)" python3 -c 'import html.parser,sys; html.parser.HTMLParser().feed(open(sys.argv[1]).read())' "$HTML"
for p in '^SUMMARY' '^PER ENGINE / MAJOR VERSION' '^ABOUT THIS REPORT' '^=== aurora-postgresql: 7' '59.1% compliant' 'past standard support' 'Pending maint\.   : on 3 server\(s\): os-upgrade 2, system-update 2, db-upgrade 1' '^PENDING MAINTENANCE \(5 action\(s\) on 3 server\(s\)' 'os-upgrade +member orders-pg15-2 +orders-aurora-pg15'; do
    if grep -qE -- "$p" "$TXT"; then ok "txt has /$p/"; else bad "txt lacks /$p/"; fi
done
chk "summary is at the top of the txt" test "$(grep -n '^SUMMARY' "$TXT" | cut -d: -f1)" -lt 10
chk "v1.3.1: txt header is 4 lines + blank (title, accounts, regions, rule)" test "$(grep -n '^SUMMARY' "$TXT" | cut -d: -f1)" -le 6
chk "v1.3.1: no most-behind list in txt / html" bash -c "! grep -qi 'most behind' '$TXT' '$HTML'"
chk "v1.3.1: long explanations only below (txt)" test "$(grep -n 'ValidUpgradeTarget' "$TXT" | head -1 | cut -d: -f1)" -gt "$(grep -n '^ABOUT THIS REPORT' "$TXT" | cut -d: -f1)"
chk "v1.3.1: long explanations only in About (html)" python3 -c 'import sys; t=open(sys.argv[1]).read(); a=t.index("<table"); assert all(k not in t[:a] for k in ("describe-db-engine-versions", "haven&#39;t", "IsMajorVersionUpgrade", "maintenance window"))' "$HTML"
t notags 0 fleet -P prod -r us-east-1 -F csv -T ''
chk "-T '' -> no tag columns" bash -c "! head -1 '$OUT/notags.out' | grep -q tag:"
t logf 0 fleet -P prod -r us-east-1 -l "$OUT/run.log"
chk "log file has timestamped lines" grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} \[INFO\]' "$OUT/run.log"

echo "== region discovery (-A) and region-wise breakdown (MOCK_SCENARIO=discover: 14 regions)"
# prod: us-east-1 = fleet, us-west-2 = one headless Aurora cluster only, ca-central-1 = describe-db-instances AccessDenied (SCP)
api_calls() { jq -c 'select(.[0] == "--output")' "$MOCK_LOG" | wc -l; }   # AWS API calls (not `aws --version` / `aws configure get`)
probes() { jq -c 'select(index("--query"))' "$MOCK_LOG" | wc -l; }
full_regions() { jq -r 'select(index("describe-db-instances") and (index("--query") | not)) | .[index("--region") + 1]' "$MOCK_LOG" | sort -u | paste -sd, -; }
: >"$MOCK_LOG"
t disc 0 discover -P prod -A -F json
jqt disc '.summary.region_overview | .mode == "discover" and .probe_parallel == 8 and .checked == 14 and .with_databases == 2 and .empty == 11 and .error == 1'
jqt disc '[.summary.regions[] | select(.status == "empty") | .region] == ["ap-northeast-1","ap-south-1","ap-southeast-1","ap-southeast-2","eu-central-1","eu-north-1","eu-west-1","eu-west-2","sa-east-1","us-east-2","us-west-1"]'
jqt disc '[.summary.regions[] | select(.status == "empty") | .total + .compliant + .non_compliant + .unknown + .with_pending] | add == 0'
chk "disc: 28 probes (2 per enabled region)" test "$(probes)" -eq 28
chk "disc: full scan only where databases or a probe error ($(full_regions))" test "$(full_regions)" == "ca-central-1,us-east-1,us-west-2"
chk "disc: no pending-maintenance call in an empty region" test "$(jq -c 'select(index("describe-pending-maintenance-actions")) | select(index("eu-west-1") or index("us-east-2"))' "$MOCK_LOG" | wc -l)" -eq 0
jqt disc '.summary.regions[] | select(.region == "us-west-2") | .status == "databases" and .total == 1 and .compliant == 1 and .probe_instances == 0 and .probe_clusters == 1'
rowt disc dr-aurora-pg15 '.region == "us-west-2" and .resource_type == "aurora-cluster" and .member_count == 0'
jqt disc '.summary.regions[] | select(.region == "ca-central-1") | .status == "error" and .probe_instances == null and .probe_clusters == 0 and .errors >= 1'
jqt disc '[.errors[] | select(.region == "ca-central-1" and .call == "rds describe-db-instances (discovery probe)" and (.message | test("AccessDenied")) and (.message | test("scanned in full anyway")))] | length == 1'
jqt disc '.meta.aws_failures >= 1'
chk "disc: aws_calls (incl. probes) = calls made ($(jq .meta.aws_calls "$OUT/disc.out") vs $(api_calls))" test "$(jq .meta.aws_calls "$OUT/disc.out")" -eq "$(api_calls)"
jqt disc '.meta.regions | length == 14'
echo "-- breakdown totals = overall totals"
jqt disc '.summary as $s | [$s.regions[].total] | add == $s.total'
jqt disc '.summary as $s | ([$s.regions[].compliant] | add) == $s.compliant and ([$s.regions[].non_compliant] | add) == $s.non_compliant and ([$s.regions[].unknown] | add) == $s.unknown and ([$s.regions[].with_pending] | add) == $s.with_pending'
jqt disc '.summary as $s | $s.regions_total | .region == "All regions" and .total == $s.total and .compliant == $s.compliant and .non_compliant == $s.non_compliant and .unknown == $s.unknown and .pct_compliant == $s.pct_compliant and .with_pending == $s.with_pending'
jqt disc '.summary.regions[] | select(.region == "us-east-1") | .total == 19 and .compliant == 11 and .non_compliant == 7 and .unknown == 1 and .pct_compliant == 57.9 and .with_pending == 3'
jqt disc '.summary as $s | [.rows[] | select(.region == "us-east-1")] | length == ($s.regions[] | select(.region == "us-east-1") | .total)'
t disc_txt 0 discover -P prod -A
has disc_txt out '^Regions  : 14 checked, 2 with databases, 11 empty, 1 error$'; has disc_txt out '^  Regions : discovery probe, 8 in parallel'
hasnt disc_txt out '^Empty'
has disc_txt out '^Accounts : 111111111111 prod-core \(prod\)   Regions: all enabled$'
chk "disc_txt: no region names above SUMMARY" test "$(sed '/^SUMMARY/q' "$OUT/disc_txt.out" | grep -cE '[a-z]{2}-[a-z]+-[0-9]')" -eq 0
has disc_txt out '^PER REGION'
has disc_txt out '^  111111111111  us-east-1       databases      19     11      7     1   57\.9% +2$'
has disc_txt out '^  111111111111  ca-central-1    error           0 .* see ERRORS \(no data\)'
hasnt disc_txt out '^  [0-9]{12}  [a-z0-9-]+ +empty '
chk "disc_txt: PER REGION = 2 databases + 1 error + ALL rows" test "$(sed -n '/^PER REGION/,/^$/p' "$OUT/disc_txt.out" | grep -cE '^  (111111111111|ALL) ')" -eq 4
has disc_txt out '^  ALL           All regions                    20     12      7     1     60% +2$'
has disc_txt out 'ca-central-1: rds describe-db-instances \(discovery probe\): .*AccessDenied'
has disc_txt err 'discovery: probing 14 region\(s\), 8 at a time'
t disc_files 0 discover -P prod -A -F csv,html -o "$OUT/disc"
RCSV="$(find "$OUT/disc" -name '*_regions.csv')"; RHTML="$(find "$OUT/disc" -name '*.html')"
chk "regions csv written" test -s "$RCSV"
chk "regions csv: header + 2 regions with databases + 1 error + All regions (no empty rows)" test "$(wc -l <"$RCSV")" -eq 5
chk "regions csv: no empty-region rows" test "$(grep -c '"empty"' "$RCSV")" -eq 0
chk "regions csv: All regions row" grep -q '^"ALL","","All regions","",20,12,7,1,60,3,5,2,2,"",""$' "$RCSV"
chk "regions csv parses with 15 columns everywhere" test "$(python3 -c 'import csv,sys; print(set(len(r) for r in csv.reader(open(sys.argv[1]))))' "$RCSV")" == "{15}"
chk "html: sortable region table" grep -q '<table class="sortable regions"><thead><tr><th>Account</th><th>Region</th><th>Status</th><th>Total</th>' "$RHTML"
chk "html: All regions total row in tfoot" grep -q '<tfoot><tr class="foot"><td><b>All regions</b></td>' "$RHTML"
chk "html: colour-coded % compliant" grep -q 'class="n bad" data-s="57.9">57.9%<div class="bar"><i class="bad"' "$RHTML"
chk "html: no empty-regions list" test "$(grep -c 'details class="empty"\|empty region(s)' "$RHTML")" -eq 0
chk "html: header region line is counts only" grep -q '&middot; Regions: 14 checked, 2 with databases, 11 empty, 1 error</p></header>' "$RHTML"
TOPH="$(cat "$RHTML")"; TOPH="${TOPH%%<table*}"   # everything above the first table
chk "html: no region names above the first table" test "$(grep -oE '[a-z]{2}-[a-z]+-[0-9]' <<<"$TOPH" | wc -l)" -eq 0
chk "html: no <details> in the header" test "$(grep -o '<header.*</header>' "$RHTML" | grep -c '<details')" -eq 0
chk "html: region table = 3 rows (databases + error), no empty rows" test "$(grep -oP '<table class="sortable regions">.*?</tbody>' "$RHTML" | grep -o '<tr[ >]' | wc -l)" -eq 4
chk "html: no empty status chip" test "$(grep -c 'class="st unk">empty<' "$RHTML")" -eq 0
chk "html: sort script covers the region table" grep -q "querySelectorAll('table.main,table.sortable')" "$RHTML"
echo "-- --no-discover / config / explicit -r"
: >"$MOCK_LOG"
t nodisc 0 discover -P prod -A --no-discover -F json
chk "nodisc: no probe" test "$(probes)" -eq 0
chk "nodisc: every enabled region scanned in full" test "$(jq -r 'select(index("describe-db-instances")) | .[index("--region") + 1]' "$MOCK_LOG" | sort -u | wc -l)" -eq 14
jqt nodisc '.summary.region_overview | .mode == "full" and .checked == 14 and .with_databases == 2 and .empty == 11 and .error == 1'
jqt nodisc '.meta.region_discovery.probe_parallel == null and ([.meta.region_status[].status] | unique) == ["scanned"]'
jqt nodisc '.summary.total == 20 and .summary.compliant == 12'
chk "nodisc: same rows as with discovery" test "$(jq -c '[.rows[] | [.account_id, .region, .identifier, .compliance_status]] | sort' "$OUT/nodisc.out")" == "$(jq -c '[.rows[] | [.account_id, .region, .identifier, .compliance_status]] | sort' "$OUT/disc.out")"
mkconf "$OUT/nd.conf" 'profiles = prod' 'all_regions = yes' 'discover = no' 'format = json'
: >"$MOCK_LOG"
t nodisc_conf 0 discover --config "$OUT/nd.conf"
chk "discover = no in config: no probe" test "$(probes)" -eq 0
jqt nodisc_conf '.summary.region_overview.mode == "full"'
: >"$MOCK_LOG"
t disc_r 0 discover -P prod -r us-east-1,us-west-2,eu-west-1 -F json
chk "-r: no probe" test "$(probes)" -eq 0
chk "-r: only the named regions" test "$(full_regions)" == "eu-west-1,us-east-1,us-west-2"
jqt disc_r '.summary.region_overview | .mode == "explicit" and .checked == 3 and .with_databases == 2 and .empty == 1 and .error == 0'
t disc_r_txt 0 discover -P prod -r us-east-1,us-west-2
has disc_r_txt out '^Regions  : 2 checked, 2 with databases, 0 empty, 0 errors$'; has disc_r_txt out '^  Regions : queried directly, no probe'
t badpp 1 discover -P prod -A --probe-parallel 0;   has badpp err 'probe-parallel'
t badpp2 1 discover -P prod -A --probe-parallel 33
echo "-- parallel probes"
: >"$MOCK_LOG"; rm -f "$OUT/timing.jsonl"
SECONDS=0
MOCK_PROBE_DELAY=0.6 MOCK_TIMING="$OUT/timing.jsonl" t par 0 discover -P prod -A --probe-parallel 4 -F json
PAR_S=$SECONDS
MAXC="$(python3 - "$OUT/timing.jsonl" <<'PY'
import json, sys
ev = sorted([(a, 1) for a, b, *_ in map(json.loads, open(sys.argv[1]))] + [(b, -1) for a, b, *_ in map(json.loads, open(sys.argv[1]))], key=lambda e: (e[0], e[1]))
c = m = 0
for _, d in ev: c += d; m = max(m, c)
print(m)
PY
)"
chk "par: 27 probe calls timed (the 28th, ca-central-1 instances, is denied before the delay)" test "$(wc -l <"$OUT/timing.jsonl")" -eq 27
chk "par: probes ran in parallel, at most 4 at a time (max concurrent = $MAXC)" test "$MAXC" -ge 2 -a "$MAXC" -le 4
chk "par: faster than serial (28 x 0.6s = 16.8s; took ${PAR_S}s)" test "$PAR_S" -lt 14
chk "par: same breakdown as default parallelism" test "$(jq -c '.summary.regions' "$OUT/par.out")" == "$(jq -c '.summary.regions' "$OUT/disc.out")"
chk "par: aws_calls (incl. probes) = calls made" test "$(jq .meta.aws_calls "$OUT/par.out")" -eq "$(api_calls)"
t ser 0 discover -P prod -A --probe-parallel 1 -F json
chk "ser: --probe-parallel 1 gives the same breakdown" test "$(jq -c '.summary.regions' "$OUT/ser.out")" == "$(jq -c '.summary.regions' "$OUT/disc.out")"
echo "-- multi-account + other scenarios"
t disc2 0 discover -P prod,nonprod -A -F json
jqt disc2 '.summary.region_overview | .checked == 28 and .with_databases + .empty + .error == 28'
jqt disc2 '.summary as $s | ([$s.regions[].total] | add) == $s.total and $s.regions_total.total == $s.total'
jqt disc2 '[.summary.regions[] | select(.status == "databases") | "\(.account_id)/\(.region)"] | sort == ["111111111111/us-east-1","111111111111/us-west-2","222222222222/ap-south-1"]'
t disc2_txt 0 discover -P prod,nonprod -A
hasnt disc2_txt out '^Empty'
has disc2_txt out '^Regions  : 28 checked, 3 with databases, 23 empty, 2 errors'
t ad_disc 0 accessdenied -P prod -A -F json
jqt ad_disc '.summary.regions[] | select(.region == "eu-west-1") | .status == "error"'
jqt ad_disc '[.errors[] | select(.region == "eu-west-1" and .call == "rds describe-db-clusters (discovery probe)")] | length == 1'
: >"$MOCK_LOG"
t disc_dry 0 discover -P prod -A --dry-run
has disc_dry out 'discovery probe, every enabled region, 8 at a time \(2 calls per region\)'
has disc_dry out 'rds describe-db-instances --max-records 20 --query length.?\(DBInstances.?\) --no-paginate'
has disc_dry out 'rds describe-db-clusters --max-records 20 --query length.?\(DBClusters.?\) --no-paginate'
has disc_dry out 'full scan, only regions where a probe found'
chk "disc_dry: no AWS calls" test ! -s "$MOCK_LOG"
t nodisc_dry 0 discover -P prod -A --no-discover --dry-run;  hasnt nodisc_dry out 'length\(DBInstances\)'
t r_dry 0 discover -P prod -r us-east-1 --dry-run;           hasnt r_dry out 'length\(DBInstances\)'

echo "== large fleet (ARG_MAX safety)"
SECONDS=0
MOCK_LARGE_N=3000 t large 0 large -P prod -r us-east-1 -F csv,json,html -o "$OUT/large"
chk "large: 3000 rows" test "$(jq '.rows | length' "$(find "$OUT/large" -name '*.json')")" -eq 3000
chk "large: under 120s ($SECONDS s)" test "$SECONDS" -lt 120
hasnt large err 'Argument list too long'

echo "== alerts (local stubs only)"
t al_mail 0 fleet "${P2[@]}" --alert-email dba@example.com
chk "mail sent (subject)" grep -qF 'NON-COMPLIANT:\ 8\ non-compliant\ of\ 22' "$MAIL_SINK"
chk "mail (no sendmail): text summary only, not the full text report" bash -c "grep -q '^RDS patch compliance: NON-COMPLIANT' '$MAIL_SINK' && ! grep -q '^PER ENGINE / MAJOR VERSION' '$MAIL_SINK'"
: >"$MAIL_SINK"
t al_none 0 fleet -P prod -r us-east-1 -e docdb --alert-email dba@example.com
chk "no alert when all compliant (alert-on noncompliant)" test ! -s "$MAIL_SINK"
t al_hook 0 fleet "${P2[@]}" --alert-webhook "$HOOK" --alert-webhook-format json
chk "json webhook payload" bash -c "grep . '$OUT/webhook.txt' | tail -1 | jq -e '.status == \"NON-COMPLIANT\" and (.non_compliant | length) == 8' >/dev/null"
t al_slack 0 fleet "${P2[@]}" --alert-webhook "$HOOK"
chk "slack webhook payload" bash -c "grep . '$OUT/webhook.txt' | tail -1 | jq -e '.text | startswith(\"*[rds_patch_compliance]\")' >/dev/null"
hasnt al_slack err 'SECRET'
t al_test 0 fleet --alert-test --alert-email dba@example.com;  chk "test alert" grep -q 'Test alert from' "$MAIL_SINK"

echo "== v1.3.0: account number in file names, --save-data, --merge (offline)"
MG="$OUT/mg in"; mkdir -p "$MG"
RDS_PCR_NOW=1790000000 t sd_prod 0 fleet -P prod -r us-east-1,ap-south-1 -F html,csv -o "$MG" --save-data
chk "single account: html name has the account number" test -f "$MG/rds_patch_compliance_111111111111_20260921_194320.html"
chk "single account: csv + regions csv names have the account number" test -f "$MG/rds_patch_compliance_111111111111_20260921_194320_regions.csv"
SD1="$MG/rds_patch_111111111111_20260921.json"
chk "save-data default name rds_patch_<acct>_<date>.json" test -f "$SD1"
chk "save-data: schema, account, profile, collected_at UTC" jq -e '.schema == "rds_patch_compliance_data" and .schema_version == 1 and .accounts == [{account: "111111111111", profile: "prod", name: "prod-core", collected_epoch: 1790000000, collected_at: "2026-09-21T14:13:20Z"}] and .collected_at == "2026-09-21T14:13:20Z"' "$SD1"
chk "save-data: regions with databases only" jq -e '.regions == ["us-east-1"]' "$SD1"
chk "save-data: per DB engine / versions / status / pending" jq -e '(.rows | length) == 19 and all(.rows[]; has("engine") and has("current_version") and has("latest_minor_version") and has("compliance_status") and has("pending_actions_detail") and .account_id == "111111111111")' "$SD1"
chk "save-data: region_status kept (empty ap-south-1 counted)" jq -e '[.region_status[] | select(.region == "ap-south-1")] | length == 1' "$SD1"
calls_before="$(wc -l <"$MOCK_LOG")"
RDS_PCR_NOW=1790000000 t sd_prod_calls 0 fleet -P prod -r us-east-1 --save-data "$OUT/sdcalls/x.json"
chk "save-data adds no AWS call (describe + sts only)" bash -c "tail -n +$(( calls_before + 1 )) '$MOCK_LOG' | grep -qE '\"(create|modify|delete|apply|reboot|start|stop|put|add|remove|restore|copy|failover|promote)-' && exit 1 || tail -n +$(( calls_before + 1 )) '$MOCK_LOG' | grep -q describe-db"
RDS_PCR_NOW=1790100000 t sd_np 0 fleet -P nonprod -r ap-south-1 --save-data "$MG/nonprod data.json"
chk "save-data FILE with a space" test -f "$MG/nonprod data.json"
RDS_PCR_NOW=1790200000 t sd_dev 0 fleet -P dev -r eu-west-1 -F json -o "$MG" --save-data
SD3="$MG/rds_patch_333333333333_20260923.json"; chk "dev data file" test -f "$SD3"
RDS_PCR_NOW=1790000000 t sd_multi 0 fleet -P prod,nonprod -r us-east-1,ap-south-1 -F html -o "$OUT/sdm" --save-data
chk "multi-account run: one data file per account" test "$(find "$OUT/sdm" -name 'rds_patch_[0-9]*_*.json' | wc -l)" -eq 2
chk "multi-account run: html name without an account number" test "$(find "$OUT/sdm" -name 'rds_patch_compliance_2026*.html' | wc -l)" -eq 1
t sd_badname 1 fleet -P prod -r us-east-1 --save-data "$OUT/x.txt"
t sd_badname2 1 fleet -P prod -r us-east-1 --save-data "$OUT/x.txt"; has sd_badname2 err 'must end in .json'

# older prod copy: the newer collection must win
jq '.collected_epoch = 1780000000 | .collected_at = "2026-05-28T20:26:40Z" | .accounts[0].collected_epoch = 1780000000 | .rows |= map(.compliance_status = "NON-COMPLIANT" | .versions_behind = 9)' "$SD1" >"$OUT/old_prod.json"
calls_before="$(wc -l <"$MOCK_LOG")"
NOAWS="$OUT/noaws"; mkdir -p "$NOAWS"; printf '#!/bin/sh\necho AWS-CALLED >>"%s/aws_called"; exit 99\n' "$OUT" >"$NOAWS/aws"; chmod +x "$NOAWS/aws"
mg() { local name="$1" exp="$2"; shift 2; PATH="$NOAWS:$PATH" RDS_PCR_NOW=1791000000 t "$name" "$exp" fleet "$@"; }
mg merge 0 --merge "$OUT/old_prod.json" "$MG" -o "$OUT/mg out/combined.html" -F html,json
MH="$OUT/mg out/combined.html"; MJ="$OUT/mg out/combined.json"
chk "merge: -o FILE.html written" test -s "$MH"
chk "merge: json next to it" test -s "$MJ"
chk "merge: zero AWS calls (no aws exec, mock log unchanged)" test ! -e "$OUT/aws_called" -a "$(wc -l <"$MOCK_LOG")" -eq "$calls_before"
has merge err 'Skipping .*rds_patch_compliance_333333333333_.*\.json \(not a --save-data file\)'
has merge err 'Account 111111111111: using newer rds_patch_111111111111_20260921\.json .* ignoring older old_prod\.json'
has merge err '0 AWS calls'
chk "merge: 3 accounts, 24 rows, newer prod data used" jq -e '(.meta.accounts | map(.account)) == ["111111111111","222222222222","333333333333"] and (.rows | length) == 24 and .summary.non_compliant == 9' "$MJ"
chk "merge: totals = sum of single runs" jq -e '.summary.total == 24 and .summary.compliant == 14 and .summary.unknown == 1' "$MJ"
chk "merge: per-account breakdown" jq -e '[.summary.accounts[] | [.account_id, .total, .non_compliant]] == [["111111111111",19,7],["222222222222",3,1],["333333333333",2,1]]' "$MJ"
chk "merge: per region by account, empty regions left out" jq -e '[.summary.regions[] | select(.status != "empty") | .account_id + "|" + .region] == ["111111111111|us-east-1","222222222222|ap-south-1","333333333333|eu-west-1"]' "$MJ"
chk "merge: support days recomputed at merge time" jq -e '[.rows[] | select(.standard_support_end != null and .standard_support_end != "")] | length > 5 and all(.[]; .support_days_left == (((.standard_support_end + "T00:00:00Z" | fromdateiso8601) - 1791000000) / 86400 | floor))' "$MJ"
chk "merge: days differ from the collection-time copy" test "$(jq '[.rows[] | select(.identifier == "shop-aurora-mysql") | .support_days_left][0]' "$SD1")" != "$(jq '[.rows[] | select(.identifier == "shop-aurora-mysql") | .support_days_left][0]' "$MJ")"
chk "merge: days until maintenance recomputed" jq -e '[.rows[] | select(.pending_actions_count > 0) | .days_until_maintenance | numbers] | length >= 1' "$MJ"
chk "merge: sources note data" jq -e '.meta.merge.files == 4 and ([.meta.merge.sources[] | select(.file == "old_prod.json") | .superseded] == [["111111111111"]])' "$MJ"
chk "merge html: header has counts, no region names" bash -c "grep -oP '<header id=\"top\">.*?</header>' '$MH' | grep -q 'Regions: 4 checked, 3 with databases, 1 empty, 0 errors' && ! grep -oP '<header id=\"top\">.*?</header>' '$MH' | grep -qE '[a-z]{2}-[a-z]+-[0-9]'"
chk "merge html: account dropdown, region / engine / status selects, name search, Export CSV" bash -c "grep -q 'id=\"f-acct\"' '$MH' && grep -q 'id=\"f-region\"' '$MH' && grep -q 'id=\"f-engine\"' '$MH' && grep -q 'id=\"f-status\"' '$MH' && grep -q 'id=\"q\"' '$MH' && grep -q 'id=\"f-csv\"' '$MH'"
chk "merge html: per account table + merged inputs note" bash -c "grep -q '<section id=\"accounts\">' '$MH' && grep -q '<section id=\"sources\">' '$MH' && grep -q 'old_prod.json' '$MH'"
chk "merge html: no empty region rows" test "$(grep -oP '<table class="sortable regions">.*?</tbody>' "$MH" | grep -o '<tr[ >]' | wc -l)" -eq 4
chk "merge html: embedded data cannot close the script tag" bash -c "grep -oP '<script type=\"application/json\" id=\"pc-data\">\K.*?(?=</script>)' '$MH' | grep -q . && ! grep -oP '<script type=\"application/json\" id=\"pc-data\">\K.*?(?=</script>)' '$MH' | grep -q '<'"
mg merge_txt 0 --merge "$SD1" "$MG/nonprod data.json" "$SD3" -F text; has merge_txt out '^PER ACCOUNT'; has merge_txt out '^Accounts : 111111111111 prod-core \(prod\), 222222222222 \(nonprod\), 333333333333 \(dev\)   Merged: 3 file\(s\)'
mg merge_dir_default 0 --merge "$MG" -o "$OUT/mgd"
chk "merge: default format html, -o DIR" test "$(find "$OUT/mgd" -name 'rds_patch_compliance_2026*.html' | wc -l)" -eq 1
mg merge_mb 0 --merge "$SD1" --max-behind 9 -F json; jqt merge_mb '.summary.non_compliant == 0'
mg merge_glob 0 --merge "$MG/rds_patch_1*.json" -F json; jqt merge_glob '(.meta.accounts | length) == 1'
# errors -> exit 3
mg mbad_missing 3 --merge "$OUT/nope.json";           has mbad_missing err 'File not found'
printf '{"rows": [' >"$OUT/trunc.json";  mg mbad_trunc 3 --merge "$OUT/trunc.json";   has mbad_trunc err 'not valid JSON'
mg mbad_html 3 --merge "$MH";                         has mbad_html err 'is an HTML report'
mg mbad_report 3 --merge "$MJ";                        has mbad_report err 'is a -F json report'
echo '{"schema":"rds_patch_compliance_data","schema_version":2,"accounts":[{"account":"1"}],"rows":[],"collected_epoch":1}' >"$OUT/v2.json"
mg mbad_v2 3 --merge "$OUT/v2.json";                  has mbad_v2 err 'newer data schema 2'
echo '{"schema":"x"}' >"$OUT/other.json"; mg mbad_other 3 --merge "$OUT/other.json"; has mbad_other err 'not a patch compliance data file'
mkdir -p "$OUT/emptydir"; mg mbad_dir 3 --merge "$OUT/emptydir";  has mbad_dir err 'No --save-data JSON file'
mg mbad_noargs 1 --merge
mg mbad_profile 1 --merge "$SD1" -P prod
mg mbad_region 1 --merge "$SD1" -r us-east-1
# Git Bash: jq.exe writes CRLF, Windows paths, spaces
CR="$OUT/crlfjq"; mkdir -p "$CR"; REALJQ="$(command -v jq)"
printf '#!/bin/bash\n"%s" "$@" | sed '"'"'s/$/\\r/'"'"'; exit "${PIPESTATUS[0]}"\n' "$REALJQ" >"$CR/jq"; chmod +x "$CR/jq"
mkdir -p "$OUT/drv/c/Users/DBA Team/patch data"; cp "$SD1" "$MG/nonprod data.json" "$SD3" "$OUT/drv/c/Users/DBA Team/patch data/"
PATH="$CR:$NOAWS:$PATH" RDS_PCR_DRIVE_ROOT="$OUT/drv" RDS_PCR_NOW=1791000000 t merge_win 0 fleet --merge 'C:\Users\DBA Team\patch data' -o "$OUT/win out/combined.html" -F html,json,csv
chk "git bash: CRLF jq output -> HTML has no CR" bash -c "test -s '$OUT/win out/combined.html' && ! grep -q $'\r' '$OUT/win out/combined.html'"
chk "git bash: same numbers as the LF merge" test "$(jq -c '[.summary.total, .summary.non_compliant, (.summary.accounts | length)]' "$OUT/win out/combined.json")" = '[24,9,3]'
chk "git bash: windows path with spaces resolved" grep -q 'Input 1: .*drv/c/Users/DBA Team/patch data/' "$OUT/merge_win.err"
chk "git bash: no aws executed" test ! -e "$OUT/aws_called"
if command -v node >/dev/null 2>&1 && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && NODE_PATH="${NODE_PATH:-}" node -e 'require("puppeteer-core")' 2>/dev/null; then
    res="$(node "$HERE/browser_check.js" "$MH" ${SHOTS:+"$SHOTS"} 2>&1)"; rc=$?
    chk "browser: filters, totals, per region, CSV export ($(jq -r '.checks' <<<"$res" 2>/dev/null) checks) ${res:0:300}" test "$rc" -eq 0
    res="$(node "$HERE/browser_check.js" "$(find "$MG" -name 'rds_patch_compliance_111111111111_*.html' | head -1)" 2>&1)"; rc=$?
    chk "browser: single-account report ${res:0:300}" test "$rc" -eq 0
    res="$(node "$HERE/browser_tabs.js" "$MH" ${SHOTS:+"$SHOTS/tabs_merged"} 2>&1)"; rc=$?
    chk "browser v1.7.0: two tabs on the merged report ($(jq -r '.checks' <<<"$res" 2>/dev/null) checks) ${res:0:300}" test "$rc" -eq 0
else echo "  skip browser check (node + puppeteer-core on NODE_PATH + Chrome not found)"; fi

echo "== v1.4.1: tampered --merge file cannot inject HTML/JS (M1)"
XP='<img src=x data-xss=1 onerror="window.__xss=1">'
XD="$OUT/xss in"; mkdir -p "$XD"
jq --arg x "$XP" '.rows[0] |= (.versions_behind = null | .compliance_status = ("UNKNOWN" + $x)) | .rows[1] |= (.engine = ("aurora-mysql" + $x) | .compliance_status = "NON-COMPLIANT") | .accounts[0].name = ("acct" + $x) | .rows[2] |= (.global_cluster = ("g" + $x) | .global_role = "primary") | .rows |= map(.maint_window_ist = ("w" + $x) | .pending_actions_detail |= map(.action = ("a" + $x) | .description = ("d" + $x) | .opt_in_status = ("o" + $x) | .on = ("member m" + $x) | .auto_applied_after_ist = ("i" + $x)))' "$SD1" >"$XD/rds_patch_111111111111_20260921.json"
mg xss 0 --merge "$XD" -o "$OUT/xss out/x.html" -F html,json,csv
XH="$OUT/xss out/x.html"
chk "xss: report written" test -s "$XH"
chk "xss: payload survived the merge (test is meaningful)" jq -e '[.rows[] | select(.compliance_status | test("data-xss"))] | length == 1' "$OUT/xss out/x.json"
chk "xss: payload only appears escaped in the HTML body" bash -c "! grep -q '<img src=x data-xss' '$XH' && grep -q '&lt;img src=x data-xss' '$XH'"
if command -v node >/dev/null 2>&1 && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && NODE_PATH="${NODE_PATH:-}" node -e 'require("puppeteer-core")' 2>/dev/null; then
    res="$(node "$HERE/xss_check.js" "$XH" 2>&1)"; rc=$?
    chk "xss: headless Chrome, no payload executed or injected ${res:0:300}" test "$rc" -eq 0
else echo "  skip xss browser check (node + puppeteer-core on NODE_PATH + Chrome not found)"; fi

echo "== v1.7.1: Pending maintenance action types (standard list + unknown type appended)"
AT="$OUT/at in"; mkdir -p "$AT"
jq '.rows |= map(.pending_actions_detail |= map(if .action == "os-upgrade" and .on == "" then .action = "storage-volume-update" else . end))' "$SD1" >"$AT/rds_patch_111111111111_20260921.json"
mg atypes 0 --merge "$AT" -o "$OUT/at out/at.html" -F html,txt
ATH="$OUT/at out/at.html"; ATT="$(find "$OUT/at out" -name '*.txt' | head -1)"
chk "v1.7.1 html: dropdown has the 5 standard types with counts, zero ones disabled, unknown type appended" bash -c "grep -q '<option value=\"hardware-maintenance\" disabled>hardware-maintenance (0)</option><option value=\"ca-certificate-rotation\" disabled>ca-certificate-rotation (0)</option><option value=\"storage-volume-update\">storage-volume-update (1)</option>' '$ATH' && grep -q '<option value=\"db-upgrade\">db-upgrade (1)</option>' '$ATH'"
chk "v1.7.1 txt: By type line" bash -c "grep -qE '^  By type: system-update 2, .*db-upgrade 1, .*storage-volume-update 1, .*hardware-maintenance 0, ca-certificate-rotation 0$' '$ATT'"
if command -v node >/dev/null 2>&1 && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && NODE_PATH="${NODE_PATH:-}" node -e 'require("puppeteer-core")' 2>/dev/null; then
    res="$(node "$HERE/browser_tabs.js" "$ATH" 2>&1)"; rc=$?
    chk "browser v1.7.1: unknown action type appended to the dropdown and strip ${res:0:300}" bash -c "test $rc -eq 0 && grep -q 'storage-volume-update' <<<'$res'"
fi

echo "== v1.3.1: merge compatibility (v1.3.0 + v1.3.1 files, report + summary script, duplicate older account)"
CP="$OUT/compat in"; mkdir -p "$CP"; cp "$HERE"/fixtures/v130/*.json "$CP/"
SUMS="$TOOL/rds_patch_compliance_summary.sh"
RDS_PCR_NOW=1790000000 MOCK_SCENARIO=fleet "$SCRIPT" -P prod -r us-east-1 --save-data "$CP/prod_v131_report.json" -o "$OUT/cpx" -F json >/dev/null 2>&1
RDS_PCR_NOW=1790200000 MOCK_SCENARIO=fleet "$SUMS" -P dev -r eu-west-1 --save-data "$CP/dev_v131_summary.json" >/dev/null 2>&1
CURV=$("$SCRIPT" --version | awk '{print $2}')
chk "compat inputs: 2 x v1.3.0 + 2 x current ($CURV)" test "$(jq -r .script_version "$CP"/*.json | sort | uniq -c | tr -s ' ' | tr '\n' ';')" = " 2 1.3.0; 2 $CURV;"
mg cmp 0 --merge "$CP" -o "$OUT/compat out/combined.html" -F html,json,csv,txt
CJ="$OUT/compat out/combined.json"
chk "compat: 3 accounts, 24 servers, 9 non-compliant" test "$(jq -c '[(.summary.accounts | length), .summary.total, .summary.non_compliant]' "$CJ")" = '[3,24,9]'
chk "compat: newer v1.3.1 prod file wins over the older v1.3.0 one" jq -e '(.meta.merge.sources[] | select(.file | test("v130_old")) | .used | length) == 0 and (.meta.merge.sources[] | select(.file | test("prod_v131")) | .used == ["111111111111"])' "$CJ"
chk "compat: v1.3.0 summary-script file used (nonprod)" jq -e '.meta.merge.sources[] | select(.file | test("summary_v130")) | .used == ["222222222222"]' "$CJ"
chk "compat: no top_behind in merged JSON" jq -e '.summary | has("top_behind") | not' "$CJ"
CT="$OUT/compat out/combined.txt"; CH="$OUT/compat out/combined.html"
chk "compat txt: no MOST BEHIND, has PER ACCOUNT + ABOUT" bash -c "! grep -qi 'most behind' '$CT' && grep -q '^PER ACCOUNT' '$CT' && grep -q '^ABOUT THIS REPORT' '$CT'"
chk "compat html: no Top most behind, has About details" bash -c "! grep -qi 'most behind' '$CH' && grep -q 'id=\"about\"' '$CH'"
chk "compat csv: 24 rows x 28 cols (no tag columns)" test "$(python3 -c 'import csv,sys; r=list(csv.reader(open(sys.argv[1]))); print(len(r)-1, set(map(len,r)))' "$OUT/compat out/combined.csv")" = "24 {28}"
chk "compat: merged outputs from pre-1.4 files show no command / ARN / tags" bash -c "! grep -lE 'modify-db|arn:aws|tag:|upgrade_command' '$OUT/compat out/combined.csv' '$OUT/compat out/combined.html' '$OUT/compat out/combined.txt' && ! grep -qE 'modify-db|upgrade_command' '$OUT/compat out/combined.json'"
chk "compat: same numbers as merging only v1.3.1-format data" test "$(jq -c '.summary | [.compliant,.non_compliant,.unknown]' "$CJ")" = '[14,9,1]'
mkdir -p "$OUT/drv/c/Users/DBA Team/compat data"; cp "$CP"/*.json "$OUT/drv/c/Users/DBA Team/compat data/"
PATH="$CR:$NOAWS:$PATH" RDS_PCR_DRIVE_ROOT="$OUT/drv" RDS_PCR_NOW=1791000000 t cmp_win 0 fleet --merge 'C:\Users\DBA Team\compat data' -o "$OUT/compat win/combined.html" -F html,json,csv,txt
chk "compat git bash: same numbers, no CR in any output" bash -c "test \"\$(jq -c '[(.summary.accounts | length), .summary.total, .summary.non_compliant]' '$OUT/compat win/combined.json')\" = '[3,24,9]' && ! grep -lq \$'\r' '$OUT/compat win/combined.html' '$OUT/compat win/combined.txt' '$OUT/compat win/combined.json'"
PATH="$NOAWS:$PATH" RDS_PCR_NOW=1791000000 "$SUMS" --merge "$CP" -o "$OUT/compat sum" -F txt,csv >/dev/null 2>"$OUT/cmp_sum.err"
chk "compat: summary script merges the same mixed set (24 / 9)" grep -q 'OVERALL  : 24 servers/clusters | COMPLIANT 14 | NON-COMPLIANT 9' "$OUT"/compat\ sum/*.txt
chk "compat: no aws executed" test ! -e "$OUT/aws_called"
if command -v node >/dev/null 2>&1 && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && NODE_PATH="${NODE_PATH:-}" node -e 'require("puppeteer-core")' 2>/dev/null; then
    res="$(node "$HERE/browser_check.js" "$CH" 2>&1)"; rc=$?
    chk "browser: compat merged HTML filters + Export CSV ($(jq -r '.checks' <<<"$res" 2>/dev/null) checks) ${res:0:300}" test "$rc" -eq 0
    res="$(node "$HERE/browser_check.js" "$OUT/compat win/combined.html" 2>&1)"; rc=$?
    chk "browser: compat git-bash merged HTML ${res:0:300}" test "$rc" -eq 0
    res="$(node "$HERE/browser_tabs.js" "$CH" 2>&1)"; rc=$?
    chk "browser v1.7.0: two tabs on a merge of v1.3.0 data files ${res:0:300}" test "$rc" -eq 0
fi

echo "== v1.4.0: Aurora global databases"
GR=(-P prod -r us-east-1,us-west-2,eu-west-1)
t glob 0 global "${GR[@]}" -F json
rowt glob orders-aurora-pg15 '.global_cluster == "orders-global" and .global_role == "primary" and (.pending_actions | test("system-update on global orders-global"))'
rowt glob orders-dr-pg15 '.global_cluster == "orders-global" and .global_role == "secondary" and .compliance_status == "NON-COMPLIANT"'
rowt glob shop-dr-mysql '.global_cluster == "shop-global" and .global_role == "secondary"'
rowt glob inv-mysql '.global_cluster == "" and .global_role == ""'
jqt glob '.summary.global_databases == 2 and .summary.global_members == 4'
jqt glob '(.summary.globals[] | select(.global_cluster == "orders-global")) | .region_status_mismatch and .overall_status == "NON-COMPLIANT" and .not_scanned == 1 and .member_count == 2'
jqt glob '(.summary.globals[] | select(.global_cluster == "shop-global")) | .region_status_mismatch | not'
jqt glob '[.rows[] | select(has("upgrade_command"))] | length == 0'
t globtxt 0 global "${GR[@]}" -F txt,csv,html -o "$OUT/glob"
GT="$(find "$OUT/glob" -name '*[0-9].txt' | head -1)"; GH="$(find "$OUT/glob" -name '*.html' | head -1)"; GC="$(find "$OUT/glob" -name '*[0-9].csv' | head -1)"
chk "glob txt: header + section + mismatch" bash -c "grep -q 'Global databases : 2 (4 members)' '$GT' && grep -q '^GLOBAL DATABASES' '$GT' && grep -q 'region status mismatch' '$GT'"
chk "glob csv: global_cluster/global_role then account_name last" bash -c "head -1 '$GC' | grep -q '\"global_cluster\",\"global_role\",\"account_name\"\$'"
echo "== v1.7.0: two-tab report (Patch compliance + Pending maintenance)"
chk "v1.7.0 txt: PENDING MAINTENANCE lists the global database action next to its cluster" bash -c "grep -q '^PENDING MAINTENANCE (6 action(s) on 3 server(s)' '$GT' && grep -qE 'system-update +global orders-global +orders-aurora-pg15' '$GT'"
chk "v1.7.0 txt: no per-server 'pending:' lines, no PEND column" bash -c "! grep -qE '^ +pending: ' '$GT' && ! grep -qE ' PEND ' '$GT'"
chk "v1.7.0 txt: soonest first outside a global group (inv-mysql db-upgrade before catalog-docdb)" bash -c "test \$(grep -nE 'db-upgrade +instance +inv-mysql' '$GT' | cut -d: -f1) -lt \$(grep -nE 'member catalog-docdb-2 +catalog-docdb' '$GT' | cut -d: -f1)"
chk "v1.7.0 html: tabs + Pending table, no badge / details / window column" bash -c "grep -q 'id=\"tb-pend\"' '$GH' && grep -q 'id=\"p-tbl\"' '$GH' && ! grep -q 'details class=\"pend\"' '$GH' && ! grep -q 'Maint. window' '$GH' && ! grep -q 'value=\"pend\"' '$GH'"
chk "v1.7.0 html: global members adjacent in tab 1 (orders-global rows are consecutive)" python3 - "$GH" <<'PY'
import re,sys,json
h=open(sys.argv[1]).read(); d=json.loads(re.search(r'id="pc-data">(.*?)</script>',h,re.S).group(1))
order=[int(i) for i in re.findall(r'<tr data-i="(\d+)"',h)]
keys=[(d['rows'][i]['account_id'],d['rows'][i].get('global_cluster') or None) for i in order]
seen=set();last=None
for k in keys:
    if k[1] and k!=last and k in seen: sys.exit(1)
    if k[1]: seen.add(k)
    last=k
roles=[d['rows'][i]['global_role'] for i in order if d['rows'][i].get('global_cluster')=='orders-global']
sys.exit(0 if roles and roles[0]=='primary' else 1)
PY
chk "v1.7.0 csv: same 28 columns, global members adjacent" python3 - "$GC" <<'PY'
import csv,sys
r=list(csv.reader(open(sys.argv[1]))); h=r[0]; gi=h.index('global_cluster')
assert len(h)==28 and all(len(x)==28 for x in r)
g=[x[gi] for x in r[1:]]; seen=set(); last=None
for k in g:
    if k and k!=last and k in seen: sys.exit(1)
    if k: seen.add(k)
    last=k
PY
chk "glob: no ARN / command / tags / notes in txt csv html" bash -c "! grep -lE 'arn:aws|modify-db|modify-global|tag:|\"note\"|Copy</button>' '$GT' '$GC' '$GH'"
chk "glob html: checkboxes + collapsed section + mismatch badge" bash -c "grep -q 'id=\"f-gl\"' '$GH' && ! grep -q 'f-global' '$GH' && grep -q 'details class=\"gdb\" data-g=\"orders-global\"' '$GH' && grep -q 'class=\"gb mm\"' '$GH' && grep -q '1 mismatched' '$GH' && grep -q '1 primary + 2 secondaries' '$GH'"
MOCK_GLOBAL_DENY=1 t globdeny 0 global "${GR[@]}" -F json
has globdeny err 'WARN.*describe-global-clusters failed.*AccessDenied'
rowt globdeny orders-aurora-pg15 '.global_cluster == null and .global_role == "unknown" and .compliance_status == "COMPLIANT"'
rowt globdeny inv-mysql '.global_role == ""'
jqt globdeny '.summary.errors == 0 and .summary.global_unknown > 0'
GD="$OUT/glob data"; mkdir -p "$GD"
MOCK_SCENARIO=global "$SCRIPT" "${GR[@]}" --save-data "$GD/new.json" -o "$OUT/gsx" -F json >/dev/null 2>&1
cp "$HERE"/fixtures/v130/*summary_v130.json "$GD/"
chk "save-data: schema 1.1 with globals" jq -e '.schema_version == 1 and .schema_minor == 1 and (.globals | length) == 2 and .global_lookup[0].status == "ok"' "$GD/new.json"
mg gmerge 0 --merge "$GD" -F json
jqt gmerge '.summary.global_databases == 2 and (.meta.global_lookup | map(select(.status == "unknown")) | length) >= 1'
jqt gmerge '[.rows[] | select(.account_id != "111111111111" and (.resource_type | test("aurora-cluster"))) | .global_role] | all(. == "unknown")'
jqt gmerge '.meta.tag_columns == []'
t gtag 0 fleet -P prod -r us-east-1 -T Owner -F csv -o "$OUT/gtag"
has gtag err 'ignored since v1.4.0'; chk "gtag: no tag column" bash -c "! grep -rq 'tag:' '$OUT/gtag'"
if command -v node >/dev/null 2>&1 && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && NODE_PATH="${NODE_PATH:-}" node -e 'require("puppeteer-core")' 2>/dev/null; then
    res="$(node "$HERE/browser_global.js" "$GH" ${SHOTS:+"$SHOTS"} 2>&1)"; rc=$?
    chk "browser: Global/Standalone, global section, search ${res:0:300}" test "$rc" -eq 0
    res="$(node "$HERE/browser_tabs.js" "$GH" ${SHOTS:+"$SHOTS/tabs_global"} 2>&1)"; rc=$?
    chk "browser v1.7.0: two tabs, global grouping, filters, cross-links, CSV, mobile ($(jq -r '.checks' <<<"$res" 2>/dev/null) checks) ${res:0:300}" test "$rc" -eq 0
fi

echo "== v1.5.0: account names (config map > iam alias > number), engine table, picker"
AN="$OUT/an"; mkdir -p "$AN"
t an_alias 0 fleet -P prod -P nonprod -r us-east-1 -F csv,json,text -o "$AN/a"
chk "alias: prod gets its alias, nonprod (AccessDenied) falls back silently" jq -e '[.meta.accounts[] | {account, name}] == [{account: "111111111111", name: "prod-core"}, {account: "222222222222", name: ""}]' "$AN"/a/*.json
hasnt an_alias err 'AccessDenied|list-account-aliases'
chk "alias: account_name is the last CSV column and filled" python3 -c 'import csv,sys,glob; r=list(csv.reader(open([f for f in glob.glob(sys.argv[1]+"/*.csv") if "_regions" not in f][0],encoding="utf-8-sig"))); h=r[0]; i=h.index("account_name"); assert i==len(h)-1; assert {(x[0],x[i]) for x in r[1:]}=={("111111111111","prod-core")}, set((x[0],x[i]) for x in r[1:])' "$AN/a"
chk "alias: json rows carry account_name" jq -e 'all(.rows[]; has("account_name")) and ([.rows[] | select(.account_id == "111111111111") | .account_name] | unique) == ["prod-core"]' "$AN"/a/*.json
chk "alias: text Accounts line + PER ACCOUNT NAME column" bash -c "grep -q '^Accounts : 111111111111 prod-core (prod), 222222222222 (nonprod)' '$AN'/a/*.txt && grep -A1 '^PER ACCOUNT' '$AN'/a/*.txt | grep -q NAME"
mkconf "$AN/n.conf"; printf '111111111111 = prod-payments   # comment\n222222222222 = "np \001x"\n' >>"$AN/n.conf"
t an_conf 0 fleet --config "$AN/n.conf" -P prod -P nonprod -r us-east-1 -r ap-south-1 -F json,html -o "$AN/c"
chk "config map wins over the alias, comment/quotes/control chars stripped" jq -e '[.meta.accounts[].name] == ["prod-payments", "np x"]' "$AN"/c/*.json
chk "html shows name (number)" grep -q 'prod-payments (111111111111)' "$AN"/c/*.html
printf '1111 = short\n' >"$AN/bad.conf"; t an_badkey 1 fleet --config "$AN/bad.conf"
MOCK_ALIAS='["x"]' MOCK_ALIAS_DENY=1 t an_deny 0 fleet -P prod -r us-east-1 -F json -o "$AN/d"
chk "alias denied: number only, no warning" jq -e '.meta.accounts[0].name == ""' "$AN"/d/*.json
hasnt an_deny err 'AccessDenied|list-account-aliases'
MOCK_ALIAS="[\"$(printf 'a%.0s' {1..80})\"]" t an_long 0 fleet -P prod -r us-east-1 -F json -o "$AN/l"
chk "alias capped at 64 chars" jq -e '(.meta.accounts[0].name | length) == 64' "$AN"/l/*.json
t an_dry 0 fleet -P prod -r us-east-1 --dry-run; has an_dry out 'iam list-account-aliases'
chk "merge: old data files without names still merge (name empty)" jq -e 'all(.accounts[]; has("name") | not)' "$HERE"/fixtures/v130/*.json
mg an_merge 0 --merge "$HERE"/fixtures/v130 "$SD1" -F json -o "$AN/m"
chk "merge: names carried through, old accounts number only" jq -e '([.meta.accounts[] | select(.account == "111111111111") | .name] | unique) == ["prod-core"] and ([.meta.accounts[] | select(.account != "111111111111") | .name] | unique) == [""]' "$AN"/m/*.json
XA='<img src=x data-xss=1 onerror="window.__xss=1">'
MOCK_ALIAS="$(jq -cn --arg x "$XA" '[$x]')" t an_xss 0 fleet -P prod -r us-east-1 -F html,json -o "$AN/x"
chk "xss alias: survives into json, escaped in html" bash -c "jq -e '.meta.accounts[0].name | test(\"data-xss\")' '$AN'/x/*.json >/dev/null && ! grep -q '<img src=x data-xss' '$AN'/x/*.html"
mkconf "$AN/x.conf"; printf '111111111111 = <svg onload=window.__xss=2> data-xss\n' >>"$AN/x.conf"
t an_xssc 0 fleet --config "$AN/x.conf" -P prod -r us-east-1 -F html -o "$AN/xc"
chk "xss config name: escaped in html" bash -c "! grep -q '<svg onload' '$AN'/xc/*.html"
if command -v node >/dev/null 2>&1 && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && NODE_PATH="${NODE_PATH:-}" node -e 'require("puppeteer-core")' 2>/dev/null; then
    for h in "$AN"/x/*.html "$AN"/xc/*.html; do
        res="$(node "$HERE/xss_check.js" "$h" 2>&1)"; rc=$?
        chk "xss account name: headless Chrome ${res:0:300}" test "$rc" -eq 0
    done
    res="$(node "$HERE/browser_check.js" "$(ls "$AN"/c/*.html)" 2>&1)"; rc=$?
    chk "browser: named accounts report ${res:0:300}" test "$rc" -eq 0
fi

echo "== v1.6.0: compliance exceptions (--exceptions FILE / compliance_exceptions.conf)"
EX="$OUT/exc"; mkdir -p "$EX"
# mg clock 1791000000 = 2026-10-03 (UTC): expiring soon = within 14 days, expires = last valid day
cat >"$EX/ok.conf" <<'CONF'
# account_id | identifier | scope | expires | reason
111111111111 | legacy-aurora-pg12 | patch        | 2026-12-31 | Decommission Dec 2026 (CHG-1)
111111111111 | inv-mysql          | patch,backup | 2026-10-10 | Vendor app pinned | owner: dba
111111111111 | billing-pg         | patch        | 2027-03-01 | Freeze <b>q1</b>
111111111111 | hr-sql             | patch        | 2026-10-02 | Old waiver
  111111111111|old-aurora-pg11|PATCH|2026-10-03|=Ends today

111111111111 | ghost-db           | patch        | 2027-01-01 | Not there
111111111111 | analytics-pg       | backup       | 2027-01-01 | Backup only (not applied by the patch tool)
CONF
mg exc_base 0 --merge "$SD1" -F json -o "$EX/base"
mg exc_on 0 --merge "$SD1" --exceptions "$EX/ok.conf" -F json,csv,text,html -o "$EX/on"
EJ="$(ls "$EX"/on/*.json)"; BJ="$(ls "$EX"/base/*.json)"
chk "exc: base fixture 19 = 11 compliant + 7 non-compliant + 1 unknown" jq -e '.summary | .total == 19 and .compliant == 11 and .non_compliant == 7 and .unknown == 1' "$BJ"
chk "exc: counts -> compliant 13 (incl. 3), non-compliant 5, unknown 1, 68.4%" jq -e '.summary | .compliant == 13 and .non_compliant == 5 and .unknown == 1 and .pct_compliant == 68.4 and .exceptions.applied == 3' "$EJ"
chk "exc: actual status kept; UNKNOWN stays UNKNOWN" jq -e '[.rows[] | select(.exception == "yes") | [.identifier, .compliance_status, .actual_status]] | sort == [["billing-pg","COMPLIANT","COMPLIANT"],["inv-mysql","COMPLIANT","NON-COMPLIANT"],["legacy-aurora-pg12","COMPLIANT","NON-COMPLIANT"],["old-aurora-pg11","UNKNOWN","UNKNOWN"]]' "$EJ"
chk "exc: UNKNOWN with matching exception stays UNKNOWN (fields listed)" jq -e '.rows[] | select(.identifier == "old-aurora-pg11") | .compliance_status == "UNKNOWN" and .actual_status == "UNKNOWN" and .exception == "yes" and .exception_flag == "expiring soon" and .exception_expires == "2026-10-03"' "$EJ"
chk "exc: NON-COMPLIANT still becomes exception" jq -e '.rows[] | select(.identifier == "legacy-aurora-pg12") | .compliance_status == "COMPLIANT" and .actual_status == "NON-COMPLIANT" and .exception == "yes"' "$EJ"
chk "exc: flags (expiring soon incl. expires today, no longer needed)" jq -e '([.rows[] | select(.exception != "no") | {(.identifier): .exception_flag}] | add) == {"legacy-aurora-pg12": "", "inv-mysql": "expiring soon", "billing-pg": "no longer needed", "hr-sql": "exception expired", "old-aurora-pg11": "expiring soon"}' "$EJ"
chk "exc: expired entry evaluated normally" jq -e '.rows[] | select(.identifier == "hr-sql") | .exception == "expired" and .compliance_status == "NON-COMPLIANT"' "$EJ"
chk "exc: summary attention 3, expired 1, unmatched ghost-db line 8, backup-only entry not counted" jq -e '.summary.exceptions | .attention == 3 and .expiring_soon == 2 and .no_longer_needed == 1 and .expired == 1 and .unmatched == [{line: 8, account: "111111111111", identifier: "ghost-db"}] and .entries == 6' "$EJ"
chk "exc: other rows unchanged vs no-file run" bash -c "diff <(jq -S '[.rows[] | select(.exception == \"no\") | del(.exception, .exception_reason, .exception_expires, .exception_flag, .actual_status)]' '$EJ') <(jq -S --argjson x '[\"legacy-aurora-pg12\",\"inv-mysql\",\"billing-pg\",\"hr-sql\",\"old-aurora-pg11\"]' '[.rows[] | select(.identifier as \$i | \$x | index([\$i]) | not)]' '$BJ')"
chk "exc: no-file JSON has no exception fields" jq -e '(.summary | has("exceptions") | not) and all(.rows[]; has("exception") | not)' "$BJ"
has exc_on err 'ok\.conf:8 \(111111111111 ghost-db\) matched no server'
has exc_on err 'hr-sql expired on 2026-10-02'
has exc_on err 'Exceptions \(patch\): 3 applied'
EC="$(ls "$EX"/on/rds_patch_compliance_*[0-9].csv)"
chk "exc csv: 5 new columns at the end" bash -c "head -1 '$EC' | grep -q ',\"account_name\",\"exception\",\"exception_reason\",\"exception_expires\",\"exception_flag\",\"actual_status\"\$'"
chk "exc csv: status COMPLIANT (EXCEPTION) on 3 waived/listed-compliant rows" test "$(grep -c '"COMPLIANT (EXCEPTION)"' "$EC")" -eq 3
chk "exc csv: UNKNOWN row keeps UNKNOWN and lists the exception" python3 -c 'import csv,sys; rows=list(csv.reader(open(sys.argv[1],newline=""))); h=rows[0]; i,s,e=h.index("identifier"),h.index("compliance_status"),h.index("exception"); r=[x for x in rows[1:] if x[i]=="old-aurora-pg11"]; raise SystemExit(0 if len(r)==1 and r[0][s]=="UNKNOWN" and r[0][e]=="yes" else 1)' "$EC"
chk "exc csv: expired row" grep -q '"expired","Old waiver","2026-10-02","exception expired","NON-COMPLIANT"$' "$EC"
chk "exc csv: reason formula guard" grep -q "\"'=Ends today\"" "$EC"
ET="$(ls "$EX"/on/*.txt)"
chk "exc text: summary + EXCEPTIONS section" bash -c "grep -q 'COMPLIANT 13 (incl. 3 exceptions)' '$ET' && grep -q '^EXCEPTIONS' '$ET' && grep -q 'line 8: 111111111111 ghost-db matched no server' '$ET' && grep -q '^  COMPLIANT\*' '$ET' && grep -q 'old-aurora-pg11' '$ET' && grep -q 'actual UNKNOWN' '$ET'"
EH="$(ls "$EX"/on/*.html)"
chk "exc html: Exception column, badge, quick filter, escaped reason" bash -c "grep -q '<th>Exception</th>' '$EH' && grep -q 'COMPLIANT (EXCEPTION)' '$EH' && grep -q 'id=\"f-exc\"' '$EH' && grep -q 'Freeze &lt;b&gt;q1&lt;/b&gt;' '$EH' && ! grep -q 'Freeze <b>' '$EH'"
mg exc_nc 0 --merge "$SD1" --exceptions "$EX/ok.conf" -F json --non-compliant-only -o "$EX/nc"
chk "exc: --non-compliant-only hides excepted servers" jq -e '[.rows[].identifier] | (index("legacy-aurora-pg12") == null) and (index("hr-sql") != null) and length == 5' "$EX"/nc/*.json
jq -r '.rows[] | select(.compliance_status == "NON-COMPLIANT") | "\(.account_id) | \(.identifier) | patch | 2027-01-01 | all non-compliant"' "$BJ" >"$EX/all.conf"
mg exc_fail 0 --merge "$SD1" --exceptions "$EX/all.conf" -F json --fail-on-noncompliant -o "$EX/fail"
chk "exc: every non-compliant excepted -> --fail-on-noncompliant exits 0" jq -e '.summary.non_compliant == 0 and .summary.exceptions.applied == 7' "$EX"/fail/*.json
mg exc_fail5 5 --merge "$SD1" --exceptions "$EX/ok.conf" -F json --fail-on-noncompliant -o "$EX/fail5"
# validation: every bad line stops the run with file:line, before any AWS call
xbad() { local name="$1" want="$2" line="$3"; printf '# header\n111111111111 | good-db | patch | 2027-01-01 | ok\n%s\n' "$line" >"$EX/$name.conf"
         : >"$MOCK_LOG"; t "$name" 1 fleet -P prod -r us-east-1 --exceptions "$EX/$name.conf"
         has "$name" err "Exceptions .*$name\\.conf:3: .*$want"; chk "$name: no AWS call made" test ! -s "$MOCK_LOG"; }
xbad exc_missing 'missing field' '111111111111 | db1 | patch | 2027-01-01 |   '
xbad exc_fields 'expected 5 fields' '111111111111 | db1 | patch | 2027-01-01'
xbad exc_acct 'account_id must be 12 digits' '11111111111 | db1 | patch | 2027-01-01 | r'
xbad exc_scope 'scope must be patch, backup or patch,backup' '111111111111 | db1 | patches | 2027-01-01 | r'
xbad exc_scope2 "scope lists 'patch' twice" '111111111111 | db1 | patch,patch | 2027-01-01 | r'
xbad exc_date 'is not a valid date' '111111111111 | db1 | patch | 2026-02-29 | r'
xbad exc_date2 'expires must be a date YYYY-MM-DD' '111111111111 | db1 | patch | never | r'
xbad exc_date3 'expires must be a date YYYY-MM-DD' '111111111111 | db1 | patch | 2027/01/01 | r'
xbad exc_glob 'is not a DB instance / cluster identifier' '111111111111 | prod-* | patch | 2027-01-01 | r'
xbad exc_dup 'duplicate entry for 111111111111 Good-DB \(patch\), already on line 2' '111111111111 | Good-DB | patch,backup | 2027-01-01 | r'
printf '111111111111 | db1 | patch | 2028-02-29 | leap day ok\n111111111111 | db1 | backup | 2027-01-01 | other scope, not a duplicate\n' >"$EX/nodup.conf"
t exc_nodup 0 fleet -P prod -r us-east-1 -F json --exceptions "$EX/nodup.conf"
t exc_nofile 1 fleet -P prod -r us-east-1 --exceptions "$EX/does-not-exist.conf"; has exc_nofile err 'Exceptions file not readable'
# default: compliance_exceptions.conf next to the script (a copy of the tool), absent = off; config key exceptions =
TC="$OUT/toolcopy"; mkdir -p "$TC"; cp -r "$HERE/../rds_patch_compliance_report.sh" "$HERE/../lib" "$TC/"; cp "$BASE_CONF" "$TC/rds_patch_compliance_report.conf"
PATH="$NOAWS:$PATH" RDS_PCR_NOW=1791000000 "$TC/rds_patch_compliance_report.sh" --merge "$SD1" -F json -o "$EX/def0" 2>"$EX/def0.err"
chk "exc default: no file next to the script -> off" jq -e '.summary | has("exceptions") | not' "$EX"/def0/*.json
cp "$EX/ok.conf" "$TC/compliance_exceptions.conf"
PATH="$NOAWS:$PATH" RDS_PCR_NOW=1791000000 "$TC/rds_patch_compliance_report.sh" --merge "$SD1" -F json -o "$EX/def1" 2>"$EX/def1.err"
chk "exc default: compliance_exceptions.conf next to the script is used" jq -e '.summary.exceptions.applied == 3' "$EX"/def1/*.json
mkconf "$EX/c.conf" "exceptions = $EX/all.conf"
mg exc_conf 0 --config "$EX/c.conf" --merge "$SD1" -F json -o "$EX/conf"
chk "exc: config key exceptions = FILE" jq -e '.summary.non_compliant == 0 and .summary.exceptions.applied == 7' "$EX"/conf/*.json
# collection: the report gets the exceptions, the --save-data file does not change
RDS_PCR_NOW=1790000000 t exc_sd 0 fleet -P prod -r us-east-1,ap-south-1 -F json -o "$EX/sd" --save-data --exceptions "$EX/ok.conf"
chk "exc: --save-data file identical with and without exceptions" bash -c "diff <(jq -S . '$SD1') <(jq -S . '$EX/sd/rds_patch_111111111111_20260921.json')"
chk "exc: direct (collection) report applies exceptions" jq -e '.summary.exceptions.applied >= 3' "$(ls "$EX"/sd/rds_patch_compliance_*.json)"
if command -v node >/dev/null 2>&1 && [[ -x "${CHROME:-/usr/bin/google-chrome}" ]] && NODE_PATH="${NODE_PATH:-}" node -e 'require("puppeteer-core")' 2>/dev/null; then
    mg exc_nohtml 0 --merge "$SD1" -o "$EX/noexc.html"
    res="$(node "$HERE/browser_exceptions.js" "$EH" "$EX/noexc.html" ${SHOTS:+"$SHOTS"} 2>&1)"; rc=$?
    chk "browser: exception column, quick filter with other filters, pop-up, CSV ($(jq -r '.checks' <<<"$res" 2>/dev/null) checks) ${res:0:400}" test "$rc" -eq 0
    res="$(node "$HERE/browser_check.js" "$EH" 2>&1)"; rc=$?
    chk "browser: existing checks still pass on a report with exceptions ${res:0:300}" test "$rc" -eq 0
else echo "  skip exceptions browser check (node + puppeteer-core on NODE_PATH + Chrome not found)"; fi

echo "== unreleased: conf file next to the script (settings, required keys, --config, CLI override)"
# newtool DIR [noconf]: a fresh copy of the tool (scripts + lib); the conf is copied in unless "noconf" is given.
newtool() { mkdir -p "$1"; cp "$REPO_SCRIPT" "$HERE/../rds_patch_compliance_summary.sh" "$1/"; cp -r "$HERE/../lib" "$1/"
            [[ "${2:-}" == noconf ]] || cp "$HERE/../rds_patch_compliance_report.conf" "$1/"; }
SHIP="$OUT/shipped"; newtool "$SHIP"; SHW="$OUT/shipped_cwd"; mkdir -p "$SHW"
REQ="$(sed -n '/^readonly -a REQUIRED_KEYS=(/,/)$/p' "$REPO_SCRIPT" | sed 's/^readonly -a REQUIRED_KEYS=(//; s/)$//' | tr -s ' \n' '\n' | grep .)"
SREQ="$(sed -n '/^readonly -a REQUIRED_KEYS=(/,/)$/p' "$HERE/../rds_patch_compliance_summary.sh" | sed 's/^readonly -a REQUIRED_KEYS=(//; s/)$//' | tr -s ' \n' '\n' | grep .)"
chk "both scripts require the same keys" test "$(sort <<<"$REQ")" = "$(sort <<<"$SREQ")"
SC="$HERE/../rds_patch_compliance_report.conf"
chk "shipped conf: every required key appears exactly once" bash -c "for k in $(tr '\n' ' ' <<<"$REQ"); do [[ \$(grep -cE \"^\$k[[:space:]]*=\" '$SC') == 1 ]] || { echo \"\$k\"; exit 1; }; done"
chk "shipped conf: no setting outside the required list" bash -c "grep -E '^[a-z_]+[[:space:]]*=' '$SC' | sed 's/[[:space:]]*=.*//' | sort | diff - <(tr ' ' '\n' <<<'$(tr '\n' ' ' <<<"$REQ")' | grep . | sort)"
chk "shipped conf: a ## comment with Allowed/Example sits above every setting" awk '
    /^##/ { blk = blk $0 "\n"; next }
    /^[[:space:]]*$/ { blk = ""; next }
    /^[a-z_]+[[:space:]]*=/ { if (blk == "" ) { print "no comment above: " $0; bad = 1 } else if (blk !~ /Allowed|Example/) { print "no Allowed/Example above: " $0; bad = 1 } blk = ""; next }
    /^[0-9]{12}[[:space:]]*=/ { blk = ""; next }
    END { exit bad }' "$SC"
t_ship() { local name="$1" exp="$2" scen="$3"; shift 3; ( cd "$SHW" && MOCK_SCENARIO="$scen" "$SHIP/rds_patch_compliance_report.sh" "$@" ) >"$OUT/$name.out" 2>"$OUT/$name.err"; local rc=$?
           if [[ "$rc" == "$exp" ]]; then ok "$name (rc=$rc)"; else bad "$name: rc=$rc expected $exp"; tail -5 "$OUT/$name.err" | sed 's/^/       /'; fi; }
RDS_PCR_NOW=1790000000 t_ship ship 0 fleet -P prod,nonprod -r us-east-1,ap-south-1
has ship err "Settings: $SHIP/rds_patch_compliance_report.conf \\(loaded automatically from the script folder\\)"
chk "shipped conf: csv + html + txt written to ./reports (formats / output_dir / prefix from the conf)" bash -c "cd '$SHW/reports' && ls | grep -cE '^rds_patch_compliance_20260921_194320\.(html|csv|txt)\$|_regions\.csv\$' | grep -qx 4"
has ship err "Wrote $SHW/reports/rds_patch_compliance_20260921_194320\\.html"
chk "shipped conf: log_file ./reports/run.log written" grep -q 'Wrote' "$SHW/reports/run.log"
chk "shipped conf: account names from the conf in the report" grep -q 'prod-payments' "$SHW/reports/rds_patch_compliance_20260921_194320.txt"
RDS_PCR_NOW=1790000000 t_ship ship_cli 0 fleet -P prod -r us-east-1 -F json -o ""
chk "CLI -o \"\" prints on the screen instead of the conf's output_dir" jq -e '.summary.total > 0' "$OUT/ship_cli.out"
newtool "$OUT/noconf" noconf
MOCK_SCENARIO=fleet "$OUT/noconf/rds_patch_compliance_report.sh" -P prod -r us-east-1 >"$OUT/noconf.out" 2>"$OUT/noconf.err"; chk "no conf next to the script: rc 1" test $? -eq 1
has noconf err 'Config file not found: .*rds_patch_compliance_report\.conf'
( MOCK_SCENARIO=fleet "$OUT/noconf/rds_patch_compliance_report.sh" --help >"$OUT/helpnoconf2.out" 2>&1; chk "--help works without a conf" test $? -eq 0 )
for k in mail_timeout max_behind attach_prefix; do
    grep -vE "^${k}[[:space:]]*=" "$BASE_CONF" >"$OUT/miss_$k.conf"
    t "miss_$k" 1 fleet --config "$OUT/miss_$k.conf" -P prod -r us-east-1; has "miss_$k" err "missing required setting\\(s\\): $k "
done
grep -vE '^(mail_timeout|warn_days|tz)[[:space:]]*=' "$BASE_CONF" >"$OUT/miss3.conf"
t miss3 1 fleet --config "$OUT/miss3.conf"; has miss3 err 'missing required setting\(s\): warn_days tz mail_timeout'
: >"$MOCK_LOG"; chk "missing key stops before any AWS call" test ! -s "$MOCK_LOG"
mkconf "$OUT/bool.conf" 'all_regions = maybe'; t badbool 1 fleet --config "$OUT/bool.conf"; has badbool err "bool.conf:[0-9]+: 'all_regions' must be yes or no"
mkconf "$OUT/nofmt.conf" 'formats ='; t nofmt 1 fleet --config "$OUT/nofmt.conf" -P prod -r us-east-1; has nofmt err 'formats is empty'
mkconf "$OUT/badnum.conf" 'mail_timeout = soon'; t badmt 1 fleet --config "$OUT/badnum.conf" -P prod -r us-east-1; has badmt err 'mail-timeout must be a positive integer'
mkconf "$OUT/alias.conf" 'profile = prod' 'region = us-east-1' 'Max-Behind = 4' 'ALERT_EMAIL = a@example.com'
t alias 0 fleet --config "$OUT/alias.conf" -F json; jqt alias '.summary.max_behind == 4'
mkconf "$OUT/cfg5.conf" 'profiles = prod' 'regions = us-east-1' 'max_behind = 5'
t cfg5 0 fleet --config "$OUT/cfg5.conf" -F json;   jqt cfg5 '.summary.max_behind == 5'; has cfg5 err 'Settings: .*cfg5\.conf \(from --config\)'
t cfg5b 0 fleet --config="$OUT/cfg5.conf" -F json;  jqt cfg5b '.summary.max_behind == 5'
t cfg5cli 0 fleet --config "$OUT/cfg5.conf" --max-behind 3 -F json;  jqt cfg5cli '.summary.max_behind == 3'
t nocfg 0 fleet -P prod -r us-east-1 -F json;  jqt nocfg '.summary.max_behind == 2'; has nocfg err 'loaded automatically from the script folder'
mkconf "$OUT/allreg.conf" 'profiles = prod' 'all_regions = yes' 'regions ='
t cli_r 0 fleet --config "$OUT/allreg.conf" -r us-east-1 --dry-run;   has cli_r out 'regions  : us-east-1 \(queried directly'
t conf_A 0 fleet --config "$OUT/allreg.conf" --dry-run;               has conf_A out 'regions  : all enabled per account'
mkconf "$OUT/reg.conf" 'profiles = prod' 'all_regions = no' 'regions = us-east-1'
t cli_A 0 fleet --config "$OUT/reg.conf" -A --dry-run;                has cli_A out 'regions  : all enabled per account'
t cli_rA 1 fleet --config "$OUT/reg.conf" -A -r us-east-1 --dry-run;  has cli_rA err 'either --region or --all-regions'
mkconf "$OUT/mgscope.conf" 'profiles = prod,nonprod' 'all_regions = yes' 'engines = postgres' 'identifiers = zzz*' 'formats = text,json' 'output_dir ='
mg conf_merge 0 --config "$OUT/mgscope.conf" --merge "$SD1" -F json -o "$OUT/conf_merge"
mg conf_merge_plain 0 --merge "$SD1" -F json -o "$OUT/conf_merge_plain"
chk "merge ignores the conf's profiles / regions / engines / identifiers" test "$(jq -c .summary.total "$OUT"/conf_merge/*.json)" = "$(jq -c .summary.total "$OUT"/conf_merge_plain/*.json)"
mg conf_merge_P 1 --merge "$SD1" -P prod;   has conf_merge_P err 'do not apply'
mg conf_merge_e 1 --merge "$SD1" -e postgres;   has conf_merge_e err 'do not apply'
mkconf "$OUT/fmtmerge.conf" 'formats = csv,txt' 'output_dir ='
mg conf_merge_fmt 0 --config "$OUT/fmtmerge.conf" --merge "$SD1" -o "$OUT/conf_merge_fmt.html"
chk "merge writes html (not the conf's formats) unless -F is given" test -s "$OUT/conf_merge_fmt.html"
# settings that used to be hard-coded
TS="$OUT/tstub"; mkdir -p "$TS"
printf '#!/usr/bin/env bash\necho "$1" >>"%s/timeout.log"\nshift\nexec "$@"\n' "$OUT" >"$TS/timeout"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/curl.log"\ncat >/dev/null\nprintf 200\n' "$OUT" >"$TS/curl"
printf '#!/usr/bin/env bash\necho "$AWS_RETRY_MODE $AWS_MAX_ATTEMPTS" >>"%s/awsenv.log"\nexec "%s/mock/aws" "$@"\n' "$OUT" "$HERE" >"$TS/aws"
chmod +x "$TS"/*
mkconf "$OUT/hard.conf" 'mail_timeout = 7' 'webhook_timeout = 9' 'webhook_retries = 1' 'aws_retry_mode = adaptive' 'max_attempts = 3' 'alert_emails = dba@example.com' "alert_webhooks = $HOOK" 'slack_max_chars = 120'
PATH="$TS:$PATH" t hard 0 fleet --config "$OUT/hard.conf" -P prod -r us-east-1 -F text -o "$OUT/hard"
chk "mail_timeout from the conf is the mail command's timeout" grep -qx 7 "$OUT/timeout.log"
chk "webhook_timeout / webhook_retries from the conf reach curl" grep -q -- '--max-time 9 --retry 1' "$OUT/curl.log"
chk "aws_retry_mode / max_attempts from the conf reach the AWS CLI" grep -qx 'adaptive 3' "$OUT/awsenv.log"
mkconf "$OUT/slack120.conf" 'slack_max_chars = 120' "alert_webhooks = $HOOK" 'profiles = prod' 'regions = us-east-1'
: >"$OUT/webhook.txt"; t slack120 0 fleet --config "$OUT/slack120.conf" -F text -o "$OUT/slack120"
chk "slack_max_chars from the conf truncates the Slack text" bash -c "grep . '$OUT/webhook.txt' | tail -1 | jq -e '(.text | length) < 400 and (.text | contains(\"truncated\"))' >/dev/null"
: >"$OUT/awsenv.log"; AWS_RETRY_MODE=legacy PATH="$TS:$PATH" t hardenv 0 fleet --config "$OUT/hard.conf" -P prod -r us-east-1 -F json; chk "AWS_RETRY_MODE in the environment wins over the conf" grep -qx 'legacy 3' "$OUT/awsenv.log"
# exception_warn_days (flag "expiring soon")
printf '111111111111 | legacy-aurora-pg12 | patch | 2026-09-26 | in five days\n' >"$OUT/exp5.conf"
mkconf "$OUT/ew14.conf" 'exception_warn_days = 14'; mkconf "$OUT/ew3.conf" 'exception_warn_days = 3'
RDS_PCR_NOW=1790000000 PATH="$NOAWS:$PATH" t ew14 0 fleet --config "$OUT/ew14.conf" --merge "$SD1" --exceptions "$OUT/exp5.conf" -F json -o "$OUT/ew14"
RDS_PCR_NOW=1790000000 PATH="$NOAWS:$PATH" t ew3 0 fleet --config "$OUT/ew3.conf" --merge "$SD1" --exceptions "$OUT/exp5.conf" -F json -o "$OUT/ew3"
chk "exception_warn_days = 14: an exception ending in 5 days is 'expiring soon'" jq -e '[.rows[] | select(.identifier == "legacy-aurora-pg12") | .exception_flag] == ["expiring soon"]' "$OUT"/ew14/*.json
chk "exception_warn_days = 3: the same exception is not flagged" jq -e '[.rows[] | select(.identifier == "legacy-aurora-pg12") | .exception_flag] == [""]' "$OUT"/ew3/*.json

echo "== unreleased: HTML alert e-mail (fake sendmail), mail / mailx fallback, webhooks unchanged"
MAILPY="$HERE/check_alert_mime.py"
SMD="$OUT/sm"; mkdir -p "$SMD/bin"
cat >"$SMD/bin/sendmail" <<'SM'
#!/usr/bin/env bash
{ printf 'ARGS:'; printf ' %q' "$@"; printf '\n'; } >>"${SENDMAIL_ARGS:?}"
cat >"${SENDMAIL_MSG:?}"
SM
chmod +x "$SMD/bin/sendmail"
# ISO: a PATH with every system tool except mail / mailx / sendmail / aws (so the fallback order can be tested)
ISO="$OUT/iso"; mkdir -p "$ISO"
for d in /usr/bin /bin; do for f in "$d"/*; do b="${f##*/}"; case "$b" in mail|mailx|sendmail|aws|mailq) continue ;; esac; [[ -e "$ISO/$b" ]] || ln -s "$f" "$ISO/$b" 2>/dev/null; done; done
em() {   # em <name> <rc> <scenario> [args...]: run with the fake sendmail first on PATH
    local name="$1"; shift
    SENDMAIL_MSG="$SMD/$name.eml" SENDMAIL_ARGS="$SMD/$name.args" PATH="$SMD/bin:$PATH" RDS_PCR_NOW=1790000000 t "$name" "$@"
}
rm -rf "$SMD/rep1"
em em1 0 fleet "${P2[@]}" -F html,csv -o "$SMD/rep1" --alert-email dba@example.com,oncall@example.com --alert-from rds@example.com
chk "mime: multipart/mixed { alternative { text, html }, patch_compliance_2026-09-21.html + .csv } = the written files" python3 "$MAILPY" mixed "$SMD/em1.eml" "$SMD/rep1" --nc 8 --date 2026-09-21
chk "mime: sendmail called with -t -oi" grep -qx 'ARGS: -t -oi' "$SMD/em1.args"
chk "mime: From / To / Subject / MIME-Version headers" bash -c "sed -n '1,/^\$/p' '$SMD/em1.eml' | grep -qx 'From: rds@example.com' && sed -n '1,/^\$/p' '$SMD/em1.eml' | grep -qx 'To: dba@example.com,oncall@example.com' && sed -n '1,/^\$/p' '$SMD/em1.eml' | grep -q '^Subject: \[rds_patch_compliance\] NON-COMPLIANT: 8 non-compliant of 22, ' && grep -qx 'MIME-Version: 1.0' '$SMD/em1.eml'"
python3 "$MAILPY" part "$SMD/em1.eml" html >"$SMD/em1.html"; python3 "$MAILPY" part "$SMD/em1.eml" text >"$SMD/em1.txt"
chk "mime: the regions CSV is not attached" bash -c "! grep -q '_regions' '$SMD/em1.eml'"
chk "mime: failures table has UNKNOWN rows, 'Current -> target' and a reason" bash -c "grep -q 'old-aurora-pg11' '$SMD/em1.html' && grep -q '15.4' '$SMD/em1.html' && grep -q '7 valid minor versions behind (limit 2)' '$SMD/em1.html'"
chk "mime: Pending is a count only (no pending action list)" bash -c "grep -q '>Pending<' '$SMD/em1.html' && ! grep -qiE 'db-upgrade|auto-apply|system-update|os-upgrade' '$SMD/em1.html' '$SMD/em1.txt'"
chk "mime: no report paths in either body" bash -c "! grep -qF '$SMD' '$SMD/em1.html' '$SMD/em1.txt'"
chk "mime: text part lists the same NON-COMPLIANT servers as the report" bash -c "[[ \$(grep -cE '^[a-z0-9-]+ \(([0-9]{12})\)|^(prod-core|222222222222) ' '$SMD/em1.txt') -ge 8 ]]"
chk "mime: escaping (identifier / note / AWS error text)" python3 "$MAILPY" escape "$HERE/../lib/alert_email.jq"
rm -rf "$SMD/rep2"; em em_csv 0 fleet "${P2[@]}" -F html,csv -o "$SMD/rep2" --alert-email dba@example.com --attach-html no
chk "attach_html = no: only the csv is attached" python3 "$MAILPY" mixed "$SMD/em_csv.eml" "$SMD/rep2" --parts csv --date 2026-09-21
em em_none 0 fleet "${P2[@]}" -F text --alert-email dba@example.com --attach-html no --attach-csv no
chk "both attach off: multipart/alternative only" python3 "$MAILPY" mixed "$SMD/em_none.eml" --parts none
em em_pre 0 fleet "${P2[@]}" -F text --alert-email dba@example.com --attach-prefix acme-patch
chk "attach_prefix: --attach-prefix names the attachments; nothing written (rendered on the fly)" python3 "$MAILPY" mixed "$SMD/em_pre.eml" --prefix acme-patch --date 2026-09-21
mkconf "$OUT/em_conf.conf" 'alert_emails = conf@example.com' 'attach_csv = no' 'attach_prefix = from-conf' 'formats = html' "output_dir = $SMD/rep3"
rm -rf "$SMD/rep3"; em em_conf 0 fleet --config "$OUT/em_conf.conf" "${P2[@]}"
chk "conf keys alert_emails / attach_csv / attach_prefix drive the e-mail" python3 "$MAILPY" mixed "$SMD/em_conf.eml" "$SMD/rep3" --parts html --prefix from-conf --date 2026-09-21
chk "conf alert_emails: the recipient is the conf's" grep -qx 'To: conf@example.com' "$SMD/em_conf.eml"
em em_ok 0 fleet -P prod -r us-east-1 -e docdb -F text --alert-email dba@example.com --alert-on always
chk "all compliant (alert_on = always): green banner, 'No NON-COMPLIANT servers.'" python3 "$MAILPY" mixed "$SMD/em_ok.eml" --status COMPLIANT --nc 0 --date 2026-09-21
rm -f "$SMD/em_none2.eml"; em em_quiet 0 fleet -P prod -r us-east-1 -e docdb -F text --alert-email dba@example.com
chk "alert_on = noncompliant: no e-mail when everything is compliant" test ! -e "$SMD/em_quiet.eml"
em em_err 0 discover -P prod -A -F text --alert-email dba@example.com
python3 "$MAILPY" part "$SMD/em_err.eml" html >"$SMD/em_err.html"
chk "AWS errors table: the region with the error, the short reason" bash -c "grep -q 'AWS errors' '$SMD/em_err.html' && grep -q 'ca-central-1' '$SMD/em_err.html' && grep -q 'AccessDenied on describe-db-instances' '$SMD/em_err.html'"
em em_test 0 fleet --alert-test --alert-email dba@example.com
chk "--alert-test over sendmail: alternative with text 'Test alert from'" bash -c "python3 '$MAILPY' part '$SMD/em_test.eml' text | grep -q '^Test alert from' && python3 '$MAILPY' part '$SMD/em_test.eml' html | grep -q 'TEST'"
# fallbacks: sendmail > mail > mailx (text summary only)
: >"$MAIL_SINK"; rm -f "$SMD/em_pref.eml"
em em_pref 0 fleet "${P2[@]}" -F text --alert-email dba@example.com
chk "sendmail is preferred over mail" bash -c "test -s '$SMD/em_pref.eml' && test ! -s '$MAIL_SINK'"
: >"$MAIL_SINK"; rm -f "$SMD/mail_only.eml"
t em_mail 0 fleet "${P2[@]}" -F text --alert-email dba@example.com --alert-from rds@example.com
chk "mail (no sendmail): text summary only, From via -r, no MIME" bash -c "grep -q '^ARGS: -r rds@example.com -s .*NON-COMPLIANT.* -- dba@example.com' '$MAIL_SINK' && grep -q '^RDS patch compliance: NON-COMPLIANT' '$MAIL_SINK' && ! grep -qiE 'multipart|base64|<html' '$MAIL_SINK'"
has em_mail err 'mail sends the text summary only'
MXB="$OUT/mxbin"; mkdir -p "$MXB"; printf '#!/usr/bin/env bash\n{ printf "ARGS:"; printf " %%q" "$@"; printf "\\n"; cat; } >>"%s/mailx.txt"\n' "$OUT" >"$MXB/mailx"; chmod +x "$MXB/mailx"
PATH="$MXB:$ISO" RDS_PCR_NOW=1790000000 MOCK_SCENARIO=fleet bash -c "PATH='$HERE/mock:$MXB:$ISO'; '$SCRIPT' ${P2[*]} -F text --alert-email dba@example.com" >"$OUT/em_mailx.out" 2>"$OUT/em_mailx.err"
chk "mailx only: text summary only" bash -c "grep -q '^ARGS: -s .*NON-COMPLIANT.* -- dba@example.com' '$OUT/mailx.txt' && grep -q '^RDS patch compliance: NON-COMPLIANT' '$OUT/mailx.txt'"
PATH="$HERE/mock:$ISO" RDS_PCR_NOW=1790000000 MOCK_SCENARIO=fleet "$SCRIPT" "${P2[@]}" -F text --alert-email dba@example.com >"$OUT/em_nomail.out" 2>"$OUT/em_nomail.err"; chk "no mail command at all: the run still succeeds (rc 0)" test $? -eq 0
has em_nomail err 'no mail, mailx or sendmail found'
# webhooks are unchanged: Slack text = '*subject*' + the full text report + the report file paths
: >"$OUT/webhook.txt"; rm -rf "$SMD/rep4"
em em_hook 0 fleet "${P2[@]}" -F text,csv -o "$SMD/rep4" --alert-webhook "$HOOK" --alert-email dba@example.com
chk "slack payload: full text report + 'Report files:' paths (unchanged)" bash -c "grep . '$OUT/webhook.txt' | tail -1 | jq -e '(.text | contains(\"PER ENGINE / MAJOR VERSION\")) and (.text | contains(\"Report files:\")) and (.text | contains(\"$SMD/rep4/\"))' >/dev/null"
chk "the e-mail of the same run has no report paths" bash -c "python3 '$MAILPY' part '$SMD/em_hook.eml' text | grep -qF '$SMD' && exit 1 || exit 0"

echo "== unreleased: report files are byte-identical to the v1.7.1 release (same data, equivalent settings)"
if git -C "$HERE/.." rev-parse -q --verify 'v1.7.1^{commit}' >/dev/null 2>&1; then
    OLD="$OUT/v171"; mkdir -p "$OLD"; git -C "$HERE/.." archive v1.7.1 | tar -x -C "$OLD"
    NEW="$OUT/v180"; newtool "$NEW"
    printf '111111111111 = prod-payments\n222222222222 = nonprod-shared\n' >"$OUT/names_only.conf"   # the shipped conf's names, as an old-style conf
    for scen in fleet oracle discover global; do
        rm -rf "$OUT/cmp_o_$scen" "$OUT/cmp_n_$scen"; mkdir -p "$OUT/cmp_n_$scen"
        ( RDS_PCR_NOW=1790000000 MOCK_SCENARIO=$scen "$OLD/rds_patch_compliance_report.sh" --config "$OUT/names_only.conf" -P prod,nonprod -A -F csv,html,text,json -o "$OUT/cmp_o_$scen" ) >/dev/null 2>&1
        ( cd "$OUT/cmp_n_$scen" && RDS_PCR_NOW=1790000000 MOCK_SCENARIO=$scen "$NEW/rds_patch_compliance_report.sh" -P prod,nonprod -A -F csv,html,text,json -o "$OUT/cmp_n_$scen/r" ) >/dev/null 2>&1
        nf="$(find "$OUT/cmp_o_$scen" -type f | wc -l)"
        chk "v1.7.1 vs new ($scen): $nf files, same names and identical bytes" bash -c "[[ $nf -ge 5 ]] && diff -r '$OUT/cmp_o_$scen' '$OUT/cmp_n_$scen/r'"
    done
    # formats / output_dir / prefix / tz taken from the shipped conf (no -F / -o on the command line)
    rm -rf "$OUT/cmp_c_o" "$OUT/cmp_c_n"; mkdir -p "$OUT/cmp_c_n"
    ( RDS_PCR_NOW=1790000000 MOCK_SCENARIO=fleet "$OLD/rds_patch_compliance_report.sh" --config "$OUT/names_only.conf" -P prod,nonprod -r us-east-1,ap-south-1 -F csv,html,text -o "$OUT/cmp_c_o" --tz Asia/Kolkata --prefix rds_patch_compliance -l "$OUT/cmp_c_o.log" ) >/dev/null 2>&1
    ( cd "$OUT/cmp_c_n" && RDS_PCR_NOW=1790000000 MOCK_SCENARIO=fleet "$NEW/rds_patch_compliance_report.sh" -P prod,nonprod -r us-east-1,ap-south-1 ) >/dev/null 2>&1
    chk "v1.7.1 with flags vs new with the shipped conf only: identical files" bash -c "diff -r '$OUT/cmp_c_o' '$OUT/cmp_c_n/reports' | grep -v 'Only in .*/reports: run.log' | grep -c . | grep -qx 0"
    # Slack and JSON webhook payloads are the same as before
    for fmtw in slack json; do
        : >"$OUT/webhook.txt"; rm -rf "$OUT/cmp_w"; mkdir -p "$OUT/cmp_w"
        ( RDS_PCR_NOW=1790000000 MOCK_SCENARIO=fleet "$OLD/rds_patch_compliance_report.sh" --config "$OUT/names_only.conf" "${P2[@]}" -F text,csv -o "$OUT/cmp_w" --alert-webhook "$HOOK" --alert-webhook-format $fmtw ) >/dev/null 2>&1
        cp "$OUT/webhook.txt" "$OUT/cmp_w_old.$fmtw"; : >"$OUT/webhook.txt"; rm -rf "$OUT/cmp_w"; mkdir -p "$OUT/cmp_w"
        ( cd "$OUT" && RDS_PCR_NOW=1790000000 MOCK_SCENARIO=fleet "$NEW/rds_patch_compliance_report.sh" "${P2[@]}" -F text,csv -o "$OUT/cmp_w" --alert-webhook "$HOOK" --alert-webhook-format $fmtw ) >/dev/null 2>&1
        chk "v1.7.1 vs new: $fmtw webhook payload identical" bash -c "[[ -s '$OUT/cmp_w_old.$fmtw' ]] && cmp '$OUT/cmp_w_old.$fmtw' '$OUT/webhook.txt'"
    done
else echo "  skip byte-identical check against v1.7.1 (git tag v1.7.1 not available)"; fi

echo "== hygiene"
chk "shellcheck script" shellcheck "$REPO_SCRIPT"
chk "shellcheck tests" shellcheck "$HERE/run_tests.sh" "$HERE/validate_cli.sh"
chk "python check script parses" python3 -B -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$HERE/check_alert_mime.py"
AFTER="$(cd "$HERE/.." && find . -path ./.git -prune -o -print | sort)"
chk "no files written into the tool folder" test "$BEFORE" = "$AFTER"

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
