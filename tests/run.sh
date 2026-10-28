#!/usr/bin/env bash
# Unit tests for rkmpp-smi. Pure bash, no dependencies, no hardware needed.
#
# The script is sourced (its main block is guarded), so these tests call the
# formatters, collectors and helpers directly and check the globals they set.
#
# Run: bash tests/run.sh

set -o pipefail
shopt -s nullglob
export LC_ALL=C

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck source=../rkmpp-smi
source ./rkmpp-smi

FAILED=0
PASSED=0
TEST=''

start() { TEST=$1; }
ok()    { PASSED=$(( PASSED + 1 )); printf '  ok   %s\n' "$TEST"; }
bad()   { FAILED=$(( FAILED + 1 )); printf '  FAIL %s: %s\n' "$TEST" "$1"; }
check() { # check <expected> <actual>
    if [[ $1 == "$2" ]]; then ok; else bad "expected [$1], got [$2]"; fi
}

# dwidth = display columns of stdin (block glyphs are 3-byte UTF-8 => 1 column).
dwidth() {
    local line bytes glyphs max=0
    while IFS= read -r line; do
        bytes=$(printf '%s' "$line" | od -An -tx1 | tr -d ' \n' | wc -c); bytes=$(( bytes / 2 ))
        glyphs=$(printf '%s' "$line" | tr -cd '█░─' | wc -c); glyphs=$(( glyphs / 3 ))
        bytes=$(( bytes - 2 * glyphs ))
        (( bytes > max )) && max=$bytes
    done
    printf '%d' "$max"
}

# ---------------------------------------------------------------------------
echo 'formatters'
# ---------------------------------------------------------------------------
start 'repeat_char writes REP without forking'
repeat_char 'x' 5; check 'xxxxx' "$REP"

start 'draw_bar clamps to 0..100'
draw_bar -7;      [[ $BAR == *'[░░░░░░░░░░░░░░░░░░░░]   0%'* ]] && ok || bad "$BAR"
draw_bar 173;     [[ $BAR == *'[████████████████████] 100%'* ]] && ok || bad "$BAR"

start 'draw_bar renders N/A for empty input'
draw_bar ''; [[ $BAR == *'N/A'* ]] && ok || bad "$BAR"

start 'draw_bar accepts float percent'
draw_bar 12.9; [[ $BAR == *'12%'* ]] && ok || bad "$BAR"

start 'fmt_hz formats MHz and GHz'
fmt_hz 1800000000;   check '1.80 GHz' "$FMT_HZ"
fmt_hz 180000000;    check '180 MHz' "$FMT_HZ"
fmt_hz 2300000000;   check '2.30 GHz' "$FMT_HZ"
fmt_hz '';           check '-' "$FMT_HZ"

start 'fmt_kb formats KiB/MiB/GiB'
fmt_kb 512;          check '512 KiB' "$FMT_KB"
fmt_kb 2048;         check '2 MiB' "$FMT_KB"
fmt_kb 8764519;      check '8.35 GiB' "$FMT_KB"

start 'fmt_temp formats millidegrees'
fmt_temp 40600;      check '40.6' "$FMT_TEMP"
fmt_temp '';         check 'N/A' "$FMT_TEMP"

start 'fmt_uptime compacts days/hours/minutes'
fmt_uptime 1300000;  check '15d 1h 6m' "$FMT_UP"
fmt_uptime 3660;     check '1h 1m' "$FMT_UP"
fmt_uptime 120;      check '2m' "$FMT_UP"

# ---------------------------------------------------------------------------
echo 'helpers'
# ---------------------------------------------------------------------------
start 'sort_dev_counts orders by descending count, numerically'
SESSION_DEVS=(rkvdec-core:10 jpege-core:2 rkvdec-core:9)
sort_dev_counts
check 'rkvdec-core:10 rkvdec-core:9 jpege-core:2' "${SESSION_DEVS[*]}"

start 'sort_dev_counts is stable for equal counts'
SESSION_DEVS=(hevc-core:1 vdpu-core:1)
sort_dev_counts
check 'hevc-core:1 vdpu-core:1' "${SESSION_DEVS[*]}"

start 'now_us returns microseconds'
t=$(now_us); [[ $t =~ ^[0-9]{13,}$ ]] && ok || bad "$t is not a large integer"

