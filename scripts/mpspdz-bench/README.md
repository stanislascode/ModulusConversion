# Decryption benchmarks: latency and throughput

`ModConv1` and `ModConv2` of `sec:modconv` on MP-SPDZ's SPDZ2k backend,
measured as the decryption they are meant to serve. `q = 2^63`, `t = 2^64`.

Plain LWE over `Z_q`, not ring-LWE. Fhenix's `F_Decrypt` takes `c` as "an LWE
ciphertext over `Z_q`", its §1.2 has "the secret key is a vector `s` over
`Z_q = Z_{2^k}`", and `Π_Decrypt` step 1 computes `[z]_k = ⟨c,s⟩_k + 2^{l−1}`.
Its benchmark uses `(n, q, p) = (1024, 2^64, 2)`, which is what `LWE_N`
defaults to here.

## The instance

**Untimed.** A secret key `⟦s⟧ ∈ Z_q^n` with coordinates below `2^16`, and a
per-decryption message bit `⟦μ⟧`. The ciphertext coordinates are drawn at run
time by `regint.get_random(34)`, so every decryption in a batch gets its own,
without putting `batch × n` constants in the bytecode.

**Timed.**

1. `e = ⟨c, ⟦s⟧⟩` — local: `n` products by public constants and `n−1`
   additions, a `LinComb`, the MAC following by linearity.
2. `⟦x⟧ = e + ⟦μ⟧·2^63`.
3. `⟦x⟧ mod 2^63 = ⟦x mod 2^63⟧_{2^63}` — `DivModConv`, free, and not even an
   instruction: the machine ring is `t` and `q | t`, so the reduction is the
   identity on the sharing.
4. `ModConv(⟦x mod 2^63⟧_{2^63}) = ⟦x mod 2^63⟧_{2^64}` — one opening.
5. `⟦x⟧ − ⟦x mod 2^63⟧_{2^64} = ⟦μ⟧·2^63`, opened — one opening.

Two openings, one more than the bare conversion. That extra one is the point:
steps 1, 2 and 5 are local, but under SPDZ2k they still move the MAC, and
that cost only surfaces when the run opens something.

**Why the noise is in range without rejection.** The precondition is
`x mod 2^63 ≤ q − Nq/β`, which is `2^62` for both protocols at the β we use.
Here `x mod 2^63 = e = ⟨c,s⟩`, and with `n = 1024`, `s < 2^16` and `c < 2^34`
the worst case is `2^10 · 2^16 · 2^34 = 2^60 < 2^62`. So the bound holds by
construction, as it does in a real scheme where the noise is small by design,
rather than by resampling until it does. `sample_lwe_key` asserts it.

The ciphertext coordinates are therefore not uniform over `Z_q`. That changes
no cost — a 64-bit multiply is a 64-bit multiply — and it is what makes the
message bit exactly recoverable and checkable.

## Files

| File | Role |
|---|---|
| `modconv.py` | protocol library |
| `modconv1_online.mpc`, `modconv2_online.mpc` | timed decryption, preprocessing from a trusted dealer; args `… batch lwe_n threads …` |
| `modconv1_preproc.mpc`, `modconv2_preproc.mpc` | secure preprocessing, no dealer |
| `run_benchmark.sh` | the three benchmarks; generates its own offline data via `Fake-Offline.x` |
| `parse_run.py` | pulls timings out of a run log (used by the script) |

## Requirements

MP-SPDZ, built with the SPDZ2k binary. From your MP-SPDZ checkout:

```sh
make -j8 spdz2k-party.x
```

On macOS, install the dependencies once first (MP-SPDZ's own `make mac-setup`
does exactly this):

```sh
brew install openssl boost libsodium gmp yasm ntl cmake
```

On Debian/Ubuntu: `libsodium-dev libgmp-dev libssl-dev libboost-dev
libboost-thread-dev libboost-iostreams-dev libboost-filesystem-dev cmake
yasm`, plus GCC 11+ or clang 11+. `compile.py` is pure Python.

