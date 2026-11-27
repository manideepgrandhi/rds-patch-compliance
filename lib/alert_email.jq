# Alert e-mail body (text or HTML), shared by rds_patch_compliance_report.sh and rds_patch_compliance_summary.sh.
# Input: the report JSON (the `json` format of the report script).
# Args:  $mode (text|html), $host, $tool (e.g. "rds_patch_compliance_report.sh v1.7.1"), $when (footer timestamp).
# The named constants below are typography only (same colours as the HTML report); every setting still comes
# from the conf file / CLI, never from this file.
# The e-mail lists what needs action: NON-COMPLIANT servers, UNKNOWN servers and AWS errors (regions that may be
# incomplete). Pending maintenance appears as a count only; the HTML report has the details.
def dash: if . == null or . == "" then "—" else . end;
def rpad($w): tostring + (" " * ([0, $w - (tostring | length)] | max));
def plural($n; $one; $many): if $n == 1 then $one else $many end;
# account number -> name (rows carry the effective name; meta.accounts may add more)
def names:
  (reduce (.rows[]? | select((.account_name // "") != "") | {key: .account_id, value: .account_name}) as $r ({}; .[$r.key] = $r.value)) as $a
  | reduce (.meta.accounts[]? | select((.name // "") != "") | {key: .account, value: .name}) as $m ($a; if has($m.key) then . else .[$m.key] = $m.value end);
def lab($names; $id): if (($names[$id] // "") != "") then "\($names[$id]) (\($id))" else $id end;
def acct_list: names as $n | ([.meta.accounts[]?.account] | map(lab($n; .)) | join(", "));
def status_word:
  if .summary.non_compliant > 0 then "NON-COMPLIANT"
  elif .summary.errors > 0 then "ERRORS"
  else "COMPLIANT" end;
# typography (matches the HTML report; not conf settings)
def col_red: "#b3261e";
def col_green: "#137333";
def col_amber: "#b54708";
def banner_bg: if status_word == "NON-COMPLIANT" then col_red elif status_word == "ERRORS" then col_amber else col_green end;
def footer:
  "\($tool)" + (if $host != "" then " · \($host)" else "" end) + (if $when != "" then " · \($when)" else "" end);

# ---- failure rows: {account, account_id, server, region, engine, current, target, reason}
def support_note: (.support_flag // "") | select(startswith("past standard") or startswith("standard support ends"));
def reason_nc($lim):
  ([ "\(.versions_behind) valid minor \(plural(.versions_behind; "version"; "versions")) behind (limit \($lim))",
     (.note // "" | select(. != "")), (support_note) ] | join("; "));
def reason_unknown:
  ([ ((.note // "") | if . == "" then "version lookup failed" else . end), (support_note) ] | join("; "));
def row_fail($names; $kind; $lim):
  {account: lab($names; .account_id), account_id: .account_id, server: (.identifier // ""), region: (.region // ""),
   engine: (.engine // ""), current: (.current_version // ""), target: (.latest_minor_version // ""),
   reason: (if $kind == "nc" then reason_nc($lim) else reason_unknown end)};
# one AWS error -> a short reason: "AccessDenied on describe-db-instances: explicit deny in a service control policy"
def err_short:
  (.message // "") as $m
  | ($m | capture("An error occurred \\((?<c>[A-Za-z0-9._]+)\\) when calling the (?<op>[A-Za-z0-9]+) operation: (?<rest>.*)$"; "s")) as $x
  | if $x == null then ($m | if length > 160 then .[0:157] + "..." else . end)
    else (($x.rest | sub("^User: \\S+ is not authorized to perform: \\S+ (with an? |because )?"; "") | sub(" \\(region scanned in full anyway\\)$"; ""))
          | if length > 160 then .[0:157] + "..." else . end) as $d
         | ((.call // "") | sub("^[a-z0-9-]+ "; "") | sub(" \\(.*$"; "")) as $op
         | "\($x.c) on \(if $op != "" then $op else $x.op end)" + (if $d != "" then ": \($d)" else "" end) end;
def error_rows($names):
  [ (.errors // []) | group_by([.account, (.region // "")])[]
    | {account: lab($names; .[0].account), account_id: .[0].account, server: "", region: (.[0].region // ""), engine: "", current: "", target: "",
       reason: ([.[] | err_short] | unique | join("; "))} ];

def nc_rows($names; $lim): [.rows[]? | select(.compliance_status == "NON-COMPLIANT") | . as $r | row_fail($names; "nc"; $lim) | . + {behind: ($r.versions_behind // 0)}]
  | sort_by([-.behind, (.server | ascii_downcase), .account_id, .region]);
def un_rows($names): [.rows[]? | select(.compliance_status == "UNKNOWN") | row_fail($names; "unknown"; 0)]
  | sort_by([(.server | ascii_downcase), .account_id, .region]);

def counts_text:
  "Resources: \(.summary.total)\n"
  + "Compliant: \(.summary.compliant)\n"
  + "Non-compliant: \(.summary.non_compliant)\n"
  + "Unknown: \(.summary.unknown)\n"
  + "Pending: \(.summary.with_pending)\n"
  + "Compliance: \(.summary.pct_compliant)% (\(.summary.compliant) of \(.summary.total))"
  + (if (.summary.exceptions.applied // 0) > 0 then ", incl. \(.summary.exceptions.applied) exception(s)" else "" end);
def rule_text:
  "Rule: NON-COMPLIANT when more than \(.summary.max_behind) valid minor \(plural(.summary.max_behind; "version"; "versions")) behind."
  + (if .summary.with_pending > 0
     then " Pending maintenance: \(.summary.with_pending) \(plural(.summary.with_pending; "server"; "servers")), \(.summary.pending_total) \(plural(.summary.pending_total; "action"; "actions")) (details are in the HTML report)."
     else "" end);

def text_table($title; $rows):
  if ($rows | length) == 0 then empty else
    ["Account", "Server", "Region", "Engine", "Current → target", "Reason"] as $h
    | ($rows | map([.account, (.server | dash), (.region | dash), (.engine | dash), (if .current == "" and .target == "" then "—" else (.current | dash) + " → " + (.target | dash) end), .reason])) as $d
    | [range(0; 6)] as $ix
    | ($ix | map(. as $i | ([$h[$i]] + [$d[][$i]] | map(length) | max))) as $w
    | ($title + " (\($rows | length)):",
       "",
       ($ix | map(. as $i | $h[$i] | rpad($w[$i])) | join("  ") | sub(" +$"; "")),
       ($ix | map(. as $i | "-" * $w[$i]) | join("  ")),
       ($d[] | . as $r | ($ix | map(. as $i | $r[$i] | rpad($w[$i])) | join("  ") | sub(" +$"; ""))),
       "")
  end;

def text_body($names; $lim):
  status_word as $st
  | (nc_rows($names; $lim)) as $nc | un_rows($names) as $un | error_rows($names) as $er
  | ("RDS patch compliance: \($st)",
     "\(.summary.non_compliant) non-compliant of \(.summary.total) servers, \(.summary.pct_compliant)% compliant",
     "",
     "Accounts: \(acct_list)",
     counts_text,
     rule_text,
     "",
     (if ($nc | length) == 0 and ($un | length) == 0 and ($er | length) == 0 then "No NON-COMPLIANT servers.", "" else empty end),
     text_table("NON-COMPLIANT servers"; $nc),
     text_table("UNKNOWN (lookup failed or version not returned)"; $un),
     text_table("AWS errors (these regions may be incomplete)"; $er),
     footer);

# ---- HTML (inline styles only; works in Outlook, Gmail and Apple Mail)
def th($s): "<th align=\"left\" style=\"border:1px solid #d0d5dd;background:#f2f4f7;padding:8px 10px;font-size:11px;text-transform:uppercase;letter-spacing:.03em;color:#475467;\">\($s | @html)</th>";
def small($s): "<div style=\"font-size:11px;color:#667085;font-weight:400;white-space:nowrap;\">\($s | @html)</div>";
def td_plain($inner): "<td style=\"border:1px solid #d0d5dd;padding:8px 10px;font-size:13px;line-height:1.4;vertical-align:top;\">\($inner)</td>";
def acct_cell($names): td_plain(((($names[.account_id] // "") as $n | if $n != "" then ($n | @html) + small(.account_id) else (.account_id | @html) end)));
def server_cell: td_plain(if .server == "" then "—" else "<span style=\"font-weight:600;\">\(.server | @html)</span>" + (if .region != "" then small(.region) else "" end) end);
def server_cell_err: td_plain(if .region == "" then "—" else "<span style=\"font-weight:600;\">—</span>" + small(.region) end);
def ver_cell:
  "<td style=\"border:1px solid #d0d5dd;padding:8px 10px;font-size:11px;line-height:1.45;vertical-align:top;font-family:Consolas,Menlo,monospace;overflow-wrap:anywhere;\">"
  + (if .current == "" and .target == "" then "—" else (.current | dash | @html) + "<div style=\"color:#667085;\">&rarr; \(.target | dash | @html)</div>" end) + "</td>";
def html_table($title; $rows; $names):
  if ($rows | length) == 0 then "" else
    "<tr><td style=\"padding:8px 20px 4px;font-size:14px;font-weight:700;\">\($title | @html) (\($rows | length))</td></tr>\n"
    + "<tr><td style=\"padding:0 20px 16px;\">\n"
    + "<table width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" style=\"border-collapse:collapse;width:100%;table-layout:fixed;\">\n"
    + "<col style=\"width:16%\"><col style=\"width:16%\"><col style=\"width:17%\"><col style=\"width:26%\"><col style=\"width:25%\">\n"
    + "<thead><tr>" + th("Account") + th("Server") + th("Engine") + th("Current → target") + th("Reason") + "</tr></thead>\n"
    + "<tbody>\n"
    + ($rows | map("<tr>" + acct_cell($names) + (if .server == "" then server_cell_err else server_cell end) + td_plain(.engine | dash | @html) + ver_cell + td_plain(.reason | @html) + "</tr>") | join("\n"))
    + "\n</tbody></table>\n</td></tr>\n"
  end;
def card($label; $val; $color; $first; $last):
  "<td style=\"padding:8px \(if $last then "0" else "14px" end) 8px \(if $first then "0" else "14px" end);\(if $last then "" else "border-right:1px solid #e4e7ec;" end)\"><div style=\"font-size:11px;color:#667085;\">\($label)</div><div style=\"font-size:18px;font-weight:700;\(if $color != "" then "color:\($color);" else "" end)\">\($val)</div></td>";
def html_body($names; $lim):
  status_word as $st | banner_bg as $bg
  | nc_rows($names; $lim) as $nc | un_rows($names) as $un | error_rows($names) as $er
  | ("<!DOCTYPE html>\n<html lang=\"en\"><head>\n<meta charset=\"utf-8\">\n"
     + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
     + "<title>RDS patch compliance: \($st | @html)</title>\n</head>\n"
     + "<body style=\"margin:0;padding:0;background:#f2f4f7;font-family:Arial,Helvetica,sans-serif;color:#1d2939;\">\n"
     + "<table role=\"presentation\" width=\"100%\" cellspacing=\"0\" cellpadding=\"0\" style=\"background:#f2f4f7;padding:0;\">\n"
     + "<tr><td align=\"center\">\n"
     + "<table role=\"presentation\" width=\"760\" cellspacing=\"0\" cellpadding=\"0\" style=\"width:760px;max-width:760px;background:#ffffff;border:1px solid #d0d5dd;\">\n"
     + "<tr><td style=\"padding:16px 20px;background:\($bg);color:#ffffff;\">\n"
     + "<div style=\"font-size:11px;letter-spacing:.04em;text-transform:uppercase;opacity:.9;\">RDS patch compliance</div>\n"
     + "<div style=\"font-size:20px;font-weight:700;margin-top:4px;\">\($st | @html)</div>\n"
     + "<div style=\"font-size:13px;margin-top:4px;\">\(.summary.non_compliant) non-compliant of \(.summary.total) servers · \(.summary.pct_compliant)% compliant</div>\n"
     + "</td></tr>\n"
     + "<tr><td style=\"padding:16px 20px 8px;font-size:14px;line-height:1.5;\">\n"
     + "<div style=\"margin-bottom:10px;\"><b>Accounts:</b> \(acct_list | @html)</div>\n"
     + "<table role=\"presentation\" cellspacing=\"0\" cellpadding=\"0\" style=\"border-collapse:collapse;\">\n<tr>\n"
     + card("Resources"; .summary.total; ""; true; false) + "\n"
     + card("Compliant"; .summary.compliant; col_green; false; false) + "\n"
     + card("Non-compliant"; .summary.non_compliant; col_red; false; false) + "\n"
     + card("Unknown"; .summary.unknown; ""; false; false) + "\n"
     + card("Pending"; .summary.with_pending; ""; false; true) + "\n"
     + "</tr></table>\n"
     + "<div style=\"font-size:12px;color:#667085;margin-top:8px;\">Compliance is \(.summary.pct_compliant)% (\(.summary.compliant) of \(.summary.total))."
     + (if (.summary.exceptions.applied // 0) > 0 then " Includes \(.summary.exceptions.applied) exception(s)." else "" end)
     + " \(rule_text | @html)</div>\n"
     + "</td></tr>\n"
     + (if ($nc | length) == 0 and ($un | length) == 0 and ($er | length) == 0 then
         "<tr><td style=\"padding:8px 20px 16px;font-size:14px;\">No NON-COMPLIANT servers.</td></tr>\n"
       else
         html_table("NON-COMPLIANT servers"; $nc; $names)
         + html_table("UNKNOWN (lookup failed or version not returned)"; $un; $names)
         + html_table("AWS errors (these regions may be incomplete)"; $er; $names)
       end)
     + "<tr><td style=\"padding:12px 20px;border-top:1px solid #e4e7ec;font-size:11px;color:#667085;\">\(footer | @html)</td></tr>\n"
     + "</table>\n</td></tr></table>\n</body></html>\n");

names as $names
| (.summary.max_behind) as $lim
| if $mode == "html" then html_body($names; $lim) else text_body($names; $lim) end
