#!/usr/bin/env bash
set -euo pipefail

MPSPDZ=${MPSPDZ:-}

if [ -z "$MPSPDZ" ] || [ ! -f "$MPSPDZ/compile.py" ]; then
    echo "Set MPSPDZ to your MP-SPDZ git root (the directory containing compile.py):" >&2
    echo "    MPSPDZ=\$HOME/MP-SPDZ $0" >&2
    exit 1
fi

if [ ! -x "$MPSPDZ/spdz2k-party.x" ]; then
    echo "$MPSPDZ/spdz2k-party.x is missing. Build it first:" >&2
    echo "    cd $MPSPDZ && make -j8 spdz2k-party.x" >&2
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
N=${N:-2}
PING=${PING:-1}
BANDWIDTH=${BANDWIDTH:-1gbit}
BATCH=${BATCH:-}
BETA2=${BETA2:-}
RESULTS=${RESULTS:-"$HERE/results/preproc"}

cp "$HERE"/modconv.py "$HERE"/modconv*.mpc "$MPSPDZ/Programs/Source/"
mkdir -p "$RESULTS"
cd "$MPSPDZ"

CSV="$RESULTS/summary.csv"
echo "protocol,parties,beta,ping_ms,bandwidth,net_emulated,batch,time_s,mb_party0,rounds,correct" > "$CSV"

EMU=no
if command -v tc >/dev/null 2>&1 && tc qdisc add dev lo root netem delay 0ms >/dev/null 2>&1; then
    tc qdisc del dev lo root >/dev/null 2>&1 || true
    trap 'tc qdisc del dev lo root >/dev/null 2>&1 || true' EXIT
    tc qdisc add dev lo root netem delay "$(awk "BEGIN{print $PING/2}")ms" rate "$BANDWIDTH"
    EMU=yes
else
    echo "WARNING: tc/netem unavailable; running at native loopback speed."
    echo "         ping/bandwidth columns record the intended condition, not an applied one."
fi

run_one() {
    local proto=$1 prog=$2 beta=$3
    shift 3
    local log="$RESULTS/$proto-N$N.log"
    echo "=== $proto  N=$N  beta=$beta  ping=${PING}ms  bw=$BANDWIDTH  emulated=$EMU ==="
    ./compile.py -R 64 "$@" > "$RESULTS/$proto-N$N-compile.log" 2>&1
    if ! Scripts/spdz2k.sh -N "$N" -d "$prog" ${BATCH:+-b $BATCH} > "$log" 2>&1; then
        echo "  RUN FAILED, see $log"
        return
    fi
    grep -E "Time1 =|converted value|expected value" "$log" || true
    python3 - "$log" "$proto" "$N" "$beta" "$PING" "$BANDWIDTH" "$EMU" "$BATCH" >> "$CSV" <<'PY'
import re, sys
log, proto, n, beta, ping, bw, emu, batch = sys.argv[1:9]
t = open(log, errors='replace').read()
m = re.search(r'Time1 = ([\d.e+-]+) seconds \(([\d.e+-]+) MB, (\d+) rounds', t)
secs, mb, rounds = (m.group(1), m.group(2), m.group(3)) if m else ('0', '0', '0')
got = re.search(r'converted value: (-?\d+)', t)
exp = re.search(r'expected value: (-?\d+)', t)
ok = 'yes' if got and exp and got.group(1) == exp.group(1) else 'NO'
print(','.join([proto, n, beta, ping, bw, emu, batch or 'default', secs, mb, rounds, ok]))
PY
}

if [ -n "$BETA2" ]; then
    B2=$BETA2
else
    B2=1
    while [ "$B2" -lt $((N + 1)) ]; do B2=$((B2 * 2)); done
fi

run_one modconv1_preproc "modconv1_preproc-2"   2     modconv1_preproc 2
run_one modconv2_preproc "modconv2_preproc-$N-$B2"  "$B2" modconv2_preproc "$N" "$B2"
run_one modconv3_preproc "modconv3_preproc"     -     modconv3_preproc

echo
echo "Summary CSV: $CSV"
