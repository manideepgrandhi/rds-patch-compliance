#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose
# rds_patch_compliance_summary.sh - high-level RDS patch compliance summary + the NON-COMPLIANT servers only.
#
# READ-ONLY. The scan and every counting rule come from rds_patch_compliance_report.sh in this folder (it is run
# with -F json and its lib/compliance.jq + lib/versions.jq do the work), so the numbers are identical to the full
# report: valid RDS minor upgrade targets only, same major line, Oracle same patch line, deprecated -> UNKNOWN.
# This script only renders a short summary (lib/summary.jq) and optionally alerts.
# Settings: the SAME conf file as the full report (rds_patch_compliance_report.conf next to the scripts, loaded
# automatically; --config FILE replaces it). The scan runs through a temporary copy of that conf in which only the
# output / alert settings are switched off, so the summary owns the files and the alerts.
# --save-data and --merge are passed to the full report too, so the data files are the same format
# (rds_patch_<ACCOUNTID>_<YYYYMMDD>.json) and files saved by either script can be merged by either script.
#
# Exit codes: 0 ok, 1 usage, 2 pre-check / collection failed, 3 bad --merge input file, 4 output error, 5 NON-COMPLIANT found with
#             --fail-on-noncompliant, 130 interrupted.
# ----------------------------------------------------------------------------
# Settings: strict mode, version, paths (the full report script does the scan)
# ----------------------------------------------------------------------------
set -Eeuo pipefail
umask 077

