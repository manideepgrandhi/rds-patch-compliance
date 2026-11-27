# rds_patch_compliance_report.sh - examples

All examples are read-only. Run them in AWS CloudShell (or anywhere with AWS CLI v2 and jq) from the tool folder.

**Settings come from the conf file.** `rds_patch_compliance_report.conf` sits next to the script and is read automatically (all regions, csv + html + txt files into `./reports`, log in `./reports/run.log`, and so on). Every setting has a short comment in that file. A command line option changes one value for that run only; `--config FILE` uses another complete copy of the file instead. `-o ''` prints one format on the screen and writes no files; `-l ''` writes no log file. The outputs below are real runs against the test mock (fake accounts `111111111111` / `222222222222`, fake servers); long outputs are cut with `...`. The run time in the log lines and the file-name stamps are the time of the run.

## Basics

### 1. Run with the settings in the conf file (nothing on the command line)

```bash
./rds_patch_compliance_report.sh
```

Output:

```text
2026-11-27 09:56:53 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:56:53 [INFO] Profile default: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:56:53 [INFO] [default] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:56:53 [INFO] [default/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:56:53 [WARN] [default/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:56:54 [INFO] [default/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:56:54 [INFO] [default] 0 Aurora global database(s)
2026-11-27 09:56:54 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_111111111111_20261127_095653.csv
2026-11-27 09:56:54 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_111111111111_20261127_095653_regions.csv
2026-11-27 09:56:55 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_111111111111_20261127_095653.html
2026-11-27 09:56:55 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_111111111111_20261127_095653.txt
2026-11-27 09:56:55 [INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 36 AWS call(s); exit 0
```

### 2. Quick look: one region, text on the screen, no files

```bash
./rds_patch_compliance_report.sh -r us-east-1 -F text -o '' -l ''
```

Output:

```text
2026-11-27 09:56:55 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:56:55 [INFO] Profile default: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:56:55 [INFO] [default/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:56:55 [WARN] [default/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:56:56 [INFO] [default/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:56:56 [INFO] [default] 0 Aurora global database(s)
RDS PATCH COMPLIANCE REPORT - 2026-11-27 04:26 UTC (2026-11-27 09:56 IST)
Accounts : 111111111111 prod-payments (default)   Regions: 1 given
Regions  : 1 checked, 1 with databases, 0 empty, 0 errors
Rule     : NON-COMPLIANT when more than 2 valid minor versions behind (same major)

SUMMARY
  Servers/clusters : 19   COMPLIANT 11   NON-COMPLIANT 7   UNKNOWN 1   -> 57.9% compliant
  Support          : 2 past standard support (Extended Support charges), 2 ending within 180 days
  Pending maint.   : on 3 server(s): os-upgrade 2, system-update 2, db-upgrade 1 (5 action(s)) - see PENDING MAINTENANCE
  Global databases : 0 (0 members)
  Other flags      : auto minor upgrade off 3, current version not returned / deprecated 1

PER ENGINE / MAJOR VERSION
  ENGINE                MAJOR      TOTAL  COMPL  NON-C  UNKN  LATEST MINOR                        SUPPORT
  aurora-mysql          8.0            2      1      1     0  8.0.mysql_aurora.3.10.0             ok (standard end 2029-05-15)
  aurora-postgresql     16             1      1      0     0  16.9                                ok (standard end 2031-01-05)
...
```

### 3. Two accounts, two regions, every format into ~/compliance

```bash
./rds_patch_compliance_report.sh -P prod,nonprod -r us-east-1,ap-south-1 -F csv,html,txt,json -o ~/compliance
```

Output:

```text
2026-11-27 09:56:56 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:56:56 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:56:56 [INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:56:56 [WARN] [prod/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:56:57 [INFO] [prod/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:56:57 [INFO] [prod/ap-south-1] 0 cluster(s), 0 instance(s), 0 resource(s) with pending maintenance
2026-11-27 09:56:57 [INFO] [prod/ap-south-1] no matching servers
2026-11-27 09:56:57 [INFO] [prod] 0 Aurora global database(s)
2026-11-27 09:56:57 [INFO] Profile nonprod: account 222222222222 (arn:aws:iam::222222222222:user/dba)
2026-11-27 09:56:57 [INFO] [nonprod/us-east-1] 0 cluster(s), 0 instance(s), 0 resource(s) with pending maintenance
2026-11-27 09:56:58 [INFO] [nonprod/us-east-1] no matching servers
2026-11-27 09:56:58 [INFO] [nonprod/ap-south-1] 1 cluster(s), 3 instance(s), 0 resource(s) with pending maintenance
2026-11-27 09:56:58 [INFO] [nonprod/ap-south-1] COMPLIANT=2 NON-COMPLIANT=1
2026-11-27 09:56:58 [INFO] [nonprod] 0 Aurora global database(s)
2026-11-27 09:56:58 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_20261127_095656.csv
2026-11-27 09:56:58 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_20261127_095656_regions.csv
2026-11-27 09:56:58 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_20261127_095656.html
2026-11-27 09:56:58 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_20261127_095656.txt
...
```

### 4. Whole estate, every enabled region, HTML only (regions are probed first; only regions with databases are scanned)

```bash
./rds_patch_compliance_report.sh -P prod --all-regions -F html -o ~/compliance
```

Output:

```text
2026-11-27 09:56:59 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:56:59 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:56:59 [INFO] [prod] discovery: probing 14 region(s), 8 at a time
2026-11-27 09:56:59 [ERROR] [prod/ca-central-1] discovery probe 'rds describe-db-instances (discovery probe)' failed: An error occurred (AccessDenied) when calling the DescribeDBInstances operation: User: arn:aws:iam::111111111...
2026-11-27 09:56:59 [ERROR] [prod/ca-central-1] 'aws rds describe-db-instances' failed (rc=254): An error occurred (AccessDenied) when calling the DescribeDBInstances operation: User: arn:aws:iam::111111111111:user/dba is not a...
2026-11-27 09:56:59 [INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:56:59 [WARN] [prod/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:00 [INFO] [prod/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:57:00 [INFO] [prod/us-west-2] 1 cluster(s), 0 instance(s), 0 resource(s) with pending maintenance
2026-11-27 09:57:00 [INFO] [prod/us-west-2] COMPLIANT=1
2026-11-27 09:57:00 [INFO] [prod] 0 Aurora global database(s)
2026-11-27 09:57:00 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_111111111111_20261127_095659.html
2026-11-27 09:57:00 [INFO] Result: 20 server(s)/cluster(s): COMPLIANT 12, NON-COMPLIANT 7, UNKNOWN 1 (60% compliant); 2 error(s); 65 AWS call(s); exit 0
```

### 4a. Probe 16 regions at a time, or skip the probe and scan every region in full

```bash
./rds_patch_compliance_report.sh -P prod,nonprod -A --probe-parallel 16 -F html,csv -o ~/compliance   # csv also writes *_regions.csv
```