# ---------------------------------------------------------------------------
echo 'collectors (run against this machine)'
# ---------------------------------------------------------------------------
start 'collect_mem reports used, cached and swap from meminfo'
collect_mem
if [[ $MEM_TOTAL -gt 0 && $MEM_PCT -ge 0 && $MEM_PCT -le 100 && -n $MEM_CACHE && $MEM_CACHE -gt 0 ]]; then
    ok
else
    bad "total=$MEM_TOTAL pct=$MEM_PCT cache=[$MEM_CACHE]"
fi

start 'prime_cpu + collect_cpu produces a sane usage delta'
prime_cpu; sleep 0.1; collect_cpu
if [[ $CPU_USAGE -ge 0 && $CPU_USAGE -le 100 && ( $CPU_FREQS == *'MHz'* || $CPU_FREQS == *'GHz'* ) ]]; then
    ok
else
    bad "usage=$CPU_USAGE freqs=[$CPU_FREQS]"
fi

start 'collect_accel degrades to empty on a non-Rockchip host'
collect_accel
if [[ -z $GPU_LOAD && -z $GPU_FREQ ]]; then ok; else bad "gpu load=[$GPU_LOAD] freq=[$GPU_FREQ]"; fi

start 'collect_mpp marks MPP unavailable without /proc/mpp_service'
collect_mpp
if [[ $MPP_OK == 0 ]]; then ok; else bad "MPP_OK=$MPP_OK"; fi

start 'collect_sessions degrades to zero sessions'
collect_sessions
if [[ $SESSION_TOTAL == 0 ]]; then ok; else bad "SESSION_TOTAL=$SESSION_TOTAL"; fi

# ---------------------------------------------------------------------------
echo 'rendered frame (--once on this machine)'
# ---------------------------------------------------------------------------
start 'a full frame renders and mentions the missing MPP source'
frame=$(INTERACTIVE=0 FORCE_COLOR=never ./rkmpp-smi --once 2>/dev/null)
rc=$?
if (( rc == 0 )) && grep -q 'MPP stats unavailable' <<< "$frame" && grep -q 'used .*/' <<< "$frame" && grep -q 'cache .*(recl)' <<< "$frame" && grep -q 'CPU' <<< "$frame"; then
    ok
else
    bad "exit $rc; frame: $(head -c 400 <<< "$frame")"
fi

start 'RGA row explains itself when debugfs is missing (root or not)'
if [[ $EUID == 0 ]]; then
    grep -qE 'RGA .*n/a \(no rkrga\)' <<< "$frame" && ok || bad "RGA row: $(grep RGA <<< "$frame")"
else
    grep -qE 'RGA .*n/a \(needs root\)' <<< "$frame" && ok || bad "RGA row: $(grep RGA <<< "$frame")"
fi