## How to run

```sh
export MPSPDZ=$HOME/MP-SPDZ      # the directory containing compile.py
./run_benchmark.sh
```

The default run reproduces Fhenix's own tables, so that every figure has a
counterpart to be set against:

| Phase | Output | Their table | Content |
|---|---|---|---|
| `latency` | `latency.csv` | Table 2, and the latency column of Table 1 | one ciphertext, parties {4,8,16} x ping {1,10,100} ms |
| `grid` | `grid.csv` | Table 3 | throughput, bandwidth {1 Gbit, 100 Mbit} x ping {1,10,100} ms x parties {4,8,16} |
| `preproc` | `preproc.csv` | Table 5 | preprocessing per thousand decryptions, N=2, under both conventions |
| `sweep` | `sweep.csv` | — | batch x threads at one network point; finds what a host is capable of. Not run by default. |

Every cell of `latency` and `grid` is run at each value of `THREAD_LIST`
(default `"1 5"`), so the single-threaded and multi-threaded figures sit side
by side in the same file and can be compared without a second run.

```sh
export MPSPDZ=$HOME/MP-SPDZ
PHASES="check" ./run_benchmark.sh    # verify shaping over the whole grid first
./run_benchmark.sh
```

Knobs: `PARTIES`, `THREAD_LIST`, `REPS` (default 5, reported as a median),
`LATENCY_PINGS`, `GRID_PINGS`, `BANDWIDTHS`, `GRID_BATCH` (default 10000),
`BATCHES` and `SWEEP_N` (the sweep), `PREPROC_BATCH`, `PREPROC_N`, `LWE_N`,
`SETTLE_S`, `RESULTS`.

**Two costs to know before starting.** The grid is
`|BW| x |PING| x |PARTIES| x |THREAD_LIST| x 2 protocols x REPS` runs — 360 at
the defaults — so budget an hour or more, and drop `REPS` to 3 for a first
look. And the offline data takes disk: roughly `174 MB x (N/4)^1.5` per
120000 inputs, where the input count is `lwe_n + (2 + beta) * batch`. The
script estimates this before each generation and refuses rather than filling
the disk, but check `df` first anyway.

### Why the offline data is not generated with `--default`

`Fake-Offline.x` writes **22 directories per party count**, one per protocol
family — gf2n, Shamir, replicated, dabits over other rings — of which these
programs read exactly one, `<N>-Z64,64-64`. Passing `--default` sizes all
twenty-two: at `N=16` that measured 16 GB where the SPDZ2k part was 1.9 GB,
and one benchmark run filled a 436 GB disk.

The script therefore uses the per-type counters instead — `-inp` for the
online phases, plus `-bit` and `-trip` for the preprocessing one — and deletes
the sibling directories once written. The same configuration that produced
893 MB under `--default` produces 108 MB this way, and the runs are
bit-for-bit unaffected.

If a previous run has already filled the disk, everything under
`Player-Data/[0-9]*-*` is regenerable:

```sh
rm -rf $MPSPDZ/Player-Data/[0-9]*-*
```

That touches no certificates (`P*.pem`, `*.key`) and no `Input-P*` files,
which compilation rewrites anyway.

**The preprocessing phase measures `-F` before live.** A live-preprocessing
run rewrites `Player-MAC-Keys-*`, which invalidates the signature on the files
`-F` reads; taking the two measurements in the other order fails with
"Signature ... doesn't match protocol".

Every row carries a `mismatches` column: the number of decryptions whose
opened plaintext differs from the value fixed in the clear at compile time.
Anything but `0` invalidates the row.

**Latency is run at 1 Gbit only.** Fhenix reports a single decryption's
latency to be bandwidth-independent, the protocol moving very little data, and
our own byte counts agree — 252 bytes per party per peer, whatever the link.
Their Table 2 gives 1 and 10 ms; we keep 100 ms because their raw logs supply
it and it is where our round advantage is largest.

### The online phases read their preprocessing from disk