Output:

```text
2026-11-27 09:57:00 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:01 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:01 [INFO] [prod] discovery: probing 14 region(s), 16 at a time
2026-11-27 09:57:01 [ERROR] [prod/ca-central-1] discovery probe 'rds describe-db-instances (discovery probe)' failed: An error occurred (AccessDenied) when calling the DescribeDBInstances operation: User: arn:aws:iam::111111111...
2026-11-27 09:57:01 [ERROR] [prod/ca-central-1] 'aws rds describe-db-instances' failed (rc=254): An error occurred (AccessDenied) when calling the DescribeDBInstances operation: User: arn:aws:iam::111111111111:user/dba is not a...
2026-11-27 09:57:01 [INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:01 [WARN] [prod/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:02 [INFO] [prod/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:57:02 [INFO] [prod/us-west-2] 1 cluster(s), 0 instance(s), 0 resource(s) with pending maintenance
2026-11-27 09:57:02 [INFO] [prod/us-west-2] COMPLIANT=1
2026-11-27 09:57:02 [INFO] [prod] 0 Aurora global database(s)
2026-11-27 09:57:02 [INFO] Profile nonprod: account 222222222222 (arn:aws:iam::222222222222:user/dba)
...
```

### 4b. See the discovery probes and the full-scan calls without making them

```bash
./rds_patch_compliance_report.sh -P prod -A --dry-run
```

Output:

```text
2026-11-27 09:57:03 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
rds_patch_compliance_report.sh v1.8.0 dry run - no AWS calls are made
  profiles : prod 
  regions  : all enabled per account; discovery probe (8 in parallel), full scan only where databases (or a probe error) are found
  filters  : 
  rule     : COMPLIANT <= 2 minor version(s) behind; support warning 180d
  formats  : csv html text -> ./reports
  settings : /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf
Profile prod:
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<region\> sts get-caller-identity 
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<region\> iam list-account-aliases  (once per account, unless a name is set in the config; optional)
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<region\> ec2 describe-regions 
  discovery probe, every enabled region, 8 at a time (2 calls per region):
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<each-region\> rds describe-db-instances --max-records 20 --query length\(DBInstances\) --no-paginate 
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<each-region\> rds describe-db-clusters --max-records 20 --query length\(DBClusters\) --no-paginate 
  full scan, only regions where a probe found a DB instance / cluster or failed:
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<each-region\> rds describe-db-clusters 
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<each-region\> rds describe-db-instances 
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<each-region\> rds describe-pending-maintenance-actions 
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<each-region\> rds describe-db-engine-versions --engine \<engine\> --engine-version \<current\>  (once per engine+vers...
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<each-region\> rds describe-db-major-engine-versions --engine \<engine\>  (once per RDS engine+region)
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region \<each-region\> rds describe-global-clusters  (once per account, only when Aurora clusters are found)
```

### 5. Only Aurora PostgreSQL clusters that need patching

```bash
./rds_patch_compliance_report.sh -e aurora-postgresql -i '*-pg*' --non-compliant-only -F text -o '' -l ''
```

Output:

```text
2026-11-27 09:57:03 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:03 [INFO] Profile default: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:04 [INFO] [default] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:04 [INFO] [default/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:04 [WARN] [default/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:04 [INFO] [default/us-east-1] COMPLIANT=3 NON-COMPLIANT=2 UNKNOWN=1
2026-11-27 09:57:04 [INFO] [default] 0 Aurora global database(s)
RDS PATCH COMPLIANCE REPORT - 2026-11-27 04:27 UTC (2026-11-27 09:57 IST)
Accounts : 111111111111 prod-payments (default)   Regions: all enabled
Regions  : 3 checked, 1 with databases, 2 empty, 0 errors
Rule     : NON-COMPLIANT when more than 2 valid minor versions behind (same major)
Filters  : engine=aurora-postgresql; identifier=*-pg*; non-compliant only

SUMMARY
  Servers/clusters : 6   COMPLIANT 3   NON-COMPLIANT 2   UNKNOWN 1   -> 50% compliant
  Support          : 2 past standard support (Extended Support charges), 0 ending within 180 days
  Pending maint.   : on 1 server(s): os-upgrade 1, system-update 1 (2 action(s)) - see PENDING MAINTENANCE
  Global databases : 0 (0 members)
  Other flags      : auto minor upgrade off 1, current version not returned / deprecated 1

PER ENGINE / MAJOR VERSION
  ENGINE                MAJOR      TOTAL  COMPL  NON-C  UNKN  LATEST MINOR  SUPPORT
  aurora-postgresql     16             1      1      0     0  16.9          ok (standard end 2031-01-05)
  aurora-postgresql     15             2      2      0     0  15.13         ok (standard end 2030-03-11)
...
```

### 6. SQL Server (all editions) and Oracle only

```bash
./rds_patch_compliance_report.sh -e 'sqlserver-*' -e 'oracle-*' -F text -o '' -l ''
```

Output:

```text
2026-11-27 09:57:04 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:04 [INFO] Profile default: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:04 [INFO] [default] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:05 [INFO] [default/us-east-1] 1 cluster(s), 8 instance(s), 0 resource(s) with pending maintenance
2026-11-27 09:57:05 [INFO] [default/us-east-1] COMPLIANT=6
RDS PATCH COMPLIANCE REPORT - 2026-11-27 04:27 UTC (2026-11-27 09:57 IST)
Accounts : 111111111111 prod-payments (default)   Regions: all enabled
Regions  : 3 checked, 1 with databases, 2 empty, 0 errors
Rule     : NON-COMPLIANT when more than 2 valid minor versions behind (same major)
Filters  : engine=sqlserver-*,oracle-*

SUMMARY
  Servers/clusters : 6   COMPLIANT 6   NON-COMPLIANT 0   UNKNOWN 0   -> 100% compliant
  Support          : 0 past standard support (Extended Support charges), 0 ending within 180 days
  Pending maint.   : none
  Global databases : 0 (0 members)
  Other flags      : auto minor upgrade off 0, current version not returned / deprecated 0

PER ENGINE / MAJOR VERSION
  ENGINE                MAJOR      TOTAL  COMPL  NON-C  UNKN  LATEST MINOR                        SUPPORT
  oracle-ee             19             5      5      0     0  per patch line, below               unknown (AWS lists no lifecycle dates for oracle-ee 19)
        latest minor, unrecognised format: 19.0.0.0.custom-build2
        latest minor, mrp: 19.0.0.0.ru-2026-10.mrp-2026-10.r1
        latest minor, plain RU: 19.0.0.0.ru-2026-10.r1
...
```

### 7. Stricter policy: at most 1 behind, warn a year before end of standard support

```bash
./rds_patch_compliance_report.sh --max-behind 1 --warn-days 365 -F text -o '' -l ''
```

Output:

```text
2026-11-27 09:57:05 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:05 [INFO] Profile default: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:05 [INFO] [default] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:05 [INFO] [default/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:06 [WARN] [default/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:06 [INFO] [default/us-east-1] COMPLIANT=5 NON-COMPLIANT=13 UNKNOWN=1
2026-11-27 09:57:06 [INFO] [default] 0 Aurora global database(s)
RDS PATCH COMPLIANCE REPORT - 2026-11-27 04:27 UTC (2026-11-27 09:57 IST)
Accounts : 111111111111 prod-payments (default)   Regions: all enabled
Regions  : 3 checked, 1 with databases, 2 empty, 0 errors
Rule     : NON-COMPLIANT when more than 1 valid minor versions behind (same major)

SUMMARY
  Servers/clusters : 19   COMPLIANT 5   NON-COMPLIANT 13   UNKNOWN 1   -> 26.3% compliant
  Support          : 2 past standard support (Extended Support charges), 2 ending within 365 days
  Pending maint.   : on 3 server(s): os-upgrade 2, system-update 2, db-upgrade 1 (5 action(s)) - see PENDING MAINTENANCE
...
```

### 8. Gate in a pipeline / cron: exit 5 when anything is NON-COMPLIANT

```bash
./rds_patch_compliance_report.sh -P prod --all-regions --fail-on-noncompliant -F csv -o ~/reports || echo "rc=$?"
```

Output:

```text
2026-11-27 09:57:07 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:07 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:07 [INFO] [prod] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:07 [INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:07 [WARN] [prod/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:08 [INFO] [prod/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:57:08 [INFO] [prod] 0 Aurora global database(s)
2026-11-27 09:57:08 [INFO] Wrote /home/cloudshell-user/reports/rds_patch_compliance_111111111111_20261127_095707.csv
2026-11-27 09:57:08 [INFO] Wrote /home/cloudshell-user/reports/rds_patch_compliance_111111111111_20261127_095707_regions.csv
2026-11-27 09:57:08 [INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 36 AWS call(s); exit 5
rc=5
```

## Your own settings file

### 9. Copy the conf, edit it, use it (`--config`), and override one value (CLI wins)

```bash
cp rds_patch_compliance_report.conf my.conf        # edit my.conf, then:
./rds_patch_compliance_report.sh --config my.conf --max-behind 3 -F text -o '' -l ''
```

Output:

```text
cp: cannot stat 'rds_patch_compliance_report.conf': No such file or directory
2026-11-27 09:57:08 [INFO] Settings: my.conf (from --config)
2026-11-27 09:57:08 [INFO] Profile default: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:08 [INFO] [default] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:08 [INFO] [default/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:08 [WARN] [default/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:09 [INFO] [default/us-east-1] COMPLIANT=15 NON-COMPLIANT=3 UNKNOWN=1
2026-11-27 09:57:09 [INFO] [default] 0 Aurora global database(s)
RDS PATCH COMPLIANCE REPORT - 2026-11-27 04:27 UTC (2026-11-27 09:57 IST)
Accounts : 111111111111 prod-payments (default)   Regions: all enabled
Regions  : 3 checked, 1 with databases, 2 empty, 0 errors
Rule     : NON-COMPLIANT when more than 3 valid minor versions behind (same major)

SUMMARY
...
```

### 9a. A setting is missing: the run stops before any AWS call and names the key

```bash
./rds_patch_compliance_report.sh --config my.conf    # my.conf has no max_behind line
```

Output:

```text
2026-11-27 09:57:09 [ERROR] Config my.conf: missing required setting(s): max_behind (every setting must be in the conf; compare with the rds_patch_compliance_report.conf that ships with the script)
```

### 9b. Show the settings in effect and the AWS calls, without making them

```bash
./rds_patch_compliance_report.sh -P prod -r us-east-1 --dry-run
```

Output:

```text
2026-11-27 09:57:09 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
rds_patch_compliance_report.sh v1.8.0 dry run - no AWS calls are made
  profiles : prod 
  regions  : us-east-1 (queried directly, no probe)
  filters  : 
  rule     : COMPLIANT <= 2 minor version(s) behind; support warning 180d
  formats  : csv html text -> ./reports
  settings : /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf
Profile prod:
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region us-east-1 sts get-caller-identity 
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region us-east-1 iam list-account-aliases  (once per account, unless a name is set in the config; optional)
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region us-east-1 rds describe-db-clusters 
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region us-east-1 rds describe-db-instances 
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region us-east-1 rds describe-pending-maintenance-actions 
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region us-east-1 rds describe-db-engine-versions --engine \<engine\> --engine-version \<current\>  (once per engine+version+re...
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region us-east-1 rds describe-db-major-engine-versions --engine \<engine\>  (once per RDS engine+region)
    aws --output json --no-cli-pager --cli-connect-timeout 30 --cli-read-timeout 30 --profile prod --region us-east-1 rds describe-global-clusters  (once per account, only when Aurora clusters are found)
```

### 9c. Account names (v1.5.0): set them at the end of the conf, otherwise the IAM account alias is used

```bash
tail -3 rds_patch_compliance_report.conf
```

Output:

```text
## Accounts not listed show their IAM account alias, else the number.   Example: 111111111111 = prod-payments
111111111111 = prod-payments
222222222222 = nonprod-shared
```

### 9d. Account names in the JSON and CSV

```bash
./rds_patch_compliance_report.sh -P prod -F json -o '' -l '' | jq -r '.meta.accounts[] | "\(.account) \(.name)"'
```

Output:

```text
111111111111 prod-payments
```

```bash
./rds_patch_compliance_report.sh -P prod -F csv -o '' -l '' | python3 -c 'import csv,sys; [print(r["account_id"], r["account_name"], r["identifier"]) for r in csv.DictReader(sys.stdin)]'
```

Output:

```text
111111111111 prod-payments shop-aurora-mysql
111111111111 prod-payments cms-aurora-mysql
111111111111 prod-payments legacy-aurora-pg12
111111111111 prod-payments reports-aurora-pg14
111111111111 prod-payments old-aurora-pg11
...
```

## HTML e-mail alert

With `sendmail` installed the alert is an HTML e-mail with a plain-text copy, the HTML report and the per-server CSV attached (short names, `patch_compliance_YYYY-MM-DD.html` / `.csv`). With only `mail` / `mailx` the text summary alone is sent. Pick the recipients, sender and attachments in the conf (`alert_emails`, `alert_from`, `attach_html`, `attach_csv`, `attach_prefix`) or with the matching options. Screenshot: [docs/sample_alert_email.png](docs/sample_alert_email.png); samples: [html](samples/sample_alert_email.html), [text](samples/sample_alert_email.txt).

### 10. E-mail when anything is non-compliant (cron, IST); needs `alert_emails` in the conf or `--alert-email`

```bash
# 30 9 * * 1  cd ~/rds-patch-compliance && ./rds_patch_compliance_report.sh --alert-email dba-team@example.com --alert-from rds-reports@example.com
```

