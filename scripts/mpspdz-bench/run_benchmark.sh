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

# The online phase reads its preprocessing from disk (-F), so the timer covers
# the online phase and nothing else. That is what makes the batch sweep
# meaningful and what makes the figure comparable to an implementation that
# separates its phases. Fake-Offline.x needs a build with -DINSECURE.
if [[ " $PHASES " == *" latency "* ]] || [[ " $PHASES " == *" throughput "* ]]; then
    if [ ! -x "$MPSPDZ/Fake-Offline.x" ]; then
        echo "$MPSPDZ/Fake-Offline.x is missing. The online phases read their" >&2
        echo "preprocessing from disk, which needs it. Build it with:" >&2
        echo "    cd $MPSPDZ" >&2
        echo "    echo 'MY_CFLAGS += -DINSECURE' >> CONFIG.mine" >&2
        echo "    make clean && make -j8 spdz2k-party.x Fake-Offline.x" >&2
        exit 1
    fi
fi

BATCHES=${BATCHES:-"1000 5000 10000"}
THREAD_LIST=${THREAD_LIST:-"1 2 4 5"}
REPS=${REPS:-5}
PARTIES=${PARTIES:-"4 8 16"}
PINGS=${PINGS:-"1 10 100"}
PREPROC_N=${PREPROC_N:-2}
PREPROC_BATCH=${PREPROC_BATCH:-1000}
LWE_N=${LWE_N:-1024}
RESULTS=${RESULTS:-"$HERE/results"}

# SPDZ2k parameters: the machine ring is 2^64 and the MAC ring 2^64.
K_PARAM=${K_PARAM:-64}
S_PARAM=${S_PARAM:-64}

# The preprocessing phase measures itself, so it cannot read itself from disk.
# It keeps the pool-size flag instead, sized above its batch: MP-SPDZ generates
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

# netem is attached with 'replace', which succeeds whether lo currently carries
# noqueue, a stale netem, or nothing. 'add' fails on the first two with
# "Exclusivity flag on, cannot modify", which stalled an earlier sweep.
#
# The measured RTT is then CHECKED, not merely printed. netem applies the delay
# it is given, but ping also measures how long the kernel takes to answer, so a
# loaded host inflates it: a stale set of parties still shutting down produced
# 14.5 ms under a nominal 1 ms. A row taken then would carry a ping label it did
# not experience, which is the one thing this harness exists to prevent.
# Wait for a previous phase's parties to actually exit. The throughput sweep
# leaves up to N processes tearing down, and ping measures how long the kernel
# takes to answer, so measuring straight after it reads the load, not the link.
settle() {
    local i
    for ((i = 0; i < 60; i++)); do
        pgrep -f spdz2k-party.x >/dev/null 2>&1 || break
        sleep 1
    done
    sleep "${SETTLE_S:-3}"
}

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
# Fake-Offline.x writes a trusted dealer's preprocessing to disk. This is not a
# secure offline phase and is not what the preproc phase measures; it exists so
# that the online timer covers the online phase alone.
ensure_prep() {
    local n=$1 need=$2 have=${PREP_SIZE[$1]:-0}
    [ "$need" -le "$have" ] && return 0
    echo "    offline data for N=$n: generating $need items"
    ./Fake-Offline.x "$n" -Z "$K_PARAM" -S "$S_PARAM" --default "$need" \
        > "$RESULTS/fake-offline-N$n-$need.log" 2>&1
    PREP_SIZE[$1]=$need
}

# inputs_needed <batch> <beta>   -- lwe_n + (2 + beta) * batch, with margin
inputs_needed() {
    awk "BEGIN{printf \"%d\", ($LWE_N + (2 + $2) * $1) * 1.5 + 10000}"
}

# preproc_inputs_needed <batch> <beta> <parties>
# ModConv2's preprocessing takes n_l + beta values from each party, where
# n_l = 63 - log2(beta); ModConv1's takes 63 random bits per conversion.
preproc_inputs_needed() {
    awk "BEGIN{
        nl = 63 - log($2)/log(2)
        mc2 = $3 * (nl + $2) * $1
        mc1 = 63 * $1
        m = (mc2 > mc1) ? mc2 : mc1
        printf \"%d\", m * 1.5 + 20000
    }"
}

# ------------------------------------------------------------------ runners
# compile_prog <src> <args...> -> PROG
# The program name carries every argument: compiling one name and running
# another silently benchmarked a stale program once already. Compilation also
# rewrites Player-Data/Input-P0-0, so a program is compiled immediately before
# it is run and never while another one is pending.
compile_prog() {
    local src=$1; shift
    PROG="$src"; local a
    for a in "$@"; do PROG="$PROG-$a"; done
    ./compile.py -R 64 "$src" "$@" > "$RESULTS/$PROG-compile.log" 2>&1
}