`throughput` and `latency` run the VM with `-F`, so the correlated randomness
comes from files written beforehand by `Fake-Offline.x` rather than being
generated during the run. The script calls `Fake-Offline.x` itself, sized to
`lwe_n + (2 + beta) * batch` inputs with margin, and regenerates only when a
configuration needs more than the last one.

This requires a build with `-DINSECURE`, which the script checks for:

```sh
cd $MPSPDZ
echo "MY_CFLAGS += -DINSECURE" >> CONFIG.mine
make clean && make -j8 spdz2k-party.x Fake-Offline.x
```

Two things follow, and both matter for how the numbers may be reported.

**It is what makes the online measurement honest.** MP-SPDZ otherwise generates
preprocessing lazily, inside the timed region, and bills it to the online timer
(see the pool section below). With `-F` there is nothing to generate, so the
timer covers the online phase and nothing else --- which is the phase the
comparison is against, since Fhenix likewise separates its two phases and loads
its precomputed gates before timing.

**It is not a secure offline phase.** `Fake-Offline.x` is a trusted dealer.
The real cost of producing this material is what the `preproc` phase measures,
separately and with no dealer. Any write-up must say so; using dealer-supplied
preprocessing to time an online phase is standard, quoting it as if the offline
phase were free is not.

## Where the speed comes from

The batch is **vectorized**, not looped: `⟦s⟧`, the masks and the correction
tables are `sint` vectors of length `BATCH_SIZE`, so 1000 decryptions issue
the same *two* opening instructions as one, and the compiler reports 2001
opens executed in ~106 measured rounds rather than ~10 000. Almost all of the
throughput gain is this.

Do **not** run configurations concurrently to go faster: the parties already
share the machine, and overlapping runs would contend for CPU and corrupt
exactly the timings being measured. The parallelism that is safe here is the
vectorization.

### The preprocessing pool, and why the online phases no longer touch it

This trap cost this suite two wrong sets of numbers, and it is worth keeping
on record even though `-F` now sidesteps it for the online phases.

MP-SPDZ generates the authenticated randomness its MAC checks consume in
batches of `-b` values, **default 1000**. A timed region that opens more than
`-b` values exhausts the pool and regenerates it mid-run --- and that
regeneration is offline work, billed to the online timer. It is invisible
unless you look at the bytes:

| batch | MB inside the timer | bytes / decryption |
|---|---|---|
| 100 | 0.010 | 100 |
| 1000 | 6.405 | 6405 |
| 4000 | 25.62 | 6405 |

The honest figure is the first row: two openings of a `Z_{2^64}` share at
`N = 4` is `2 x 16 x 3 = 96` bytes. The rows at and above 1000 measure
preprocessing, at 64x the protocol's own cost.

Raising `-b` above the batch only postpones this. It caps out: at `batch=2000`
throughput collapsed from 43,668 to 13,093 decryptions/sec and at `batch=4000`
the run failed outright, because the pool is sized from the program's declared
usage and MAC-check randomness is not declarable. Raising it globally is worse
still --- a `batch=1` latency run then generates a 20,000-item pool it never
touches, which at `N=16` measured 69 seconds and 2.5 GB of traffic to decrypt
one ciphertext.

`-F` removes the problem rather than managing it: with the material on disk
there is nothing to generate, the batch has no ceiling, and the measurement is
flat at **11 rounds and 96 bytes per decryption from `batch=1000` to
`batch=10000`**. That flatness is the protocol's central property, and it is
what the `-b` path was hiding.

`PREP_BATCH` survives for the `preproc` phase alone, which measures the
preprocessing and therefore cannot read it from a file.

**How to check a row.** At `threads=1`, a batched row must report about 96
bytes per decryption at `N = 4`, scaling as `N - 1`, and 11 rounds regardless
of batch size. Under threading the byte figure is party 0's share across tapes
and is not comparable; compare it only at `threads=1`.

### Halving the MAC checks (`DEFER=1`)