Output:

```text
2026-11-27 09:57:12 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:12 [INFO] Profile default: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:12 [INFO] [default] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:13 [INFO] [default/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:13 [WARN] [default/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:13 [INFO] [default/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:57:13 [INFO] [default] 0 Aurora global database(s)
2026-11-27 09:57:14 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_111111111111_20261127_095712.csv
2026-11-27 09:57:14 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_111111111111_20261127_095712_regions.csv
2026-11-27 09:57:14 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_111111111111_20261127_095712.html
2026-11-27 09:57:14 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_111111111111_20261127_095712.txt
2026-11-27 09:57:14 [INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 36 AWS call(s); exit 0
2026-11-27 09:57:14 [INFO] Alert: e-mail (NON-COMPLIANT) sent to dba-team@example.com
```

## Reading the data with jq / python

These use `-F json` or `-F csv` with `-o ''` so the data goes to stdout (the log lines go to stderr and are hidden here).

### 11. Tags (no longer shown as columns since v1.4.0) from the JSON rows

```bash
./rds_patch_compliance_report.sh -F json -o '' -l '' | jq -r '.rows[] | "\(.identifier) \(.tags.Environment // "-")"'
```

Output:

```text
shop-aurora-mysql prod
cms-aurora-mysql prod
legacy-aurora-pg12 prod
reports-aurora-pg14 prod
old-aurora-pg11 prod
crm-aurora-pg15 prod
...
```

### 12. Only the CSV columns you need

```bash
./rds_patch_compliance_report.sh -F csv -o '' -l '' | python3 -c 'import csv,sys; [print(r["identifier"], r["versions_behind"], r["compliance_status"]) for r in csv.DictReader(sys.stdin)]'
```

Output:

```text
shop-aurora-mysql 5 NON-COMPLIANT
cms-aurora-mysql 1 COMPLIANT
legacy-aurora-pg12 6 NON-COMPLIANT
reports-aurora-pg14 3 NON-COMPLIANT
old-aurora-pg11  UNKNOWN
crm-aurora-pg15 2 COMPLIANT
...
```

### 13. Non-compliant servers as JSON lines

```bash
./rds_patch_compliance_report.sh -F json -o '' -l '' | jq -c '.rows[] | select(.compliance_status == "NON-COMPLIANT") | {identifier, engine, current_version, latest_minor_version, versions_behind}'
```

Output:

```text
{"identifier":"shop-aurora-mysql","engine":"aurora-mysql","current_version":"8.0.mysql_aurora.3.05.2","latest_minor_version":"8.0.mysql_aurora.3.10.0","versions_behind":5}
{"identifier":"legacy-aurora-pg12","engine":"aurora-postgresql","current_version":"12.15","latest_minor_version":"12.22","versions_behind":6}
{"identifier":"reports-aurora-pg14","engine":"aurora-postgresql","current_version":"14.12","latest_minor_version":"14.17","versions_behind":3}
{"identifier":"inv-mysql","engine":"mysql","current_version":"8.0.36","latest_minor_version":"8.0.43","versions_behind":6}
...
```

### 14. Aurora global database members and their status (v1.4.0)

```bash
./rds_patch_compliance_report.sh -A -F json -o '' -l '' | jq -r '.summary.globals[] | "\(.global_cluster) \(.overall_status)\(if .region_status_mismatch then " (region status mismatch)" else "" end)", (.members[] | "  \(.role) \(.region) \(.identifier) \(.current_version // "-") \(.compliance_status)")'
```

Output:

```text
shop-global NON-COMPLIANT
  primary us-east-1 shop-aurora-mysql 8.0.mysql_aurora.3.05.2 NON-COMPLIANT
  secondary eu-west-1 shop-dr-mysql 8.0.mysql_aurora.3.05.2 NON-COMPLIANT
orders-global COMPLIANT
  primary us-east-1 orders-aurora-pg15 15.8 COMPLIANT
  secondary ap-northeast-1 orders-dr-tokyo - NOT SCANNED
  secondary us-west-2 orders-dr-pg15 - NOT SCANNED
```

### 15. Pending maintenance per server, readable

```bash
./rds_patch_compliance_report.sh -F json -o '' -l '' | jq -r '.rows[] | select(.pending_actions_count > 0) | "\(.identifier): \(.pending_actions)"'
```

Output:

```text
orders-aurora-pg15: system-update on cluster (auto-apply 2026-12-14, forced 2027-01-13) - Upgrade to Aurora PostgreSQL 15.8.1 patch; os-upgrade on member orders-pg15-2 (opt-in: next-maintenance) - New Operating System update is...
catalog-docdb: system-update on member catalog-docdb-2 (auto-apply 2026-12-27, forced 2027-01-26) - Upgrades to the DocumentDB engine
inv-mysql: db-upgrade (auto-apply 2026-12-07) - Automatic minor version upgrade to 8.0.40; os-upgrade (no date, optional) - New Operating System update is available; it includes sec...
```

### 16. Servers whose auto minor upgrade would move them, and to what

```bash
./rds_patch_compliance_report.sh -F json -o '' -l '' | jq -r '.rows[] | select(.default_auto_upgrade_target != null) | "\(.identifier) \(.current_version) -> \(.default_auto_upgrade_target) (auto minor upgrade: \(.auto_minor_upgrade))"'
```

Output:

```text
shop-aurora-mysql 8.0.mysql_aurora.3.05.2 -> 8.0.mysql_aurora.3.08.2 (auto minor upgrade: mixed)
reports-aurora-pg14 14.12 -> 14.15 (auto minor upgrade: false)
orders-aurora-pg15 15.8 -> 15.12 (auto minor upgrade: true)
inv-mysql 8.0.36 -> 8.0.40 (auto minor upgrade: false)
...
```

### 17. Check one server's valid minor targets yourself (the exact source the report uses)

```bash
aws rds describe-db-engine-versions --engine aurora-postgresql --engine-version 15.8 --region us-east-1 \
  --query 'DBEngineVersions[].ValidUpgradeTarget[?IsMajorVersionUpgrade==`false`].[EngineVersion,AutoUpgrade]' --output table
```

Output (this one is the AWS CLI itself, so the table is an example):

```text
-----------------------
|DescribeDBEngineVersions|
+---------+-----------+
|  15.9   |  False    |
|  15.10  |  False    |
|  15.12  |  False    |
|  15.13  |  True     |
+---------+-----------+
```

### 17a. Region-wise compliance as JSON lines, or only regions below 80 %

```bash
./rds_patch_compliance_report.sh -P prod -A -F json -o '' -l '' | jq -c '.summary.regions[] | select(.total > 0) | {account_id, region, total, compliant, non_compliant, unknown, pct_compliant}'
```

Output:

```text
{"account_id":"111111111111","region":"us-east-1","total":19,"compliant":11,"non_compliant":7,"unknown":1,"pct_compliant":57.9}
{"account_id":"111111111111","region":"us-west-2","total":1,"compliant":1,"non_compliant":0,"unknown":0,"pct_compliant":100}
```



