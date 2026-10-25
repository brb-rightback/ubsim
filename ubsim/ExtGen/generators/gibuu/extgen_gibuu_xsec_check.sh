#!/bin/bash
#
# Validation V4 (in every job): the cross section GiBUU actually had while
# serving (mean trial weight, from trial_stats.txt) against the cross-section
# table the splines were made from (extgen_gibuu_tables.py --xsec).
#
# Usage:
#   extgen_gibuu_xsec_check.sh -t trial_stats.txt -x XSEC_TABLE -o REPORT
#                              [-w WARN_PULL] [-f FAIL_PULL] [--allow-missing]
#
# Per channel (target, nu, CC/NC), in total and in energy bands, it adds up
#   obs = sum over requests of sum_w           (sum of trial weights)
#   exp = sum over requests of n_trials x sigma_table(E)
# (sigma_table linearly interpolated, zero outside the table) and writes
#   pull = (obs - exp) / sqrt(var_obs + exp_err^2)
# var_obs from sum_w2 per request; exp_err adds the table's rel_err linearly
# (conservative: neighbouring requests share table points).
# Report lines (summed over jobs by extgen_gibuu_v4_summary.py):
#   tgt nu ccnc band n_req n_trials obs exp var_obs exp_err ratio pull flag
# flag: ok, WARN (|pull| > WARN_PULL, default 4), FAIL (|pull| > FAIL_PULL,
# default 8, in a channel total), MISSING (channel not in the table).
# Exit code 1 on FAIL, or on MISSING without --allow-missing.

set -euo pipefail

die() { echo "extgen_gibuu_xsec_check.sh: ERROR: $*" >&2; exit 2; }

TS= XS= OUT= WARN=4 FAIL=8 ALLOW_MISSING=0
while [ $# -gt 0 ]; do
  case $1 in
    -t) TS=$2; shift 2 ;;
    -x) XS=$2; shift 2 ;;
    -o) OUT=$2; shift 2 ;;
    -w) WARN=$2; shift 2 ;;
    -f) FAIL=$2; shift 2 ;;
    --allow-missing) ALLOW_MISSING=1; shift ;;
    *) die "bad option $1 (see the header of this script)" ;;
  esac
done
[ -n "$TS" ] && [ -n "$XS" ] && [ -n "$OUT" ] || die "give -t, -x and -o"
[ -f "$TS" ] || die "$TS not found"
[ -f "$XS" ] || die "$XS not found"
# an empty table would make awk read trial_stats as the table (FNR == NR)
awk '!/^#/ && NF >= 5 { n++ } END { exit !n }' "$XS" || die "$XS has no table rows"

status=0
awk -v warn="$WARN" -v fail="$FAIL" -v allow="$ALLOW_MISSING" \
    -v tsname="$TS" -v xsname="$XS" '
  function band(E) {
    if (E < 0.5) return "0-0.5"
    if (E < 1)   return "0.5-1"
    if (E < 2)   return "1-2"
    if (E < 4)   return "2-4"
    return "4-8+"
  }
  # sigma and rel_err at E for channel c, linear between table points
  function interp(c, E,    i, n, f) {
    n = np[c]
    if (E < te[c, 1] || E > te[c, n]) { ir = 0; return 0 }
    for (i = 1; i < n && te[c, i + 1] < E; i++) ;
    if (i == n) { ir = tr[c, n]; return ts[c, n] }
    f = (E - te[c, i]) / (te[c, i + 1] - te[c, i])
    ir = (1 - f) * tr[c, i] + f * tr[c, i + 1]
    return (1 - f) * ts[c, i] + f * ts[c, i + 1]
  }
  function add(k, n, sw, sw2, ex, exe) {
    if (!(k in nreq)) { keys[++nk] = k }
    nreq[k]++; ntr[k] += n; obs[k] += sw; expv[k] += ex; experr[k] += exe
    if (n > 1) var[k] += (sw2 - sw * sw / n) * n / (n - 1)
  }
  FNR == NR {  # table: nu cur tgt E sigma # rel_err n  (sorted by E per channel)
    if ($0 ~ /^#/ || NF < 5) next
    c = $3 " " $1 " " $2
    np[c]++; te[c, np[c]] = $4 + 0; ts[c, np[c]] = $5 + 0
    tr[c, np[c]] = ($6 == "#" && NF >= 7) ? $7 + 0 : 0
    next
  }
  /^#/ || NF < 10 { next }
  {  # trial_stats: req_id tgt nu ccnc E n sum_w sum_w2 max_w n_dropped
    c = $2 " " $3 " " $4
    if (!(c in np)) { missing[c]++; add(c " all", $6, $7, $8, 0, 0); next }
    s = interp(c, $5 + 0)
    ex = $6 * s; exe = ex * ir
    add(c " all", $6, $7, $8, ex, exe)
    add(c " " band($5 + 0), $6, $7, $8, ex, exe)
  }
  END {
    print "# extgen-xsec-check v1 trial_stats=" tsname " table=" xsname
    print "# tgt nu ccnc band n_req n_trials obs exp var_obs exp_err ratio pull flag   (w: 1e-38 cm^2 per nucleus)"
    bad = 0
    for (j = 1; j <= nk; j++) {
      k = keys[j]; split(k, p, " "); c = p[1] " " p[2] " " p[3]
      if (c in missing) {
        flag = "MISSING"; ratio = "nan"; pull = "nan"
        if (!allow) bad = 1
      } else {
        d = var[k] + experr[k] ^ 2
        ratio = (expv[k] > 0) ? sprintf("%.4f", obs[k] / expv[k]) : "nan"
        pv = (d > 0) ? (obs[k] - expv[k]) / sqrt(d) : 0
        pull = sprintf("%+.2f", pv)
        flag = "ok"
        if (pv > warn || pv < -warn) flag = "WARN"
        if (p[4] == "all" && (pv > fail || pv < -fail)) { flag = "FAIL"; bad = 1 }
      }
      printf "%s %s %d %d %.10g %.10g %.10g %.10g %s %s %s\n", c, p[4], nreq[k], ntr[k],
             obs[k], expv[k], var[k], experr[k], ratio, pull, flag
    }
    exit bad
  }' "$XS" "$TS" > "$OUT" || status=$?

[ "$status" -le 1 ] && grep -q "^# extgen-xsec-check v1" "$OUT" || die "awk failed"
grep -v '^#' "$OUT" | awk '$4 == "all" { printf "extgen_gibuu_xsec_check.sh: %s %s %s: %d requests, obs/exp %s, pull %s %s\n", $1, $2, $3, $5, $11, $12, $13 }'
exit "$status"
