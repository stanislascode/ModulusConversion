import os
import random

from Compiler.types import sint, cint, regint, Array
from Compiler.library import print_ln

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

    def put(self, party, v):
        self.vals[party].append(int(v))
        return len(self.vals[party]) - 1

    def put_many(self, party, vs):
        return [self.put(party, v) for v in vs]

    def flush(self):
        for p, vs in enumerate(self.vals):
            with open('Player-Data/Input-P%d-0' % p, 'w') as f:
                f.write(' '.join(str(v) for v in vs) + '\n')


def read_from(party, n):
    return [sint.get_input_from(party) for _ in range(n)]


def warm_up():
    return sint(0).reveal()


def random_bits(n):
    return [sint.get_random_bit() for _ in range(n)]


def combine_bits(bits):
    acc = sint(0)
    for i in range(len(bits)):
        acc = acc + bits[i] * (1 << i)
    return acc


def onehot(abits):
    n = len(abits)
    vec = [1 - abits[0], abits[0]]
    for j in range(1, n):
        a = abits[j]
        size = len(vec)
        new = [None] * (2 * size)
        for p in range(size):
            hi = vec[p] * a
            new[p] = vec[p] - hi
            new[p + size] = hi
        vec = new
    return vec


def suffix_products(e):
    n = len(e)
    cur = list(e)
    step = 1
    while step < n:
        nxt = []
        for i in range(n):
            if i + step < n:
                nxt.append(cur[i] * cur[i + step])
            else:
                nxt.append(cur[i])
        cur = nxt
        step *= 2
    return cur + [sint(1)]


def corrections_from_carries(m, carry_terms, beta):
    us = []
    for i in range(beta):
        acc = carry_terms[0]
        for j in range(i + 1, beta):
            acc = acc + carry_terms[1][j]
        us.append(m - acc * Q)
    return us


def preproc_modconv1(beta):
    n_u = log2_exact(beta)
    n_l = K_Q - n_u
    bits = random_bits(K_Q)
    m = combine_bits(bits)
    delta = onehot(bits[n_l:])
    return m, corrections_from_carries(m, (sint(0), delta), beta)


def preproc_modconv3():
    bits = random_bits(K_Q)
    return combine_bits(bits), bits


def sample_party_shares_modconv2(beta, n_parties, inputs):
    n_u = log2_exact(beta)
    n_l = K_Q - n_u
    for s in range(n_parties):
        ms = random.randrange(Q)
        bits = [(ms >> i) & 1 for i in range(n_l)]
        a = ms >> n_l
        inputs.put_many(s, bits + [1 if i == a else 0 for i in range(beta)])
    inputs.flush()
    return n_l


def preproc_modconv2(beta, n_parties, n_l):
    deltas = []
    m = sint(0)
    for s in range(n_parties):
        vals = read_from(s, n_l + beta)
        bits, d = vals[:n_l], vals[n_l:]
        check = sint(0)
        for i in range(beta):
            check = check + d[i]
        print_ln('hot-one check party %s: %s', s, check.reveal())
        part = combine_bits(bits)
        for i in range(beta):
            part = part + d[i] * (i * (Q // beta))
        m = m + part
        deltas.append(d)

    Delta = deltas[0]
    w = sint(0)
    for s in range(1, n_parties):
        prod = [[Delta[jp] * deltas[s][i] for i in range(beta)] for jp in range(beta)]
        new = []
        for j in range(beta):
            acc = sint(0)
            for jp in range(beta):
                for i in range(beta):
                    if (jp + i) % beta == j:
                        acc = acc + prod[jp][i]
            new.append(acc)
        chi = sint(0)
        for jp in range(beta):
            for i in range(beta):
                if jp + i >= beta:
                    chi = chi + prod[jp][i]
        Delta = new
        w = w + chi

    return m, corrections_from_carries(m, (w, Delta), beta)


def deal_modconv1(beta):
    m = random.randrange(Q)
    am = alpha_of(m, beta)
    return m, [(m - Q * (1 if am > i else 0)) % T for i in range(beta)]


def deal_modconv2(beta, n_parties):
    ms = [random.randrange(Q) for _ in range(n_parties)]
    m = sum(ms)
    s = sum(alpha_of(v, beta) for v in ms)
    us = []
    for i in range(beta):
        c = -((-(s - i)) // beta)
        us.append((m - c * Q) % T)
    return m % Q, us


def deal_modconv3():
    m = random.randrange(Q)
    return m, [(m >> i) & 1 for i in range(K_Q)]


def sample_input(beta_bound):
    return random.randrange(Q // beta_bound + 1)


def online_lookup(x_share, m_share, u_shares, beta):
    n_u = log2_exact(beta)
    y = (x_share + m_share).reveal() & (Q - 1)
    idx = regint(y >> (K_Q - n_u))
    table = Array(beta, sint)
    for i in range(beta):
        table[i] = u_shares[i]
    return y - table[idx], y


def online_compare(x_share, m_share, bit_shares):
    y = (x_share + m_share).reveal() & (Q - 1)
    ybits = y.bit_decompose(K_Q)
    e = []
    for j in range(K_Q):
        e.append(1 - ybits[j] - bit_shares[j] + 2 * (ybits[j] * bit_shares[j]))
    E = suffix_products(e)
    lt = sint(0)
    for i in range(K_Q):
        lt = lt + ybits[i] * (E[i + 1] - E[i])
    c = 1 - lt - E[0]
    return y - combine_bits(bit_shares) + Q * c, y


def check_result(res, expected):
    got = res.reveal()
    print_ln('converted value: %s', got)
    print_ln('expected value: %s', expected)
