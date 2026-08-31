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
| `run_benchmark.sh` | the three benchmarks |
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

Three phases, three CSVs in `results/`:

| Phase | Output | Content |
|---|---|---|
| `throughput` | `table1.csv` | N=4, 1 ms, 1 Gbit: latency (ms) and throughput (dec/sec) for both protocols |
| `latency` | `table2.csv` | latency across ping {1,10,100} ms × parties {4,8,16} |
| `preproc` | `preproc.csv` | seconds for the batched preprocessing of 1000 decryptions, N=2 |

Run one phase at a time with `PHASES="preproc" ./run_benchmark.sh`. Other
knobs: `BATCH_SIZE` (default 1000), `PREP_BATCH` (the VM's `-b`, see below),
`THREADS` (default 1, see below), `PARTIES`, `PINGS`, `PREPROC_N`, `LWE_N`,
`RESULTS`.

Every row carries a `mismatches` column: the number of decryptions in the
batch whose opened plaintext differs from the value fixed in the clear at
compile time. Anything but `0` invalidates the row.

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

### The preprocessing pool must outsize the batch

This is the single largest correctness trap in the throughput measurement,
and an earlier run of this suite fell into it.

MP-SPDZ generates the authenticated randomness its MAC checks consume in
batches of `-b` values, **default 1000**. A timed region that opens more than
`-b` values exhausts the pool and regenerates it mid-run — and that
regeneration is offline work, billed to the timer. It is invisible unless you
look at the bytes:

| batch | MB inside the timer | bytes / decryption |
|---|---|---|
| 100 | 0.010 | 100 |
| 1000 | 6.405 | 6405 |
| 4000 | 25.62 | 6405 |

The honest figure is the first row. Two openings of a `Z_{2^64}` share at
`N = 4` is `2 × 16 × 3 = 96` bytes, and `batch = 100` measures 100. The batches
at and above 1000 measure preprocessing, at 64× the protocol's own cost.

`PREP_BATCH` (default `max(20 × BATCH_SIZE, 20000)`) is passed to the VM as
`-b`, so the pool is generated once. That alone is not enough: the generation
still has to happen *outside* the timer, which is what the circuit-shaped
warm-up does — the online programs run `decrypt_batch` once, in full, before
`start_timer(1)`. A scalar warm-up `Open` does not size the pool and leaves
the cost in the timer; both pieces are required.

With both in place, `batch = 1000` at `N = 4` reports 0.0964 MB and 11 rounds,
against the 0.00072 MB and 10 rounds of `batch = 1`. That is what
vectorization is supposed to look like, and it is the row to trust.

### Threads per party: measured, and not worth it

`THREADS` splits the batch across `@multithread` tapes. It defaults to **1**,
because measurement says more is worse. At `N = 4`, `batch = 1000`, with the
pool sized correctly:

| THREADS | time | rounds | dec/sec |
|---|---|---|---|
| 1 | 0.0403 s | 11 | 24 800 |
| 2 | 0.0483 s | 22 | 20 700 |
| 5 | 0.1368 s | 55 | 7 300 |

The reasoning that motivated threading — that a party is CPU-bound on
`BATCH_SIZE × n` local multiplications while cores sit idle — is wrong about
the critical path. The timed region is *two opening instructions*. Each extra
tape opens separately, so rounds scale with `THREADS` while the CPU work that
could be split is not what the run is waiting on. At 1 ms ping a round costs
about 0.7 ms, so 55 rounds spend ~30 ms to save ~18 ms of arithmetic.

The knob remains so the table above can be reproduced, and `table1.csv`
records the column so no row is ever read at the wrong thread count. Latency
rows are hard-coded to `THREADS=1` in the script rather than taken from the
environment.

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

`time_s, mb_party0, rounds` come from the timer, so they cover the phase and
not the setup around it. Two caveats on `rounds`:

- MP-SPDZ counts one round per polling iteration of its socket exchange, not
  per network round-trip, so a single `Open` reports 5 rounds rather than 1.
  Use the compiler's `integer opens` count for round complexity: 2 for both
  protocols, being the conversion's opening plus the one that yields the
  message. The measured figure is 10, five per opening.
- A batched row should report ~96 bytes per decryption at `N = 4` and a round
  count within one or two of the `batch = 1` row. Anything far above that is
  preprocessing inside the timer — see the pool section above — not a slower
  protocol.

Neither protocol's online phase consumes a triple, so both run at `N = 16` at
the default batch size. `BATCH` is there for the preprocessing of ModConv2,
whose `(N−1)β²` multiplications grow quickly with the party count.

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
