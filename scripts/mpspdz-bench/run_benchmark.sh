#!/usr/bin/env bash
set -euo pipefail

# Reproduces the benchmark grid of Fhenix (CCS'25) for ModConv1 and ModConv2.
#
#   latency  -> their Table 2, and the latency column of their Table 1:
#               one ciphertext, parties x ping time
#   grid     -> their Table 3: throughput over bandwidth x ping time x parties
#   preproc  -> their Table 5: preprocessing per thousand decryptions, both
#               under their convention (ignoring triple and random-bit
#               generation) and end to end
#   sweep    -> not one of their tables; finds the (batch, threads) a host is
#               capable of, which `grid` then holds fixed. Not run by default.
#
# Every online phase reads its correlated randomness from disk, so its timer
# covers the online phase and nothing else, as theirs does.

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
PHASES=${PHASES:-"latency grid preproc"}
ALLOW_NO_TC=${ALLOW_NO_TC:-0}

if [[ " $PHASES " != *" check "* ]] && [ ! -x "$MPSPDZ/Fake-Offline.x" ]; then
    echo "$MPSPDZ/Fake-Offline.x is missing. The online phases read their" >&2
    echo "preprocessing from disk, which needs it. Build it with:" >&2
    echo "    cd $MPSPDZ" >&2
    echo "    echo 'MY_CFLAGS += -DINSECURE' >> CONFIG.mine" >&2
    echo "    make clean && make -j8 spdz2k-party.x Fake-Offline.x" >&2
    exit 1
fi

PARTIES=${PARTIES:-"4 8 16"}
THREAD_LIST=${THREAD_LIST:-"1 5"}
REPS=${REPS:-5}

# Their Table 2 gives 1 and 10 ms only; 100 ms is kept because their raw logs
# provide it and it is where our round advantage is largest.
LATENCY_PINGS=${LATENCY_PINGS:-"1 10 100"}

# Their Table 3 grid.
GRID_PINGS=${GRID_PINGS:-"1 10 100"}
BANDWIDTHS=${BANDWIDTHS:-"1gbit 100mbit"}
GRID_BATCH=${GRID_BATCH:-10000}

# `sweep` only.
BATCHES=${BATCHES:-"1000 5000 10000"}
SWEEP_N=${SWEEP_N:-4}

PREPROC_N=${PREPROC_N:-2}
PREPROC_BATCH=${PREPROC_BATCH:-1000}
LWE_N=${LWE_N:-1024}
RESULTS=${RESULTS:-"$HERE/results"}

K_PARAM=${K_PARAM:-64}
S_PARAM=${S_PARAM:-64}

# The preprocessing phase measures itself and so cannot read itself from a
# file; it keeps the pool-size flag, sized above its batch. MP-SPDZ generates
# MAC-check randomness in batches of -b (default 1000), and a timed region
# opening more than that regenerates mid-run, billing offline work to the timer.
PREP_BATCH=${PREP_BATCH:-$(( PREPROC_BATCH * 20 > 20000 ? PREPROC_BATCH * 20 : 20000 ))}

cp "$HERE"/modconv.py "$HERE"/modconv*.mpc "$MPSPDZ/Programs/Source/"
mkdir -p "$RESULTS"
cd "$MPSPDZ"

# ------------------------------------------------------------------ network
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
elif ! $TC qdisc replace dev lo root netem delay 1ms rate 1gbit 2>"$TCERR"; then
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
    trap '$TC qdisc del dev lo root >/dev/null 2>&1 || true' EXIT INT TERM HUP
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

rtt_now() {
    command -v ping >/dev/null 2>&1 || { echo ""; return; }
    ping -c 3 -q 127.0.0.1 2>/dev/null | tail -1 | awk -F'= ' '{print $2}' | cut -d/ -f2
}

# Wait for a previous cell's parties to exit. ping measures how long the kernel
# takes to answer, so measuring while they tear down reads the load, not the
# link: a stale set of parties once produced 14.5 ms under a nominal 1 ms.
settle() {
    local i
    for ((i = 0; i < 60; i++)); do
        pgrep -f spdz2k-party.x >/dev/null 2>&1 || break
        sleep 1
    done
    sleep "${SETTLE_S:-3}"
}