readonly SCRIPT_NAME="rds_patch_compliance_summary.sh"
readonly SCRIPT_VERSION="1.8.1"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
FULL="${RDS_PCS_FULL:-$SCRIPT_DIR/rds_patch_compliance_report.sh}"
[[ "$FULL" == /* ]] || FULL="$PWD/$FULL"
LIB="$SCRIPT_DIR/lib/summary.jq"
EMAIL_LIB="$SCRIPT_DIR/lib/alert_email.jq"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
    echo "$SCRIPT_NAME: bash 4.4+ required (found $BASH_VERSION)" >&2; exit 2
fi

# ----------------------------------------------------------------------------
# Settings: empty on purpose. Every value comes from the conf file (load_config); CLI options override it.
# ----------------------------------------------------------------------------
readonly CONFIG_NAME="rds_patch_compliance_report.conf"   # the same conf as the full report; --config FILE replaces it
readonly MAX_PROBE_PARALLEL=32
# Every key the conf file must contain (same list as the full report).
readonly -a REQUIRED_KEYS=(profiles regions all_regions discover probe_parallel engines identifiers
    max_behind warn_days non_compliant_only oracle_any_patch_line fail_on_noncompliant exceptions
    formats output_dir prefix tz log_file verbose
    alert_emails alert_from alert_on attach_html attach_csv attach_prefix mail_timeout
    alert_webhooks alert_webhook_format slack_max_chars webhook_timeout webhook_retries
    aws_timeout max_attempts aws_retry_mode exception_warn_days)
PROFILES=(); REGIONS=(); ALL_REGIONS=0; DISCOVER=1; PROBE_PARALLEL=""; ENGINES=(); IDENTIFIERS=()
FORMATS=(); FORMATS_SET=0; OUTPUT_DIR=""; PREFIX=""; CONF_PREFIX=""; PREFIX_SET=0
MAX_BEHIND=""; MAX_BEHIND_SET=0; WARN_DAYS=""; SAVE_DATA=0; SAVE_DATA_FILE=""; MERGE=0; MERGE_ARGS=(); ORACLE_ANY_LINE=0; FAIL_ON_NC=0; VERBOSE=0
ALERT_EMAILS=(); ALERT_WEBHOOKS=(); ALERT_ON=""; ALERT_WEBHOOK_FORMAT=""; ALERT_FROM=""
ATTACH_HTML=0; ATTACH_CSV=0; ATTACH_PREFIX=""; MAIL_TIMEOUT=""; SLACK_MAX_CHARS=""; WEBHOOK_TIMEOUT=""; WEBHOOK_RETRIES=""
EXC_FILE=""; LOG_FILE=""
# shellcheck disable=SC2034  # set through a nameref in load_config; the summary always lists only NON-COMPLIANT
NC_ONLY_CONF=0
CONFIG_FILE=""; CONFIG_AUTO=0; HELP_MODE=0
declare -A CLI_SET=()   # settings given on the command line (they replace what the conf said)
WORK=""; WRITTEN=()

# ----------------------------------------------------------------------------
# Logging and small helpers
# ----------------------------------------------------------------------------
# _log LEVEL MESSAGE...: timestamped line to stderr.
_log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${*:2}" >&2; }
# Level wrappers.
log_info() { _log INFO "$@"; }
log_warn() { _log WARN "$@"; }
# die CODE MESSAGE...: log an ERROR line and exit with CODE.
die() { local code="$1"; shift; _log ERROR "$@"; exit "$code"; }
# need_arg OPTION REMAINING_ARGC: exit 1 when an option that needs a value is the last argument.
need_arg() { [[ "$2" -ge 2 ]] || die 1 "Option $1 requires a value (see --help)"; }
# add_list ARRAY_NAME 'a, b,c': split on commas, trim spaces, append the non-empty items.
add_list() {
    local -n _arr="$1"; local _item; local -a _parts
    IFS=',' read -r -a _parts <<<"$2"
    for _item in "${_parts[@]}"; do
        _item="${_item#"${_item%%[![:space:]]*}"}"; _item="${_item%"${_item##*[![:space:]]}"}"
        [[ -n "$_item" ]] && _arr+=("$_item")
    done
    return 0
}
# redact_url URL: keep only scheme://host, so a webhook token never reaches the log.
redact_url() { if [[ "$1" =~ ^([a-zA-Z]+://[^/]+) ]]; then printf '%s/...' "${BASH_REMATCH[1]}"; else printf '<webhook>'; fi; }

# to_bool VAR KEY VALUE WHERE: set VAR to 1 or 0 from yes/no (also true/false, on/off, 1/0); anything else stops the run.
to_bool() {
    local -n _b="$1"
    case "${3,,}" in 1|y|yes|true|on) _b=1 ;; 0|n|no|false|off) _b=0 ;; *) die 1 "$4: '$2' must be yes or no (got '$3')" ;; esac
}
# cur VAR: the current value of a setting for --help (lists joined by commas, 1/0 shown as yes/no, empty as "(empty)").
cur() {
    local n="$1" v; local -n _c="$n"
    case "$(declare -p "$n" 2>/dev/null)" in "declare -a"*) v="$(IFS=,; printf '%s' "${_c[*]}")" ;; *) v="${_c}" ;; esac
    case "$n" in ALL_REGIONS|DISCOVER|ORACLE_ANY_LINE|FAIL_ON_NC|VERBOSE|ATTACH_HTML|ATTACH_CSV)
        case "$v" in 1) v=yes ;; 0) v=no ;; esac ;; esac
    printf '%s' "${v:-(empty)}"
}

# ----------------------------------------------------------------------------
# Usage
# ----------------------------------------------------------------------------
# usage: print the --help text.
usage() {
    cat <<USAGE
$SCRIPT_NAME $SCRIPT_VERSION - RDS patch compliance SUMMARY (read-only)

Shows only the high-level picture and the NON-COMPLIANT servers. The rule (same as the full report):
NON-COMPLIANT when versions_behind > --max-behind (conf: max_behind = $(cur MAX_BEHIND)).

Settings: every value comes from the conf file next to the scripts ($CONFIG_NAME), the same file the full
report uses; --config FILE uses another complete copy. An option below overrides one value for this run.
In this help [conf key = value] shows what the conf file currently says.

Usage: $SCRIPT_NAME [options]
  -P, --profile P[,P]       AWS CLI profile(s)  [repeatable]  [profiles = $(cur PROFILES)]
  -r, --region R[,R]        Region(s); replaces all_regions  [repeatable]  [regions = $(cur REGIONS)]
  -A, --all-regions         Every enabled region; a quick discovery probe per region (in parallel) skips
                            regions with no DB instance / cluster  [all_regions = $(cur ALL_REGIONS)]
      --no-discover         With -A: scan every enabled region in full (no probe)  [discover = $(cur DISCOVER)]
      --probe-parallel N    With -A: regions probed at a time, 1-$MAX_PROBE_PARALLEL  [probe_parallel = $(cur PROBE_PARALLEL)]
  -e, --engine GLOB         Engine filter, e.g. 'aurora-*', oracle-ee  [repeatable]  [engines = $(cur ENGINES)]
  -i, --identifier GLOB     Cluster / instance filter  [repeatable]  [identifiers = $(cur IDENTIFIERS)]
      --max-behind N        Allowed minor versions behind  [max_behind = $(cur MAX_BEHIND)]
      --warn-days N         "Support ending" window in days  [warn_days = $(cur WARN_DAYS)]
      --oracle-any-patch-line  Oracle: count targets on other patch lines too  [oracle_any_patch_line = $(cur ORACLE_ANY_LINE)]
  -F, --format F[,F]        txt | html | csv  (csv = non-compliant rows + summary CSV)  [formats = $(cur FORMATS)]
                            (json in the conf is skipped here: the summary has no json format)
  -o, --output-dir DIR      Write files there; -o "" prints one txt summary on the screen  [output_dir = $(cur OUTPUT_DIR)]
      --prefix NAME         File name prefix (conf prefix + _summary)  [prefix = $(cur CONF_PREFIX)]
      --save-data [FILE.json]  Also save the raw data (same format as rds_patch_compliance_report.sh --save-data):
                            default rds_patch_<ACCOUNTID>_<YYYYMMDD>.json per account in -o DIR (or the current folder)
      --merge FILE|DIR...   Offline: summarise --save-data files of either script (a DIR = its *.json data files).
                            0 AWS calls, jq only; the newer collection wins per account; days recomputed now.
                            -P / -r / -A / --no-discover / --probe-parallel / -e / -i / --save-data do not apply.
      --fail-on-noncompliant  Exit 5 when any NON-COMPLIANT server is found  [fail_on_noncompliant = $(cur FAIL_ON_NC)]
      --exceptions FILE     Compliance exceptions file (v1.6.0), passed to the full report.
                            A listed NON-COMPLIANT server (scope patch) shows COMPLIANT (EXCEPTION) and counts
                            as compliant until the expiry date. UNKNOWN stays UNKNOWN; the exception is still listed.
                            Empty in the conf = compliance_exceptions.conf next to the scripts, if present.  [exceptions = $(cur EXC_FILE)]
      --alert-email ADDR    E-mail the summary (sendmail: HTML + text + attachments; mail/mailx: text only)  [repeatable]
                            [alert_emails = $(cur ALERT_EMAILS)]
      --alert-webhook URL   POST the summary to a webhook (curl)  [repeatable]  [alert_webhooks = $(cur ALERT_WEBHOOKS)]
      --alert-webhook-format F  slack | json  [alert_webhook_format = $(cur ALERT_WEBHOOK_FORMAT)]
      --alert-on WHEN       noncompliant (NON-COMPLIANT found or AWS errors) | always  [alert_on = $(cur ALERT_ON)]
      --alert-from ADDR     From address for e-mail  [alert_from = $(cur ALERT_FROM)]
      --attach-html YES|NO  Attach the HTML summary to the e-mail (sendmail only)  [attach_html = $(cur ATTACH_HTML)]
      --attach-csv YES|NO   Attach the non-compliant CSV to the e-mail (sendmail only)  [attach_csv = $(cur ATTACH_CSV)]
      --attach-prefix NAME  Short name of the attachments: NAME_YYYY-MM-DD.html / .csv  [attach_prefix = $(cur ATTACH_PREFIX)]
      --mail-timeout SEC    Stop the mail command after SEC seconds  [mail_timeout = $(cur MAIL_TIMEOUT)]
      --config FILE         Use this conf file instead of $CONFIG_NAME next to the scripts (it must be complete)
  -v, --verbose             Debug log of the scan  [verbose = $(cur VERBOSE)]
  -h, --help | -V, --version
Merge example (Git Bash):  $SCRIPT_NAME --merge "C:\\Users\\me\\Downloads\\patch data" -F txt,html,csv -o out
Exit codes: 0 ok, 1 usage / conf error, 2 pre-check / collection failed, 3 bad --merge input, 4 output error, 5 non-compliant (--fail-on-noncompliant), 130 interrupted.
Needs: aws CLI v2 (not for --merge), jq 1.6+, and rds_patch_compliance_report.sh, its conf and lib/ next to this script.
USAGE
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
# load_config FILE: read the conf (same format as the full report): 'key = value' settings; '123456789012 = name' lines
# are display names for the full report and are skipped here. Every key in REQUIRED_KEYS must be present.
load_config() {
    local file="$1" line key val lineno=0 k where
    local -A seen=()
    local -a missing=()
    if [[ ! -r "$file" ]]; then
        (( HELP_MODE )) && return 0
        if (( CONFIG_AUTO )); then die 1 "Config file not found: $file (it ships next to the script: restore it from the release, or pass --config FILE)"; fi
        die 1 "Config file not readable: $file"
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$(( lineno + 1 )); line="${line%$'\r'}"; where="Config $file:$lineno"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        [[ "$line" =~ ^[[:space:]]*[0-9]{12}[[:space:]]*= ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_-]*)[[:space:]]*=[[:space:]]*(.*)$ ]] \
            || die 1 "$where: invalid line (expected key=value)"
        key="${BASH_REMATCH[1],,}"; key="${key//-/_}"; val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"([^\"]*)\" || "$val" =~ ^\'([^\']*)\' ]]; then val="${BASH_REMATCH[1]}"
        else
            [[ "$val" =~ ^(.*[^[:space:]])?[[:space:]]+#.*$ ]] && val="${BASH_REMATCH[1]}"
            val="${val%"${val##*[![:space:]]}"}"
        fi
        case "$key" in
            profile) key=profiles ;; region) key=regions ;; engine) key=engines ;; identifier) key=identifiers ;;
            format) key=formats ;; alert_email) key=alert_emails ;; alert_webhook) key=alert_webhooks ;;
        esac
        case "$key" in
            profiles)               PROFILES=(); add_list PROFILES "$val" ;;
            regions)                REGIONS=(); add_list REGIONS "$val" ;;
            all_regions)            to_bool ALL_REGIONS "$key" "$val" "$where" ;;
            discover)               to_bool DISCOVER "$key" "$val" "$where" ;;
            probe_parallel)         PROBE_PARALLEL="$val" ;;
            engines)                ENGINES=(); add_list ENGINES "$val" ;;
            identifiers)            IDENTIFIERS=(); add_list IDENTIFIERS "$val" ;;
            tag_columns|top)        seen[$key]=1; continue ;;   # ignored (deprecated)
            formats)                FORMATS=(); add_list FORMATS "$val" ;;
            output_dir)             OUTPUT_DIR="${val/#\~/$HOME}" ;;
            prefix)                 CONF_PREFIX="$val" ;;
            tz|aws_timeout|max_attempts|aws_retry_mode|exception_warn_days) ;;   # used by the scan (checked there)
            max_behind)             MAX_BEHIND="$val" ;;
            warn_days)              WARN_DAYS="$val" ;;
            non_compliant_only)     to_bool NC_ONLY_CONF "$key" "$val" "$where" ;;   # the summary always lists only NON-COMPLIANT
            oracle_any_patch_line)  to_bool ORACLE_ANY_LINE "$key" "$val" "$where" ;;
            fail_on_noncompliant)   to_bool FAIL_ON_NC "$key" "$val" "$where" ;;
            exceptions)             EXC_FILE="${val/#\~/$HOME}" ;;
            log_file)               LOG_FILE="${val/#\~/$HOME}" ;;
            verbose)                to_bool VERBOSE "$key" "$val" "$where" ;;
            alert_emails)           ALERT_EMAILS=(); add_list ALERT_EMAILS "$val" ;;
            alert_webhooks)         ALERT_WEBHOOKS=(); add_list ALERT_WEBHOOKS "$val" ;;
            alert_webhook_format)   ALERT_WEBHOOK_FORMAT="$val" ;;
            alert_on)               ALERT_ON="$val" ;;
            alert_from)             ALERT_FROM="$val" ;;
            attach_html)            to_bool ATTACH_HTML "$key" "$val" "$where" ;;
            attach_csv)             to_bool ATTACH_CSV "$key" "$val" "$where" ;;
            attach_prefix)          ATTACH_PREFIX="$val" ;;
            mail_timeout)           MAIL_TIMEOUT="$val" ;;
            slack_max_chars)        SLACK_MAX_CHARS="$val" ;;
            webhook_timeout)        WEBHOOK_TIMEOUT="$val" ;;
            webhook_retries)        WEBHOOK_RETRIES="$val" ;;
            aws_access_key_id|aws_secret_access_key|aws_session_token|secret|password)
                die 1 "$where: credentials are not accepted here; use an AWS CLI profile / SSO / role" ;;
            *) die 1 "$where: unknown key '$key'" ;;
        esac
        seen[$key]=1
    done <"$file"
    (( HELP_MODE )) && return 0
    for k in "${REQUIRED_KEYS[@]}"; do [[ -n "${seen[$k]:-}" ]] || missing+=("$k"); done
    (( ${#missing[@]} == 0 )) || die 1 "Config $file: missing required setting(s): ${missing[*]} (every setting must be in the conf; compare with the $CONFIG_NAME that ships with the script)"
}

# parse_args "$@": load the conf first (--config FILE wherever it appears, else $CONFIG_NAME next to the script),
# then apply the options in order. An option given here replaces the conf value for this run.
parse_args() {
    local opt i j a
    for (( i = 1; i <= $#; i++ )); do
        a="${!i}"
        case "$a" in
            --config=*) CONFIG_FILE="${a#--config=}" ;;
            --config)   j=$(( i + 1 )); (( j <= $# )) || die 1 "Option --config requires a value"; CONFIG_FILE="${!j}" ;;
            -h|--help|-V|--version) HELP_MODE=1 ;;
        esac
    done
    if [[ -z "$CONFIG_FILE" ]]; then CONFIG_FILE="$SCRIPT_DIR/$CONFIG_NAME"; CONFIG_AUTO=1; fi
    load_config "$CONFIG_FILE"
    local -A seen=()
    # reset_once ARRAY_NAME: the first time an option is seen it replaces the conf list; later uses append.
    reset_once() { [[ -n "${seen[$1]:-}" ]] && return 0; seen[$1]=1; local -n _a="$1"; _a=(); }
    while (( $# )); do
        opt="$1"
        if [[ "$opt" == --*=* ]]; then set -- "${opt%%=*}" "${opt#*=}" "${@:2}"; opt="$1"; fi
        case "$opt" in
            -P|--profile)       need_arg "$opt" $#; reset_once PROFILES; add_list PROFILES "$2"; CLI_SET[profiles]=1; shift 2 ;;
            -r|--region)        need_arg "$opt" $#; reset_once REGIONS; add_list REGIONS "$2"; CLI_SET[regions]=1; shift 2 ;;
            -A|--all-regions)   ALL_REGIONS=1; CLI_SET[all_regions]=1; shift ;;
            --no-discover)      DISCOVER=0; CLI_SET[discover]=1; shift ;;
            --probe-parallel)   need_arg "$opt" $#; PROBE_PARALLEL="$2"; CLI_SET[probe_parallel]=1; shift 2 ;;
            -e|--engine)        need_arg "$opt" $#; reset_once ENGINES; add_list ENGINES "$2"; CLI_SET[engines]=1; shift 2 ;;
            -i|--identifier)    need_arg "$opt" $#; reset_once IDENTIFIERS; add_list IDENTIFIERS "$2"; CLI_SET[identifiers]=1; shift 2 ;;
            --max-behind)       need_arg "$opt" $#; MAX_BEHIND="$2"; MAX_BEHIND_SET=1; shift 2 ;;
            --save-data)        SAVE_DATA=1; if [[ $# -ge 2 && "$2" != -* ]]; then SAVE_DATA_FILE="$2"; shift; fi; shift ;;
            --merge)            MERGE=1; shift; while (( $# )) && [[ "$1" != -* ]]; do MERGE_ARGS+=("$1"); shift; done ;;
            --warn-days)        need_arg "$opt" $#; WARN_DAYS="$2"; shift 2 ;;
            --oracle-any-patch-line) ORACLE_ANY_LINE=1; shift ;;
            -F|--format)        need_arg "$opt" $#; reset_once FORMATS; add_list FORMATS "$2"; FORMATS_SET=1; shift 2 ;;
            -o|--output-dir)    need_arg "$opt" $#; OUTPUT_DIR="$2"; shift 2 ;;
            --prefix)           need_arg "$opt" $#; PREFIX="$2"; PREFIX_SET=1; shift 2 ;;
            --fail-on-noncompliant) FAIL_ON_NC=1; shift ;;
            --exceptions)       need_arg "$opt" $#; EXC_FILE="$2"; shift 2 ;;
            --alert-email)      need_arg "$opt" $#; reset_once ALERT_EMAILS; add_list ALERT_EMAILS "$2"; shift 2 ;;
            --alert-webhook)    need_arg "$opt" $#; reset_once ALERT_WEBHOOKS; add_list ALERT_WEBHOOKS "$2"; shift 2 ;;
            --alert-webhook-format) need_arg "$opt" $#; ALERT_WEBHOOK_FORMAT="$2"; shift 2 ;;
            --alert-on)         need_arg "$opt" $#; ALERT_ON="$2"; shift 2 ;;
            --alert-from)       need_arg "$opt" $#; ALERT_FROM="$2"; shift 2 ;;
            --attach-html)      need_arg "$opt" $#; to_bool ATTACH_HTML attach_html "$2" "Option --attach-html"; shift 2 ;;
            --attach-csv)       need_arg "$opt" $#; to_bool ATTACH_CSV attach_csv "$2" "Option --attach-csv"; shift 2 ;;
            --attach-prefix)    need_arg "$opt" $#; ATTACH_PREFIX="$2"; shift 2 ;;
            --mail-timeout)     need_arg "$opt" $#; MAIL_TIMEOUT="$2"; shift 2 ;;
            --config)           shift 2 ;;
            -v|--verbose)       VERBOSE=1; shift ;;
            -h|--help)          usage; exit 0 ;;
            -V|--version)       echo "$SCRIPT_NAME $SCRIPT_VERSION"; exit 0 ;;
            *)                  die 1 "Unknown option: $opt (see --help)" ;;
        esac
    done
    # -r replaces all_regions = yes from the conf; -A replaces regions from the conf (both on the command line = an error)
    if [[ -n "${CLI_SET[regions]:-}" && -z "${CLI_SET[all_regions]:-}" ]]; then ALL_REGIONS=0; fi
    if [[ -n "${CLI_SET[all_regions]:-}" && -z "${CLI_SET[regions]:-}" ]]; then REGIONS=(); fi
    (( PREFIX_SET )) || PREFIX="${CONF_PREFIX}_summary"
}

# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------
# validate: check the options, formats and alert settings, and that the full report script and lib files exist.
validate() {
    local f x
    if (( ! FORMATS_SET )); then   # conf formats: the summary has no json format, so json is skipped
        local -a keep=(); for f in "${FORMATS[@]}"; do if [[ "${f,,}" == json ]]; then log_info "formats: json is skipped (the summary writes txt, html, csv)"; else keep+=("$f"); fi; done
        FORMATS=("${keep[@]}")
    fi
    (( ${#FORMATS[@]} )) || FORMATS=(txt)
    FORMATS=("${FORMATS[@],,}")
    for f in "${FORMATS[@]}"; do case "$f" in txt|text|html|csv) ;; *) die 1 "Unknown format '$f' (txt, html, csv)" ;; esac; done
    if [[ -z "$OUTPUT_DIR" ]] && { (( ${#FORMATS[@]} > 1 )) || [[ "${FORMATS[0]}" != txt && "${FORMATS[0]}" != text ]]; }; then
        die 1 "html / csv / several formats need -o DIR"
    fi
    [[ "$MAX_BEHIND" =~ ^[0-9]+$ ]] || die 1 "--max-behind must be a whole number >= 0"
    [[ "$WARN_DAYS" =~ ^[0-9]+$ ]] || die 1 "--warn-days must be a whole number >= 0"
    [[ "$PREFIX" =~ ^[A-Za-z0-9._-]+$ && "$PREFIX" != .* ]] || die 1 "--prefix may contain only letters, digits, . _ -"
    (( ALL_REGIONS && ${#REGIONS[@]} )) && die 1 "Use either -r or --all-regions, not both"
    { [[ "$PROBE_PARALLEL" =~ ^[0-9]+$ ]] && (( 10#$PROBE_PARALLEL >= 1 && 10#$PROBE_PARALLEL <= MAX_PROBE_PARALLEL )); } \
        || die 1 "--probe-parallel must be a whole number from 1 to $MAX_PROBE_PARALLEL"
    [[ "$ATTACH_PREFIX" =~ ^[A-Za-z0-9._-]+$ ]] || die 1 "--attach-prefix may contain only letters, digits, . _ -"
    { [[ "$MAIL_TIMEOUT" =~ ^[0-9]+$ ]] && (( 10#$MAIL_TIMEOUT > 0 )); } || die 1 "--mail-timeout must be a positive integer"
    { [[ "$SLACK_MAX_CHARS" =~ ^[0-9]+$ ]] && (( 10#$SLACK_MAX_CHARS > 0 )); } || die 1 "slack_max_chars must be a positive integer"
    { [[ "$WEBHOOK_TIMEOUT" =~ ^[0-9]+$ ]] && (( 10#$WEBHOOK_TIMEOUT > 0 )); } || die 1 "webhook_timeout must be a positive integer"
    [[ "$WEBHOOK_RETRIES" =~ ^[0-9]+$ ]] || die 1 "webhook_retries must be a whole number (0 or more)"
    MAIL_TIMEOUT=$(( 10#$MAIL_TIMEOUT )); SLACK_MAX_CHARS=$(( 10#$SLACK_MAX_CHARS )); WEBHOOK_TIMEOUT=$(( 10#$WEBHOOK_TIMEOUT )); WEBHOOK_RETRIES=$(( 10#$WEBHOOK_RETRIES ))
    case "${ALERT_ON,,}" in noncompliant|always) ALERT_ON="${ALERT_ON,,}" ;; *) die 1 "--alert-on must be noncompliant or always" ;; esac
    case "${ALERT_WEBHOOK_FORMAT,,}" in slack|json) ALERT_WEBHOOK_FORMAT="${ALERT_WEBHOOK_FORMAT,,}" ;; *) die 1 "--alert-webhook-format must be slack or json" ;; esac
    for x in "${ALERT_EMAILS[@]}"; do
        [[ "$x" =~ ^[^[:space:]@\;\|\&\$\`]+@[^[:space:]@\;\|\&\$\`]+$ ]] || die 1 "Invalid --alert-email address: $x"
    done
    for x in "${ALERT_WEBHOOKS[@]}"; do [[ "$x" =~ ^https?:// ]] || die 1 "--alert-webhook must be an http(s) URL: $(redact_url "$x")"; done
    if (( MERGE )); then
        (( ${#MERGE_ARGS[@]} )) || die 1 "--merge needs at least one --save-data file or directory"
        [[ -n "${CLI_SET[profiles]:-}${CLI_SET[regions]:-}${CLI_SET[all_regions]:-}${CLI_SET[discover]:-}" ]] && die 1 "--merge works offline on saved data: -P / -r / -A / --no-discover do not apply"
        [[ -n "${CLI_SET[probe_parallel]:-}" ]] && die 1 "--merge: --probe-parallel does not apply"
        [[ -n "${CLI_SET[engines]:-}${CLI_SET[identifiers]:-}" ]] && die 1 "--merge: -e / -i do not apply"
        (( SAVE_DATA )) && die 1 "--merge cannot be combined with --save-data"
        PROFILES=(); REGIONS=(); ALL_REGIONS=0; ENGINES=(); IDENTIFIERS=()   # the conf's scan scope is not used offline
    fi
    if [[ -n "$SAVE_DATA_FILE" ]]; then
        [[ "$SAVE_DATA_FILE" == *.json ]] || die 1 "--save-data FILE must end in .json"
        [[ "$SAVE_DATA_FILE" == /* ]] || SAVE_DATA_FILE="$PWD/$SAVE_DATA_FILE"
    fi
    # resolve before collect() may cd (e.g. default --save-data into -o DIR)
    if [[ -n "$EXC_FILE" ]]; then
        [[ "$EXC_FILE" == /* ]] || EXC_FILE="$PWD/$EXC_FILE"
    fi
    if [[ -n "$LOG_FILE" ]]; then [[ "$LOG_FILE" == /* ]] || LOG_FILE="$PWD/$LOG_FILE"; fi
    [[ "$CONFIG_FILE" == /* ]] || CONFIG_FILE="$PWD/$CONFIG_FILE"
    log_info "Settings: $CONFIG_FILE ($( (( CONFIG_AUTO )) && echo "loaded automatically from the script folder" || echo "from --config"))"
    command -v jq >/dev/null 2>&1 || die 2 "jq not found in PATH"
    [[ -x "$FULL" ]] || die 2 "Full report script not found or not executable: $FULL"
    [[ -r "$LIB" && -r "$SCRIPT_DIR/lib/versions.jq" ]] || die 2 "lib/summary.jq or lib/versions.jq missing next to $SCRIPT_NAME"
    (( ! ${#ALERT_EMAILS[@]} )) || [[ -r "$EMAIL_LIB" ]] || die 2 "lib/alert_email.jq missing next to $SCRIPT_NAME"
}

# ----------------------------------------------------------------------------
# Collection (delegated to rds_patch_compliance_report.sh -F json)
# ----------------------------------------------------------------------------
# collect: run the full report (scan, or --merge offline) and keep its finalized JSON in $REPORT.
# the full report does the read-only scan; its JSON is the single source of the numbers
# child_conf: a copy of the conf for the scan, with the output and alert settings switched off (the summary writes the
# files and sends the alerts itself); relative paths are made absolute because the scan may run in another folder.
child_conf() {
    CHILD_CONF="$WORK/scan.conf"
    {
        cat -- "$CONFIG_FILE"
        printf '\n## summary: the scan only returns JSON; files and alerts belong to the summary\n'
        printf 'formats = json\noutput_dir =\nnon_compliant_only = no\nfail_on_noncompliant = no\nalert_emails =\nalert_webhooks =\n'
        printf 'log_file = %s\nexceptions = %s\n' "$LOG_FILE" "$EXC_FILE"
    } >"$CHILD_CONF"
    if [[ -n "$LOG_FILE" ]]; then mkdir -p -- "$(dirname -- "$LOG_FILE")" 2>/dev/null || true; fi
}
collect() {
    local -a a=(--config "$WORK/scan.conf" -F json --warn-days "$WARN_DAYS")
    local x rc=0 dir=.
    child_conf
    if (( MERGE )); then
        # offline: the full report merges (0 AWS calls, exit 3 on a bad file); --max-behind only when given (default: from the files)
        a=(--merge "${MERGE_ARGS[@]}" "${a[@]}")
        (( MAX_BEHIND_SET )) && a+=(--max-behind "$MAX_BEHIND")
        (( ORACLE_ANY_LINE )) && a+=(--oracle-any-patch-line)
        (( VERBOSE )) && a+=(-v)
        [[ -n "$EXC_FILE" ]] && a+=(--exceptions "$EXC_FILE")
        REPORT="$WORK/report.json"
        RDS_PCR_NO_SETTINGS_LOG=1 "$FULL" "${a[@]}" >"$REPORT" || rc=$?
        (( rc == 0 )) || die "$rc" "Merge failed (rds_patch_compliance_report.sh --merge exit $rc)"
        jq -e '.summary.total != null' "$REPORT" >/dev/null 2>&1 || die 2 "Merge returned no report"
        return 0
    fi
    a+=(--max-behind "$MAX_BEHIND")
    for x in "${PROFILES[@]}"; do a+=(-P "$x"); done
    for x in "${REGIONS[@]}"; do a+=(-r "$x"); done
    for x in "${ENGINES[@]}"; do a+=(-e "$x"); done
    for x in "${IDENTIFIERS[@]}"; do a+=(-i "$x"); done
    (( ALL_REGIONS )) && a+=(--all-regions)
    (( DISCOVER )) || a+=(--no-discover)
    a+=(--probe-parallel "$PROBE_PARALLEL")
    (( ORACLE_ANY_LINE )) && a+=(--oracle-any-patch-line)
    (( VERBOSE )) && a+=(-v)
    [[ -n "$EXC_FILE" ]] && a+=(--exceptions "$EXC_FILE")
    if (( SAVE_DATA )); then
        # the full report writes the data file(s); default names go to -o DIR (or the current folder)
        if [[ -n "$SAVE_DATA_FILE" ]]; then a+=(--save-data "$SAVE_DATA_FILE")
        else a+=(--save-data); [[ -n "$OUTPUT_DIR" ]] && { mkdir -p -- "$OUTPUT_DIR" || die 4 "Cannot create $OUTPUT_DIR"; dir="$OUTPUT_DIR"; }; fi
    fi
    REPORT="$WORK/report.json"
    ( cd -- "$dir" && RDS_PCR_NO_SETTINGS_LOG=1 exec "$FULL" "${a[@]}" ) >"$REPORT" || rc=$?
    (( rc == 0 )) || die "$rc" "Scan failed (rds_patch_compliance_report.sh exit $rc)"
    jq -e '.summary.total != null' "$REPORT" >/dev/null 2>&1 || die 2 "Scan returned no report"
}

# ----------------------------------------------------------------------------
# jq helpers and rendering
# ----------------------------------------------------------------------------
# jq.exe (Git Bash on Windows) writes CRLF: every jq output used here is made LF-only
JQ_CRLF=0
# detect_jq_eol: set JQ_CRLF=1 when this jq writes CRLF line ends.
detect_jq_eol() { if [[ "$(jq -jn '"x\n"' | wc -c | tr -d ' \r')" != 2 ]]; then JQ_CRLF=1; fi; }
# unix_eol: stdin filter; strips CR when JQ_CRLF=1.
unix_eol() { if (( JQ_CRLF )); then tr -d '\r'; else cat; fi; }
# jqr ARGS...: jq with LF-only output.
jqr() { jq "$@" | unix_eol; }
# render MODE: render $REPORT with lib/summary.jq (text, html, csv_nc, csv_summary, csv_accounts, csv_regions, alert).
render() { jqr -r --arg mode "$1" --arg version "$SCRIPT_VERSION" -f "$LIB" "$REPORT"; }

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------
# write_outputs: text to stdout without -o; else one file per format (csv = summary, non-compliant, accounts,
# regions files), with the account number in the names when one account was scanned.
write_outputs() {
    local f stamp file acct
    if [[ -z "$OUTPUT_DIR" ]]; then render text || die 4 "Rendering failed"; return 0; fi
    mkdir -p -- "$OUTPUT_DIR" || die 4 "Cannot create $OUTPUT_DIR"
    stamp="$(date -u +%Y%m%d_%H%M%S)"
    # one account: its number goes into the file names
    acct="$(jqr -r 'if (.meta.accounts | length) == 1 then .meta.accounts[0].account else "" end' "$REPORT")"
    [[ "$acct" =~ ^[0-9]{12}$ ]] && stamp="${acct}_$stamp"
    for f in "${FORMATS[@]}"; do
        case "$f" in
            txt|text) file="$OUTPUT_DIR/${PREFIX}_$stamp.txt"; render text >"$file" || die 4 "Writing $file failed" ;;
            html)     file="$OUTPUT_DIR/${PREFIX}_$stamp.html"; render html >"$file" || die 4 "Writing $file failed" ;;
            csv)      file="$OUTPUT_DIR/${PREFIX}_${stamp}_summary.csv"; render csv_summary >"$file" || die 4 "Writing $file failed"
                      WRITTEN+=("$(cd -- "$OUTPUT_DIR" && pwd -P)/${file##*/}")
                      file="$OUTPUT_DIR/${PREFIX}_${stamp}_noncompliant.csv"; render csv_nc >"$file" || die 4 "Writing $file failed"
                      WRITTEN+=("$(cd -- "$OUTPUT_DIR" && pwd -P)/${file##*/}")
                      file="$OUTPUT_DIR/${PREFIX}_${stamp}_accounts.csv"; render csv_accounts >"$file" || die 4 "Writing $file failed"
                      WRITTEN+=("$(cd -- "$OUTPUT_DIR" && pwd -P)/${file##*/}")
                      file="$OUTPUT_DIR/${PREFIX}_${stamp}_regions.csv"; render csv_regions >"$file" || die 4 "Writing $file failed" ;;
        esac
        WRITTEN+=("$(cd -- "$OUTPUT_DIR" && pwd -P)/${file##*/}")
    done
    printf '%s\n' "${WRITTEN[@]}" | while IFS= read -r f; do log_info "Wrote $f"; done
    # the screen still gets the text summary when txt is requested
    case " ${FORMATS[*]} " in *" txt "*|*" text "*) render text ;; esac
}