# run_prog <parties> <prog> [-F|-b N] -> RUN_S RUN_MB RUN_ROUNDS RUN_ERR
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

beta2_of() { local b=1; while [ "$b" -lt $(($1 + 1)) ]; do b=$((b * 2)); done; echo "$b"; }

# repeat_online <reps> <parties> <src> <args...>
#   -> MED_S (median time), LAST_MB, LAST_ROUNDS, ERR_TOTAL, RAW (all times)
# Compiles once and runs `reps` times: the repetitions exist to average out host
# noise, and recompiling between them only adds noise of its own.
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

# ------------------------------------------------------------------ check
if [[ " $PHASES " == *" check "* ]]; then
    echo "Checking network emulation before committing to a long run."
    for PING in $PINGS; do
        net "$PING" 1gbit
    done
    echo "Emulation works. Drop 'check' from PHASES to run the benchmark."
    exit 0
fi

# ------------------------------------------------------------------ latency
# One decryption at a time, across the ping x parties grid. Threads are pinned
# to 1: at batch=1 there is nothing to split and an extra tape only adds a tape.
if [[ " $PHASES " == *" latency "* ]]; then
    CSV2="$RESULTS/latency.csv"
    echo "protocol,parties,beta,ping_ms,bandwidth,net_emulated,reps,latency_ms_median,rounds,bytes_per_dec,mismatches,raw_times_s" > "$CSV2"
    for PING in $PINGS; do
        net "$PING" 1gbit
        for N in $PARTIES; do
            B2=$(beta2_of "$N")
            ensure_prep "$N" "$(inputs_needed 1 "$B2")"
            repeat_online "$REPS" "$N" modconv1_online 2 1 "$LWE_N" 1
            BPD=$(awk "BEGIN{printf \"%.1f\", $LAST_MB*1048576}")
            echo "modconv1,$N,2,$PING,1gbit,$EMU,$REPS,$(awk "BEGIN{printf \"%.4f\", $MED_S*1000}"),$LAST_ROUNDS,$BPD,$ERR_TOTAL,\"$RAW\"" >> "$CSV2"
            repeat_online "$REPS" "$N" modconv2_online "$N" "$B2" 1 "$LWE_N" 1
            BPD=$(awk "BEGIN{printf \"%.1f\", $LAST_MB*1048576}")
            echo "modconv2,$N,$B2,$PING,1gbit,$EMU,$REPS,$(awk "BEGIN{printf \"%.4f\", $MED_S*1000}"),$LAST_ROUNDS,$BPD,$ERR_TOTAL,\"$RAW\"" >> "$CSV2"
            echo "=== latency N=$N ping=${PING}ms done ==="
        done
    done
fi