The two openings are **dependent**: the index selecting the correction comes
from the first opened value. `SubProcessor::POpen` checks an opened value's MAC
both before and after every opening, so a dependent pair pays two full checks —
six round trips, against the 5.56 Fhenix spends.

`DEFER=1` opens both without checking and covers them with a single
`check_point()` before the timer stops. Measured, `N = 4`, batch 1000, ModConv1:

| | MP-SPDZ rounds | data/party | correctness |
|---|---|---|---|
| two checks (default) | 10 | 0.096312 MB | 0 mismatches |
| one batched check | **7** | 0.096252 MB | 0 mismatches |

Six round trips become four, below their 5.56, with the check inside the timed
region rather than deferred past it.

**It requires `patches/mpspdz-defer-check.patch`.** `reveal(check=False)` sets a
per-opening flag that the VM ignores, because `POpen` also checks whenever
`nthreads > 0` and the schedule file reports 1 even for a single-tape program.
The patch changes that to `> 1`, preserving the conservative behaviour where it
is needed. Without the patch `DEFER=1` runs and is correct but changes nothing;
compare the round counts of a `DEFER=0` and a `DEFER=1` row to tell.

**It works on a single tape only**, so the harness pairs it with `THREADS=1`
and skips the other combinations.

Why it is sound: nothing leaves the computation before the batched check, a
tampered opening selects a wrong correction and fails that check, `y` is masked
by a uniform `m` so tampering reveals no more than the honest value did, and the
check fails on a MAC mismatch independently of the plaintext, so there is no
selective failure. `patches/PATCH.md` states the argument in full — read it
against the protocol as specified before relying on the figures.

### A round reduction that does not work, and why

The two openings are **dependent**: the index selecting the correction comes
from the first opened value, and MP-SPDZ checks an opened value's MAC before it
may influence a further secret computation. A dependent pair costs twice what
an independent pair does — measured at `N = 4`, five of MP-SPDZ's rounds for
two independent openings against ten for two dependent ones, which is the six
round trips the latency fit shows against Fhenix's 5.56.

The obvious fix is to remove the dependency: open `y` together with all `β`
candidates `v_i = x + u_i`, which depend on nothing, then compute
`m = v_α − y` in the clear. It works, it is correct (0 mismatches over the
whole grid), and it does halve the round count, 11 to 6, for
`(β+1)/2` times the communication.

**It is also insecure, and must not be used.** The correction table is
`u_i = m − 2^63·c_i`, and `c_i` is *not* public: for ModConv1 it is
`[α(m) > i]`, a function of the secret mask. An adversary who sees both `y' = x + m`
and every `v_i` computes the differences `v_i − y' = −2^63·c_i`, in which `x`
cancels, and so recovers `α(m)` exactly. Since `y` is public and
`m = (y − x) mod q`, knowing `α(m)` confines `e = ⟨c, s⟩` to a range of width
`q/β` — `log₂ β` bits of the secret key leaked per decryption, and fatal over
many of them.

The sound route to fewer round trips is the other one: keep the openings
dependent but **defer the MAC check** of the first to the end. Opening
optimistically and checking all MACs before any output is released is the
standard SPDZ argument, a forged share would select a wrong correction, and the
final check would catch it. That would give four round trips against their
five. It needs MP-SPDZ to be persuaded not to check eagerly — `POpen` calls
`check()` on the compiler's say-so and we found no lever for it — so it is a
virtual-machine change, not a program one.

### Threads per party

`THREADS` splits the batch across `@multithread` tapes; the script sweeps it
over `THREAD_LIST` and reports the best point together with the batch size that
produced it.

It helps, once the preprocessing is off the critical path. Measured at `N = 4`
on a 20-core host, ModConv1, decryptions/sec:

| | batch 1000 | batch 5000 | batch 10000 |
|---|---|---|---|
| 1 thread | 50,383 | 74,722 | 74,500 |
| 2 | 91,394 | 67,347 | 84,183 |
| 4 | 86,342 | 109,265 | 102,435 |
| 5 | 71,978 | 87,395 | 110,610 |

