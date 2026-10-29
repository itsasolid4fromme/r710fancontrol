#!/usr/bin/env bash
# r710-fan: fan control for a Dell PowerEdge R710 (iDRAC6) over IPMI-over-LAN.
#
#   r710-fan daemon          run the control loop (the container's default command)
#   r710-fan status          show temperatures, fan RPMs, override and last decision
#   r710-fan set <percent>   hold a fixed fan speed (the heat failsafe stays active)
#   r710-fan curve           follow FAN_CURVE again (the default behaviour)
#   r710-fan auto            hand fan control back to the iDRAC (Dell automatic)
#   r710-fan test            check that the iDRAC answers and accepts fan commands
#
# Each check also writes $STATE_DIR/status.json and appends to $STATE_DIR/history.csv
# for the web page (web/server.py). The page sets a mode by writing $STATE_DIR/override,
# which this loop notices within a second.
#
# Dell raw IPMI commands used (iDRAC6/7/8, and iDRAC9 before firmware 3.34.34.34):
#   raw 0x30 0x30 0x01 0x00          manual fan control on
#   raw 0x30 0x30 0x01 0x01          back to Dell automatic control
#   raw 0x30 0x30 0x02 0xff <hex%>   set every fan to <hex%> duty cycle
#
# The R710 reports CPU temperature as a PECI value: a negative number of degrees
# below the CPU's throttle point (for example -46 means 46C of headroom). It does
# not report absolute CPU temperatures, so the fan curve follows the front inlet
# "Ambient Temp" sensor and the CPU headroom is used as a failsafe.
set -uo pipefail

: "${IDRAC_HOST:=}"
: "${IDRAC_USER:=root}"
: "${IDRAC_PASSWORD:=}"
: "${IPMI_CIPHER:=3}"              # iDRAC6 does not support ipmitool's newer default, suite 17
: "${CHECK_INTERVAL:=30}"          # seconds between checks
: "${FAN_CURVE:=20:12 24:15 27:20 30:30 33:45}"   # "ambientC:percent" points, linear between them
: "${POWER_CURVE:=}"               # optional "watts:percent" points; fans run at the higher of the two curves
: "${MIN_FAN:=10}"                 # never go below this percent
: "${MAX_FAN:=100}"
: "${AMBIENT_AUTO_C:=35}"          # inlet temp at which control goes back to Dell
: "${CPU_MARGIN_AUTO_C:=20}"       # CPU headroom (C below throttle) at which control goes back to Dell
: "${CPU_TEMP_AUTO_C:=80}"         # used only if the iDRAC reports absolute CPU temps instead
: "${FAN_FAIL_RPM:=1000}"          # any fan below this RPM -> back to Dell (iDRAC6 alarms at 720)
: "${POWER_AUTO_W:=0}"             # system power draw at which control goes back to Dell; 0 = off
: "${POWER_HYSTERESIS_W:=20}"      # watts the draw must drop before manual control resumes
: "${HYSTERESIS_C:=3}"             # degrees the temps must drop before manual control resumes
: "${MAX_FAILURES:=3}"             # consecutive failed reads before shouting about it
: "${HEARTBEAT_CYCLES:=20}"        # log a status line at least this often
: "${MONITOR_ONLY:=false}"         # true = read and log only, never change the fans
: "${HISTORY_DAYS:=7}"             # days of readings kept in state/history.csv for the web page
: "${STATE_DIR:=/state}"
: "${IPMITOOL:=ipmitool}"

OVERRIDE_FILE="$STATE_DIR/override"
STATUS_FILE="$STATE_DIR/last-status"
STATUS_JSON="$STATE_DIR/status.json"
HISTORY_FILE="$STATE_DIR/history.csv"
PID_FILE="${PID_FILE:-/tmp/r710-fan.pid}"
NL=$'\n'
FAN_ADDR="all"      # becomes "individual" if the iDRAC refuses the 0xff all-fans address
FAN_IDS=""
SDR_ERR=""
FIRMWARE=""
AMBIENT=""
CPU_READINGS=""
FAN_RPMS=""
FAN_JSON="[]"
MIN_RPM=""
AVG_RPM=""
POWER_W=""

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }
is_true() { case "$1" in [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1|[Oo][Nn]) return 0 ;; *) return 1 ;; esac; }
is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }
last_line() { printf '%s' "${1##*$NL}"; }