# ------------------------------------------------------------------ throughput
# Sweeps threads x batch and keeps the best median. Both are reported, because
# a throughput figure without them is not reproducible.
if [[ " $PHASES " == *" throughput "* ]]; then
    CSV1="$RESULTS/throughput.csv"
    echo "protocol,parties,beta,ping_ms,bandwidth,net_emulated,batch,threads,reps,time_s_median,throughput_dec_per_sec,bytes_per_dec,rounds,mismatches" > "$CSV1"
    SWEEP="$RESULTS/throughput-sweep.csv"
    echo "protocol,batch,threads,throughput_dec_per_sec,bytes_per_dec,rounds,mismatches,raw_times_s" > "$SWEEP"
    net 1 1gbit
    B2=$(beta2_of 4)
    echo "    sweeping threads {$THREAD_LIST} x batch {$BATCHES}, $REPS reps each"

    # One generation at the largest size the whole sweep needs. Sizing it per
    # batch instead regenerates from scratch each time the batch grows, which
    # cost five generations where one does.
    MAXNEED=0
    for B in $BATCHES; do
        for BE in 2 "$B2"; do
            NEED=$(inputs_needed "$B" "$BE")
            [ "$NEED" -gt "$MAXNEED" ] && MAXNEED=$NEED
        done
    done
    ensure_prep 4 "$MAXNEED"

    for p in 1 2; do
        if [ "$p" = 1 ]; then NAME=modconv1; BETA=2; else NAME=modconv2; BETA=$B2; fi
        BEST_TP=0; BEST_B=0; BEST_T=0; BEST_MB=0; BEST_R=0; BEST_E=0; BEST_S=0
        for B in $BATCHES; do
            for T in $THREAD_LIST; do
                if [ "$p" = 1 ]; then
                    repeat_online "$REPS" 4 modconv1_online 2 "$B" "$LWE_N" "$T"
                else
                    repeat_online "$REPS" 4 modconv2_online 4 "$B2" "$B" "$LWE_N" "$T"
                fi
                if [ "$(awk "BEGIN{print ($MED_S > 0)}")" != 1 ]; then
                    echo "    $NAME B=$B T=$T: FAILED"
                    echo "$NAME,$B,$T,0,0,0,-1,\"$RAW\"" >> "$SWEEP"
                    continue
                fi
                TP=$(awk "BEGIN{printf \"%.1f\", $B/$MED_S}")
                BPD=$(awk "BEGIN{printf \"%.1f\", $LAST_MB*1048576/$B}")
                echo "$NAME,$B,$T,$TP,$BPD,$LAST_ROUNDS,$ERR_TOTAL,\"$RAW\"" >> "$SWEEP"
                echo "    $NAME B=$B T=$T: $TP dec/s, $BPD bytes/dec, $LAST_ROUNDS rounds, mismatches $ERR_TOTAL"
                # a row is only admissible if it decrypted correctly every time
                [ "$ERR_TOTAL" -ne 0 ] && continue
                if [ "$(awk "BEGIN{print ($TP > $BEST_TP)}")" = 1 ]; then
                    BEST_TP=$TP; BEST_B=$B; BEST_T=$T; BEST_MB=$BPD
                    BEST_R=$LAST_ROUNDS; BEST_E=$ERR_TOTAL; BEST_S=$MED_S
                fi
            done
        done
        echo "$NAME,4,$BETA,1,1gbit,$EMU,$BEST_B,$BEST_T,$REPS,$BEST_S,$BEST_TP,$BEST_MB,$BEST_R,$BEST_E" >> "$CSV1"
        echo "=== $NAME best: $BEST_TP dec/s at batch=$BEST_B threads=$BEST_T ==="
    done
fi

# ------------------------------------------------------------------ preprocessing
# Measured twice, under two conventions that answer different questions.
#
#   generation=included  -- live preprocessing (-b). The oblivious-transfer
#       traffic that produces the random bits and Beaver triples is inside the
#       timer. This is the end-to-end cost of the offline phase.
#
#   generation=excluded  -- the material is read from disk (-F), so the timer
#       covers the protocol's own work alone. This is the convention of
#       Fhenix's Table 5, "ignoring triple and random-bit generation", and is
#       the row to set against it.
if [[ " $PHASES " == *" preproc "* ]]; then
    CSV3="$RESULTS/preproc.csv"
    echo "protocol,parties,beta,batch,ping_ms,bandwidth,net_emulated,generation,time_s,mb_party0,rounds,mismatches" > "$CSV3"
    net 1 1gbit
    B2=$(beta2_of "$PREPROC_N")
    ensure_prep "$PREPROC_N" "$(preproc_inputs_needed "$PREPROC_BATCH" "$B2" "$PREPROC_N")"

    for MODE in included excluded; do
        if [ "$MODE" = included ]; then FLAGS=(-b "$PREP_BATCH"); else FLAGS=(-F); fi

        compile_prog modconv1_preproc 2 "$PREPROC_BATCH"
        run_prog "$PREPROC_N" "$PROG" "${FLAGS[@]}"
        echo "modconv1,$PREPROC_N,2,$PREPROC_BATCH,1,1gbit,$EMU,$MODE,$RUN_S,$RUN_MB,$RUN_ROUNDS,$RUN_ERR" >> "$CSV3"
        echo "=== preproc modconv1 (generation $MODE): $RUN_S s, $RUN_MB MB, $RUN_ROUNDS rounds, mismatches $RUN_ERR ==="

        compile_prog modconv2_preproc "$PREPROC_N" "$B2" "$PREPROC_BATCH"
        run_prog "$PREPROC_N" "$PROG" "${FLAGS[@]}"
        echo "modconv2,$PREPROC_N,$B2,$PREPROC_BATCH,1,1gbit,$EMU,$MODE,$RUN_S,$RUN_MB,$RUN_ROUNDS,$RUN_ERR" >> "$CSV3"
        echo "=== preproc modconv2 (generation $MODE): $RUN_S s, $RUN_MB MB, $RUN_ROUNDS rounds, mismatches $RUN_ERR ==="
    done
fi

echo
echo "Results in $RESULTS/{throughput,throughput-sweep,latency,preproc}.csv"
