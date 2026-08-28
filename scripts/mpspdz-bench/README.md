# Modulus-conversion benchmarks: Z_{2^63} → Z_{2^64}

Benchmarks for the three protocols of `sec:modconv`, run on MP-SPDZ's SPDZ2k
backend. Pure modulus conversion — no threshold-decryption wrapper.

**Input:** a SPDZ2k sharing `⟦x⟧_q` with `q = 2^63`.
**Output:** a SPDZ2k sharing `⟦x⟧_t` with `t = 2^64`.

## Files

| File | Role |
|---|---|
| `modconv.py` | protocol library (dealer, preprocessing, online phases) |
| `modconv1_preproc.mpc`, `modconv2_preproc.mpc`, `modconv3_preproc.mpc` | secure preprocessing, no dealer |
| `modconv1_online.mpc`, `modconv2_online.mpc`, `modconv3_online.mpc` | online phase, preprocessing from a trusted dealer |
| `run_preproc.sh` | preprocessing sweep, `N = 2` |
| `run_online.sh` | online sweep, `N ∈ {4,8,16}` × Fhenix's network grid |

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

On Debian/Ubuntu the equivalent is `libsodium-dev libgmp-dev libssl-dev
libboost-dev libboost-thread-dev libboost-iostreams-dev libboost-filesystem-dev
cmake yasm`, plus GCC 11+ or clang 11+. MP-SPDZ builds libOTe itself via
`make libote` when needed. Python 3 is required for `compile.py`, which is
pure Python and needs no packages of its own.

## How to run

The scripts live in this repo and stay there. Tell them where your MP-SPDZ git
root is — the directory containing `compile.py` — and run them:

```sh
export MPSPDZ=$HOME/MP-SPDZ

./run_preproc.sh        # preprocessing, N=2
./run_online.sh         # online, N=4,8,16 x {1,10,100}ms x {100Mbit,1Gbit}
```

Without `MPSPDZ` set, both scripts stop immediately and say so.

They copy `modconv.py` and the six `.mpc` into `$MPSPDZ/Programs/Source/` on
every run, so editing them here is enough — no manual sync.

Results land in this repo, under `results/{preproc,online}/`: a `summary.csv`
plus one `.log` per configuration. Override with env vars:

```sh
PARTIES="4 8" PINGS="10" BATCH=128 BETA2=8 ./run_online.sh
RESULTS=/tmp/out ./run_preproc.sh
```

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

The timer covers the online phase (or the preprocessing) and nothing else.
Excluded, deliberately:

- the dealer's `Input` calls that hand the preprocessing to the parties —
  Fhenix likewise loads its precomputed gates into memory before timing;
- a one-time warm-up `Open`, which absorbs SPDZ2k's first-Open setup cost
  (measured at ~80 rounds for the first `Open` in a process, ~5 for every
  one after it — a session cost, not a per-conversion cost);
- the final `Open` that checks the result against the expected value. That
  opening is verification, not protocol. Every run reports `converted value`
  and `expected value`, and `summary.csv` carries a `correct` column.

## Parameters

`q = 2^63`, `t = 2^64`, compiled with `-R 64`, so the machine ring **is** `t`
exactly and no ring slack is needed anywhere.

| | β | precondition on `x` | Mults (preprocessing) |
|---|---|---|---|
| ModConv1 | 2, fixed for every N | `x ≤ q − q/β = 2^62` | 0 |
| ModConv2 | depends on N — see below | `x ≤ q − Nq/β` | `(N−1)β²` |
| ModConv3 | — | none | 0 |

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

Override it with `BETA2`:

```sh
BETA2=5 PARTIES="4" ./run_online.sh
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
- `q = 2^63` is a power of two, so by the parenthetical in
  `step:modconv3-preproc:accept` ModConv3's preprocessing skips its
  comparison and rejection too, leaving the same 63 random bits.

ModConv2 uses `Q = t` as its auxiliary modulus. The paper endorses this
(`taking Q to be t leaves step:modconv2-preproc:transfer nothing to do ...
and thus returns the protocol one obtains by leaving the auxiliary modulus
out altogether`), and a single-ring MP-SPDZ program has no cheaper option.

## Comparison

ModConv3's online phase compares the bit-shared mask against the public `y`.
It is implemented as a bitwise circuit over the shared mask bits: the
XOR-with-public terms are linear and free, and the only cost is a suffix
product over the 63 equality bits, computed by a doubling scan — 315
multiplications in 6 rounds. This is why no ring slack is needed: nothing
here is a generic secure comparison of two large secret values.

`protocol:compare` and `sec:compare` are forward references to a section not
yet written, so this is one concrete point on the multiplication/round
trade-off that section is meant to lay out, not an implementation of a
protocol the paper already fixes.

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
suite does not measure. ModConv1's and ModConv3's preprocessing have no
inputs and are not affected.

**The `⟦x⟧_q` sharing is embedded in the `2^64` machine ring.** A genuine
`Z_{2^63}` sharing has shares whose sum is only defined mod `2^63`; here
party 0 inputs `x` exactly, so the opened `y` carries a top bit that a real
`Z_{2^63}` sharing would randomize. The protocol reduces `y` mod `q` before
using it, so correctness is unaffected and the communication cost is
identical; only that one bit of the transcript differs from the real thing.

## Reading the CSV

`time_s, mb_party0, rounds` come from the timer, so they cover the phase and
not the setup around it. Two caveats on `rounds`:

- MP-SPDZ counts one round per polling iteration of its socket exchange, not
  per network round-trip, so a single `Open` reports 5 rounds rather than 1.
  Use the compiler's `integer opens` count for round complexity — 2 for
  ModConv1 and ModConv2 (1 protocol `Open` + 1 verification), 3 for ModConv3.
- `batch` records MP-SPDZ's `-b` preprocessing batch size. It changes the
  measured rounds and data substantially (ModConv3 at `N = 16`: 185 rounds
  at the default vs 971 at `-b 128`), so it must be held constant across any
  configurations being compared. It is in the CSV for exactly that reason.

`BATCH=128` is needed for ModConv3 at `N = 16` on a small machine: with
MP-SPDZ's default batch size, live OT triple generation across 16 parties
exhausts memory (`bad_alloc`). ModConv1 and ModConv2 need no triples and run
at `N = 16` at the default batch size.

## Network emulation

Both scripts apply `tc netem` when it is available, crossing the ping times
`{1, 10, 100}` ms with bandwidths `{100 Mbit/s, 1 Gbit/s}` — Fhenix's grid —
and pass `-d` so parties communicate pairwise rather than through a
coordinator, matching its fully connected topology.

`tc` needs Linux with `NET_ADMIN` and a kernel carrying `sch_netem`; it is
absent on macOS and inside restricted containers. When it is missing the
scripts say so, run every configuration at native loopback speed, and record
`net_emulated=no` with the ping and bandwidth columns naming the condition
that was *intended*. Those rows are not latency measurements.