check_config() {
  [ -n "$IDRAC_HOST" ] || die "IDRAC_HOST is not set"
  [ -n "$IDRAC_PASSWORD" ] || die "IDRAC_PASSWORD is not set"
  local v p
  for v in CHECK_INTERVAL MIN_FAN MAX_FAN AMBIENT_AUTO_C CPU_MARGIN_AUTO_C CPU_TEMP_AUTO_C FAN_FAIL_RPM \
           POWER_AUTO_W POWER_HYSTERESIS_W HYSTERESIS_C MAX_FAILURES HEARTBEAT_CYCLES IPMI_CIPHER HISTORY_DAYS; do
    is_int "${!v}" || die "$v must be a whole number, got '${!v}'"
  done
  (( CHECK_INTERVAL >= 1 )) || die "CHECK_INTERVAL must be at least 1"
  (( MIN_FAN >= 1 && MAX_FAN <= 100 && MIN_FAN <= MAX_FAN )) || die "need 1 <= MIN_FAN <= MAX_FAN <= 100"
  (( HEARTBEAT_CYCLES >= 1 && MAX_FAILURES >= 1 )) || die "HEARTBEAT_CYCLES and MAX_FAILURES must be at least 1"
  [ -n "${FAN_CURVE// /}" ] || die "FAN_CURVE is empty"
  for p in $FAN_CURVE; do
    [[ "$p" =~ ^[0-9]+:[0-9]+$ ]] || die "FAN_CURVE point '$p' is not tempC:percent"
  done
  for p in $POWER_CURVE; do
    [[ "$p" =~ ^[0-9]+:[0-9]+$ ]] || die "POWER_CURVE point '$p' is not watts:percent"
  done
}

ipmi() {
  IPMI_PASSWORD="$IDRAC_PASSWORD" "$IPMITOOL" -I lanplus -C "$IPMI_CIPHER" \
    -H "$IDRAC_HOST" -U "$IDRAC_USER" -E -N 3 -R 2 "$@"
}