# ----------------------------------------------------------------------------
# Alerts (optional)
# ----------------------------------------------------------------------------
# find_mailer: sendmail first (it can send the HTML body and attachments), else mail, then mailx (text only).
find_mailer() {
    local c
    command -v sendmail 2>/dev/null && return 0
    [[ -x /usr/sbin/sendmail ]] && { echo /usr/sbin/sendmail; return 0; }
    for c in mail mailx; do command -v "$c" 2>/dev/null && return 0; done
    return 0
}
# attach_mime_name FILE: short name used only in the e-mail headers: <attach_prefix>_YYYY-MM-DD.<ext> (UTC date of the run).
attach_mime_name() { printf '%s_%s.%s' "$ATTACH_PREFIX" "$(date -u +%Y-%m-%d)" "${1##*.}"; }
# mime_attach BOUNDARY FILE: one base64 attachment part.
mime_attach() {
    local bnd="$1" f="$2" name ctype
    name="$(attach_mime_name "$f")"
    case "${f##*.}" in html|htm) ctype="text/html; charset=UTF-8" ;; csv) ctype="text/csv; charset=UTF-8" ;; *) ctype="application/octet-stream" ;; esac
    printf -- '\n--%s\nContent-Type: %s; name="%s"\nContent-Disposition: attachment; filename="%s"\nContent-Transfer-Encoding: base64\n\n' "$bnd" "$ctype" "$name" "$name"
    base64 <"$f"
}
# send_email SUBJECT TEXT_FILE HTML_FILE [ATTACH...]: sendmail gets multipart/mixed { alternative { text, HTML }, attachments };
# mail / mailx get the text summary only. The mail command may run at most mail_timeout seconds.
send_email() {
    local subject="$1" text="$2" html="$3" mailer to mixed alt a
    shift 3
    local -a atts=("$@") tmo=()
    command -v timeout >/dev/null 2>&1 && tmo=(timeout "$MAIL_TIMEOUT")
    mailer="$(find_mailer)"
    [[ -n "$mailer" ]] || { log_warn "Alert: no mail, mailx or sendmail found; e-mail not sent"; return 1; }
    if [[ "${mailer##*/}" != sendmail ]]; then
        local -a from=(); [[ -n "$ALERT_FROM" ]] && from=(-r "$ALERT_FROM")
        log_info "Alert: ${mailer##*/} sends the text summary only (install sendmail for the HTML body and attachments)"
        "${tmo[@]}" "$mailer" "${from[@]}" -s "$subject" -- "${ALERT_EMAILS[@]}" <"$text"; return
    fi
    to="$(IFS=,; printf '%s' "${ALERT_EMAILS[*]}")"
    mixed="rds_pcs_$(date +%s)_$$"; alt="rds_pcs_alt_$(date +%s)_$$"
    {
        [[ -n "$ALERT_FROM" ]] && printf 'From: %s\n' "$ALERT_FROM"
        printf 'To: %s\nSubject: %s\nMIME-Version: 1.0\n' "$to" "$subject"
        if (( ${#atts[@]} )); then
            printf 'Content-Type: multipart/mixed; boundary="%s"\n\nThis is a MIME message.\n\n' "$mixed"
            printf -- '--%s\nContent-Type: multipart/alternative; boundary="%s"\n\n' "$mixed" "$alt"
        else
            printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "$alt"
        fi
        printf -- '--%s\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n' "$alt"
        cat -- "$text"
        printf -- '\n--%s\nContent-Type: text/html; charset=UTF-8\nContent-Transfer-Encoding: 8bit\n\n' "$alt"
        cat -- "$html"
        printf -- '\n--%s--\n' "$alt"
        if (( ${#atts[@]} )); then
            for a in "${atts[@]}"; do mime_attach "$mixed" "$a"; done
            printf -- '\n--%s--\n' "$mixed"
        fi
    } | "${tmo[@]}" "$mailer" -t -oi
}
# alert_bodies TEXT_OUT HTML_OUT: write the e-mail text and HTML bodies with lib/alert_email.jq (same bodies as the full report).
alert_bodies() {
    local host when m
    host="$(hostname 2>/dev/null || echo unknown)"; when="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    for m in text html; do
        jq -r -f "$EMAIL_LIB" --arg mode "$m" --arg host "$host" --arg tool "$SCRIPT_NAME v$SCRIPT_VERSION" --arg when "$when" "$REPORT" \
            | unix_eol >"$WORK/alert_body.$m.tmp" || return 1
    done
    mv -f -- "$WORK/alert_body.text.tmp" "$1"; mv -f -- "$WORK/alert_body.html.tmp" "$2"
}
# alert_attachments: print the files to attach: the written HTML summary / non-compliant CSV, else one rendered into the work dir.
alert_attachments() {
    local w f=""
    if (( ATTACH_HTML )); then
        for w in "${WRITTEN[@]}"; do [[ "$w" == *.html ]] && f="$w"; done
        if [[ -z "$f" ]]; then f="$WORK/${PREFIX}_summary.html"; render html >"$f" || f=""; fi
        [[ -n "$f" && -s "$f" ]] && printf '%s\n' "$f"
    fi
    if (( ATTACH_CSV )); then
        f=""
        for w in "${WRITTEN[@]}"; do [[ "$w" == *_noncompliant.csv ]] && f="$w"; done
        if [[ -z "$f" ]]; then f="$WORK/${PREFIX}_noncompliant.csv"; render csv_nc >"$f" || f=""; fi
        [[ -n "$f" && -s "$f" ]] && printf '%s\n' "$f"
    fi
    return 0
}
# send_webhook_alert: POST the JSON payload with curl; the URL is passed on stdin (-K -), so it never shows in ps.
send_webhook_alert() {   # <url> <payload-file>
    local url="$1" payload="$2" out
    command -v curl >/dev/null 2>&1 || { log_warn "Alert: curl not installed; webhook skipped"; return 1; }
    out="$(printf 'url = "%s"\n' "${url//\"/\\\"}" | curl -sS --fail --max-time "$WEBHOOK_TIMEOUT" --retry "$WEBHOOK_RETRIES" \
            -H 'Content-Type: application/json' --data-binary "@$payload" -o /dev/null -w '%{http_code}' -K - 2>&1)" \
        || { log_warn "Alert: webhook $(redact_url "$url") failed: ${out%%$'\n'*}"; return 1; }
    log_info "Alert: webhook $(redact_url "$url") -> HTTP $out"
}
# send_alerts: send the summary to every e-mail / webhook; with --alert-on noncompliant only when NON-COMPLIANT
# servers or AWS errors were found.
send_alerts() {
    (( ${#ALERT_EMAILS[@]} + ${#ALERT_WEBHOOKS[@]} )) || return 0
    local body="$WORK/alert_body.txt" payload="$WORK/alert_payload.json" status subject url
    if [[ "$ALERT_ON" == noncompliant ]] && [[ "$(jqr -r '.summary.non_compliant + .summary.errors' "$REPORT")" == 0 ]]; then return 0; fi
    status="$(jqr -r 'if .summary.non_compliant > 0 then "NON-COMPLIANT" elif .summary.errors > 0 then "ERRORS" else "COMPLIANT" end' "$REPORT")"
    subject="[rds_patch_compliance_summary] $status: $(jqr -r '"\(.summary.non_compliant) non-compliant of \(.summary.total), \(.summary.pct_compliant)% compliant"' "$REPORT")"
    render text >"$body" || { log_warn "Alert: rendering failed"; return 0; }
    if [[ "$ALERT_WEBHOOK_FORMAT" == slack ]]; then
        jqr -cn --arg h "$subject" --rawfile b "$body" --argjson max "$SLACK_MAX_CHARS" \
            '{text: ("*" + $h + "*\n```" + (if ($b | length) > $max then $b[0:$max] + "\n... (truncated)" else $b end) + "```")}' >"$payload"
    else
        render alert | jqr -c --arg s "$subject" --arg st "$status" --rawfile b "$body" '. + {status: $st, text: ($s + "\n\n" + $b)}' >"$payload" \
            || { log_warn "Alert: building the payload failed"; return 0; }
    fi
    if (( ${#ALERT_EMAILS[@]} )); then
        local mtext="$WORK/mail_body.txt" mhtml="$WORK/mail_body.html"; local -a atts=()
        if alert_bodies "$mtext" "$mhtml"; then
            mapfile -t atts < <(alert_attachments)
            if send_email "$subject" "$mtext" "$mhtml" "${atts[@]}"; then log_info "Alert: e-mail ($status) sent to ${ALERT_EMAILS[*]}"
            else log_warn "Alert: e-mail to ${ALERT_EMAILS[*]} failed"; fi
        else log_warn "Alert: building the e-mail body failed; e-mail not sent"; fi
    fi
    for url in "${ALERT_WEBHOOKS[@]}"; do send_webhook_alert "$url" "$payload" || true; done
    return 0
}

# ----------------------------------------------------------------------------
# Exit and signal traps
# ----------------------------------------------------------------------------
# on_exit (EXIT trap): remove the work dir and keep the exit code.
# shellcheck disable=SC2317,SC2329  # invoked via trap
on_exit() { local rc=$?; trap - EXIT INT TERM; [[ -n "$WORK" && -d "$WORK" ]] && rm -rf -- "$WORK"; exit "$rc"; }
# on_signal (INT / TERM trap): log and exit 130.
# shellcheck disable=SC2317,SC2329
on_signal() { _log ERROR "Interrupted"; exit 130; }

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
# main: parse + validate, collect via the full report, write outputs, set exit 5 with --fail-on-noncompliant
# when NON-COMPLIANT servers exist, then send alerts.
main() {
    trap on_exit EXIT
    trap on_signal INT TERM
    parse_args "$@"
    validate
    detect_jq_eol
    WORK="$(mktemp -d "${TMPDIR:-/tmp}/rds_pcs.XXXXXX")"
    collect
    write_outputs
    local rc=0
    (( FAIL_ON_NC )) && [[ "$(jqr -r '.summary.non_compliant' "$REPORT")" != 0 ]] && rc=5
    log_info "$(jqr -r '"\(if .meta.merge then "Merged \(.meta.accounts | length) account(s) from \(.meta.merge.files) file(s), 0 AWS calls. " else "" end)Summary: \(.summary.total) server(s)/cluster(s): COMPLIANT \(.summary.compliant), NON-COMPLIANT \(.summary.non_compliant), UNKNOWN \(.summary.unknown) (\(.summary.pct_compliant)% compliant)"' "$REPORT"); exit $rc"
    send_alerts
    exit "$rc"
}

main "$@"