```bash
./rds_patch_compliance_report.sh -P prod -A -F json -o '' -l '' | jq -r '.summary.regions[] | select(.pct_compliant != null and .pct_compliant < 80) | "\(.region) \(.pct_compliant)%"'
```

Output:

```text
us-east-1 57.9%
```

### 17b. Region counts (JSON keeps the full list, incl. empty regions: `.summary.region_overview.empty_regions`)

```bash
./rds_patch_compliance_report.sh -P prod -A -F json -o '' -l '' | jq '.summary.region_overview | del(.empty_regions)'
```

Output:

```text
{
  "mode": "discover",
  "probe_parallel": 8,
  "checked": 14,
  "with_databases": 2,
  "empty": 11,
  "error": 1
}
```

### 17c. Global databases with mismatched members (v1.5.1; in the HTML: tick Global or click the Global databases card)

```bash
./rds_patch_compliance_report.sh -P prod -A -F json -o '' -l '' | jq -r '.summary.globals[] | select(.version_differs or .region_status_mismatch) | "\(.global_cluster) \(.account_id) \(.overall_status) \(.versions | join(","))"'
```

Output:

```text
(no output: no global database in this sample has mismatched members)
```

## Summary script (rds_patch_compliance_summary.sh)

High-level summary plus the NON-COMPLIANT servers only (same scan and counting rules as the full report). It reads the **same** `rds_patch_compliance_report.conf` (scope, rule, e-mail and webhook settings); its file names use `<prefix>_summary`. Options override the conf. With `formats = csv,html,txt` in the conf, it writes those files into `output_dir` and prints the text summary on the screen.

### 18. Summary on the screen (txt)

```bash
./rds_patch_compliance_summary.sh -P prod,nonprod -r us-east-1,ap-south-1 -F txt -o ''
```

Output:

```text
2026-11-27 09:57:31 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:31 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:31 [INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:31 [WARN] [prod/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:32 [INFO] [prod/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:57:32 [INFO] [prod/ap-south-1] 0 cluster(s), 0 instance(s), 0 resource(s) with pending maintenance
2026-11-27 09:57:32 [INFO] [prod/ap-south-1] no matching servers
2026-11-27 09:57:32 [INFO] [prod] 0 Aurora global database(s)
2026-11-27 09:57:32 [INFO] Profile nonprod: account 222222222222 (arn:aws:iam::222222222222:user/dba)
2026-11-27 09:57:32 [INFO] [nonprod/us-east-1] 0 cluster(s), 0 instance(s), 0 resource(s) with pending maintenance
2026-11-27 09:57:33 [INFO] [nonprod/us-east-1] no matching servers
2026-11-27 09:57:33 [INFO] [nonprod/ap-south-1] 1 cluster(s), 3 instance(s), 0 resource(s) with pending maintenance
2026-11-27 09:57:33 [INFO] [nonprod/ap-south-1] COMPLIANT=2 NON-COMPLIANT=1
2026-11-27 09:57:33 [INFO] [nonprod] 0 Aurora global database(s)
2026-11-27 09:57:33 [INFO] Result: 22 server(s)/cluster(s): COMPLIANT 13, NON-COMPLIANT 8, UNKNOWN 1 (59.1% compliant); 0 error(s); 46 AWS call(s); exit 0
RDS PATCH COMPLIANCE - SUMMARY
Run      : 2026-11-27 04:27 UTC / 2026-11-27 09:57 IST
Scanned  : accounts 111111111111 (prod), 222222222222 (nonprod); regions ap-south-1, us-east-1
Rule     : NON-COMPLIANT when the current version is more than 2 valid minor versions behind the latest (3 or more); counted from RDS ValidUpgradeTarget (same major; Oracle: same patch line)

Regions  : 4 checked, 2 with databases, 2 empty, 0 errors

OVERALL  : 22 servers/clusters | COMPLIANT 13 | NON-COMPLIANT 8 | UNKNOWN 1 | 59.1% compliant
GLOBAL   : Global databases: 0 (0 members)

PER ACCOUNT
...
```

### 19. Summary as txt + one-page HTML + CSVs (non-compliant rows, summary, regions, accounts) into ~/compliance

```bash
./rds_patch_compliance_summary.sh -P prod --all-regions -F txt,html,csv -o ~/compliance
```

Output:

```text
2026-11-27 09:57:33 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:33 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:33 [INFO] [prod] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:34 [INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:34 [WARN] [prod/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:35 [INFO] [prod/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:57:35 [INFO] [prod] 0 Aurora global database(s)
2026-11-27 09:57:35 [INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 36 AWS call(s); exit 0
2026-11-27 09:57:35 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_summary_111111111111_20261127_042735.txt
2026-11-27 09:57:35 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_summary_111111111111_20261127_042735.html
2026-11-27 09:57:35 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_summary_111111111111_20261127_042735_summary.csv
2026-11-27 09:57:35 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_summary_111111111111_20261127_042735_noncompliant.csv
2026-11-27 09:57:35 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_summary_111111111111_20261127_042735_accounts.csv
2026-11-27 09:57:35 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_summary_111111111111_20261127_042735_regions.csv
RDS PATCH COMPLIANCE - SUMMARY
Run      : 2026-11-27 04:27 UTC / 2026-11-27 09:57 IST
Scanned  : accounts 111111111111 (prod); all enabled regions
Rule     : NON-COMPLIANT when the current version is more than 2 valid minor versions behind the latest (3 or more); counted from RDS ValidUpgradeTarget (same major; Oracle: same patch line)

Regions  : 3 checked, 1 with databases, 2 empty, 0 errors (discovery probe)

OVERALL  : 19 servers/clusters | COMPLIANT 11 | NON-COMPLIANT 7 | UNKNOWN 1 | 57.9% compliant
GLOBAL   : Global databases: 0 (0 members)

PER ACCOUNT
  ACCOUNT       NAME          COLLECTED              REGIONS TOTAL  COMPL  NON-C  UNKN  %COMPL  PEND
  111111111111  prod          2026-11-27 04:27 UTC         1    19     11      7     1   57.9%     3

PER REGION
  ACCOUNT       REGION           TOTAL  COMPL  NON-C  UNKN  %COMPL  PEND
  111111111111  us-east-1           19     11      7     1   57.9%     3
  ALL           All regions         19     11      7     1   57.9%     3

PER ENGINE
  ENGINE             MAJOR    TOTAL  COMPL  NON-C  UNKN   %COMPL  LATEST MINOR
  aurora-mysql       all          2      1      1     0      50%
                     8.0          2      1      1     0           8.0.mysql_aurora.3.10.0
  aurora-postgresql  all          6      3      2     1      50%
                     16           1      1      0     0           16.9
                     15           2      2      0     0           15.13
...
```