# Fills AMBIENT, CPU_READINGS, FAN_RPMS, MIN_RPM and POWER_W from one read of the
# iDRAC's sensor records. Output is captured, never piped: a reader that exits early
# would kill ipmitool mid-session and leak one of the iDRAC6's few IPMI sessions.
read_sensors() {
  local sdr
  if ! sdr=$(ipmi sdr elist full 2>&1); then SDR_ERR=$sdr; return 1; fi
  AMBIENT=$(awk -F'|' 'tolower($1) ~ /ambient|inlet/ && $5 ~ /degrees C/ {
              v=$5; gsub(/[^0-9.-]/, "", v); printf "%d", v; exit }' <<<"$sdr")
  CPU_READINGS=$(awk -F'|' '{ e=$4; gsub(/ /, "", e) }
              e ~ /^3\./ && $5 ~ /degrees C/ { v=$5; gsub(/[^0-9.-]/, "", v); printf "%d ", v }' <<<"$sdr")
  CPU_READINGS=${CPU_READINGS% }
  FAN_RPMS=$(awk -F'|' '$5 ~ /RPM/ { n=$1; gsub(/^ +| +$/, "", n); sub(/ RPM$/, "", n)
              v=$5; gsub(/[^0-9]/, "", v); printf "%s%s:%s", sep, n, v; sep=", " }' <<<"$sdr")
  MIN_RPM=$(awk -F'|' '$5 ~ /RPM/ { v=$5; gsub(/[^0-9]/, "", v); v+=0; if (m == "" || v < m) m=v }
              END { if (m != "") print m }' <<<"$sdr")
  AVG_RPM=$(awk -F'|' '$5 ~ /RPM/ { v=$5; gsub(/[^0-9]/, "", v); s+=v; n++ }
              END { if (n) printf "%d", s / n + 0.5 }' <<<"$sdr")
  FAN_JSON=$(awk -F'|' '$5 ~ /RPM/ { n=$1; gsub(/^ +| +$/, "", n); sub(/ RPM$/, "", n); gsub(/[^A-Za-z0-9 _.-]/, "", n)
              v=$5; gsub(/[^0-9]/, "", v); printf "%s{\"name\":\"%s\",\"rpm\":%d}", sep, n, v; sep="," }' <<<"$sdr")
  FAN_JSON="[$FAN_JSON]"
  POWER_W=$(awk -F'|' 'tolower($1) ~ /system level|pwr consumption/ && $5 ~ /Watts/ {
              v=$5; gsub(/[^0-9.]/, "", v); printf "%d", v; exit }' <<<"$sdr")
  [ -n "$FAN_RPMS" ] || { SDR_ERR="no fan readings in the sensor list"; return 1; }
  return 0
}

# curve_pct <value> [curve]: linear interpolation over "x:percent" points (default FAN_CURVE).
curve_pct() {
  awk -v t="$1" -v c="${2:-$FAN_CURVE}" 'BEGIN {
    n = split(c, p, " ")
    for (i = 1; i <= n; i++) { split(p[i], kv, ":"); T[i] = kv[1] + 0; P[i] = kv[2] + 0 }
    if (t <= T[1]) { print P[1]; exit }
    if (t >= T[n]) { print P[n]; exit }
    for (i = 1; i < n; i++)
      if (t >= T[i] && t <= T[i+1]) {
        if (T[i+1] == T[i]) { print P[i+1]; exit }
        printf "%d\n", P[i] + (P[i+1] - P[i]) * (t - T[i]) / (T[i+1] - T[i]) + 0.5; exit
      }
    print P[n]
  }'
}

set_auto() { ipmi raw 0x30 0x30 0x01 0x01 >/dev/null 2>&1; }

set_manual() {
  local hex out id ok=0
  hex=$(printf '0x%02x' "$1")
  if ! out=$(ipmi raw 0x30 0x30 0x01 0x00 2>&1); then log "manual-mode command failed: $(last_line "$out")"; return 1; fi
  if [ "$FAN_ADDR" = all ]; then
    out=$(ipmi raw 0x30 0x30 0x02 0xff "$hex" 2>&1) && return 0
    if [[ "$out" == *"rsp=0xcc"* ]]; then
      log "iDRAC refused the all-fans address 0xff; probing fans one at a time"
      FAN_ADDR=individual
      for id in 0x00 0x01 0x02 0x03 0x04 0x05 0x06 0x07; do
        ipmi raw 0x30 0x30 0x02 "$id" "$hex" >/dev/null 2>&1 && FAN_IDS+="$id "
      done
      if [ -z "$FAN_IDS" ]; then log "no fan address accepted the speed command"; FAN_ADDR=all; return 1; fi
      log "per-fan addresses accepted: $FAN_IDS"
      return 0
    fi
    log "fan speed command failed: $(last_line "$out")"
    return 1
  fi
  for id in $FAN_IDS; do ipmi raw 0x30 0x30 0x02 "$id" "$hex" >/dev/null 2>&1 && ok=1; done
  if (( ! ok )); then log "per-fan speed commands all failed"; return 1; fi
  return 0
}

read_override() {
  local o=""
  [ -f "$OVERRIDE_FILE" ] && o=$(tr -d '[:space:]' < "$OVERRIDE_FILE")
  printf '%s' "$o"
}

json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\t'/ }; s=${s//$'\r'/}; s=${s//$NL/ }
  printf '"%s"' "$s"
}
json_num() { if [[ "$1" =~ ^-?[0-9]+$ ]]; then printf '%s' "$1"; else printf 'null'; fi; }
json_bool() { if is_true "$1"; then printf 'true'; else printf 'false'; fi; }

# write_status <mode> <target percent, empty for Dell auto> <detail>
# mode is one of curve, fixed, auto, failsafe, error. Read by the web page.
write_status() {
  local tmp="$STATUS_JSON.tmp" cpu="" v
  for v in $CPU_READINGS; do cpu+="${cpu:+,}$v"; done
  {
    printf '{"time":%s,"mode":%s,"target":%s,"detail":%s,' \
      "$(date +%s)" "$(json_str "$1")" "$(json_num "$2")" "$(json_str "$3")"
    printf '"ambient":%s,"power":%s,"cpu":[%s],"fans":%s,"avg_rpm":%s,"min_rpm":%s,' \
      "$(json_num "$AMBIENT")" "$(json_num "$POWER_W")" "$cpu" "$FAN_JSON" "$(json_num "$AVG_RPM")" "$(json_num "$MIN_RPM")"
    printf '"override":%s,"monitor_only":%s,"interval":%s,"idrac":%s,"firmware":%s,' \
      "$(json_str "$(read_override)")" "$(json_bool "$MONITOR_ONLY")" "$CHECK_INTERVAL" "$(json_str "$IDRAC_HOST")" "$(json_str "$FIRMWARE")"
    printf '"config":{"min_fan":%s,"max_fan":%s,"fan_curve":%s,"power_curve":%s,"ambient_auto_c":%s,"power_auto_w":%s,"fan_fail_rpm":%s}}\n' \
      "$MIN_FAN" "$MAX_FAN" "$(json_str "$FAN_CURVE")" "$(json_str "$POWER_CURVE")" "$AMBIENT_AUTO_C" "$POWER_AUTO_W" "$FAN_FAIL_RPM"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS_JSON" 2>/dev/null
}

# append_history <mode> <target>: one CSV row per check, trimmed to HISTORY_DAYS.
append_history() {
  local max n
  printf '%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s)" "$AMBIENT" "$POWER_W" "$AVG_RPM" "$MIN_RPM" "$2" "$1" \
    >> "$HISTORY_FILE" 2>/dev/null || return 0
  max=${HISTORY_ROWS:-$(( HISTORY_DAYS * 86400 / CHECK_INTERVAL ))}
  n=$(wc -l < "$HISTORY_FILE")
  if (( n > max + max / 10 )); then
    tail -n "$max" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv -f "$HISTORY_FILE.tmp" "$HISTORY_FILE"
  fi
}

# Sleeps CHECK_INTERVAL seconds, but returns early when fanctl sends USR1 (POKED) or
# when the override file no longer matches what the last check used (the web page
# writes it from another container, so it cannot signal). Changes apply within a second.
# After the fan speed changes (QUICK_RECHECK), the next check comes after at most 10s,
# so the page shows the new RPM once the fans have settled instead of a full interval later.
POKED=0
LAST_OVERRIDE=""
QUICK_RECHECK=0
wait_next() {
  local start=$SECONDS sleeper limit=$CHECK_INTERVAL
  if (( QUICK_RECHECK && limit > 10 )); then limit=10; fi
  QUICK_RECHECK=0
  while (( SECONDS - start < limit )); do
    if (( POKED )) || [ "$(read_override)" != "$LAST_OVERRIDE" ]; then
      POKED=0
      return 0
    fi
    sleep 1 &
    sleeper=$!
    wait "$sleeper" 2>/dev/null
    kill "$sleeper" 2>/dev/null
  done
  POKED=0
  return 0
}

on_stop() {
  log "stopping"
  if ! is_true "$MONITOR_ONLY"; then
    if set_auto; then log "fans handed back to Dell automatic control"
    else log "WARNING: could not restore Dell automatic control"; fi
  fi
  rm -f "$PID_FILE"
  exit 0
}

daemon() {
  # Not configured yet: idle instead of exiting, so Docker does not restart-loop the container.
  if [ -z "$IDRAC_HOST" ] || [ -z "$IDRAC_PASSWORD" ]; then
    log "waiting for configuration: set IDRAC_HOST and IDRAC_PASSWORD in .env, then run: sudo docker compose up -d"
    trap 'log "stopping"; exit 0' TERM INT
    while :; do sleep 3600 & wait $!; done
  fi
  check_config
  mkdir -p "$STATE_DIR"
  echo $$ > "$PID_FILE"
  local monitor=false
  is_true "$MONITOR_ONLY" && monitor=true
  # docker stop sends TERM: always hand the fans back to Dell before exiting.
  trap on_stop TERM INT
  trap 'POKED=1' USR1   # sent by the set/curve/auto commands to apply a change right away

  log "r710-fan starting: iDRAC $IDRAC_HOST user $IDRAC_USER cipher $IPMI_CIPHER, every ${CHECK_INTERVAL}s"
  log "curve '$FAN_CURVE' clamp ${MIN_FAN}-${MAX_FAN}%; Dell takes over at ambient ${AMBIENT_AUTO_C}C, CPU headroom ${CPU_MARGIN_AUTO_C}C, fan below ${FAN_FAIL_RPM} RPM, power $( (( POWER_AUTO_W > 0 )) && echo "${POWER_AUTO_W}W" || echo "check off")"
  if $monitor; then log "MONITOR_ONLY is on: fan speeds will be logged, never changed"; fi
  local mc
  mc=$(ipmi mc info 2>/dev/null)
  FIRMWARE=$(awk -F': ' '/Firmware Revision/ { print $2 }' <<<"$mc")
  if [ -n "$FIRMWARE" ]; then log "iDRAC firmware $FIRMWARE"; fi

  local heat=0 fails=0 applied="" prev_applied="" cycles=0 warned_cpu=0
  local reason want source lim_amb lim_margin lim_cpu lim_power v override label line
  local st_mode st_target st_detail
  while :; do
    cycles=$((cycles + 1))
    if ! read_sensors; then
      fails=$((fails + 1))
      log "sensor read failed ($fails/$MAX_FAILURES): $(last_line "$SDR_ERR")"
      if (( fails == MAX_FAILURES )); then
        log "WARNING: iDRAC not answering. Fans stay at their last setting until it does; trying to restore Dell control"
      fi
      # Keep trying every cycle: a sensor read can fail while commands still get through.
      if (( fails >= MAX_FAILURES )) && ! $monitor && [ "$applied" != auto ]; then
        if set_auto; then applied=auto; log "Dell automatic control restored while sensors are unreadable"; fi
      fi
      AMBIENT="" POWER_W="" CPU_READINGS="" FAN_RPMS="" FAN_JSON="[]" MIN_RPM="" AVG_RPM=""
      LAST_OVERRIDE=$(read_override)
      write_status error "" "iDRAC not answering: $(last_line "$SDR_ERR")"
      append_history error ""
    else
      fails=0
      reason="" want="" source=""
      lim_amb=$AMBIENT_AUTO_C lim_margin=$CPU_MARGIN_AUTO_C lim_cpu=$CPU_TEMP_AUTO_C
      if (( heat )); then
        lim_amb=$((AMBIENT_AUTO_C - HYSTERESIS_C))
        lim_margin=$((CPU_MARGIN_AUTO_C + HYSTERESIS_C))
        lim_cpu=$((CPU_TEMP_AUTO_C - HYSTERESIS_C))
      fi
      if [ -z "$AMBIENT" ]; then
        reason="no ambient temperature reading"
      elif (( AMBIENT >= lim_amb )); then
        reason="ambient ${AMBIENT}C is at or above ${lim_amb}C"
      fi
      if [ -z "$CPU_READINGS" ] && (( ! warned_cpu )); then
        log "note: iDRAC reports no CPU temperature; relying on inlet temperature, power draw and fan checks"
        warned_cpu=1
      fi
      for v in $CPU_READINGS; do
        if (( v < 0 && -v <= lim_margin )); then
          reason="${reason:+$reason; }CPU only $((-v))C below its throttle point"
        elif (( v > 0 && v >= lim_cpu )); then
          reason="${reason:+$reason; }CPU at ${v}C"
        fi
      done
      if [ -n "$MIN_RPM" ] && (( MIN_RPM < FAN_FAIL_RPM )); then
        reason="${reason:+$reason; }a fan reads ${MIN_RPM} RPM"
      fi
      if (( POWER_AUTO_W > 0 )) && [ -n "$POWER_W" ]; then
        lim_power=$POWER_AUTO_W
        (( heat )) && lim_power=$((POWER_AUTO_W - POWER_HYSTERESIS_W))
        if (( POWER_W >= lim_power )); then
          reason="${reason:+$reason; }power draw ${POWER_W}W is at or above ${lim_power}W"
        fi
      fi

      override=$(read_override)
      LAST_OVERRIDE=$override
      if [ -n "$reason" ]; then
        heat=1; want=auto; source="failsafe: $reason"
        st_mode=failsafe; st_detail=$reason
      else
        heat=0
        if [ "$override" = auto ]; then
          want=auto; source="override"; st_mode=auto; st_detail="Dell automatic, chosen by hand"
        elif is_int "$override"; then
          want=$override; source="fixed override"; st_mode=fixed; st_detail="fixed speed"
        else
          want=$(curve_pct "$AMBIENT"); source="curve"; st_mode=curve; st_detail="inlet temperature curve"
          if [ -n "${POWER_CURVE// /}" ] && [ -n "$POWER_W" ]; then
            v=$(curve_pct "$POWER_W" "$POWER_CURVE")
            if (( v > want )); then want=$v; source="power curve"; st_detail="power draw curve"; fi
          fi
        fi
        if [ "$want" != auto ]; then
          (( want < MIN_FAN )) && want=$MIN_FAN
          (( want > MAX_FAN )) && want=$MAX_FAN
        fi
      fi
      st_target=$want
      [ "$want" = auto ] && st_target=""

      if [ "$want" = auto ]; then label="Dell auto"; else label="${want}%"; fi
      line="ambient=${AMBIENT:-?}C cpu=[${CPU_READINGS:-n/a}] power=${POWER_W:-?}W fans=[${FAN_RPMS}] -> ${label} (${source})"
      printf '%s %s\n' "$(date '+%F %T')" "$line" > "$STATUS_FILE" 2>/dev/null

      prev_applied=$applied
      if $monitor; then
        if (( cycles == 1 || cycles % HEARTBEAT_CYCLES == 0 )) || [ "$applied" != "$want" ]; then
          log "[monitor] $line"
        fi
        applied=$want
      elif [ "$want" = auto ]; then
        if [ "$applied" != auto ]; then
          if set_auto; then applied=auto; log "$line"; else log "could not restore Dell automatic control"; fi
        elif (( cycles % HEARTBEAT_CYCLES == 0 )); then
          log "$line"
        fi
      else
        if set_manual "$want"; then
          if [ "$applied" != "$want" ] || (( cycles % HEARTBEAT_CYCLES == 0 )); then log "$line"; fi
          applied=$want
        else
          log "manual control failed; handing fans back to Dell"
          if set_auto; then applied=auto; fi
          st_mode=failsafe; st_target=""; st_detail="the iDRAC rejected the fan command"
        fi
      fi
      write_status "$st_mode" "$st_target" "$st_detail"
      append_history "$st_mode" "$st_target"
      if [ "$applied" != "$prev_applied" ] && ! $monitor; then QUICK_RECHECK=1; fi
    fi
    wait_next
  done
}

poke_daemon() {
  local pid=""
  pid=$(cat "$PID_FILE" 2>/dev/null) || true
  if [ -n "$pid" ] && kill -USR1 "$pid" 2>/dev/null; then echo "applied; watch it with: docker logs -f r710-fan"
  else echo "saved; the daemon is not running here, so it applies on the next start"; fi
}

cmd=${1:-daemon}
case "$cmd" in
  daemon) daemon ;;
  status)
    check_config
    out=$(ipmi sdr elist full 2>&1) || { echo "FAILED: $out" >&2; exit 1; }
    echo "== sensors"; awk -F'|' '$5 !~ /Disabled|No Reading/' <<<"$out"
    o=$(read_override); echo "== override: ${o:-none (following FAN_CURVE)}"
    if [ -f "$STATUS_FILE" ]; then echo "== last decision"; cat "$STATUS_FILE"; fi
    ;;
  set)
    p=${2:-}
    is_int "$p" || { echo "usage: r710-fan set <percent>" >&2; exit 2; }
    (( p >= MIN_FAN && p <= MAX_FAN )) || { echo "percent must be between $MIN_FAN and $MAX_FAN" >&2; exit 2; }
    mkdir -p "$STATE_DIR"; echo "$p" > "$OVERRIDE_FILE"
    echo "fixed fan speed ${p}% (failsafe still active)"; poke_daemon ;;
  curve) rm -f "$OVERRIDE_FILE"; echo "following FAN_CURVE"; poke_daemon ;;
  auto)  mkdir -p "$STATE_DIR"; echo auto > "$OVERRIDE_FILE"; echo "Dell automatic control"; poke_daemon ;;
  test)
    check_config
    echo "connecting to $IDRAC_HOST as $IDRAC_USER with cipher suite $IPMI_CIPHER..."
    if ! out=$(ipmi mc info 2>&1); then
      echo "FAILED: iDRAC did not answer: $(last_line "$out")" >&2
      echo "Check IPMI over LAN, the address, the login and IPMI_CIPHER." >&2; exit 1
    fi
    grep -E "Firmware Revision|Manufacturer Name" <<<"$out"
    read_sensors || { echo "FAILED reading sensors: $SDR_ERR" >&2; exit 1; }
    echo "ambient=${AMBIENT:-none}C cpu=[${CPU_READINGS:-n/a}] power=${POWER_W:-?}W fans=[$FAN_RPMS]"
    if out=$(ipmi raw 0x30 0x30 0x01 0x01 2>&1); then
      echo "OK: iDRAC accepts Dell fan-control commands (left in Dell automatic mode)"
    else
      echo "FAILED: fan command refused: $out" >&2
      echo "The iDRAC user needs Administrator privilege for IPMI over LAN." >&2; exit 1
    fi
    ;;
  -h|--help|help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command '$cmd' (try: daemon, status, set, curve, auto, test)" >&2; exit 2 ;;
esac