# net <ping_ms> <bandwidth>
# Attaches with 'replace', which succeeds whether lo carries noqueue, a stale
# netem, or nothing; 'add' fails on the first two with "Exclusivity flag on".
# The resulting RTT is then CHECKED, not merely printed.
net() {
    settle
    [ "$HAVE_TC" -eq 1 ] || { EMU=no; return 0; }
    $TC qdisc replace dev lo root netem delay "$(awk "BEGIN{print $1/2}")ms" rate "$2"
    if ! $TC qdisc show dev lo | grep -q netem; then
        echo "ERROR: netem is not attached to lo after adding it." >&2
        exit 1
    fi
    EMU=yes

    local asked=$1 tol best="" m i
    tol=$(awk "BEGIN{print $asked + ($asked*0.5 > 1 ? $asked*0.5 : 1)}")
    for i in 1 2 3; do
        m=$(rtt_now)
        [ -z "$m" ] && { echo "    network: asked ${asked}ms/$2, ping unavailable"; return 0; }
        if [ -z "$best" ] || [ "$(awk "BEGIN{print ($m < $best)}")" = 1 ]; then best=$m; fi
        [ "$(awk "BEGIN{print ($m <= $tol)}")" = 1 ] && break
        sleep 3
    done

    echo "    network: asked ${asked}ms/$2, measured loopback RTT $best ms"
    if [ "$(awk "BEGIN{print ($best > $tol)}")" = 1 ]; then
        echo >&2
        echo "Refusing to run: loopback RTT is ${best} ms under a nominal ${asked} ms" >&2
        echo "(tolerance ${tol} ms). netem is attached, so this is host load, not" >&2
        echo "shaping -- most often parties from a previous run still exiting:" >&2
        echo "    pgrep -c spdz2k-party.x   # should be 0" >&2
        echo "    pkill -f spdz2k-party.x   # if it is not" >&2
        echo "    uptime                    # load average should be near idle" >&2
        echo "Every row measured now would carry a ping label it did not" >&2
        echo "experience. Wait for the host to settle and re-run, or pass" >&2
        echo "ALLOW_BAD_RTT=1 to record the rows anyway." >&2
        [ "${ALLOW_BAD_RTT:-0}" = "1" ] || exit 1
        EMU=degraded
    fi
}

# ------------------------------------------------------------------ offline data
declare -A PREP_SIZE

# ensure_prep <parties> <items>
# Fake-Offline.x writes a trusted dealer's material to disk. This is not a
# secure offline phase and is not what `preproc` measures; it exists so that
# the online timer covers the online phase alone, as Fhenix's does.
ensure_prep() {
    local n=$1 need=$2 have=${PREP_SIZE[$1]:-0}
    [ "$need" -le "$have" ] && return 0
    echo "    offline data for N=$n: generating $need items"
    ./Fake-Offline.x "$n" -Z "$K_PARAM" -S "$S_PARAM" --default "$need" \
        > "$RESULTS/fake-offline-N$n-$need.log" 2>&1
    PREP_SIZE[$1]=$need
}

# inputs_needed <batch> <beta>   -- lwe_n + (2 + beta) * batch, with margin
inputs_needed() { awk "BEGIN{printf \"%d\", ($LWE_N + (2 + $2) * $1) * 1.5 + 10000}"; }

# preproc_inputs_needed <batch> <beta> <parties>
preproc_inputs_needed() {
    awk "BEGIN{ nl = 63 - log($2)/log(2)
                a = $3 * (nl + $2) * $1; b = 63 * $1
                printf \"%d\", ((a > b) ? a : b) * 1.5 + 20000 }"
}

beta2_of() { local b=1; while [ "$b" -lt $(($1 + 1)) ]; do b=$((b * 2)); done; echo "$b"; }

# ------------------------------------------------------------------ runners
# The program name carries every argument: compiling one name and running
# another silently benchmarked a stale program once. Compilation also rewrites
# Player-Data/Input-P0-0, so a program is compiled immediately before it runs.
compile_prog() {
    local src=$1; shift
    PROG="$src"; local a
    for a in "$@"; do PROG="$PROG-$a"; done
    ./compile.py -R 64 "$src" "$@" > "$RESULTS/$PROG-compile.log" 2>&1
}

run_prog() {
    local n=$1 prog=$2; shift 2
    local log="$RESULTS/$prog-N$n.log"
    if ! Scripts/spdz2k.sh -N "$n" -d "$@" "$prog" > "$log" 2>&1; then
        echo "  RUN FAILED, see $log" >&2
        RUN_S=0; RUN_MB=0; RUN_ROUNDS=0; RUN_ERR=-1
        return
    fi
    eval "$(python3 "$HERE/parse_run.py" "$log")"
}

