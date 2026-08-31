import os
import random

from Compiler.types import sint, cint, regint, Array
from Compiler.library import print_ln, multithread, check_point

K_Q = 63
K_T = 64
Q = 1 << K_Q
T = 1 << K_T


def log2_exact(n):
    assert n & (n - 1) == 0 and n > 0
    return n.bit_length() - 1


def next_pow2_at_least(n):
    p = 1
    while p < n:
        p *= 2
    return p


def default_beta_modconv2(n_parties):
    return next_pow2_at_least(n_parties + 1)


def alpha_of(v, beta):
    return (beta * v) // Q


class Inputs:
    def __init__(self, n_parties):
        self.vals = [[] for _ in range(n_parties)]
        os.makedirs('Player-Data', exist_ok=True)

    def put_many(self, party, vs):
        self.vals[party].extend(int(v) for v in vs)

    def flush(self):
        for p, vs in enumerate(self.vals):
            with open('Player-Data/Input-P%d-0' % p, 'w') as f:
                f.write(' '.join(str(v) for v in vs) + '\n')


def read_from(party, n):
    return [sint.get_input_from(party) for _ in range(n)]


def read_vec_from(party, size):
    return sint.get_input_from(party, size=size)


def warm_up():
    return sint(0).reveal(check=False)


def warm_up_threads(*args, **kwargs):
    decrypt_batch(*args, **kwargs)


def combine_bits(bits, size=1):
    acc = sint(0, size=size)
    for i in range(len(bits)):
        acc = acc + bits[i] * (1 << i)
    return acc


def onehot(abits):
    vec = [1 - abits[0], abits[0]]
    for j in range(1, len(abits)):
        a = abits[j]
        half = len(vec)
        new = [None] * (2 * half)
        for p in range(half):
            hi = vec[p] * a
            new[p] = vec[p] - hi
            new[p + half] = hi
        vec = new
    return vec


def corrections(m, carry, delta, beta):
    us = []
    for i in range(beta):
        acc = carry
        for j in range(i + 1, beta):
            acc = acc + delta[j]
        us.append(m - acc * Q)
    return us


def preproc_modconv1(beta, size=1):
    n_l = K_Q - log2_exact(beta)
    bits = [sint.get_random_bit(size=size) for _ in range(K_Q)]
    m = combine_bits(bits, size)
    return m, corrections(m, sint(0, size=size), onehot(bits[n_l:]), beta)


def sample_party_shares_modconv2(beta, n_parties, inputs, size=1):
    n_l = K_Q - log2_exact(beta)
    for s in range(n_parties):
        masks = [random.randrange(Q) for _ in range(size)]
        for i in range(n_l):
            inputs.put_many(s, [(v >> i) & 1 for v in masks])
        for i in range(beta):
            inputs.put_many(s, [1 if alpha_of(v, beta) == i else 0 for v in masks])
    return n_l


