# lib/compliance.jq - logic + rendering for rds_patch_compliance_report.sh
include "versions" {search: "./"};   # lib/versions.jq: version parsing + minor candidate selection (shared with the sibling tools)
# Modes ($mode): rows | finalize | text | csv | json | html | alert | vkey_cmp (tests)
# Every mode gets: $now (epoch), $max_behind, $warn_days, $top_n, $tagcols, $f (filters), $nc_only; optional --argjson oracle_any (default false)

# ------------------------------------------------------------------ helpers
# h: HTML-escape any value.
def h: tostring | @html;
# alab: account label, "name (number)" or "number (profile)".
def alab: if (.name // "") != "" then "\(.name) (\(.account))" else "\(.account) (\(.profile))" end;   # v1.5.0 "name (number)"
# dash: "-" for null / empty, else the value as text.
def dash: if . == null or . == "" then "-" else tostring end;
# glob2re: shell glob (* ?) -> anchored regex, other regex characters escaped.
def glob2re: "^" + (gsub("(?<c>[.+^$(){}|\\[\\]\\\\])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
# gmatch($globs): true when the input matches any glob (case-insensitive); an empty list matches everything.
def gmatch($globs): . as $v | ($globs | length) == 0 or any($globs[]; . as $g | ($v // "") | test($g | glob2re; "i"));
# sq: shell-quote a value only when it needs quoting.
def sq: tostring | if test("^[A-Za-z0-9_./:=@,+%-]+$") then . else "'" + gsub("'"; "'\\''") + "'" end;
# day: first 10 characters (YYYY-MM-DD) of a date string, null when empty.
def day: if . == null or . == "" then null else (tostring | .[0:10]) end;
# epoch_of_day: YYYY-MM-DD -> epoch seconds at 00:00 UTC.
def epoch_of_day: if . == null then null else (. + "T00:00:00Z" | fromdateiso8601) end;

# ------------------------------------------------------------------ version compare
# A version string is split into runs of digits and runs of letters; digit runs compare as NUMBERS (15.10 > 15.9,
# 3.05.2 = 3.5.2), letter runs as strings, and a shorter prefix sorts first (15.4 < 15.4.1). jq orders numbers
# before strings, so "19.0.0.0.ru-2024-01.rur-2024-01.r1" and "15.00.4415.2.v1" compare field by field.
# Aurora MySQL "8.0.mysql_aurora.3.05.2" shares the "8.0.mysql_aurora." prefix inside one major line, so the
# Aurora release (3.05.2) decides.
# vkey lives in lib/versions.jq; Oracle patch lines are parsed there (ora_parse) and compared numerically.
# vcmp($a; $b): -1 / 0 / 1 by vkey (used by the vkey_cmp test mode).
def vcmp($a; $b): ($a | vkey) as $x | ($b | vkey) as $y | if $x < $y then -1 elif $x > $y then 1 else 0 end;
# major line when AWS no longer lists the version (deprecated): same rule AWS uses for MajorEngineVersion
def derive_major($engine):
  split(".") as $k
  | if ($engine | test("postgres")) then (if (($k[0] | tonumber? // 0)) >= 10 then $k[0] else $k[0] + "." + ($k[1] // "0") end)
    elif ($engine | test("^oracle")) then $k[0]
    else ($k[0] + "." + ($k[1] // "0")) end;

# ------------------------------------------------------------------ maintenance window UTC -> IST
# dayn / dname: weekday name <-> number (sun = 0).
def dayn: {"sun":0,"mon":1,"tue":2,"wed":3,"thu":4,"fri":5,"sat":6}[ascii_downcase];
def dname: ["sun","mon","tue","wed","thu","fri","sat"][.];
# two: zero-pad to 2 digits.
def two: tostring | if length < 2 then "0" + . else . end;
# shift_win($mins): move a maintenance window "ddd:hh:mm-ddd:hh:mm" by $mins minutes, wrapping around the week
# (10080 minutes). Used with 330 for UTC -> IST.
def shift_win($mins):
  if . == null or . == "" then "" else
  split("-") | map(split(":") | ((.[0] | dayn) * 1440 + (.[1] | tonumber) * 60 + (.[2] | tonumber) + $mins) % 10080
                   | "\((. / 1440 | floor) | dname):\(((. % 1440) / 60 | floor) | two):\((. % 60) | two)") | join("-") end;

# ------------------------------------------------------------------ rows (per profile / region)
# svc_of: engine -> AWS CLI service (docdb, neptune, else rds).
def svc_of: if . == "docdb" then "docdb" elif . == "neptune" then "neptune" else "rds" end;
# in_scope: true for the engines this report covers.
def in_scope: test("^(aurora-postgresql|aurora-mysql|postgres|mysql|mariadb|sqlserver-(ee|se|ex|web)|oracle-(ee|se2|ee-cdb|se2-cdb)|docdb|neptune)$");
# tags_obj: TagList [{Key, Value}] -> {key: value}.
def tags_obj: [(.TagList // [])[] | {key: .Key, value: .Value}] | from_entries;

# one pending maintenance action -> structured + readable ("on" = "cluster", "member <id>" or "" for an instance)
# utc_day / ist_of / utc_of: an AWS timestamp as YYYY-MM-DD, "YYYY-MM-DD HH:MM IST" (+5:30) or "YYYY-MM-DD HH:MM UTC".
def utc_day: if . == null or . == "" then null else tostring | .[0:10] end;
def ist_of: if . == null or . == "" then null else (tostring | .[0:19] + "Z" | fromdateiso8601 + 19800 | strftime("%Y-%m-%d %H:%M IST")) end;
def utc_of: if . == null or . == "" then null else (tostring | .[0:16] | sub("T"; " ")) + " UTC" end;
# pend_item($on): one PendingMaintenanceActionDetails entry -> structured fields + a one-line text.
def pend_item($on):
  { action: .Action, on: $on, description: (.Description // ""), opt_in_status: (.OptInStatus // ""),
    auto_applied_after: (.AutoAppliedAfterDate | utc_day), forced_apply: (.ForcedApplyDate | utc_day), current_apply: (.CurrentApplyDate | utc_day),
    auto_applied_after_ist: (.AutoAppliedAfterDate | ist_of), forced_apply_ist: (.ForcedApplyDate | ist_of),
    auto_applied_after_utc: (.AutoAppliedAfterDate | utc_of), forced_apply_utc: (.ForcedApplyDate | utc_of) }
  | . + {text: (.action + (if .on != "" then " on " + .on else "" end)
          + " (" + ([ (if .auto_applied_after then "auto-apply \(.auto_applied_after)" else empty end),
                      (if .forced_apply then "forced \(.forced_apply)" else empty end),
                      (if .opt_in_status != "" then "opt-in: \(.opt_in_status)" else empty end) ] | if length == 0 then "no date, optional" else join(", ") end) + ")"
          + (if .description != "" then " - " + (.description | if length > 60 then .[0:57] + "..." else . end) else "" end))};

# rows (mode rows): one region's describe output ($ARGS.named clusters, instances, pma, ev, lc) -> one report row per
# cluster or standalone instance, with versions_behind, compliance_status, support dates and pending actions.
# Cluster members are not rows of their own: a cluster is judged once.
def rows:
  $ARGS.named as $A | ($A.account // "") as $account | ($A.profile // "") as $profile | ($A.region // "") as $region
  | ($A.clusters[0] // []) as $cl | ($A.instances[0] // []) as $in | ($A.pma[0] // []) as $pma
  | ($A.ev[0] // {}) as $ev | ($A.lc[0] // {}) as $lc
  | ($in | map({key: .DBInstanceIdentifier, value: .}) | from_entries) as $ix
  | ([$pma[] | .ResourceIdentifier as $a | .PendingMaintenanceActionDetails[]? | {arn: $a, d: .}] | group_by(.arn) | map({key: .[0].arn, value: map(.d)}) | from_entries) as $pc
  | ( [ $cl[] | select(.Engine | in_scope) | . as $c
        | {kind: "cluster", id: .DBClusterIdentifier, arn: .DBClusterArn, engine: .Engine, version: .EngineVersion,
           rtype: (if .Engine == "docdb" then "docdb-cluster" elif .Engine == "neptune" then "neptune-cluster"
                   elif (.Engine | startswith("aurora")) then "aurora-cluster" else "multi-az-cluster" end),
           window: (.PreferredMaintenanceWindow // ""), tags: tags_obj,
           members: [ (.DBClusterMembers // [])[] | {id: .DBInstanceIdentifier, writer: (.IsClusterWriter // false)} ],
           auto: ( if (.AutoMinorVersionUpgrade // null) != null and (.Engine | startswith("aurora") | not) then [.AutoMinorVersionUpgrade]
                   else [ (.DBClusterMembers // [])[] | $ix[.DBInstanceIdentifier].AutoMinorVersionUpgrade | select(. != null) ] end ),
           member_arns: [ (.DBClusterMembers // [])[] | {id: .DBInstanceIdentifier, arn: $ix[.DBInstanceIdentifier].DBInstanceArn} | select(.arn != null) ] } ]
      + [ $in[] | select((.DBClusterIdentifier // "") == "") | select(.Engine | in_scope)
        | {kind: "instance", id: .DBInstanceIdentifier, arn: .DBInstanceArn, engine: .Engine, version: .EngineVersion,
           rtype: "instance", window: (.PreferredMaintenanceWindow // ""), tags: tags_obj, members: [],
           auto: [.AutoMinorVersionUpgrade | select(. != null)], member_arns: []} ] ) as $res
  | [ $res[]
      | select(.engine | gmatch($f.engines))
      | select(. as $r | ([$r.id] + [$r.members[].id]) | any(.[]; gmatch($f.identifiers)))
      | . as $r
      # ONLY RDS metadata for THIS version: ValidUpgradeTarget[] of describe-db-engine-versions --engine E --engine-version V,
      # minor targets only (IsMajorVersionUpgrade == false) of the same engine. Nothing is derived from the full version list.
      | ($ev[$r.engine + "|" + $r.version] // {ok: false, error: "no lookup"}) as $e
      | ($e.ok == true) as $ok
      | ($ok and ($e.returned != true)) as $deprecated
      | ($ok and ($e.returned == true)) as $known
      | ($e.major // ($r.version | derive_major($r.engine))) as $major
      # minor_select (lib/versions.jq): same engine, IsMajorVersionUpgrade false, SAME major line (all engines),
      # Oracle: SAME patch line (mrp/rur/plain RU/spb...) unless --oracle-any-patch-line; newer than current only
      | (($e.targets // []) | minor_select($r.engine; $r.version; ($e.major // null); ($ARGS.named.oracle_any // false))) as $sel
      | $sel.targets as $tg
      | ($tg | map(.EngineVersion)) as $newer
      | ([ $tg[] | select(.AutoUpgrade == true) | .EngineVersion ] | .[-1] // null) as $auto_target
      | ([ ($e.targets // [])[] | select(.IsMajorVersionUpgrade == true) ] | length) as $major_targets
      # versions_behind = how many valid newer minor targets RDS lists (null when the lookup failed / deprecated)
      | (if $known then ($newer | length) else null end) as $behind
      # compliance: UNKNOWN without a usable lookup; COMPLIANT when behind <= --max-behind; else NON-COMPLIANT
      | (if $known | not then "UNKNOWN" elif $behind <= $max_behind then "COMPLIANT" else "NON-COMPLIANT" end) as $status
      | ($lc[$r.engine] // null) as $l
      | ([ ($l.majors // [])[] | select(.MajorEngineVersion == $major) | .SupportedEngineLifecycles[]? ]) as $lcs
      | ([ $lcs[] | select(.LifecycleSupportName | test("standard"; "i")) | .LifecycleSupportEndDate | day ] | .[0]) as $std
      | ([ $lcs[] | select(.LifecycleSupportName | test("extended"; "i")) | .LifecycleSupportEndDate | day ] | .[0]) as $ext
      | (if $std == null then null else ((($std | epoch_of_day) - $now) / 86400 | floor) end) as $days
      | ( if $l == null then (if ($r.engine | svc_of) != "rds" then "n/a (no lifecycle API for \($r.engine))" else "unknown (lifecycle lookup unavailable)" end)
          elif $std == null then "unknown (AWS lists no lifecycle dates for \($r.engine) \($major))"
          elif $days < 0 then "past standard support (Extended Support charges)"
          elif $days <= $warn_days then "standard support ends in \($days) days"
          else "ok" end ) as $sflag
      | ( [ ($pc[$r.arn] // [])[] | pend_item(if $r.kind == "cluster" then "cluster" else "" end) ]
          + [ $r.member_arns[] as $m | ($pc[$m.arn] // [])[] | pend_item("member " + $m.id) ] ) as $pend
      | ( if ($r.auto | length) == 0 then "unknown" elif all($r.auto[]; . == true) then "true" elif all($r.auto[]; . == false) then "false" else "mixed" end ) as $auto
      | ($newer[-1] // $r.version) as $latest
      | {account_id: $account, profile: $profile, region: $region, resource_type: $r.rtype, identifier: $r.id,
         members: ($r.members | map(.id + (if .writer then " (writer)" else "" end)) | join(", ")),
         member_count: ($r.members | length),
         engine: $r.engine, major_version: $major, current_version: $r.version,
         latest_minor_version: (if $known then $latest else null end),
         versions_behind: $behind, newer_versions: $newer, default_auto_upgrade_target: $auto_target, major_upgrade_targets: $major_targets,
         excluded_targets: $sel.excluded, version_warnings: $sel.warnings,
         compliance_status: $status, auto_minor_upgrade: $auto,
         standard_support_end: $std, extended_support_end: $ext, support_days_left: $days, support_flag: $sflag,
         past_standard_support: ($sflag | startswith("past")), nearing_end_of_support: ($sflag | startswith("standard support ends")),
         deprecated_version: $deprecated,
         pending_actions_count: ($pend | length), pending_actions: ($pend | map(.text) | join("; ")), pending_actions_detail: $pend,
         maint_window_utc: $r.window, maint_window_ist: ($r.window | shift_win(330)),
         tags: $r.tags, arn: $r.arn,
         # Aurora global database pending actions (ResourceIdentifier = the global cluster ARN) seen in this region;
         # finalize keeps only the ones of this cluster's global database (membership comes from describe-global-clusters)
         global_pending_raw: (if $r.rtype == "aurora-cluster" then [ $pc | to_entries[] | select(.key | test(":global-cluster:")) | {garn: .key, d: .value} ] else [] end),
         note: ([ (if $ok | not then "version lookup failed: \($e.error // "unknown")" else empty end),
                  (if $deprecated then "current version not returned by describe-db-engine-versions (deprecated or not offered in \($region)); no valid upgrade targets known" else empty end),
                  ($sel.excluded[] | .reason),
                  (if $auto == "false" then "auto minor upgrade is off" elif $auto == "mixed" then "auto minor upgrade is off on some members" else empty end) ] | join("; "))} ];

# ------------------------------------------------------------------ compliance exceptions (v1.6.0)
# $ARGS.named.exc = [null] or absent: feature off; [[entries]]: compliance_exceptions.conf entries (validated by the script).
# An unexpired entry for the scope makes the server compliant (actual_status keeps the evaluated one); expires = last valid
# UTC day; within 14 days -> "expiring soon"; actual already compliant -> "no longer needed"; past expiry -> normal status.
# exc_list: the entries array, or null when the feature is off; exc_on: true when it is on.
def exc_list: (($ARGS.named.exc // [null])[0]);
def exc_on: exc_list != null;
# exc_left($d): whole UTC days from today to the expiry day $d (0 = expires today, negative = expired).
def exc_left($d): (($d + "T00:00:00Z" | fromdateiso8601) / 86400 | floor) - ($now | floor / 86400 | floor);
# exc_find($scope; $acct; $id): the first entry for this account + identifier (case-insensitive) + scope, or null.
def exc_find($scope; $acct; $id): ($id | ascii_downcase) as $i
  | [ exc_list[]? | select(.account == $acct and (.identifier | ascii_downcase) == $i and ((.scopes | index([$scope])) != null)) ] | .[0];
# exc_eval($e; $ok): exception fields for a row; $ok = the evaluated status is already compliant.
def exc_eval($e; $ok):
  if $e == null then {exception: "no", exception_reason: "", exception_expires: "", exception_flag: ""}
  else exc_left($e.expires) as $d
  | {exception: (if $d < 0 then "expired" else "yes" end), exception_reason: $e.reason, exception_expires: $e.expires,
     exception_flag: (if $d < 0 then "exception expired"
                      else [ (if $ok then "no longer needed" else empty end), (if $d <= 14 then "expiring soon" else empty end) ] | join(", ") end)} end;
# exc_unmatched($scope; $rows): entries of this scope that match no row (typo or decommissioned server).
def exc_unmatched($scope; $rows):
  [ exc_list[]? | select((.scopes | index([$scope])) != null) | . as $e | ($e.identifier | ascii_downcase) as $i
    | select([ $rows[] | select(.account_id == $e.account and (.identifier | ascii_downcase) == $i) ] | length == 0)
    | {line, account, identifier} ];
# exc_counts($rows; $scope): summary.exceptions counts (entries, applied, attention, expired, unmatched...).
def exc_counts($rows; $scope):
  {entries: ([ exc_list[]? | select((.scopes | index([$scope])) != null) ] | length),
   applied: ([ $rows[] | select(.exception == "yes") ] | length),
   attention: ([ $rows[] | select(.exception == "yes" and .exception_flag != "") ] | length),
   expiring_soon: ([ $rows[] | select(.exception == "yes" and (.exception_flag | contains("expiring soon"))) ] | length),
   no_longer_needed: ([ $rows[] | select(.exception == "yes" and (.exception_flag | contains("no longer needed"))) ] | length),
   expired: ([ $rows[] | select(.exception == "expired") ] | length),
   unmatched: exc_unmatched($scope; $rows)};
# exc_apply: evaluate the patch exception for one row; actual_status keeps the real result.
def exc_apply:   # patch scope; rows keep compliance_status = COMPLIANT so every count, %, alert and exit code includes them
  exc_eval(exc_find("patch"; .account_id; .identifier); .compliance_status == "COMPLIANT") as $v
  | . + $v + {actual_status: .compliance_status} | if $v.exception == "yes" then .compliance_status = "COMPLIANT" else . end;
# exc_label: status text shown to people ("COMPLIANT (EXCEPTION)" for an applied exception).
def exc_label: if .exception == "yes" then "COMPLIANT (EXCEPTION)" else .compliance_status end;
# exc_cols: extra CSV / page columns, only when exceptions are on.
def exc_cols: if exc_on then ["exception","exception_reason","exception_expires","exception_flag","actual_status"] else [] end;

# ------------------------------------------------------------------ finalize: filters, sort, summary
# st_rank: sort order of statuses (NON-COMPLIANT first).
def st_rank: {"NON-COMPLIANT": 0, "UNKNOWN": 1, "COMPLIANT": 2}[.] // 3;
# pct($a; $b): $a / $b as a percentage with one decimal (0 when $b is 0).
def pct($a; $b): if $b == 0 then 0 else ($a * 1000 / $b | round) / 10 end;
# counts: total / compliant / non_compliant / unknown of an array of rows.
def counts: {total: length, compliant: (map(select(.compliance_status == "COMPLIANT")) | length),
             non_compliant: (map(select(.compliance_status == "NON-COMPLIANT")) | length),
             unknown: (map(select(.compliance_status == "UNKNOWN")) | length)};
# Region-wise breakdown: one entry per account + region that was checked (meta.region_status, written by the
# script: scanned | databases | empty | probe-error), counted from ALL rows (before --non-compliant-only).
# Final status: error (any AWS error there, incl. a failed discovery probe), empty (no DB instance / cluster),
# databases (has instances / clusters). checked = databases + empty + error.
def region_rank: {"databases": 0, "error": 1, "empty": 2}[.] // 3;
# region_counts: counts + % compliant, pending maintenance and past-standard-support for a group of rows.
def region_counts: counts + {pct_compliant: (if length == 0 then null else pct(counts.compliant; length) end),
                             with_pending: (map(select(.pending_actions_count > 0)) | length), pending_total: (map(.pending_actions_count) | add // 0),
                             past_standard_support: (map(select(.past_standard_support)) | length)};
# region_breakdown: one entry per account + region checked, with its final status and counts (see above).
def region_breakdown:
  . as $r
  | ($r.rows | group_by([.account_id, .region]) | map({key: (.[0].account_id + "|" + .[0].region), value: .}) | from_entries) as $by
  | [ ([($r.meta.region_status // [])[]] + [$r.rows[] | {account: .account_id, profile, region, status: "scanned"}]) | unique_by([.account, .region])[]
      | . as $x | ($by[$x.account + "|" + $x.region] // []) as $g
      | ([$r.errors[] | select(.account == $x.account and .region == $x.region)] | length) as $ne
      | {account_id: $x.account, profile: $x.profile, region: $x.region,
         status: (if $ne > 0 or $x.status == "probe-error" then "error"
                  elif ($g | length) > 0 or $x.status == "databases" then "databases"
                  elif $x.status == "empty" then "empty"
                  else "empty" end),
         skipped: ($x.status == "empty"), probe_instances: $x.probe_instances, probe_clusters: $x.probe_clusters, errors: $ne}
        + ($g | region_counts) ]
  | sort_by([(.status | region_rank), .account_id, .region]);
# Dates relative to $now are recomputed here (collection run AND --merge), so a merged report counts days from merge time.
def days_from($d): if $d == null then null else ((($d | epoch_of_day) - $now) / 86400 | floor) end;
# refresh_row: recompute support days / flag and next maintenance date against $now.
def refresh_row:
  (if .standard_support_end != null then days_from(.standard_support_end) as $days
     | .support_days_left = $days
     | .support_flag = (if $days < 0 then "past standard support (Extended Support charges)"
                        elif $days <= $warn_days then "standard support ends in \($days) days" else "ok" end)
   else . end)
  | .past_standard_support = (.support_flag | startswith("past")) | .nearing_end_of_support = (.support_flag | startswith("standard support ends"))
  | .pending_actions_detail |= map(([.current_apply, .auto_applied_after, .forced_apply] | map(select(. != null)) | min) as $m
                                   | . + {next_date: $m, days_until: days_from($m)})
  | ([.pending_actions_detail[].next_date | select(. != null)] | min) as $nx
  | .next_maintenance = $nx | .days_until_maintenance = days_from($nx);
# account_breakdown($regs): one summary entry per account (regions with databases, errors, counts).
def account_breakdown($regs):
  . as $r
  | [ ($r.meta.accounts // [])[] | . as $a | [$r.rows[] | select(.account_id == $a.account)] as $g
      | {account_id: $a.account, profile: $a.profile, account_name: ($a.name // ""), collected_utc: ($a.collected_utc // $r.meta.generated_utc), source: ($a.source // null),
         regions_with_databases: ([$regs[] | select(.account_id == $a.account and .status == "databases")] | length),
         errors: ([$r.errors[] | select(.account == $a.account)] | length)} + ($g | region_counts) ]
  | sort_by(.account_id);
# ------------------------------------------------------------------ Aurora global databases
# meta.globals: describe-global-clusters per account ({account, id, arn, engine, version, status, members[{arn, region, cluster, role}]});
# meta.global_lookup: per account {account, profile, status: ok | error | not-needed | unknown, message}. Old data files have neither:
# their Aurora clusters get global_role "unknown". Idempotent (global pending items are stripped before they are re-added).
def annotate_globals:
  . as $r
  | ([($r.meta.global_lookup // [])[] | {key: .account, value: .status}] | from_entries) as $ls
  | ([($r.meta.globals // [])[] | . as $g | .members[] | {key: .arn, value: {id: $g.id, garn: $g.arn, role: .role}}] | from_entries) as $gm
  | .rows |= map(
      if .resource_type != "aurora-cluster" then . + {global_cluster: "", global_role: "", global_arn: null}
      elif ($ls[.account_id] // "unknown") as $st | ($st != "ok" and $st != "not-needed") then . + {global_cluster: null, global_role: "unknown", global_arn: null}
      else ($gm[.arn] // {id: "", garn: null, role: ""}) as $m | . + {global_cluster: $m.id, global_role: $m.role, global_arn: $m.garn} end
      | .pending_actions_detail |= map(select(.on | startswith("global ") | not))
      | . as $x
      | (if $x.global_arn then [ ($x.global_pending_raw // [])[] | select(.garn == $x.global_arn) | .d[] | pend_item("global " + $x.global_cluster) ] else [] end) as $gp
      | .pending_actions_detail += $gp
      | .pending_actions_count = (.pending_actions_detail | length) | .pending_actions = (.pending_actions_detail | map(.text) | join("; "))
      | (if (.global_cluster // "") != "" then
           .note = ([(.note | split("; ")[] | select(. != "" and (startswith("Aurora global database") | not)))]
                    + ["Aurora global database \(.global_cluster) (\(.global_role)): automatic minor version upgrade does not apply to global database members"]
                    + (if .engine == "aurora-mysql" then ["upgrade the secondary clusters first, then the primary, to the same version"
                         + (if .global_role == "secondary" and .member_count == 0 then "; headless secondary: add an instance before a minor upgrade" else "" end)]
                       else ["Aurora PostgreSQL: modify-global-cluster upgrades every member in one managed minor upgrade"] end) | join("; "))
         elif .global_role == "unknown" then .note = ([(.note | split("; ")[] | select(. != "" and (startswith("global database membership") | not)))] + ["global database membership unknown"] | join("; "))
         else . end));
# global_summary: one entry per Aurora global database with its members (primary first), overall status
# (worst member), and flags when the member versions or statuses differ.
def global_summary:
  . as $r
  | ([($r.meta.globals // [])[] | {key: "\(.account)|\(.id)", value: .}] | from_entries) as $gi
  | [ $r.rows[] | select((.global_cluster // "") != "") ] | group_by([.account_id, .global_cluster])
  | map(. as $g | $gi["\($g[0].account_id)|\($g[0].global_cluster)"] as $meta
      | ([$g[] | {account_id, region, identifier, role: .global_role, current_version, latest_minor_version, versions_behind, compliance_status,
                  headless: (.member_count == 0), scanned: true}]
         + [ ($meta.members // [])[] | . as $m | select([$g[] | select(.arn == $m.arn)] | length == 0)
             | {account_id: $g[0].account_id, region, identifier: .cluster, role, current_version: null, latest_minor_version: null, versions_behind: null,
                compliance_status: "NOT SCANNED", headless: null, scanned: false} ]
         | sort_by([(if .role == "primary" then 0 else 1 end), .region])) as $mem
      | ([$mem[] | select(.scanned)]) as $sc
      | {account_id: $g[0].account_id, account_name: ($g[0].account_name // ""), global_cluster: $g[0].global_cluster, engine: $g[0].engine, global_status: ($meta.status // null),
         members: $mem, member_count: ($sc | length), not_scanned: ([$mem[] | select(.scanned | not)] | length),
         overall_status: ($sc | map(.compliance_status) | sort_by(st_rank) | .[0]),
         versions: ($sc | map(.current_version) | unique),
         version_differs: (($sc | map(.current_version) | unique | length) > 1),
         region_status_mismatch: ($sc | group_by(.current_version) | any(.[]; (map(.compliance_status) | unique | length) > 1)),
         pending: ([$g[].pending_actions_detail[] | select(.on | startswith("global ")) | .text] | unique)})
  | sort_by([(.overall_status | st_rank), .account_id, .global_cluster]);
# finalize (mode finalize): apply account names, refresh dates, exceptions and global database info, filter
# (--non-compliant-only), sort, and build the summary block used by every renderer.
def finalize:
  (($ARGS.named.acct_names // {}) as $cn | .meta.accounts |= ((. // []) | map(. + {name: (if ($cn[.account] // "") != "" then $cn[.account] else (.name // "") end)})))
  | ([.meta.accounts[] | {key: .account, value: .name}] | from_entries) as $an
  | (.rows |= map(refresh_row | del(.upgrade_command) | . + {account_name: ($an[.account_id] // "")}))   # files saved before v1.4.0 carry upgrade_command
  # exceptions are applied before anything is counted, so an excepted server counts as COMPLIANT everywhere
  | (if exc_on then .rows |= map(exc_apply) else . end)
  | annotate_globals
  | . as $r
  | ($r | global_summary) as $gs
  | ($r | region_breakdown) as $regs
  # --non-compliant-only hides rows from the list; the summary ($all) still counts every row
  | ($r.rows | map(select(($nc_only | not) or .compliance_status == "NON-COMPLIANT"))
             | sort_by([.engine, (.compliance_status | st_rank), -(.versions_behind // -1), (.identifier | ascii_downcase), .account_id, .region])) as $rows
  | ($r.rows | counts) as $all
  | $r + {rows: $rows,
          summary: ($all + {
             pct_compliant: pct($all.compliant; $all.total), shown: ($rows | length),
             max_behind: $max_behind, warn_days: $warn_days,
             past_standard_support: ($r.rows | map(select(.past_standard_support)) | length),
             nearing_end_of_support: ($r.rows | map(select(.nearing_end_of_support)) | length),
             auto_minor_off: ($r.rows | map(select(.auto_minor_upgrade == "false" or .auto_minor_upgrade == "mixed")) | length),
             with_pending: ($r.rows | map(select(.pending_actions_count > 0)) | length),
             pending_total: ($r.rows | map(.pending_actions_count) | add // 0),
             pending_by_action: ([$r.rows[].pending_actions_detail[].action] | group_by(.) | map({key: .[0], value: length}) | sort_by(-.value, .key) | from_entries),
             deprecated: ($r.rows | map(select(.deprecated_version)) | length),
             errors: ($r.errors | length),
             globals: $gs, global_databases: ($gs | length), global_members: ([$gs[].member_count] | add // 0),
             global_unknown: ($r.rows | map(select(.global_role == "unknown")) | length),
             global_lookup: ($r.meta.global_lookup // []),
             exceptions: (if exc_on then exc_counts($r.rows; "patch") else null end),
             regions: ($regs | map(. + {account_name: ($an[.account_id] // "")})),
             accounts: ($r | account_breakdown($regs)),
             regions_total: ({account_id: "ALL", profile: "", region: "All regions", status: "",
                              errors: ($r.errors | length)} + ($r.rows | region_counts)),
             region_overview: {mode: ($r.meta.region_discovery.mode // "explicit"), probe_parallel: ($r.meta.region_discovery.probe_parallel // null),
                               checked: ($regs | length), with_databases: ($regs | map(select(.status == "databases")) | length),
                               empty: ($regs | map(select(.status == "empty")) | length), error: ($regs | map(select(.status == "error")) | length),
                               empty_regions: ($regs | map(select(.status == "empty")) | group_by(.account_id) | map({account_id: .[0].account_id, regions: map(.region)}))},
             engines: ($r.rows | group_by(.engine) | map(. as $g | {engine: $g[0].engine, anchor: ("eng-" + ($g[0].engine | gsub("[^A-Za-z0-9]"; "-")))} + ($g | counts)
                         + {pct_compliant: pct(($g | counts).compliant; $g | length),
                            majors: ($g | group_by(.major_version) | map(. as $m | {major: $m[0].major_version} + ($m | counts)
                                       + {latest_minor: ([$m[].latest_minor_version] | latest_of($m[0].engine)),   # Oracle: per patch line
                                          standard_support_end: ([$m[].standard_support_end | select(. != null)] | .[0] // null),
                                          support_flag: ($m[0].support_flag)}) | sort_by(.major | vkey) | reverse)}))
          } | if .exceptions == null then del(.exceptions) else . end)};

# ------------------------------------------------------------------ text
# pad($n) / rpad($n): left / right align text to $n characters (pad also cuts longer text).
def pad($n): tostring | if length >= $n then .[0:$n] else . + (" " * ($n - length)) end;
def rpad($n): tostring | if length >= $n then . else (" " * ($n - length)) + . end;
# short_list: up to 4 versions as a list, else the first 3 + count + latest.
def short_list: if length == 0 then "-" elif length <= 4 then join(", ") else (.[:3] | join(", ")) + ", ... +\(length - 3) (latest \(.[-1]))" end;
# pend_summary: one line of pending maintenance counts per action.
def pend_summary: "on \(.with_pending) server(s): " + (.pending_by_action | to_entries | map("\(.key) \(.value)") | join(", ") | if . == "" then "none" else . end);
# pend_tip: pending actions with auto-apply / forced dates (UTC = IST), for the HTML tooltip.
def pend_tip: [ .pending_actions_detail[] | .text + (if .auto_applied_after_utc then " | auto-apply \(.auto_applied_after_utc) = \(.auto_applied_after_ist)" else "" end)
                + (if .forced_apply_utc then " | forced \(.forced_apply_utc) = \(.forced_apply_ist)" else "" end) ] | join("\n");
# region_mode_txt / region_line: how regions were chosen, and the "N checked, ..." line.
def region_mode_txt: {"discover": "discovery probe, \(.probe_parallel) in parallel; full scan only where databases or a probe error",
                       "full": "every enabled region scanned in full (--no-discover)", "explicit": "queried directly, no probe", "merge": "merged offline from saved data"}[.mode] // .mode;
def region_line: "\(.checked) checked, \(.with_databases) with databases, \(.empty) empty, \(.error) error\(if .error == 1 then "" else "s" end)";
# Region NAMES are never listed in the report header; empty regions (no DB instance / cluster) are only counted.
# Rows / CSV show regions with databases or an AWS error; JSON summary.regions keeps every region (incl. empty).
def shown_regions: [.summary.regions[] | select(.status != "empty")];
# text (mode text): the plain-text report.
def text:
  . as $r | $r.summary as $s | $s.region_overview as $ro | (($r.meta.accounts | length) > 1) as $multi
  | ([12, ($r.rows[] | (.current_version, .latest_minor_version) | tostring | length)] | max + 2) as $vw
  | ([20, ($s.engines[].engine | length)] | max + 2) as $ew
  | "RDS PATCH COMPLIANCE REPORT - \($r.meta.generated_utc) (\($r.meta.generated_local))",
    "Accounts : \($r.meta.accounts | map("\(.account)\(if (.name // "") != "" then " " + .name else "" end) (\(.profile))") | join(", "))" + (if $ro.mode == "explicit" then "   Regions: \($r.meta.regions | length) given" elif $ro.mode == "merge" then "   Merged: \($r.meta.merge.files) file(s)" else "   Regions: all enabled" end),
    "Regions  : \($ro | region_line)",
    "Rule     : NON-COMPLIANT when more than \($s.max_behind) valid minor versions behind (same major)",
    (if ($r.meta.filters_text // "") != "" then "Filters  : \($r.meta.filters_text)" else empty end),
    "",
    "SUMMARY",
    "  Servers/clusters : \($s.total)   COMPLIANT \($s.compliant)\(if $s.exceptions then " (incl. \($s.exceptions.applied) exceptions)" else "" end)   NON-COMPLIANT \($s.non_compliant)   UNKNOWN \($s.unknown)   -> \($s.pct_compliant)% compliant",
    "  Support          : \($s.past_standard_support) past standard support (Extended Support charges), \($s.nearing_end_of_support) ending within \($s.warn_days) days",
    "  Pending maint.   : " + (if $s.with_pending == 0 then "none" else ($s | pend_summary) + " (\($s.pending_total) action(s))" end),
    "  Global databases : \($s.global_databases) (\($s.global_members) members)" + (if $s.global_unknown > 0 then "; \($s.global_unknown) Aurora cluster(s) with unknown membership" else "" end),
    "  Other flags      : auto minor upgrade off \($s.auto_minor_off), current version not returned / deprecated \($s.deprecated)",
    (if $s.errors > 0 then "  AWS errors       : \($s.errors) (see ERRORS at the end; affected regions may be missing)" else empty end),
    (if $s.exceptions then "  Exceptions       : \($s.exceptions.applied) applied (counted as COMPLIANT, marked *)"
       + (if $s.exceptions.attention > 0 then "; expiring soon or no longer needed: \($s.exceptions.attention)" else "" end)
       + (if $s.exceptions.expired > 0 then "; expired: \($s.exceptions.expired)" else "" end)
       + (if ($s.exceptions.unmatched | length) > 0 then "; matched no server: \($s.exceptions.unmatched | length)" else "" end) else empty end),
    "",
    "PER ENGINE / MAJOR VERSION",
    "  " + ("ENGINE" | pad($ew)) + ("MAJOR" | pad(10)) + ("TOTAL" | rpad(6)) + ("COMPL" | rpad(7)) + ("NON-C" | rpad(7)) + ("UNKN" | rpad(6)) + "  " + ("LATEST MINOR" | pad($vw)) + "SUPPORT",
    ($s.engines[] | . as $e | .majors[] | "  " + ($e.engine | pad($ew)) + (.major | pad(10)) + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6)) + "  " + ((.latest_minor | dash) as $l | if ($l | contains("; ")) then ("per patch line, below" | pad($vw)) else ($l | pad($vw)) end) + (.support_flag | dash) + (if .standard_support_end != null then " (standard end \(.standard_support_end))" else "" end)
       + ((.latest_minor // "") | if contains("; ") then "\n" + (split("; ") | map("        latest minor, " + .) | join("\n")) else "" end)),
    ($s.engines[] | "  " + (.engine | pad($ew)) + ("all" | pad(10)) + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6)) + "  \(.pct_compliant)% compliant"),
    "",
    (if $s.global_databases > 0 then "GLOBAL DATABASES",
       ($s.globals[] | "  \(.global_cluster) [\(.engine)] account \(.account_id): \(.overall_status)" + (if .region_status_mismatch then "  ** region status mismatch **" else "" end) + (if .version_differs then "  (versions differ: \(.versions | join(", ")))" else "" end),
         (.members[] | "      " + (.role | pad(10)) + (.region | pad(16)) + (.identifier | pad(32)) + (.current_version | dash | pad($vw)) + (.compliance_status) + (if .headless then " (headless)" else "" end) + (if .versions_behind != null then ", \(.versions_behind) behind" else "" end)),
         (.pending[] | "      pending: " + .)), "" else empty end),
    "PER REGION",
    "  " + ("ACCOUNT" | pad(14)) + ("REGION" | pad(16)) + ("STATUS" | pad(11)) + ("TOTAL" | rpad(6)) + ("COMPL" | rpad(7)) + ("NON-C" | rpad(7)) + ("UNKN" | rpad(6)) + ("%COMPL" | rpad(8)) + ("PEND" | rpad(6)) + ("PAST-STD" | rpad(10)),
    (($r | shown_regions) + [$s.regions_total] | .[] | "  " + (.account_id | pad(14)) + (.region | pad(16)) + (.status | pad(11)) + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6))
       + ((if .pct_compliant == null then "-" else "\(.pct_compliant)%" end) | rpad(8)) + (.with_pending | rpad(6)) + (.past_standard_support | rpad(10))
       + (if .status == "error" then "  see ERRORS" + (if .total == 0 then " (no data)" else " (partial)" end) else "" end)),
    "",
    "PER ACCOUNT",
    "  " + ("ACCOUNT" | pad(14)) + ("PROFILE" | pad(16)) + ("COLLECTED" | pad(22)) + ("REG" | rpad(4)) + ("TOTAL" | rpad(6)) + ("COMPL" | rpad(7)) + ("NON-C" | rpad(7)) + ("UNKN" | rpad(6)) + ("%COMPL" | rpad(8)) + ("PEND" | rpad(6)) + "  NAME",
    ($s.accounts[] | "  " + (.account_id | pad(14)) + (.profile | pad(16)) + (.collected_utc | pad(22)) + (.regions_with_databases | rpad(4)) + (.total | rpad(6)) + (.compliant | rpad(7)) + (.non_compliant | rpad(7)) + (.unknown | rpad(6))
       + ((if .pct_compliant == null then "-" else "\(.pct_compliant)%" end) | rpad(8)) + (.with_pending | rpad(6)) + "  " + (.account_name // "" | dash)),
    "",
    ($s.engines[] | . as $e
      | "=== \($e.engine): \($e.total) (compliant \($e.compliant), non-compliant \($e.non_compliant), unknown \($e.unknown)) ===",
        "  " + ("STATUS" | pad(14)) + ("BEHIND" | rpad(6)) + "  " + ("IDENTIFIER" | pad(32)) + ("TYPE" | pad(17)) + ("CURRENT" | pad($vw)) + ("LATEST MINOR" | pad($vw)) + ("AUTO" | pad(7)) + ("PEND" | rpad(4)) + "  " + ("ACCOUNT" | pad(13)) + ("REGION" | pad(15)) + "FLAGS",
        ($r.rows[] | select(.engine == $e.engine)
          | ("  " + ((if .exception == "yes" then "COMPLIANT*" else .compliance_status end) | pad(14)) + (.versions_behind | dash | rpad(6)) + "  " + (.identifier | pad(32)) + (.resource_type | pad(17)) + (.current_version | pad($vw)) + (.latest_minor_version | dash | pad($vw))
            + (.auto_minor_upgrade | pad(7)) + (.pending_actions_count | rpad(4)) + "  " + (.account_id | pad(13)) + (.region | pad(15))
            + ([ (if .support_flag != "ok" and (.support_flag | startswith("n/a") | not) then .support_flag else empty end), (if .deprecated_version then "current version not returned (deprecated?)" else empty end)] | join("; ") | dash)),
          (.pending_actions_detail[] | "      pending: " + .text + (if .auto_applied_after_ist then " [auto-apply \(.auto_applied_after_ist)]" else "" end))),
        ""),
    (if ($r.rows | length) == 0 then "No servers matched.", "" else empty end),
    (if ($r.errors | length) > 0 then "ERRORS", ($r.errors[] | "  \(.account) \(.profile)/\(.region): \(.call): \(.message)"), "" else empty end),
    (if $s.exceptions then "EXCEPTIONS (* = COMPLIANT by exception; actual = evaluated status)",
       ([ $r.rows[] | select(.exception != "no") ] | if length == 0 then "  none of the shown servers is listed" else .[]
          | "  " + (.account_id | pad(13)) + (.identifier | pad(32)) + ("until \(.exception_expires)" | pad(17)) + ("actual \(.actual_status)" | pad(21))
            + (if .exception == "expired" then "EXPIRED (evaluated normally) " else "" end) + (if .exception_flag != "" and .exception != "expired" then "[\(.exception_flag)] " else "" end) + .exception_reason end),
       ($s.exceptions.unmatched[] | "  line \(.line): \(.account) \(.identifier) matched no server"), "" else empty end),
    "ABOUT THIS REPORT",
    "  Rule    : COMPLIANT = at most \($s.max_behind) valid minor upgrade target(s) for the current version; NON-COMPLIANT = \($s.max_behind + 1)+; UNKNOWN = lookup failed or current version not returned (deprecated).",
    "  Source  : ValidUpgradeTarget (IsMajorVersionUpgrade=false) of describe-db-engine-versions --engine-version <current>, per server; latest minor per major = highest valid target seen.",
    "  Regions : \($ro | region_mode_txt); empty regions are only counted; PER REGION lists regions with databases or an AWS error.",
    "  Pending : maintenance actions AWS scheduled or offered and not yet applied (clusters include member actions).",
    "  Globals : Aurora global databases from describe-global-clusters; overall = worst member; mismatch = same version, different status across regions.",
    "  Read-only: nothing was changed.";

# ------------------------------------------------------------------ csv / json
# cols: base per-server CSV columns (in order).
def cols: ["account_id","profile","region","resource_type","identifier","members","engine","major_version","current_version","latest_minor_version",
           "versions_behind","newer_versions","default_auto_upgrade_target","compliance_status","auto_minor_upgrade","standard_support_end","extended_support_end","support_flag",
           "pending_actions_count","pending_actions","deprecated_version","maint_window_utc","maint_window_ist"];
# csv (mode csv): per-server CSV; free-text exception fields get a formula guard.
def csv:
  . as $r
  | (cols + ["next_maintenance","days_until_maintenance","global_cluster","global_role","account_name"] + exc_cols | @csv),
    ($r.rows[] | . as $x | ([cols[] | if . == "compliance_status" then ($x | exc_label) else $x[.] end] | map(if type == "array" then join(" ") elif . == null then "" else . end))
       + [($x.next_maintenance // ""), ($x.days_until_maintenance // ""), ($x.global_cluster // ""), ($x.global_role // ""), ($x.account_name // "")]
       + [exc_cols[] | ($x[.] // "") | if test("^[=+@\t\r-]") then "'" + . else . end] | @csv);   # free-text reason: formula guard
# csv_regions (mode csv_regions): region breakdown CSV (regions with databases or errors + an ALL row).
def csv_regions:
  [["account_id","account_id"],["profile","profile"],["region","region"],["status","status"],["total","total"],["compliant","compliant"],
   ["non_compliant","non_compliant"],["unknown","unknown"],["pct_compliant","pct_compliant"],["servers_with_pending_maintenance","with_pending"],
   ["pending_actions","pending_total"],["past_standard_support","past_standard_support"],["aws_errors","errors"],
   ["probe_instances_max20","probe_instances"],["probe_clusters_max20","probe_clusters"]] as $c
  | ($c | map(.[0]) | @csv), ((shown_regions + [.summary.regions_total])[] | . as $x | [$c[] | $x[.[1]] | if . == null then "" else . end] | @csv);
# json_out (mode json): the finalized report as is; alert (mode alert): compact payload for webhooks.
def json_out: .;
def alert: {summary: .summary, non_compliant: [.rows[] | select(.compliance_status == "NON-COMPLIANT") | {account_id, region, identifier, engine, current_version, latest_minor_version, versions_behind}], errors: .errors};

# ------------------------------------------------------------------ html
# stc / sfc: CSS class for a compliance status / support flag.
def stc: {"COMPLIANT": "ok", "NON-COMPLIANT": "bad", "UNKNOWN": "unk"}[.] // "unk";
def sfc: if startswith("past") then "bad" elif startswith("standard support ends") then "warn" elif . == "ok" then "ok" else "muted" end;
# card / cardx: summary cards at the top of the HTML page (cardx is clickable).
def card($label; $val; $cls; $sub): "<div class=\"card \($cls)\" data-k=\"\($label | ascii_downcase | gsub("[^a-z]+"; "-"))\"><div class=\"v\">\($val | h)</div><div class=\"l\">\($label | h)</div><div class=\"s\">\($sub | h)</div></div>";
def cardx($label; $val; $cls; $sub; $act; $ic; $pop):   # v1.5.0 clickable card (role=button)
  "<div class=\"card \($cls)\" data-k=\"\($label | ascii_downcase | gsub("[^a-z]+"; "-"))\" data-act=\"\($act)\" role=\"button\" tabindex=\"0\">"
  + (if $ic != "" then "<span class=\"ic\" aria-hidden=\"true\">\($ic)</span>" else "" end)
  + "<div class=\"v\">\($val | h)</div><div class=\"l\">\($label | h)</div><div class=\"s\">\($sub | h)</div>"
  + (if $pop then "<div class=\"pop\" role=\"tooltip\"></div>" else "" end) + "</div>";
# riskc: CSS class $c when $n > 0, else "zero".
def riskc($n; $c): if $n > 0 then $c else "zero" end;
# dleft: days as text ("in N day(s)", "today", "N day(s) overdue").
def dleft: if . == null then "" elif . < 0 then "\(-.) day(s) overdue" elif . == 0 then "today" else "in \(.) day(s)" end;
# gbadge: "global" badge next to an Aurora global database member.
def gbadge: if .global_role == "unknown" then " <span class=\"gb unk\" title=\"describe-global-clusters unavailable for this account\">global: unknown</span>"
  elif (.global_cluster // "") != "" then " <span class=\"gb\(if ._gmm then " mm" else "" end)\" title=\"\(if ._gmm then "Global DB members differ (version or status across regions)" else "Aurora global database" end)\">global: \(.global_cluster | h) &middot; \(.global_role | h)\(if .member_count == 0 then " (headless)" else "" end)</span>" else "" end;
# html_row: one <tr> of the main HTML table.
def html_row:
  . as $x
  | "<tr data-i=\"\(._i)\"><td>" + (if .exception == "yes" then "<span class=\"st ok exc\" title=\"Exception until \(.exception_expires | h); actual status \(.actual_status | h)\">COMPLIANT (EXCEPTION)</span><div class=\"sub\">actual \(.actual_status | h)</div>"
       else "<span class=\"st \(.compliance_status | stc)\">\(.compliance_status | h)</span>" end) + "</td><td data-s=\"\(.versions_behind // -1 | h)\">\(.versions_behind | dash)</td>"
  + "<td><b>\(.identifier | h)</b>" + gbadge + (if .members != "" then "<div class=\"sub\">\(.members | h)</div>" else "" end) + "</td>"
  + "<td>\(.resource_type | h)</td><td>\(.major_version | h)</td><td class=\"mono\">\(.current_version | h)\(if .deprecated_version then " <span class=\"st bad\">DEPRECATED</span>" else "" end)</td><td class=\"mono\">\(.latest_minor_version | dash | h)</td>"
  + "<td class=\"mono small\">\(.newer_versions | short_list | h)</td><td class=\"mono small\">\(.default_auto_upgrade_target | dash | h)</td>"
  + "<td class=\"\(if .auto_minor_upgrade == "true" then "ok" elif .auto_minor_upgrade == "unknown" then "muted" else "warn" end)\">\(.auto_minor_upgrade | h)</td>"
  + "<td>\(.standard_support_end | dash | h)</td><td>\(.extended_support_end | dash | h)</td><td class=\"\(.support_flag | sfc)\">\(.support_flag | h)</td>"
  + "<td data-s=\"\(.pending_actions_count | h)\">" + (if .pending_actions_count == 0 then "<span class=\"muted\">0</span>"
       else "<details class=\"pend\" title=\"\(pend_tip | h)\"><summary><span class=\"badge\">\(.pending_actions_count | h)</span></summary><ul>"
            + (.pending_actions_detail | map("<li>\(.text | h)" + (if .auto_applied_after_ist then "<div class=\"sub\">auto-apply \(.auto_applied_after_utc | h) = \(.auto_applied_after_ist | h)</div>" else "" end)
                + (if .forced_apply_ist then "<div class=\"sub\">forced \(.forced_apply_utc | h) = \(.forced_apply_ist | h)</div>" else "" end) + "</li>") | join("")) + "</ul></details>"
            + (if .days_until_maintenance != null then "<div class=\"sub \(if .days_until_maintenance < 0 then "bad" elif .days_until_maintenance <= 14 then "warn" else "" end)\">next \(.next_maintenance | h) &middot; \(.days_until_maintenance | dleft)</div>" else "" end) end) + "</td><td class=\"small\">\(.maint_window_utc | dash | h) UTC<br>\(.maint_window_ist | dash | h) IST</td>"
  + "<td>\(if (.account_name // "") != "" then "\(.account_name) (\(.account_id))" else .account_id end | h)<div class=\"sub\">\(.profile | h) &middot; \(.region | h)</div></td>"
  + (if exc_on then "<td class=\"small exc-c\" data-s=\"\({"yes": 2, "expired": 1}[.exception] // 0)\">" + (if .exception == "no" then "<span class=\"muted\">-</span>"
       else "\(.exception_reason | h)<div class=\"sub\">until \(.exception_expires | h)</div>"
            + (if .exception_flag != "" then " <span class=\"st \(if .exception == "expired" then "bad" else "warn" end) xf\">\(.exception_flag | h)</span>" else "" end) end) + "</td>" else "" end)
  + "</tr>";
# rgc / pctc: CSS class for a region status / a compliance percentage.
def rgc: {"databases": "db", "error": "bad", "empty": "unk"}[.] // "unk";
def pctc: if . == null then "muted" elif . >= 100 then "ok" elif . >= 80 then "warn" else "bad" end;
# region_tr($foot): one row of the per-region table ($foot = the All regions total row).
def region_tr($foot):
  "<tr\(if $foot then " class=\"foot\"" else " data-k=\"\(.account_id | h)|\(.region | h)\"" end)><td>\(if $foot then "<b>All regions</b>" else (if (.account_name // "") != "" then "\(.account_name) (\(.account_id))" else .account_id end | h) + "<div class=\"sub\">\(.profile | h)</div>" end)</td>"
  + "<td>\(if $foot then "" else "<b>\(.region | h)</b>" end)</td>"
  + "<td data-s=\"\(if $foot then 9 else (.status | region_rank) end)\">\(if $foot then "" else "<span class=\"st \(.status | rgc)\">\(.status | h)</span>" + (if .status == "error" then "<div class=\"sub\">see Errors\(if .total == 0 then ", no data" else ", partial" end)</div>" else "" end) end)</td>"
  + "<td class=\"n\" data-s=\"\(.total)\"><b>\(.total)</b></td><td class=\"n \(if .compliant > 0 then "ok" else "" end)\" data-s=\"\(.compliant)\">\(.compliant)</td>"
  + "<td class=\"n \(if .non_compliant > 0 then "bad" else "" end)\" data-s=\"\(.non_compliant)\">\(.non_compliant)</td><td class=\"n\" data-s=\"\(.unknown)\">\(.unknown)</td>"
  + "<td class=\"n \(.pct_compliant | pctc)\" data-s=\"\(.pct_compliant // -1)\">" + (if .pct_compliant == null then "-" else "\(.pct_compliant)%<div class=\"bar\"><i class=\"\(.pct_compliant | pctc)\" style=\"width:\(.pct_compliant)%\"></i></div>" end) + "</td>"
  + "<td class=\"n \(if .with_pending > 0 then "warn" else "" end)\" data-s=\"\(.with_pending)\">\(.with_pending)\(if .pending_total > 0 then "<div class=\"sub\">\(.pending_total) action(s)</div>" else "" end)</td>"
  + "<td class=\"n \(if .past_standard_support > 0 then "bad" else "" end)\" data-s=\"\(.past_standard_support)\">\(.past_standard_support)</td></tr>";
# html_regions: the Per region section.
def html_regions($r; $s; $ro; $multi):
  "<section id=\"regions\"><h2>Per region <span class=\"muted\">\($ro | region_line) &middot; \($ro | region_mode_txt | h)\(if $multi then " &middot; per account x region" else "" end) &middot; click a header to sort</span></h2>"
  + "<table class=\"sortable regions\"><thead><tr><th>Account</th><th>Region</th><th>Status</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Pending maint.</th><th>Past standard support</th></tr></thead><tbody>"
  + ($r | shown_regions | map(region_tr(false)) | join("")) + "</tbody><tfoot>" + ($s.regions_total | region_tr(true)) + "</tfoot></table>"
  + "</section>";
# account_tr / html_accounts: the Per account table (multi-account and merged reports).
def account_tr:
  "<tr data-a=\"\(.account_id | h)\"><td><b>\(if (.account_name // "") != "" then "\(.account_name) (\(.account_id))" else .account_id end | h)</b><div class=\"sub\">\(.profile | h)</div></td><td class=\"small\">\(.collected_utc | dash | h)\(if .source then "<div class=\"sub\">\(.source | h)</div>" else "" end)</td>"
  + "<td class=\"n\" data-s=\"\(.regions_with_databases)\">\(.regions_with_databases)\(if .errors > 0 then "<div class=\"sub bad\">\(.errors) error(s)</div>" else "" end)</td>"
  + "<td class=\"n\" data-s=\"\(.total)\"><b>\(.total)</b></td><td class=\"n \(if .compliant > 0 then "ok" else "" end)\" data-s=\"\(.compliant)\">\(.compliant)</td>"
  + "<td class=\"n \(if .non_compliant > 0 then "bad" else "" end)\" data-s=\"\(.non_compliant)\">\(.non_compliant)</td><td class=\"n\" data-s=\"\(.unknown)\">\(.unknown)</td>"
  + "<td class=\"n \(.pct_compliant | pctc)\" data-s=\"\(.pct_compliant // -1)\">" + (if .pct_compliant == null then "-" else "\(.pct_compliant)%<div class=\"bar\"><i class=\"\(.pct_compliant | pctc)\" style=\"width:\(.pct_compliant)%\"></i></div>" end) + "</td>"
  + "<td class=\"n \(if .with_pending > 0 then "warn" else "" end)\" data-s=\"\(.with_pending)\">\(.with_pending)\(if .pending_total > 0 then "<div class=\"sub\">\(.pending_total) action(s)</div>" else "" end)</td>"
  + "<td class=\"n \(if .past_standard_support > 0 then "bad" else "" end)\" data-s=\"\(.past_standard_support)\">\(.past_standard_support)</td></tr>";
def html_accounts($s):
  "<section id=\"accounts\"><h2>Per account <span class=\"muted\">\($s.accounts | length) account(s) &middot; click a header to sort</span></h2>"
  + "<table class=\"sortable accounts\"><thead><tr><th>Account</th><th>Collected</th><th>Regions with DBs</th><th>Total</th><th>Compliant</th><th>Non-compliant</th><th>Unknown</th><th>% compliant</th><th>Pending maint.</th><th>Past standard support</th></tr></thead><tbody>"
  + ($s.accounts | map(account_tr) | join("")) + "</tbody></table></section>";
# html_sources: the Merged inputs section (only for --merge reports).
def html_sources($r):
  if ($r.meta.merge // null) == null then "" else
  "<section id=\"sources\"><h2>Merged inputs <span class=\"muted\">\($r.meta.merge.files) file(s) &middot; per account the newest collection wins &middot; days to maintenance / support counted from merge time (\($r.meta.generated_utc | h))</span></h2>"
  + "<table class=\"sources\"><thead><tr><th>File</th><th>Collected</th><th>Accounts used</th><th>Accounts ignored (newer file exists)</th><th>Script</th></tr></thead><tbody>"
  + ($r.meta.merge.sources | map("<tr><td class=\"mono small\">\(.file | h)</td><td class=\"small\">\(.collected_utc | h)<div class=\"sub\">\(.collected_local // "" | h)</div></td><td>\(.used | join(", ") | dash | h)</td><td class=\"muted\">\(.superseded | join(", ") | dash | h)</td><td class=\"small\">v\(.script_version | h)</td></tr>") | join(""))
  + "</tbody></table></section>" end;
# plural: "1 thing" / "N things".
def plural($n; $one; $many): "\($n) \(if $n == 1 then $one else $many end)";
# html_globals: the Global databases section (only when there are any).
def html_globals($s):
  if $s.global_databases == 0 then "" else
  "<section id=\"globals\"><h3>Global databases <span class=\"muted\" id=\"g-cnt\">\($s.global_databases)</span></h3>"
  + ([$s.globals[] | . as $g
      | ([.members[] | select(.role == "primary")] | length) as $np | ((.members | length) - $np) as $ns
      | "<details class=\"gdb\" data-g=\"\($g.global_cluster | h)\" data-a=\"\($g.account_id | h)\"\(if $g.region_status_mismatch or $g.version_differs then " data-mm=\"1\"" else "" end)><summary><b>\($g.global_cluster | h)</b>"
        + " <span class=\"st \($g.overall_status | stc)\">\($g.overall_status | h)</span>"
        + " <span class=\"muted\">\(if $g.account_name != "" then "\($g.account_name) (\($g.account_id))" else $g.account_id end | h) &middot; \($g.engine | h) &middot; \(plural($np; "primary"; "primaries")) + \(plural($ns; "secondary"; "secondaries"))</span>"
        + (if $g.region_status_mismatch then " <span class=\"st warn\">status mismatch</span>" else "" end)
        + (if $g.version_differs then " <span class=\"st warn\">versions differ</span>" else "" end)
        + "</summary><table class=\"globals\"><thead><tr><th>Role</th><th>Region</th><th>Cluster</th><th>Version</th><th>Status</th></tr></thead><tbody>"
        + ([.members[] | "<tr><td>\(.role | h)</td><td>\(.region | h)</td><td>\(.identifier | h)\(if .headless then " <span class=\"muted\">(headless)</span>" else "" end)</td><td class=\"mono\">\(.current_version | dash | h)</td>"
            + "<td><span class=\"st \(.compliance_status | stc)\">\(.compliance_status | h)</span>\(if .versions_behind != null then " <span class=\"muted\">\(.versions_behind) behind</span>" else "" end)</td></tr>"] | join(""))
        + "</tbody></table>"
        + ([ (if $g.not_scanned > 0 then "\($g.not_scanned) member(s) not scanned" else empty end), ($g.pending[] | "pending: " + (. | h)) ] | if length == 0 then "" else "<p class=\"small muted\">" + join(" &middot; ") + "</p>" end)
        + "</details>"] | join(""))
  + "</section>" end;
# page_data($r): JSON embedded in the page for lib/compliance_page.js (filters, totals, CSV export);
# "<" and line separators are escaped so the JSON cannot close the <script> tag.
def page_data($r):
  {cols: (cols + ["next_maintenance","days_until_maintenance","global_cluster","global_role","account_name"] + exc_cols),
   csv_acct: (if ($r.meta.accounts | length) == 1 then $r.meta.accounts[0].account else "" end), csv_stamp: ($r.meta.generated_utc | gsub("[^0-9]"; "") | .[0:12]),
   nc_only: $nc_only,
   accounts: [$r.meta.accounts[] | {account, profile, name: (.name // "")}],
   globals: [$r.summary.globals[] | {a: .account_id, g: .global_cluster}],
   engines: [$r.summary.engines[] | {engine, anchor, majors: [.majors[] | {major, latest_minor, standard_support_end, support_flag}]}],
   rows: [$r.rows[] | del(.pending_actions_detail, .excluded_targets, .version_warnings, .tags, .arn, .note, .global_arn, .global_pending_raw, .upgrade_command)]}
  + (if exc_on then {exc: true} else {} end)
  | tojson | gsub("<"; "\\u003c") | gsub("\u2028"; "\\u2028") | gsub("\u2029"; "\\u2029");
# html (mode html): the self-contained offline HTML page (inline CSS + JS, no external requests).
def html:
  . as $r | $r.summary as $s | $s.region_overview as $ro | (($r.meta.accounts | length) > 1) as $multi
  | ([$s.globals[] | select(.version_differs or .region_status_mismatch) | {key: "\(.account_id)|\(.global_cluster)", value: true}] | from_entries) as $gmm
  | ($r.rows | to_entries | map(.value + {_i: .key, _gmm: ($gmm["\(.value.account_id)|\(.value.global_cluster // "")"] // false)})) as $irows
  | "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>RDS patch compliance - \($r.meta.generated_utc | h)</title><style>"
  + "body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;margin:0;background:#f5f6f8;color:#1f2933}header{background:#232f3e;color:#fff;padding:16px 26px}"
  + "header h1{margin:0;font-size:21px}header p{margin:4px 0 0;color:#c9d1d9;font-size:13px}main{padding:16px 26px}"
  + ".cards{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:10px}.card{position:relative;background:#fff;border-radius:8px;padding:8px 12px;min-width:130px;box-shadow:0 1px 3px rgba(0,0,0,.12);border-left:5px solid #c3cad3;cursor:pointer;outline:none}"
  + ".card:hover,.card:focus-visible{box-shadow:0 0 0 2px #232f3e33,0 1px 3px rgba(0,0,0,.12)}.card.on{box-shadow:0 0 0 2px #232f3e;background:#eef2f7}"
  + ".card .v{font-size:20px;font-weight:700}.card .l{font-size:12.5px;font-weight:600}.card .s{font-size:11.5px;color:#52606d}"
  + ".cards.stat .card{min-width:190px;padding:12px 16px 12px 52px}.cards.stat .card .v{font-size:28px}.cards.risk{gap:8px}.cards.risk .card{min-width:0;padding:6px 10px}.cards.risk .card .s{max-width:190px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.toolbar select{max-width:135px}.card .ic{position:absolute;left:14px;top:14px;width:26px;height:26px;border-radius:50%;text-align:center;line-height:26px;font-weight:700;color:#fff;background:#7b8794}"
  + ".card.c-tot{border-left-color:#232f3e}.card.c-tot .ic{background:#232f3e}.card.c-ok{border-left-color:#2e7d32}.card.c-ok .ic{background:#2e7d32}.card.c-bad{border-left-color:#c62828}.card.c-bad .ic{background:#c62828}.card.c-unk{border-left-color:#7b8794}"
  + ".card.bad{border-left-color:#c62828}.card.bad .v{color:#c62828}.card.warn{border-left-color:#e08a00}.card.warn .v{color:#b26a00}.card.info{border-left-color:#5c6bc0}.card.zero{border-left-color:#c3cad3}.card.zero .v{color:#9aa5b1}"
  + ".pop{display:none;position:absolute;left:0;top:100%;margin-top:6px;z-index:20;background:#232f3e;color:#fff;border-radius:6px;padding:8px 10px;font-size:12px;min-width:200px;white-space:nowrap;box-shadow:0 4px 12px rgba(0,0,0,.25)}"
  + ".card:hover .pop.has,.card:focus .pop.has{display:block}.pop div{display:flex;justify-content:space-between;gap:16px}.pop b{font-weight:700}"
  + "#engines h2 .tgl{font-size:12.5px;font-weight:400;margin-left:14px;color:#52606d}.ftag{display:none;font-size:11px;font-weight:600;background:#fff4e0;color:#b26a00;border-radius:9px;padding:1px 8px;margin-left:8px}.filtered .ftag{display:inline-block}"
  + ".escroll{max-height:420px;overflow:auto;display:inline-block;box-shadow:0 1px 3px rgba(0,0,0,.12);margin-bottom:16px;border-radius:4px}.escroll table{box-shadow:none;margin:0}"
  + "table.eng{min-width:900px}table.eng th[data-c]{cursor:pointer}table.eng th[data-c]:hover{background:#dde3ea}table.eng th.sd::after{content:' ▾'}table.eng th.sa::after{content:' ▴'}"
  + "table.eng tr.er td{background:#fff;font-weight:600}table.eng tr.mr td{background:#fafbfc;font-weight:400}table.eng tr.mr td:first-child{padding-left:34px}"
  + ".car{border:0;background:none;cursor:pointer;font-size:13px;width:20px;padding:0;color:#52606d}.car[aria-expanded=true]{transform:rotate(90deg)}.car.none{visibility:hidden}"
  + "a.en{color:#0d47a1;text-decoration:none;cursor:pointer}a.en:hover{text-decoration:underline}.lnk{cursor:pointer;text-decoration:underline dotted;}.lnk:hover{color:#0d47a1}td.n .bar{min-width:110px}"
  + "h2.secs button{font-size:12px;font-weight:400;margin-left:8px;padding:3px 9px;border:1px solid #9aa5b1;border-radius:5px;background:#fff;cursor:pointer}"
  + "details.eng-sec{margin-bottom:8px}details.eng-sec>summary{cursor:pointer;background:#fff;padding:8px 12px;border-radius:6px;box-shadow:0 1px 3px rgba(0,0,0,.12);font-size:14px}details.eng-sec[open]>summary{margin-bottom:6px}details.eng-sec .es{font-size:12.5px;margin-left:6px}"
  + "#cpk{position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:50;display:flex;align-items:flex-start;justify-content:center;padding-top:60px}#cpk .box{background:#fff;border-radius:8px;width:420px;max-height:75vh;overflow:auto;box-shadow:0 8px 30px rgba(0,0,0,.3)}"
  + "#cpk .hd{position:sticky;top:0;background:#f0f3f7;padding:10px 12px;border-bottom:1px solid #dde3ea}#cpk .hd b{display:block;margin-bottom:6px}#cpk .hd button{margin-right:6px;padding:4px 10px;border:1px solid #9aa5b1;border-radius:5px;background:#fff;cursor:pointer;font-size:12.5px}#cpk .hd button.pri{background:#232f3e;color:#fff;border-color:#232f3e}"
  + "#cpk label{display:block;padding:3px 12px;font-size:12.5px;font-family:SFMono-Regular,Consolas,monospace}#cpk label:hover{background:#f5f6f8}"
  + "table{border-collapse:collapse;background:#fff;font-size:12.5px;box-shadow:0 1px 3px rgba(0,0,0,.12);margin-bottom:16px}th{background:#e9edf2;text-align:left;padding:6px 8px;position:sticky;top:0}td{padding:6px 8px;border-top:1px solid #e6e9ee;vertical-align:top}"
  + "table.main th{cursor:pointer}table.main th:hover{background:#dde3ea}.st{display:inline-block;padding:2px 7px;border-radius:10px;font-weight:700;font-size:11.5px;white-space:nowrap}"
  + ".st.ok{background:#e6f4ea;color:#1b5e20}.st.bad{background:#fdecea;color:#b71c1c}.st.unk{background:#eceff1;color:#455a64}td.ok{color:#2e7d32}td.bad{color:#c62828;font-weight:600}td.warn{color:#b26a00;font-weight:600}td.muted,.muted{color:#7b8794}"
  + ".sub{color:#7b8794;font-size:11px}.mono,code{font-family:SFMono-Regular,Consolas,monospace;font-size:11.5px}.small{font-size:11.5px}td.cmd code{display:block;max-width:380px;white-space:pre-wrap;word-break:break-all}"
  + ".badge{display:inline-block;min-width:18px;padding:1px 7px;border-radius:10px;background:#e08a00;color:#fff;font-weight:700;text-align:center}details.pend summary{cursor:pointer;list-style:none}details.pend ul{margin:4px 0 0;padding-left:16px;min-width:260px}"
  + ".cp{margin-top:4px;font-size:11px;padding:2px 8px;border:1px solid #9aa5b1;background:#fff;border-radius:5px;cursor:pointer}.cp.ok{background:#e6f4ea}"
  + "h2{font-size:16px;margin:18px 0 6px}h3{font-size:14px;margin:12px 0 6px}#q{width:420px;padding:7px 10px;border:1px solid #9aa5b1;border-radius:6px;margin:8px 0 12px;font-size:13px}"
  + ".grid{display:flex;flex-wrap:wrap;gap:16px;align-items:flex-start}table.sortable th{cursor:pointer}table.sortable th:hover{background:#dde3ea}td.n{text-align:right}"
  + ".st.db{background:#e3f0fb;color:#0d47a1}.gb{display:inline-block;margin-left:6px;padding:1px 7px;border-radius:9px;font-size:11px;background:#ede7f6;color:#4527a0;font-weight:600}.gb.unk{background:#eceff1;color:#546e7a}table.globals td{vertical-align:top}tfoot td{border-top:2px solid #232f3e;background:#f0f3f7;font-weight:600}"
  + ".bar{height:4px;background:#e6e9ee;border-radius:2px;margin-top:3px;min-width:70px}.bar i{display:block;height:4px;border-radius:2px;background:#2e7d32}.bar i.warn{background:#e08a00}.bar i.bad{background:#c62828}"
  + ".toolbar{position:sticky;top:0;z-index:5;background:#f5f6f8;display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 0;margin-bottom:6px;border-bottom:1px solid #dde3ea}"
  + ".toolbar select,.toolbar input,.toolbar button{padding:6px 8px;border:1px solid #9aa5b1;border-radius:6px;font-size:13px;background:#fff}.toolbar input#q{width:190px;margin:0}.toolbar button{cursor:pointer}.toolbar button.pri{background:#232f3e;color:#fff;border-color:#232f3e}"
  + ".toolbar .cnt{color:#52606d;font-size:12.5px}.gchk{display:inline-flex;gap:10px;font-size:13px}.gchk[hidden]{display:none}.gchk label{display:inline-flex;gap:4px;align-items:center;cursor:pointer}.gchk input{margin:0}"
  + ".st.warn{background:#fff3e0;color:#b26a00}.gb.mm{background:#fff3e0;color:#b26a00}.empty{background:#fff3e0;border-radius:6px;padding:8px 12px;color:#7a4a00;font-weight:600}.empty[hidden]{display:none}"
  + ".gdb{background:#fff;border-radius:8px;margin:0 0 6px;box-shadow:0 1px 3px rgba(0,0,0,.12)}.gdb summary{cursor:pointer;padding:7px 12px;font-size:13px}.gdb table{margin:0 12px 8px;width:auto}.gdb p{margin:0 12px 8px}.flt-note{display:none;color:#b26a00;font-size:12px;margin:0 0 8px}.filtered .flt-note{display:block}"
  + ".about{margin:18px 0;background:#fff;border-radius:8px;padding:8px 14px;box-shadow:0 1px 3px rgba(0,0,0,.12);font-size:12.5px}.about summary{cursor:pointer;font-weight:600}footer{padding:10px 26px 24px;color:#7b8794;font-size:12px}"
  + (if exc_on then ".st.exc{background:#e3f2fd;color:#0d47a1}.xf{font-size:10.5px;margin-top:2px}.excn{background:#fff3e0;border-radius:6px;padding:6px 12px;color:#7a4a00;font-size:12.5px;margin:0 0 8px}" else "" end)
  + "</style></head><body>"
  + "<header id=\"top\"><h1>RDS patch compliance report</h1><p>\($r.meta.generated_utc | h) &middot; \($r.meta.generated_local | h) &middot; accounts \($r.meta.accounts | map(alab) | join(", ") | h) &middot; Regions: \($ro | region_line)\(if $r.meta.merge then " &middot; merged from \($r.meta.merge.files) file(s)" else "" end)</p></header><main>"
  + "<div class=\"toolbar\" id=\"filters\"><select id=\"f-acct\" aria-label=\"Account\"><option value=\"\">All accounts</option></select><select id=\"f-region\" aria-label=\"Region\"><option value=\"\">All regions</option></select>"
  + "<select id=\"f-engine\" aria-label=\"Engine\"><option value=\"\">All engines</option></select><select id=\"f-status\" aria-label=\"Compliance status\"><option value=\"\">All statuses</option></select><span id=\"g-box\" class=\"gchk\"><label><input type=\"checkbox\" id=\"f-gl\"> Global</label><label><input type=\"checkbox\" id=\"f-sa\"> Standalone</label></span>"
  + "<input id=\"q\" type=\"search\" placeholder=\"Search DB, account, engine, version\" aria-label=\"Search\"><select id=\"f-flag\" aria-label=\"Flag\"><option value=\"\">Flag: any</option><option value=\"past\">Extended Support</option><option value=\"near\">Support ending</option><option value=\"aoff\">Auto minor upgrade off</option><option value=\"pend\">Pending maintenance</option><option value=\"dep\">Version not returned</option></select>"
  + (if exc_on then "<select id=\"f-exc\" aria-label=\"Exceptions\"><option value=\"\">Exceptions: all</option><option value=\"yes\">Exceptions only</option><option value=\"no\">Non-exceptions</option><option value=\"attn\">Expiring soon or no longer needed</option><option value=\"expired\">Expired exceptions</option></select>" else "" end)
  + "<button id=\"f-reset\" type=\"button\">Reset</button><button id=\"f-csv\" class=\"pri\" type=\"button\">Export CSV</button><span class=\"cnt\" id=\"f-count\"></span></div>"
  + "<p id=\"empty\" class=\"empty\" hidden>No servers match. <button type=\"button\" id=\"empty-reset\">Clear filters</button></p><p class=\"flt-note\">Filtered view: cards and tables show only matching servers.</p>"
  + (if $s.exceptions and ($s.exceptions.expired > 0 or ($s.exceptions.unmatched | length) > 0) then "<p class=\"excn\" id=\"exc-note\"><b>Exceptions file:</b> "
       + ([ (if $s.exceptions.expired > 0 then "\($s.exceptions.expired) expired (evaluated normally; renew or remove)" else empty end),
            (if ($s.exceptions.unmatched | length) > 0 then "\($s.exceptions.unmatched | length) matched no server: " + ($s.exceptions.unmatched | map("\(.account) \(.identifier) (line \(.line))") | join(", ")) else empty end) ] | map(h) | join(" &middot; ")) + "</p>" else "" end)
  + "<p class=\"muted rule\"><b>Rule:</b> NON-COMPLIANT when more than \($s.max_behind) valid minor versions behind (same major). <a href=\"#about\">About this report</a></p>"
  + "<div class=\"cards stat\">" + cardx("Servers / clusters"; $s.total; "c-tot"; "\($r.meta.accounts | length) account(s), \($r.meta.regions | length) region(s)"; "reset"; "#"; false)
  + cardx("Compliant"; $s.compliant; "c-ok"; "\($s.pct_compliant)% of all" + (if $s.exceptions then " · incl. \($s.exceptions.applied) exceptions" else "" end); "s:COMPLIANT"; "✓"; ($s.exceptions != null))
  + cardx("Non-compliant"; $s.non_compliant; "c-bad"; "> \($s.max_behind) behind"; "s:NON-COMPLIANT"; "✕"; true)
  + cardx("Unknown"; $s.unknown; "c-unk"; "lookup failed / not returned"; "s:UNKNOWN"; "?"; true) + "</div>"
  + "<div class=\"cards risk\">"
  + cardx("Extended Support"; $s.past_standard_support; riskc($s.past_standard_support; "bad"); "past standard support"; "f:past"; ""; false)
  + cardx("Support ending"; $s.nearing_end_of_support; riskc($s.nearing_end_of_support; "warn"); "within \($s.warn_days) days"; "f:near"; ""; false)
  + cardx("Auto minor upgrade off"; $s.auto_minor_off; riskc($s.auto_minor_off; "warn"); "incl. mixed clusters"; "f:aoff"; ""; false)
  + cardx("Pending maintenance"; $s.with_pending; riskc($s.with_pending; "warn"); ($s.pending_by_action | to_entries | map("\(.key) \(.value)") | join(", ") | if . == "" then "none" else . end); "f:pend"; ""; false)
  + cardx("Version not returned"; $s.deprecated; riskc($s.deprecated; "bad"); "deprecated / not offered"; "f:dep"; ""; false)
  + cardx("Global databases"; $s.global_databases; (if $s.global_unknown > 0 then "warn" else riskc($s.global_databases; "info") end); "\($s.global_members) members" + ([$s.globals[] | select(.version_differs or .region_status_mismatch)] | length | if . > 0 then " · \(.) mismatched" else "" end) + (if $s.global_unknown > 0 then "; \($s.global_unknown) unknown" else "" end); "gl"; ""; false)
  + cardx("Regions"; "\($ro.with_databases) / \($ro.checked)"; (if $ro.error > 0 then "bad" else "info" end); "with DBs; \($ro.empty) empty, \($ro.error) error(s)"; "scroll:regions"; ""; false) + "</div>"
  + "<section id=\"engines\"><h2>Engine compliance <span class=\"ftag\">Filtered</span><label class=\"tgl\"><input type=\"checkbox\" id=\"eng-all\"> Show all majors</label></h2>"
  + "<div class=\"escroll\"><table class=\"eng\" id=\"eng-tbl\"><thead><tr><th data-c=\"e\">Engine</th><th data-c=\"n\">Servers</th><th data-c=\"p\">% compliant</th><th data-c=\"nc\">Non-compliant</th><th data-c=\"s\">Support</th><th>Latest minor</th></tr></thead><tbody>"
  + ([$s.engines[] | "<tr class=\"er\"><td><a href=\"#\(.anchor)\">\(.engine | h)</a></td><td class=\"n\">\(.total)</td><td class=\"n\">\(.pct_compliant)%</td><td class=\"n\">\(.non_compliant)</td><td></td><td></td></tr>"] | join(""))
  + "</tbody></table></div></section>"
  + html_accounts($s) + html_regions($r; $s; $ro; $multi) + html_globals($s)
  + "<h2 class=\"secs\">Servers by engine <button type=\"button\" id=\"x-open\">Expand all</button><button type=\"button\" id=\"x-close\">Collapse all</button></h2>"
  + ([$s.engines[] | . as $e
      | "<details class=\"eng-sec\" id=\"\($e.anchor)\" data-e=\"\($e.engine | h)\"><summary><b>\($e.engine | h)</b> <span class=\"es muted\">\($e.total) &middot; non-compliant \($e.non_compliant) &middot; \($e.pct_compliant)%</span></summary>"
        + "<table class=\"main\"><thead><tr><th>Status</th><th>Behind</th><th>Identifier / members</th><th>Type</th><th>Major</th><th>Current</th><th>Latest minor</th><th>Valid minor targets</th><th>Auto-upgrade default</th><th>Auto minor</th><th>Standard end</th><th>Extended end</th><th>Support</th><th>Pending maint.</th><th>Maint. window</th><th>Account</th>" + (if exc_on then "<th>Exception</th>" else "" end) + "</tr></thead><tbody>"
        + ([$irows[] | select(.engine == $e.engine) | html_row] | join("")) + "</tbody></table></details>"] | join(""))
  + (if ($r.rows | length) == 0 then "<p>No servers matched.</p>" else "" end)
  + (if ($r.errors | length) > 0 then "<h2>Errors</h2><ul>" + ($r.errors | map("<li>\(.profile | h)/\(.region | h): \(.call | h): \(.message | h)</li>") | join("")) + "</ul>" else "" end)
  + html_sources($r)
  + "<details id=\"about\" class=\"about\"><summary>About this report</summary><ul>"
  + "<li><b>COMPLIANT</b> = at most \($s.max_behind) valid minor upgrade target(s) for the current version; <b>NON-COMPLIANT</b> = \($s.max_behind + 1) or more; <b>UNKNOWN</b> = lookup failed or current version not returned (deprecated).</li>"
  + "<li>Counted are only the valid minor upgrade targets RDS returns for the server's current version (describe-db-engine-versions --engine-version &lt;current&gt;, ValidUpgradeTarget with IsMajorVersionUpgrade=false). Latest minor per major = highest valid target seen (or the current version when up to date).</li>"
  + "<li><b>Regions:</b> \($ro | region_mode_txt | h). Empty regions are only counted; tables list regions with databases or an AWS error.</li>"
  + "<li><b>Pending maint.</b> = maintenance actions AWS has scheduled or offered for this server that haven't been applied yet (cluster rows include their member instances' actions); click the badge to expand, hover for IST dates.</li>"
  + "<li><b>Global databases</b> (Aurora): membership from describe-global-clusters (one call per account). Overall status = the worst member; <i>region status mismatch</i> = members on the same version but with a different status (valid targets differ per region). Automatic minor version upgrade does not apply to global database members.</li>"
  + (if exc_on then "<li><b>Exceptions</b> (compliance_exceptions.conf, scope patch): a listed server shows COMPLIANT (EXCEPTION) and counts as compliant until its expiry date (last valid UTC day); <i>actual</i> is the evaluated status. Expired entries are evaluated normally; <i>expiring soon</i> = within 14 days; <i>no longer needed</i> = the server is compliant on its own.</li>" else "" end)
  + "<li>Read-only: nothing was changed.</li></ul></details>"
  + "<script type=\"application/json\" id=\"pc-data\">" + page_data($r) + "</script>"
  + "</main><footer>\($r.meta.script | h) v\($r.meta.version | h) &middot; read-only</footer>"
  + "<script>(function(){Array.prototype.forEach.call(document.querySelectorAll('table.main,table.sortable'),function(t){var b=t.tBodies[0],dir={};"
  + "t.tHead.addEventListener('click',function(e){var th=e.target.closest('th');if(!th)return;var i=th.cellIndex;dir[i]=!dir[i];"
  + "var rows=Array.prototype.slice.call(b.rows);rows.sort(function(x,y){var a=x.cells[i],c=y.cells[i];if(!a||!c)return 0;var va=a.getAttribute('data-s'),vb=c.getAttribute('data-s');"
  + "var r=(va!==null&&vb!==null)?parseFloat(va)-parseFloat(vb):a.textContent.localeCompare(c.textContent,undefined,{numeric:true});return dir[i]?r:-r;});rows.forEach(function(r){b.appendChild(r);});});});"
  + "})();</script><script>" + ($ARGS.named.pagejs // "") + "</script></body></html>";

# ------------------------------------------------------------------ main: dispatch on $mode
if $mode == "rows" then rows elif $mode == "finalize" then finalize elif $mode == "text" then text elif $mode == "csv" then csv
elif $mode == "html" then html elif $mode == "json" then json_out elif $mode == "csv_regions" then csv_regions elif $mode == "alert" then alert
elif $mode == "vkey_cmp" then vcmp($ARGS.named.a; $ARGS.named.b)
elif $mode == "vcmp_e" then vcmp_e($ARGS.named.e; $ARGS.named.a; $ARGS.named.b) elif $mode == "major" then ($ARGS.named.a | derive_major($ARGS.named.e)) else . end