### 20. Only Oracle, stricter rule (non-compliant when 2 or more behind)

```bash
./rds_patch_compliance_summary.sh -P prod -r us-east-1 -e 'oracle-*' --max-behind 1 -F txt -o ''
```

Output:

```text
2026-11-27 09:57:35 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:35 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:35 [INFO] [prod/us-east-1] 1 cluster(s), 8 instance(s), 0 resource(s) with pending maintenance
2026-11-27 09:57:35 [INFO] [prod/us-east-1] COMPLIANT=2 NON-COMPLIANT=3
2026-11-27 09:57:36 [INFO] Result: 5 server(s)/cluster(s): COMPLIANT 2, NON-COMPLIANT 3, UNKNOWN 0 (40% compliant); 0 error(s); 10 AWS call(s); exit 0
RDS PATCH COMPLIANCE - SUMMARY
Run      : 2026-11-27 04:27 UTC / 2026-11-27 09:57 IST
Scanned  : accounts 111111111111 (prod); regions us-east-1; filters: engine=oracle-*
Rule     : NON-COMPLIANT when the current version is more than 1 valid minor versions behind the latest (2 or more); counted from RDS ValidUpgradeTarget (same major; Oracle: same patch line)

Regions  : 1 checked, 1 with databases, 0 empty, 0 errors

OVERALL  : 5 servers/clusters | COMPLIANT 2 | NON-COMPLIANT 3 | UNKNOWN 0 | 40% compliant
GLOBAL   : Global databases: 0 (0 members)

PER ACCOUNT
  ACCOUNT       NAME          COLLECTED              REGIONS TOTAL  COMPL  NON-C  UNKN  %COMPL  PEND
  111111111111  prod          2026-11-27 04:27 UTC         1     5      2      3     0     40%     0

PER REGION
  ACCOUNT       REGION           TOTAL  COMPL  NON-C  UNKN  %COMPL  PEND
  111111111111  us-east-1            5      2      3     0     40%     0
...
```

### 21. Weekly job: e-mail the team only when something is non-compliant, non-zero exit for the scheduler

```bash
./rds_patch_compliance_summary.sh -P prod --all-regions --alert-email dba-team@example.com --fail-on-noncompliant; echo "rc=$?"
```

Output:

```text
2026-11-27 09:57:36 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:36 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:36 [INFO] [prod] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:36 [INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:36 [WARN] [prod/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:37 [INFO] [prod/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:57:37 [INFO] [prod] 0 Aurora global database(s)
2026-11-27 09:57:37 [INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 36 AWS call(s); exit 0
2026-11-27 09:57:37 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_111111111111_20261127_042737_summary.csv
2026-11-27 09:57:37 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_111111111111_20261127_042737_noncompliant.csv
2026-11-27 09:57:37 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_111111111111_20261127_042737_accounts.csv
2026-11-27 09:57:37 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_111111111111_20261127_042737_regions.csv
2026-11-27 09:57:37 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_111111111111_20261127_042737.html
2026-11-27 09:57:37 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_111111111111_20261127_042737.txt
2026-11-27 09:57:37 [INFO] Summary: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); exit 5
2026-11-27 09:57:37 [INFO] Alert: e-mail (NON-COMPLIANT) sent to dba-team@example.com
rc=5
```

In examples 21 and 25 the text summary that also prints on the screen is hidden here (`>/dev/null` in the run); the log lines are on stderr.

## Summary only, several accounts: save in CloudShell, merge in Git Bash (summary v1.3.0)

A merge never scans: it ignores the conf's profiles / regions / engines / identifiers (giving them on the command line is an error), and writes files in the conf's formats unless you give `-F`.

### 22. Save the data once per account (CloudShell, read-only)

```bash
./rds_patch_compliance_summary.sh --all-regions --save-data -o data -F txt
```

Output:

```text
2026-11-27 09:57:37 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:38 [INFO] Profile default: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:38 [INFO] [default] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:38 [INFO] [default/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:38 [WARN] [default/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:39 [INFO] [default/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:57:39 [INFO] [default] 0 Aurora global database(s)
2026-11-27 09:57:39 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/data/rds_patch_111111111111_20261127.json
2026-11-27 09:57:39 [INFO] Result: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 36 AWS call(s); exit 0
2026-11-27 09:57:39 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/data/rds_patch_compliance_summary_111111111111_20261127_042739.txt
RDS PATCH COMPLIANCE - SUMMARY
Run      : 2026-11-27 04:27 UTC / 2026-11-27 09:57 IST
...
```

### 23. Merge offline (Git Bash on the laptop, 0 AWS calls); full-report `--save-data` files work too

```bash
./rds_patch_compliance_summary.sh --merge data -F txt,html,csv -o combined
```

Output:

```text
2026-11-27 09:57:41 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:41 [INFO] Input 1: data/rds_patch_111111111111_20261127.json (collected 2026-11-27T04:27:39Z, account(s) 111111111111 (prod))
2026-11-27 09:57:41 [INFO] Input 2: data/rds_patch_222222222222_20261127.json (collected 2026-11-27T04:27:40Z, account(s) 222222222222 (nonprod))
2026-11-27 09:57:41 [INFO] Merged 2 account(s) from 2 file(s): 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 0 AWS calls; exit 0
2026-11-27 09:57:42 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/combined/rds_patch_compliance_summary_20261127_042741.txt
2026-11-27 09:57:42 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/combined/rds_patch_compliance_summary_20261127_042741.html
2026-11-27 09:57:42 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/combined/rds_patch_compliance_summary_20261127_042741_summary.csv
2026-11-27 09:57:42 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/combined/rds_patch_compliance_summary_20261127_042741_noncompliant.csv
2026-11-27 09:57:42 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/combined/rds_patch_compliance_summary_20261127_042741_accounts.csv
2026-11-27 09:57:42 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/combined/rds_patch_compliance_summary_20261127_042741_regions.csv
RDS PATCH COMPLIANCE - SUMMARY
Run      : 2026-11-27 04:27 UTC / 2026-11-27 09:57 IST
Merged   : 2 file(s), offline (0 AWS calls); days counted from 2026-11-27 04:27 UTC; accounts 111111111111 (prod), 222222222222 (nonprod)
Rule     : NON-COMPLIANT when the current version is more than 2 valid minor versions behind the latest (3 or more); counted from RDS ValidUpgradeTarget (same major; Oracle: same patch line)

Regions  : 2 checked, 1 with databases, 1 empty, 0 errors (merged from saved data)

OVERALL  : 19 servers/clusters | COMPLIANT 11 | NON-COMPLIANT 7 | UNKNOWN 1 | 57.9% compliant
GLOBAL   : Global databases: 0 (0 members)

PER ACCOUNT
  ACCOUNT       NAME          COLLECTED              REGIONS TOTAL  COMPL  NON-C  UNKN  %COMPL  PEND
  111111111111  prod          2026-11-27 04:27 UTC         1    19     11      7     1   57.9%     3
  222222222222  nonprod       2026-11-27 04:27 UTC         0     0      0      0     0       -     0

PER REGION
  ACCOUNT       REGION           TOTAL  COMPL  NON-C  UNKN  %COMPL  PEND
  111111111111  us-east-1           19     11      7     1   57.9%     3
  ALL           All regions         19     11      7     1   57.9%     3

PER ENGINE
  ENGINE             MAJOR    TOTAL  COMPL  NON-C  UNKN   %COMPL  LATEST MINOR
  aurora-mysql       all          2      1      1     0      50%
                     8.0          2      1      1     0           8.0.mysql_aurora.3.10.0
  aurora-postgresql  all          6      3      2     1      50%
                     16           1      1      0     0           16.9
                     15           2      2      0     0           15.13
                     14           1      0      1     0           14.17
                     12           1      0      1     0           12.22
                     11           1      0      0     1           -
...
```