start 'rule never under-runs the row content width'
# Block glyphs are 3-byte UTF-8, so count columns as (bytes - 2*glyphs).
# (grep -o would match a multibyte glyph once per byte in some locales, so
# glyphs are counted as byte-triples via tr.)
rule_width=$(( $(sed -n '2p' <<< "$frame" | tr -cd '─' | wc -c) / 3 ))
content_width=$(dwidth <<< "$frame")
# A non-interactive --once run has no tput width, so the layout must fall back
# to $COLUMNS (80 by default) and cover the widest row without under-running.
navail=$(grep -m1 '^DEFAULT_WIDTH=' rkmpp-smi); navail=${navail%%#*}; navail=${navail#*=}; navail=${navail%%[[:space:]]*}
if [[ $rule_width -eq $navail && $content_width -eq $rule_width ]]; then
    ok
else
    bad "rule=$rule_width content=$content_width (expected both $navail)"
fi

# ---------------------------------------------------------------------------
echo 'fit to width (snapped windows)'
# ---------------------------------------------------------------------------
for w in 120 100 80 70 60 50 48; do
    start "every row fits within COLUMNS=$w"
    framed=$(COLUMNS=$w ./rkmpp-smi --once --no-color 2>/dev/null)
    maxw=$(dwidth <<< "$framed")
    ruled=$(( $(sed -n '2p' <<< "$framed" | tr -cd '─' | wc -c) / 3 ))
    if [[ $maxw -le $w && $ruled -eq $w ]]; then
        ok
    else
        bad "widest=$maxw rule=$ruled, want <=$w and rule=$w"
    fi
done

start 'very narrow terminals clamp to MIN_WIDTH instead of wrapping'
minw=$(grep -m1 '^MIN_WIDTH=' rkmpp-smi); minw=${minw%%#*}; minw=${minw#*=}; minw=${minw%%[[:space:]]*}
ruled=$(( $(COLUMNS=20 ./rkmpp-smi --once --no-color 2>/dev/null | sed -n '2p' | tr -cd '─' | wc -c) / 3 ))
check "$minw" "$ruled"

start 'CPU frequency labels survive at 80 cols (all clusters, compact)'
w80=$(COLUMNS=80 ./rkmpp-smi --once --no-color 2>/dev/null | sed -n '3p')
# At 80 columns the freq list is compacted but must still start with a label.
grep -qE 'L[0-9]+ [0-9]' <<< "$w80" && ok || bad "row: $w80"

# The interactive path takes its width from tput, not COLUMNS; drive a real
# pty at a fixed size and check nothing is painted wider than the window.
if command -v python3 >/dev/null 2>&1; then
    start 'interactive (tput) layout fits a 64-column pty'
    if python3 - ./rkmpp-smi 64 <<'PYEOF'
import os, pty, select, sys, time, fcntl, termios, struct, re
script, width = sys.argv[1], int(sys.argv[2])
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/bash", ["bash", script, "-n", "0.3"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, width, 0, 0))
buf = b""; t0 = time.time(); sent = False
while time.time() - t0 < 3:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try: buf += os.read(fd, 65536)
        except OSError: pass
    if not sent and time.time() - t0 > 1.0:
        os.write(fd, b"q"); sent = True
    try:
        if os.waitpid(pid, os.WNOHANG)[0] != 0: break
    except ChildProcessError: break
os.close(fd)
text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "\n", buf.decode("utf-8", "replace"))
widest = max((len(l) for l in text.split("\n")), default=0)
sys.exit(0 if widest <= width else 1)
PYEOF
    then ok; else bad 'a painted line exceeded the pty width'; fi
fi

# ---------------------------------------------------------------------------
echo 'CLI'
# ---------------------------------------------------------------------------
start '--version prints the version'
out=$(./rkmpp-smi --version); check 'rkmpp-smi 1.0.0' "$out"

start '--help mentions --version'
./rkmpp-smi --help | grep -q -- '--version' && ok || bad '--version missing from help'

start 'invalid interval exits 2'
./rkmpp-smi -n abc 2>/dev/null; check 2 "$?"

start 'zero interval exits 2'
./rkmpp-smi -n 0 2>/dev/null; check 2 "$?"

start 'unknown option exits 2'
./rkmpp-smi --nope 2>/dev/null; check 2 "$?"

# ---------------------------------------------------------------------------
echo 'interactive (pty): q quits cleanly at a fast interval'
# ---------------------------------------------------------------------------
# Uses python3's pty to drive the real TUI. Skipped when python3 is absent, so
# the suite stays dependency-free for the bash-only parts.
if command -v python3 >/dev/null 2>&1; then
    start 'q quits with exit 0 at -n 0.1 (fast frames must still see the key)'
    if python3 - ./rkmpp-smi 0.1 <<'PYEOF'
import os, pty, select, sys, time
script, interval = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/bash", ["bash", script, "-n", interval])
t0 = time.time(); sent = False; code = None
while time.time() - t0 < 10:
    r, _, _ = select.select([fd], [], [], 0.1)
    if r:
        try: os.read(fd, 65536)
        except OSError: pass
    if not sent and time.time() - t0 > 1.0:
        os.write(fd, b"q"); sent = True
    try:
        w = os.waitpid(pid, os.WNOHANG)
        if w[0] != 0: code = os.waitstatus_to_exitcode(w[1]); break
    except ChildProcessError:
        code = 0; break
sys.exit(0 if (sent and code == 0) else 1)
PYEOF
    then ok; else bad 'did not quit on q within 10s'; fi
else
    start 'pty test (skipped: no python3)'
    ok
fi

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
(( FAILED == 0 ))