median() { printf '%s\n' "$@" | sort -g | awk '{v[NR]=$1} END{print (NR%2)?v[(NR+1)/2]:(v[NR/2]+v[NR/2+1])/2}'; }

# repeat_online <reps> <parties> <src> <args...>
# Compiles once and runs `reps` times; the repetitions average host noise, and
# recompiling between them would only add noise of its own.
repeat_online() {
    local reps=$1 n=$2; shift 2
    compile_prog "$@"
    local times=() i
    ERR_TOTAL=0
    for ((i = 0; i < reps; i++)); do
        run_prog "$n" "$PROG" -F
        times+=("$RUN_S")
        LAST_MB=$RUN_MB; LAST_ROUNDS=$RUN_ROUNDS
        ERR_TOTAL=$((ERR_TOTAL + RUN_ERR))
    done
    RAW="${times[*]}"
    MED_S=$(median "${times[@]}")
}

# cell <csv> <protocol> <parties> <beta> <ping> <bw> <batch> <threads>
cell() {
    local csv=$1 name=$2 n=$3 beta=$4 ping=$5 bw=$6 batch=$7 t=$8
    if [ "$name" = modconv1 ]; then
        repeat_online "$REPS" "$n" modconv1_online 2 "$batch" "$LWE_N" "$t"
    else
        repeat_online "$REPS" "$n" modconv2_online "$n" "$beta" "$batch" "$LWE_N" "$t"
    fi
    if [ "$(awk "BEGIN{print ($MED_S > 0)}")" = 1 ]; then
        CELL_TP=$(awk "BEGIN{printf \"%.1f\", $batch/$MED_S}")
        CELL_BPD=$(awk "BEGIN{printf \"%.1f\", $LAST_MB*1048576/$batch}")
        CELL_MS=$(awk "BEGIN{printf \"%.4f\", $MED_S*1000}")
    else CELL_TP=0; CELL_BPD=0; CELL_MS=0; fi
    echo "$name,$n,$beta,$ping,$bw,$EMU,$batch,$t,$REPS,$CELL_MS,$CELL_TP,$CELL_BPD,$LAST_ROUNDS,$ERR_TOTAL,\"$RAW\"" >> "$csv"
}

HEADER="protocol,parties,beta,ping_ms,bandwidth,net_emulated,batch,threads,reps,time_ms_median,throughput_dec_per_sec,bytes_per_dec,rounds,mismatches,raw_times_s"

# ------------------------------------------------------------------ check
if [[ " $PHASES " == *" check "* ]]; then
    echo "Verifying network emulation over the whole grid before a long run."
    for BW in $BANDWIDTHS; do
        for PING in $GRID_PINGS; do net "$PING" "$BW"; done
    done
    echo "Emulation verified. Drop 'check' from PHASES to run the benchmark."
    exit 0
fi

# ------------------------------------------------------------------ latency
# One ciphertext: their Table 2, whose N=4 / 1 ms cell is also the latency
# column of their Table 1. Bandwidth is held at 1 Gbit because they report a
# single decryption's latency to be bandwidth-independent, the protocol moving
# very little data; our own byte counts agree.
if [[ " $PHASES " == *" latency "* ]]; then
    CSV="$RESULTS/latency.csv"; echo "$HEADER" > "$CSV"
    for PING in $LATENCY_PINGS; do
        net "$PING" 1gbit
        for N in $PARTIES; do
            B2=$(beta2_of "$N")
            ensure_prep "$N" "$(inputs_needed 1 "$B2")"
            for T in $THREAD_LIST; do
                cell "$CSV" modconv1 "$N" 2 "$PING" 1gbit 1 "$T"
                echo "    latency modconv1 N=$N ${PING}ms T=$T: $CELL_MS ms (mismatches $ERR_TOTAL)"
                cell "$CSV" modconv2 "$N" "$B2" "$PING" 1gbit 1 "$T"
                echo "    latency modconv2 N=$N ${PING}ms T=$T: $CELL_MS ms (mismatches $ERR_TOTAL)"
            done
        done
    done
fi

