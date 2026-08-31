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
PHASES=${PHASES:-"latency throughput preproc"}
ALLOW_NO_TC=${ALLOW_NO_TC:-0}
BATCH_SIZE=${BATCH_SIZE:-1000}
PARTIES=${PARTIES:-"4 8 16"}
PINGS=${PINGS:-"1 10 100"}
PREPROC_N=${PREPROC_N:-2}
LWE_N=${LWE_N:-1024}
RESULTS=${RESULTS:-"$HERE/results"}

cp "$HERE"/modconv.py "$HERE"/modconv*.mpc "$MPSPDZ/Programs/Source/"
mkdir -p "$RESULTS"
cd "$MPSPDZ"

TC=""
if command -v tc >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then TC="tc"; elif command -v sudo >/dev/null 2>&1; then TC="sudo tc"; fi
fi

HAVE_TC=0
TCERR=$(mktemp)
if ! command -v tc >/dev/null 2>&1; then
    echo "WARNING: tc not found. Install it:  sudo apt install iproute2"
elif [ -z "$TC" ]; then
    echo "WARNING: tc needs root and sudo is unavailable. Re-run this script as root."
elif ! $TC qdisc add dev lo root netem delay 1ms rate 1gbit 2>"$TCERR"; then
    echo "WARNING: tc could not install a netem qdisc:"
    sed 's/^/             /' "$TCERR"
    echo "         'qdisc kind is unknown' -> kernel lacks sch_netem:"
    echo "             sudo apt install linux-modules-extra-\$(uname -r) && sudo modprobe sch_netem"
    echo "         'Operation not permitted' -> this VM/container has no NET_ADMIN."
else
    $TC qdisc del dev lo root >/dev/null 2>&1 || true
    HAVE_TC=1
fi
rm -f "$TCERR"

if [ "$HAVE_TC" -eq 1 ]; then
    trap '$TC qdisc del dev lo root >/dev/null 2>&1 || true' EXIT
elif [ "$ALLOW_NO_TC" = "1" ]; then
    echo "         ALLOW_NO_TC=1: running unshaped anyway. The ping and bandwidth"
    echo "         columns then name the INTENDED condition, not an applied one,"
    echo "         and the rows are not latency measurements."
else
    echo >&2
    echo "Refusing to run: network emulation is the point of this benchmark, and" >&2
    echo "without it every row would carry a ping label it did not experience." >&2
    echo "Fix tc (see above), or pass ALLOW_NO_TC=1 to run unshaped on purpose." >&2
    exit 1
fi

# measured loopback RTT, so a wrong shaping is caught before a long run
rtt_now() {
    command -v ping >/dev/null 2>&1 || { echo "n/a"; return; }
    ping -c 3 -q 127.0.0.1 2>/dev/null | tail -1 | awk -F'= ' '{print $2}' | cut -d/ -f2
}

net() {
    [ "$HAVE_TC" -eq 1 ] || { EMU=no; return 0; }
    $TC qdisc del dev lo root >/dev/null 2>&1 || true
    $TC qdisc add dev lo root netem delay "$(awk "BEGIN{print $1/2}")ms" rate "$2"
    if ! $TC qdisc show dev lo | grep -q netem; then
        echo "ERROR: netem is not attached to lo after adding it." >&2
        exit 1
    fi
    EMU=yes
    echo "    network: asked ${1}ms/$2, measured loopback RTT $(rtt_now) ms"
}

# run <parties> <source> <args...>  -> sets RUN_S RUN_MB RUN_ROUNDS RUN_ERR
run() {
    local n=$1 src=$2
    shift 2
    local prog="$src" a
    for a in "$@"; do prog="$prog-$a"; done
    local log="$RESULTS/$prog-N$n.log"
    ./compile.py -R 64 "$src" "$@" > "$RESULTS/$prog-N$n-compile.log" 2>&1
    if ! Scripts/spdz2k.sh -N "$n" -d "$prog" > "$log" 2>&1; then
        echo "  RUN FAILED, see $log" >&2
        RUN_S=0; RUN_MB=0; RUN_ROUNDS=0; RUN_ERR=-1
        return
    fi
    eval "$(python3 "$HERE/parse_run.py" "$log")"
}

beta2_of() { local b=1; while [ "$b" -lt $(($1 + 1)) ]; do b=$((b * 2)); done; echo "$b"; }