Two things to read out of that table. The batch matters more than the threads
--- one thread at batch 5000 already beats one thread at batch 1000 by 48% ---
because the rounds are fixed and a larger batch dilutes them. And the surface
is **not** monotone: the machine has 20 cores for `N x THREADS` runnable
threads, so points contend with each other and single runs are noisy. That is
why `REPS` defaults to 5 and the script reports a median.

An earlier revision of this file claimed threading was a net loss. That was
measured on a two-core host running four parties --- oversubscribed before a
single extra thread was asked for --- and it was wrong. Where the time actually
goes: holding everything else fixed and varying the LWE dimension gives 0.014 s
at `n = 1` against 0.037 s at `n = 1024`, so the inner product is about 62% of
the online time and is local arithmetic, which is exactly what extra cores
parallelise. The remaining 38% is the two openings, which they do not.

The cost of extra tapes is that each opens separately, so the reported round
count scales with `THREADS` (11 at 1 thread, 22 at 2, 55 at 5). Those rounds
overlap in wall time when there are cores to run them and serialise when there
are not, which is the whole of the difference between the two measurements
above. Latency rows are pinned to `THREADS=1`, since at `batch=1` there is
nothing to split.

### Why `compile.py` cannot just go in your PATH

`compile.py` must run with the MP-SPDZ root as its working directory: it
imports the `Compiler` package from there, reads sources from
`Programs/Source/`, and writes bytecode to `Programs/Bytecode/`. A symlink on
`PATH` would resolve all of those against whatever directory you happen to be
in. `Scripts/spdz2k.sh` has the same property — it locates `spdz2k-party.x`
and `Player-Data/` relative to the MP-SPDZ root — and our `.mpc` files write
the dealer's values into `Player-Data/Input-P0-0` relative to the working
directory at compile time. So the scripts `cd` into `$MPSPDZ` and run
everything from there; that is what the `MPSPDZ` variable is for.

The scripts compile immediately before each run. This is required, not
cosmetic: the dealer's values go to `Player-Data/Input-P0-0` at compile time,
so compiling several programs and then running them makes each one read
another's inputs.

## What is measured

The timer covers the timed steps above (or the preprocessing) and nothing
else. Excluded, deliberately:

- sampling the instance and the dealer's `Input` calls handing the
  preprocessing to the parties — Fhenix likewise loads its precomputed gates
  into memory before timing starts;
- a one-time warm-up `Open`, which absorbs SPDZ2k's first-Open setup cost
  (~80 rounds for the first `Open` in a process, ~5 for every one after it —
  a session cost, not a per-decryption cost).

Both openings of the decryption are *inside* the timer, the final one
included: it produces the plaintext, so it is protocol, not verification.
Correctness costs no further opening — the script compares the opened
plaintexts against the bits fixed in the clear at compile time, and every row
carries the resulting `mismatches` count, which is 0 on a good run.

## Parameters

`q = 2^63`, `t = 2^64`, compiled with `-R 64`, so the machine ring **is** `t`
exactly and no ring slack is needed anywhere.

| | β | precondition on `x` | Mults (preprocessing) |
|---|---|---|---|
| ModConv1 | 2, fixed for every N | `cs mod 2^63 ≤ q − q/β = 2^62` | 0 |
| ModConv2 | depends on N — see below | `cs mod 2^63 ≤ q − Nq/β = 2^62` | `(N−1)β²` |

### β for ModConv2 is a decision, not a detail

`protocol:modconv2` requires `β ≥ N+1`, so unlike ModConv1 its β cannot be
held fixed across party counts. Which β to pick above that floor is a real
trade-off, and the default here (`BETA2` unset → the smallest power of two
`≥ N+1`) is one end of it:

| N | β = N+1 (the floor) | mults | bound on `x` | β = 2^k (default here) | mults | bound on `x` |
|---|---|---|---|---|---|---|
| 2 | 3 | 9 | `q/3` | 4 | 16 | `q/2` |
| 4 | 5 | 75 | `q/5` | 8 | 192 | `q/2` |
| 8 | 9 | 567 | `q/9` | 16 | 1792 | `q/2` |
| 16 | 17 | 4335 | `q/17` | 32 | 15360 | `q/2` |

Multiplication counts are measured from `compile.py`, and match `(N−1)β²`
exactly at every point. So the power-of-two default buys a much better input
bound — `q/2` at every N instead of `q/(N+1)` — and pays roughly 3.5× the
preprocessing multiplications for it. Which side of that is right depends on
what the paper wants to claim; it is not for the benchmark to decide.

Override it by editing the `beta2_of` helper in `run_benchmark.sh`, or by
compiling `modconv2_online` by hand with the β you want:

```sh
PARTIES="4" ./run_benchmark.sh   # beta is the second program argument
```

**Caveat: only powers of two are implemented.** `modconv.py` derives the
interval index `α(m)` by slicing the top bits of `m`, which needs `β | q` as
2-powers, and `log2_exact` asserts it — `BETA2=5` will abort. Supporting the
floor `β = N+1` exactly means implementing the general interval machinery the
2-power case lets us skip: unequal interval lengths, the public bits `g_i`,
the comparison of the offset against `T`, and the rejection loop. That is a
real piece of work, not a flag, and it is not here.

ModConv1 is unaffected: `β = 2` is a power of two at every N, and the
`remark*` after `protocol:modconv1-preproc` is exactly the case that makes
its preprocessing free of multiplications.

Three simplifications the parameters license, each from the paper:

- `q | t`, so `remark:modconv{1,2,3}-divisible` applies: `⟦m⟧_q` is never
  stored. It follows from the corrections (resp. the mask bits) by a
  `DivModConv`, which is free.
- `q` and `β` are powers of two, so `q/β` is too. Per the text following
  `protocol:modconv1-preproc`, the comparison step drops, the acceptance
  test reduces to opening `⟦h⟧_Q` with `h = 1`, and nothing is ever
  rejected. ModConv1's preprocessing is therefore `k = 63` shared random
  bits and local linear combinations: no multiplication, no opening.

ModConv2 uses `Q = t` as its auxiliary modulus. The paper endorses this
(`taking Q to be t leaves step:modconv2-preproc:transfer nothing to do ...
and thus returns the protocol one obtains by leaving the auxiliary modulus
out altogether`), and a single-ring MP-SPDZ program has no cheaper option.

## Deviations from the paper

**ModConv2's preprocessing takes plain `Input`, not `CheckedInput`.** The
paper's `step:modconv2-preproc:input` and `step:modconv2-preproc:range` prove
bit-ness and the range condition on each party's contribution, and
`step:modconv2-preproc:cons-check` runs `maBitsConsCheck` across the moduli.
Here the parties' vectors go in through SPDZ2k's own authenticated `Input`,
which authenticates the values but proves nothing about their shape. Only
the hot-one check (`step:modconv2-preproc:hot-one`) is implemented; every
run prints its opened value, which must be 1. **ModConv2's preprocessing
numbers therefore understate the paper's protocol**, and by an amount this
suite does not measure. ModConv1's preprocessing takes no input and is
not affected.

**The `⟦x⟧_q` sharing is embedded in the `2^64` machine ring.** A genuine
`Z_{2^63}` sharing has shares whose sum is only defined mod `2^63`; here
party 0 inputs `x` exactly, so the opened `y` carries a top bit that a real
`Z_{2^63}` sharing would randomize. The protocol reduces `y` mod `q` before
using it, so correctness is unaffected and the communication cost is
identical; only that one bit of the transcript differs from the real thing.

## Reading the CSV

All four CSVs share one row format, so they can be concatenated and filtered.
Every row is the median of `REPS` runs and carries its own `raw_times_s`, so
the spread is visible rather than hidden behind the median; `time_ms_median`
is the figure to read for `latency`, `throughput_dec_per_sec` for `grid` and
`sweep`.