### 24. Merge with a stricter rule and a non-zero exit when anything is NON-COMPLIANT

```bash
./rds_patch_compliance_summary.sh --merge data/*.json --max-behind 1 --fail-on-noncompliant -F csv -o ~/combined; echo "rc=$?"
```

Output:

```text
2026-11-27 09:57:44 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:44 [INFO] Input 1: data/rds_patch_111111111111_20261127.json (collected 2026-11-27T04:27:42Z, account(s) 111111111111 (prod))
2026-11-27 09:57:44 [INFO] Input 2: data/rds_patch_222222222222_20261127.json (collected 2026-11-27T04:27:43Z, account(s) 222222222222 (nonprod))
2026-11-27 09:57:44 [INFO] Merged 2 account(s) from 2 file(s): 19 server(s)/cluster(s): COMPLIANT 5, NON-COMPLIANT 13, UNKNOWN 1 (26.3% compliant); 0 error(s); 0 AWS calls; exit 0
2026-11-27 09:57:44 [INFO] Wrote /home/cloudshell-user/combined/rds_patch_compliance_summary_20261127_042744_summary.csv
2026-11-27 09:57:44 [INFO] Wrote /home/cloudshell-user/combined/rds_patch_compliance_summary_20261127_042744_noncompliant.csv
2026-11-27 09:57:44 [INFO] Wrote /home/cloudshell-user/combined/rds_patch_compliance_summary_20261127_042744_accounts.csv
2026-11-27 09:57:44 [INFO] Wrote /home/cloudshell-user/combined/rds_patch_compliance_summary_20261127_042744_regions.csv
2026-11-27 09:57:44 [INFO] Merged 2 account(s) from 2 file(s), 0 AWS calls. Summary: 19 server(s)/cluster(s): COMPLIANT 5, NON-COMPLIANT 13, UNKNOWN 1 (26.3% compliant); exit 5
rc=5
```

### 25. Alert from merged data

```bash
./rds_patch_compliance_summary.sh --merge data --alert-email dba@example.com
```

Output:

```text
2026-11-27 09:57:46 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:46 [INFO] Input 1: data/rds_patch_111111111111_20261127.json (collected 2026-11-27T04:27:44Z, account(s) 111111111111 (prod))
2026-11-27 09:57:46 [INFO] Input 2: data/rds_patch_222222222222_20261127.json (collected 2026-11-27T04:27:46Z, account(s) 222222222222 (nonprod))
2026-11-27 09:57:46 [INFO] Merged 2 account(s) from 2 file(s): 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); 0 error(s); 0 AWS calls; exit 0
2026-11-27 09:57:47 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_20261127_042746_summary.csv
2026-11-27 09:57:47 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_20261127_042746_noncompliant.csv
2026-11-27 09:57:47 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_20261127_042746_accounts.csv
2026-11-27 09:57:47 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_20261127_042746_regions.csv
2026-11-27 09:57:47 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_20261127_042746.html
2026-11-27 09:57:47 [INFO] Wrote /home/cloudshell-user/rds-patch-compliance/reports/rds_patch_compliance_summary_20261127_042746.txt
2026-11-27 09:57:47 [INFO] Merged 2 account(s) from 2 file(s), 0 AWS calls. Summary: 19 server(s)/cluster(s): COMPLIANT 11, NON-COMPLIANT 7, UNKNOWN 1 (57.9% compliant); exit 0
2026-11-27 09:57:47 [INFO] Alert: e-mail (NON-COMPLIANT) sent to dba@example.com
```

## Exceptions (v1.6.0)

Approved exceptions for servers you know are non-compliant. Same shared file as rds-backup-compliance and rds-compliance-report. A matched, unexpired entry (scope `patch` or `patch,backup`) turns **NON-COMPLIANT** into **Compliant (exception)** / `COMPLIANT (EXCEPTION)`, counts as compliant in every %, and appears in the summary as `COMPLIANT N (incl. X exceptions)`. **UNKNOWN stays UNKNOWN**; the exception is still listed against that server. The HTML gets an Exception column and an Exceptions quick filter (all / exceptions only / non-exceptions / expiring soon or no longer needed / expired). Flags: **expiring soon** (14 days or less), **no longer needed** (already compliant), **exception expired**. CSV columns at the end: `exception`, `exception_reason`, `exception_expires`, `exception_flag`, `actual_status`. With no file the reports are exactly as before. Applied when the report is built (direct scan or `--merge`); `--save-data` files never change. The summary script accepts `--exceptions FILE` and passes it through to the full report.

### 1. Set up the file

```bash
cp /home/cloudshell-user/rds-patch-compliance/compliance_exceptions.conf.example \
   /home/cloudshell-user/rds-patch-compliance/compliance_exceptions.conf
vi /home/cloudshell-user/rds-patch-compliance/compliance_exceptions.conf
```

One entry per line, all five fields required (`account_id | identifier | scope | expires | reason`). Sample:

```text
# account_id | identifier         | scope        | expires    | reason
111111111111 | legacy-aurora-pg12 | patch        | 2026-12-31 | Decommission in December, CHG-1234 (owner: dba-team)
111111111111 | reports-pg         | patch,backup | 2027-03-31 | Vendor-pinned version, backups by vendor tool | INC-77
111111111111 | dev-docdb          | backup       | 2027-01-31 | Backup-only waiver (not applied by the patch tool)
```

`expires` is mandatory `YYYY-MM-DD` (UTC), last day the exception applies. `#` comments and blank lines are ignored. The real `compliance_exceptions.conf` is in `.gitignore`.

### 2. Default run (file next to the script)

If `compliance_exceptions.conf` sits next to the script it is picked up automatically:

```bash
/home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.sh -P prod --all-regions \
  -F html,csv,txt -o /home/cloudshell-user/compliance
```

Output:

```text
2026-11-27 09:57:47 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:47 [INFO] Exceptions file /home/cloudshell-user/rds-patch-compliance/compliance_exceptions.conf: 3 entries
2026-11-27 09:57:47 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:47 [INFO] [prod] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:47 [INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:47 [WARN] [prod/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:48 [INFO] [prod/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:57:48 [INFO] [prod] 0 Aurora global database(s)
2026-11-27 09:57:48 [WARN] Exception compliance_exceptions.conf:3 (111111111111 reports-pg) matched no server in this report
2026-11-27 09:57:48 [INFO] Exceptions (patch): 1 applied (counted as COMPLIANT), 0 expiring soon or no longer needed, 0 expired, 1 unmatched
2026-11-27 09:57:48 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_111111111111_20261127_095747.html
2026-11-27 09:57:48 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_111111111111_20261127_095747.csv
2026-11-27 09:57:49 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_111111111111_20261127_095747_regions.csv
2026-11-27 09:57:49 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_111111111111_20261127_095747.txt
...
```

### 3. Custom location

```bash
mkdir -p /home/cloudshell-user/configs
cp /home/cloudshell-user/rds-patch-compliance/compliance_exceptions.conf.example \
   /home/cloudshell-user/configs/compliance_exceptions.conf
# edit /home/cloudshell-user/configs/compliance_exceptions.conf, then:
/home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.sh -P prod --all-regions \
  -F html,csv,txt -o /home/cloudshell-user/compliance \
  --exceptions /home/cloudshell-user/configs/compliance_exceptions.conf
```

Output:

```text
2026-11-27 09:57:49 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:49 [INFO] Exceptions file /home/cloudshell-user/configs/compliance_exceptions.conf: 3 entries
2026-11-27 09:57:49 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:49 [INFO] [prod] discovery: probing 3 region(s), 8 at a time
2026-11-27 09:57:49 [INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
2026-11-27 09:57:49 [WARN] [prod/us-east-1] aurora-postgresql 11.9 is not returned by describe-db-engine-versions (deprecated / not offered here); its servers are UNKNOWN
2026-11-27 09:57:50 [INFO] [prod/us-east-1] COMPLIANT=11 NON-COMPLIANT=7 UNKNOWN=1
2026-11-27 09:57:50 [INFO] [prod] 0 Aurora global database(s)
2026-11-27 09:57:50 [WARN] Exception compliance_exceptions.conf:3 (111111111111 reports-pg) matched no server in this report
2026-11-27 09:57:50 [INFO] Exceptions (patch): 1 applied (counted as COMPLIANT), 0 expiring soon or no longer needed, 0 expired, 1 unmatched
2026-11-27 09:57:50 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_111111111111_20261127_095749.html
2026-11-27 09:57:50 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_111111111111_20261127_095749.csv
2026-11-27 09:57:50 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_111111111111_20261127_095749_regions.csv
2026-11-27 09:57:51 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_111111111111_20261127_095749.txt
...
```

Config file alternative: `exceptions = /home/cloudshell-user/configs/compliance_exceptions.conf` (CLI `--exceptions` wins).

### 4. Multi-account: `--save-data` then `--merge`

Exceptions are applied when the report is built. `--save-data` files are unchanged (with or without `--exceptions`).

```bash
# CloudShell, once per account (read-only) -> rds_patch_<ACCOUNT>_<YYYYMMDD>.json
/home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.sh --all-regions --save-data \
  -o /home/cloudshell-user/data

# Offline merge: exceptions applied here
/home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.sh \
  --merge /home/cloudshell-user/data -F html,csv,txt -o /home/cloudshell-user/compliance \
  --exceptions /home/cloudshell-user/configs/compliance_exceptions.conf
```

Output:

```text
2026-11-27 09:57:53 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:53 [INFO] Exceptions file /home/cloudshell-user/configs/compliance_exceptions.conf: 3 entries
2026-11-27 09:57:53 [INFO] Input 1: data/rds_patch_111111111111_20261127.json (collected 2026-11-27T04:27:51Z, account(s) 111111111111 (prod))
2026-11-27 09:57:53 [INFO] Input 2: data/rds_patch_222222222222_20261127.json (collected 2026-11-27T04:27:52Z, account(s) 222222222222 (nonprod))
2026-11-27 09:57:53 [WARN] Exception compliance_exceptions.conf:3 (111111111111 reports-pg) matched no server in this report
2026-11-27 09:57:53 [INFO] Exceptions (patch): 1 applied (counted as COMPLIANT), 0 expiring soon or no longer needed, 0 expired, 1 unmatched
2026-11-27 09:57:53 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_20261127_095753.html
2026-11-27 09:57:53 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_20261127_095753.csv
2026-11-27 09:57:53 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_20261127_095753_regions.csv
2026-11-27 09:57:53 [INFO] Wrote /home/cloudshell-user/compliance/rds_patch_compliance_20261127_095753.txt
2026-11-27 09:57:53 [INFO] Merged 2 account(s) from 2 file(s): 19 server(s)/cluster(s): COMPLIANT 12, NON-COMPLIANT 6, UNKNOWN 1 (63.2% compliant); 0 error(s); 0 AWS calls; exit 0
```

### 5. Validation error (run stops, exit 1, before any AWS call)

A missing field, a bad account / scope / date, or a duplicate account + identifier for the same scope stops the run with `file:line`. Real captured output:

Invalid date (2026 is not a leap year):

```text
2026-11-09 16:08:06 [ERROR] Exceptions /home/cloudshell-user/rds-patch-compliance/compliance_exceptions.conf:3: expires '2026-02-29' is not a valid date
```

Duplicate (case-insensitive identifier; `patch,backup` collides with an existing `patch` row):

```text
2026-11-09 16:08:06 [ERROR] Exceptions /home/cloudshell-user/rds-patch-compliance/compliance_exceptions.conf:3: duplicate entry for 111111111111 Good-DB (patch), already on line 2
```

Fix: correct the date to a real `YYYY-MM-DD`, or remove / change the duplicate line so each account + identifier appears at most once per scope (`patch` and `backup` may both be listed, either as two lines or as `patch,backup`).

### 6. Turning exceptions off

```bash
# rename (keep for later)
mv /home/cloudshell-user/rds-patch-compliance/compliance_exceptions.conf \
   /home/cloudshell-user/rds-patch-compliance/compliance_exceptions.conf.off

# or remove
rm /home/cloudshell-user/rds-patch-compliance/compliance_exceptions.conf
```

With no file (and no `--exceptions`), the report matches the pre-exceptions behaviour. A normal run then has no exceptions lines in its output:

Output:

```text
2026-11-27 09:57:53 [INFO] Settings: /home/cloudshell-user/rds-patch-compliance/rds_patch_compliance_report.conf (loaded automatically from the script folder)
2026-11-27 09:57:53 [INFO] Profile prod: account 111111111111 (arn:aws:iam::111111111111:user/dba)
2026-11-27 09:57:53 [INFO] [prod/us-east-1] 11 cluster(s), 29 instance(s), 4 resource(s) with pending maintenance
...
```