# ---------------------------------------------------------------- check
if [[ " $PHASES " == *" check "* ]]; then
    echo "Checking network emulation before committing to a long run."
    for PING in $PINGS; do
        net "$PING" 1gbit
    done
    echo "Emulation works. Drop 'check' from PHASES to run the benchmark."
    exit 0
fi

# ---------------------------------------------------------------- table 1
if [[ " $PHASES " == *" latency "* ]] || [[ " $PHASES " == *" throughput "* ]]; then
    CSV1="$RESULTS/table1.csv"
    echo "protocol,parties,beta,ping_ms,bandwidth,net_emulated,latency_ms,throughput_dec_per_sec,batch,mismatches" > "$CSV1"
    net 1 1gbit
    B2=$(beta2_of 4)
    for p in 1 2; do
        if [ "$p" = 1 ]; then
            run 4 modconv1_online 2 1 "$LWE_N"
            L_S=$RUN_S; L_E=$RUN_ERR
            run 4 modconv1_online 2 "$BATCH_SIZE" "$LWE_N"
            NAME=modconv1; BETA=2
        else
            run 4 modconv2_online 4 "$B2" 1 "$LWE_N"
            L_S=$RUN_S; L_E=$RUN_ERR
            run 4 modconv2_online 4 "$B2" "$BATCH_SIZE" "$LWE_N"
            NAME=modconv2; BETA=$B2
        fi
        TP=$(awk "BEGIN{printf \"%.1f\", $BATCH_SIZE/$RUN_S}")
        LMS=$(awk "BEGIN{printf \"%.4f\", $L_S*1000}")
        echo "$NAME,4,$BETA,1,1gbit,$EMU,$LMS,$TP,$BATCH_SIZE,$((L_E + RUN_ERR))" >> "$CSV1"
        echo "=== table1 $NAME : latency ${LMS} ms, throughput $TP dec/s ==="
    done
fi

# ---------------------------------------------------------------- table 2
if [[ " $PHASES " == *" latency "* ]]; then
    CSV2="$RESULTS/table2.csv"
    echo "protocol,parties,beta,ping_ms,bandwidth,net_emulated,latency_ms,rounds,mb_party0,mismatches" > "$CSV2"
    for PING in $PINGS; do
        net "$PING" 1gbit
        for N in $PARTIES; do
            B2=$(beta2_of "$N")
            run "$N" modconv1_online 2 1 "$LWE_N"
            echo "modconv1,$N,2,$PING,1gbit,$EMU,$(awk "BEGIN{printf \"%.4f\", $RUN_S*1000}"),$RUN_ROUNDS,$RUN_MB,$RUN_ERR" >> "$CSV2"
            run "$N" modconv2_online "$N" "$B2" 1 "$LWE_N"
            echo "modconv2,$N,$B2,$PING,1gbit,$EMU,$(awk "BEGIN{printf \"%.4f\", $RUN_S*1000}"),$RUN_ROUNDS,$RUN_MB,$RUN_ERR" >> "$CSV2"
            echo "=== table2 N=$N ping=${PING}ms done ==="
        done
    done
fi

# ---------------------------------------------------------------- offline
if [[ " $PHASES " == *" preproc "* ]]; then
    CSV3="$RESULTS/preproc.csv"
    echo "protocol,parties,beta,batch,ping_ms,bandwidth,net_emulated,time_s,mb_party0,rounds,mismatches" > "$CSV3"
    net 1 1gbit
    B2=$(beta2_of "$PREPROC_N")
    run "$PREPROC_N" modconv1_preproc 2 "$BATCH_SIZE"
    echo "modconv1,$PREPROC_N,2,$BATCH_SIZE,1,1gbit,$EMU,$RUN_S,$RUN_MB,$RUN_ROUNDS,$RUN_ERR" >> "$CSV3"
    echo "=== preproc modconv1 : $RUN_S s for $BATCH_SIZE ==="
    run "$PREPROC_N" modconv2_preproc "$PREPROC_N" "$B2" "$BATCH_SIZE"
    echo "modconv2,$PREPROC_N,$B2,$BATCH_SIZE,1,1gbit,$EMU,$RUN_S,$RUN_MB,$RUN_ROUNDS,$RUN_ERR" >> "$CSV3"
    echo "=== preproc modconv2 : $RUN_S s for $BATCH_SIZE ==="
fi

echo
echo "Results in $RESULTS/{table1,table2,preproc}.csv"