Three checks before a row is worth reporting:

- `mismatches` is `0`. The sweep will not elect a point that is not.
- `rounds` is 11 for a batched row and 10 for `batch=1`, at `threads=1`.
  MP-SPDZ counts one round per polling iteration of its socket exchange, not
  per network round-trip, so a single `Open` reports 5. The protocol-level
  figure is the two openings.
- `bytes_per_dec` is about 96 at `N = 4`, scaling as `N - 1`. Far above that
  means preprocessing inside the timer, which `-F` should have made impossible;
  under `threads > 1` the figure is party 0's share across tapes and is not
  comparable.

The `raw_times_s` column exists because the sweep surface is not monotone on a
shared host. If the spread within a point approaches the gap between points,
raise `REPS` rather than reporting the difference.

One display artifact to expect rather than debug: MP-SPDZ occasionally reports
`Time1 = ... (0 MB, 0 rounds)` for party 0, which surfaces as `0.0` in
`bytes_per_dec` and `0` in `rounds`. The timing and `mismatches` for that run
are still valid; it is a quirk of which party the per-thread accounting is
attributed to, not a failed measurement. It is another reason to read the
`rounds` column across a whole sweep rather than from one cell.

## Ordering, and why the phases run cold first

`latency` runs before `throughput`, which runs before `preproc`, regardless of
the order named in `PHASES`. This is not arbitrary: the throughput sweep is by
far the heaviest phase, and the latency measurement is the one made entirely of
network round-trips, so measuring latency after throughput reads the host's
recovery rather than the link. On one run that produced a 14.5 ms loopback RTT
under a nominal 1 ms.

`net()` additionally waits for every `spdz2k-party.x` to exit before it
measures, and then checks the RTT against the nominal ping rather than merely
printing it (`SETTLE_S` tunes the extra pause, default 3 s). Outside a
tolerance of `max(1 ms, 50%)` the run stops rather than write rows carrying a
ping label they did not experience; `ALLOW_BAD_RTT=1` overrides it and marks
those rows `net_emulated=degraded`.

## Network emulation

The grid is Fhenix's: ping {1, 10, 100} ms crossed with 1 Gbit/s, applied
with `tc netem` on loopback, and `-d` so parties talk pairwise rather than
through a coordinator.

**Check before committing to a long run:**

```sh
PHASES="check" ./run_benchmark.sh
```

This applies each ping in turn and prints the loopback RTT it actually
measures with `ping`, then exits. If the measured RTT does not track what was
asked, the shaping is not doing what you think and the benchmark rows would
be mislabelled.

**The script refuses to run unshaped.** If `tc` cannot attach, it stops with
a diagnosis instead of producing a full grid of rows carrying ping labels
they never experienced — which is exactly what happened on an earlier
attempt, where the online sweep silently produced 54 such rows. To run
unshaped deliberately (for a pure rounds-and-bytes measurement) pass
`ALLOW_NO_TC=1`; those rows are then explicitly not latency measurements.

`tc` needs three things:

1. **The binary.** `sudo apt install iproute2`, or `sudo dnf install iproute-tc`.
2. **Root.** `tc qdisc add` is privileged. The script calls `sudo tc`
   automatically when not run as root; you may be prompted once. This was the
   original cause of the asymmetry between an earlier preprocessing run
   (which happened to be run as root, and shaped correctly) and the online
   sweep (which was not, and silently did not).
3. **The `sch_netem` kernel module.** Present on a normal distro kernel,
   missing from minimal cloud images and most containers. Symptom:
   `Error: Specified qdisc kind is unknown`. Fix:

   ```sh
   sudo apt install linux-modules-extra-$(uname -r)
   sudo modprobe sch_netem
   ```

   `Operation not permitted` instead means no `NET_ADMIN` capability — a
   Docker container needs `--cap-add=NET_ADMIN`.

The delay is set to half the requested ping, because a loopback packet
crosses `lo` once each way, so the round trip sees it twice. The `check`
phase is what confirms that on your kernel.