# ------------------------------------------------------------------ grid
# Their Table 3: throughput over bandwidth x ping x parties. The batch is held
# fixed so that what moves between cells is the network, which is where a
# protocol's communication per decryption shows rather than its host's cores.
if [[ " $PHASES " == *" grid "* ]]; then
    CSV="$RESULTS/grid.csv"; echo "$HEADER" > "$CSV"
    echo "    grid at batch=$GRID_BATCH, threads {$THREAD_LIST}, $REPS reps per cell"
    for N in $PARTIES; do
        ensure_prep "$N" "$(inputs_needed "$GRID_BATCH" "$(beta2_of "$N")")"
    done
    for BW in $BANDWIDTHS; do
        for PING in $GRID_PINGS; do
            net "$PING" "$BW"
            for N in $PARTIES; do
                B2=$(beta2_of "$N")
                for T in $THREAD_LIST; do
                    cell "$CSV" modconv1 "$N" 2 "$PING" "$BW" "$GRID_BATCH" "$T"
                    echo "    modconv1 N=$N $BW ${PING}ms T=$T: $CELL_TP dec/s, $CELL_BPD B/dec (mismatches $ERR_TOTAL)"
                    cell "$CSV" modconv2 "$N" "$B2" "$PING" "$BW" "$GRID_BATCH" "$T"
                    echo "    modconv2 N=$N $BW ${PING}ms T=$T: $CELL_TP dec/s, $CELL_BPD B/dec (mismatches $ERR_TOTAL)"
                done
            done
        done
    done
fi

# ------------------------------------------------------------------ sweep
if [[ " $PHASES " == *" sweep "* ]]; then
    CSV="$RESULTS/sweep.csv"; echo "$HEADER" > "$CSV"
    net 1 1gbit
    B2=$(beta2_of "$SWEEP_N")
    for B in $BATCHES; do
        ensure_prep "$SWEEP_N" "$(inputs_needed "$B" "$B2")"
        for T in $THREAD_LIST; do
            cell "$CSV" modconv1 "$SWEEP_N" 2 1 1gbit "$B" "$T"
            echo "    sweep modconv1 B=$B T=$T: $CELL_TP dec/s"
            cell "$CSV" modconv2 "$SWEEP_N" "$B2" 1 1gbit "$B" "$T"
            echo "    sweep modconv2 B=$B T=$T: $CELL_TP dec/s"
        done
    done
fi

# ------------------------------------------------------------------ preprocessing
# Twice, under two conventions.
#   included -- live preprocessing (-b): the oblivious-transfer traffic that
#       produces the random bits and Beaver triples is inside the timer.
#   excluded -- material read from disk (-F): the protocol's own work alone,
#       which is the convention of Fhenix's Table 5.
if [[ " $PHASES " == *" preproc "* ]]; then
    CSV="$RESULTS/preproc.csv"
    echo "protocol,parties,beta,batch,ping_ms,bandwidth,net_emulated,generation,time_s,mb_party0,rounds,mismatches" > "$CSV"
    net 1 1gbit
    B2=$(beta2_of "$PREPROC_N")
    ensure_prep "$PREPROC_N" "$(preproc_inputs_needed "$PREPROC_BATCH" "$B2" "$PREPROC_N")"
    for MODE in included excluded; do
        if [ "$MODE" = included ]; then FLAGS=(-b "$PREP_BATCH"); else FLAGS=(-F); fi
        compile_prog modconv1_preproc 2 "$PREPROC_BATCH"
        run_prog "$PREPROC_N" "$PROG" "${FLAGS[@]}"
        echo "modconv1,$PREPROC_N,2,$PREPROC_BATCH,1,1gbit,$EMU,$MODE,$RUN_S,$RUN_MB,$RUN_ROUNDS,$RUN_ERR" >> "$CSV"
        echo "    preproc modconv1 ($MODE): $RUN_S s, $RUN_MB MB, $RUN_ROUNDS rounds, mismatches $RUN_ERR"
        compile_prog modconv2_preproc "$PREPROC_N" "$B2" "$PREPROC_BATCH"
        run_prog "$PREPROC_N" "$PROG" "${FLAGS[@]}"
        echo "modconv2,$PREPROC_N,$B2,$PREPROC_BATCH,1,1gbit,$EMU,$MODE,$RUN_S,$RUN_MB,$RUN_ROUNDS,$RUN_ERR" >> "$CSV"
        echo "    preproc modconv2 ($MODE): $RUN_S s, $RUN_MB MB, $RUN_ROUNDS rounds, mismatches $RUN_ERR"
    done
fi

echo
echo "Results in $RESULTS/{latency,grid,sweep,preproc}.csv"