def preproc_modconv2(beta, n_parties, n_l, size=1):
    deltas = []
    m = sint(0, size=size)
    for s in range(n_parties):
        bits = [read_vec_from(s, size) for _ in range(n_l)]
        d = [read_vec_from(s, size) for _ in range(beta)]
        part = combine_bits(bits, size)
        for i in range(beta):
            part = part + d[i] * (i * (Q // beta))
        m = m + part
        deltas.append(d)

    Delta = deltas[0]
    w = sint(0, size=size)
    for s in range(1, n_parties):
        prod = [[Delta[jp] * deltas[s][i] for i in range(beta)] for jp in range(beta)]
        new = []
        for j in range(beta):
            acc = sint(0, size=size)
            for jp in range(beta):
                for i in range(beta):
                    if (jp + i) % beta == j:
                        acc = acc + prod[jp][i]
            new.append(acc)
        chi = sint(0, size=size)
        for jp in range(beta):
            for i in range(beta):
                if jp + i >= beta:
                    chi = chi + prod[jp][i]
        Delta = new
        w = w + chi

    return m, corrections(m, w, Delta, beta)


def deal_modconv1(beta, size):
    ms, us = [], [[] for _ in range(beta)]
    for _ in range(size):
        m = random.randrange(Q)
        am = alpha_of(m, beta)
        ms.append(m)
        for i in range(beta):
            us[i].append((m - Q * (1 if am > i else 0)) % T)
    return ms, us


def deal_modconv2(beta, n_parties, size):
    ms, us = [], [[] for _ in range(beta)]
    for _ in range(size):
        parts = [random.randrange(Q) for _ in range(n_parties)]
        m = sum(parts)
        s = sum(alpha_of(v, beta) for v in parts)
        ms.append(m % Q)
        for i in range(beta):
            c = -((-(s - i)) // beta)
            us[i].append((m - c * Q) % T)
    return ms, us


def sample_lwe_key(n, s_bits, c_bits, bound):
    worst = n * ((1 << s_bits) - 1) * ((1 << c_bits) - 1)
    assert worst <= bound, (worst, bound)
    return [random.randrange(1, 1 << s_bits) for _ in range(n)]


def lwe_inner_product(sk_shares, c_bits, size):
    acc = None
    for s in sk_shares:
        term = s * cint(regint.get_random(c_bits, size=size))
        acc = term if acc is None else acc + term
    return acc


def online_lookup(x, m, u_vecs, beta):
    n_u = log2_exact(beta)
    y = (x + m).reveal() & (Q - 1)
    alpha = y >> (K_Q - n_u)
    u = u_vecs[0] * (alpha == 0)
    for i in range(1, beta):
        u = u + u_vecs[i] * (alpha == i)
    return y - u, y


def signed_t(v):
    v %= T
    return v - T if v >= T // 2 else v


def count_mismatches(opened, expected, size):
    ref = Array(size, cint)
    ref.assign(expected)
    diff = Array(size, regint)
    diff.assign_vector(regint(opened != ref.get_vector(0, size)))
    total = regint(0)
    for i in range(size):
        total = total + diff[i]
    return total


def to_array(vec, size):
    a = sint.Array(size)
    a.assign_vector(vec)
    return a


def _decrypt_body(sk_arr, mu_arr, m_arr, u_arrs, beta, n_u, out, base, size,
                  c_bits, defer):
    acc = None
    for j in range(len(sk_arr)):
        term = sk_arr[j] * cint(regint.get_random(c_bits, size=size))
        acc = term if acc is None else acc + term
    x = acc + mu_arr.get_vector(base, size) * Q
    # The first opening is masked by m, and nothing leaves the computation
    # before the second is checked, so its MAC check may be deferred: a
    # tampered value selects a wrong correction and the final check -- which
    # covers every value opened since the last check -- fails. Needs the POpen
    # patch and a single tape, MP-SPDZ checking unconditionally once a program
    # has threads.
    y = (x + m_arr.get_vector(base, size)).reveal(check=not defer) & (Q - 1)
    alpha = y >> (K_Q - n_u)
    u = u_arrs[0].get_vector(base, size) * (alpha == 0)
    for i in range(1, beta):
        u = u + u_arrs[i].get_vector(base, size) * (alpha == i)
    out.assign_vector((x - (y - u)).reveal(check=not defer), base=base)


def decrypt_batch(sk_arr, mu_arr, m_arr, u_arrs, beta, batch, c_bits, threads,
                  defer=False):
    n_u = log2_exact(beta)
    out = Array(batch, cint)

    if threads <= 1:
        _decrypt_body(sk_arr, mu_arr, m_arr, u_arrs, beta, n_u, out, 0, batch,
                      c_bits, defer)
        if defer:
            # one batched check covering both openings, inside the timer, and
            # before any value leaves the computation
            check_point()
        return out

    @multithread(threads, batch)
    def _(base, size):
        _decrypt_body(sk_arr, mu_arr, m_arr, u_arrs, beta, n_u, out, base,
                      size, c_bits, False)

    return out
