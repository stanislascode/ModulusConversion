# `mpspdz-defer-check.patch`

Lets a single-tape program defer its MAC checks, so that two dependent
openings cost one batched check instead of two.

## What it changes

`SubProcessor<T>::POpen` checks before and after every opening when

```cpp
if (inst.get_n() or BaseMachine::s().nthreads > 0)
```

`inst.get_n()` is the per-opening flag that `reveal(check=...)` sets from the
program. The second clause makes it dead: the schedule file gives `nthreads = 1`
even for a program with one tape, so the condition is always true and
`reveal(check=False)` has no effect. The patch changes `> 0` to `> 1`, which
keeps the conservative behaviour for genuinely multi-threaded programs — where
an opened value may reach another thread through memory before it is checked —
and lets a single-tape program say what it means.

## Why deferring is sound here

The decryption opens twice: `y = x + m`, from which the correction index is
derived, and then the plaintext. With `DEFER=1` neither is checked at the point
of opening, and a single `check_point()` covers both before `stop_timer` and
before any value leaves the computation.

- A tampered first opening yields a wrong index, hence a wrong correction,
  hence a wrong plaintext, and the batched check fails: the program aborts
  with nothing released. This is the standard optimistic-opening argument.
- Nothing extra leaks. `y` is masked by a uniform `m`; tampering replaces it
  with `y + δ` for an adversarial `δ`, which reveals no more than `y` did.
- No selective failure: the check fails because a MAC does not match, which
  does not depend on the plaintext, so the abort probability carries no
  information.

`MAC_Check_Z2k::Check` verifies every value opened since the last check with
one random linear combination, which is what makes a single check at the end
cover both openings.

## Measured

`N = 4`, batch 1000, ModConv1, preprocessing from disk:

| | MP-SPDZ rounds | data/party | correctness |
|---|---|---|---|
| two checks (default) | 10 | 0.096312 MB | 0 mismatches |
| one batched check | **7** | 0.096252 MB | 0 mismatches |

Fitting latency against ping time, that is six round trips against four, where
Fhenix spends 5.56.

## Applying it

```sh
cd $MPSPDZ
patch -p1 < /path/to/mpspdz-defer-check.patch
make -j8 spdz2k-party.x
```

Without the patch, `DEFER=1` compiles and runs correctly but changes nothing,
because the VM ignores the flag. The harness cannot detect this; compare a
`DEFER=0` and a `DEFER=1` row and check the round counts differ.

## Limits

Only at `THREADS=1`. With more than one tape `nthreads > 1` holds and the VM
checks eagerly again, which is the conservative behaviour the patch preserves
on purpose. The harness therefore runs `DEFER=1` only in single-threaded cells.
