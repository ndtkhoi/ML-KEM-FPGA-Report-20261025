"""Bit-exact FIPS 203 reference functions for the report-3 RTL.

This model keeps every coefficient in the canonical range 0..q-1.  It is
small and deliberately literal so that RTL waveforms can be traced back to
Algorithms 9-12 of FIPS 203.
"""

from __future__ import annotations

from collections.abc import Sequence

from mlkem_params import N, Q, ZETAS, gamma_for_pair


def _check_poly(poly: Sequence[int], name: str) -> None:
    if len(poly) != N:
        raise ValueError(f"{name} must contain exactly {N} coefficients")
    if any(not 0 <= value < Q for value in poly):
        raise ValueError(f"{name} contains a coefficient outside [0, {Q - 1}]")


def ntt(poly: Sequence[int]) -> list[int]:
    """FIPS 203 Algorithm 9."""

    _check_poly(poly, "NTT input")
    result = list(poly)
    zeta_index = 1
    length = 128

    while length >= 2:
        for start in range(0, N, 2 * length):
            zeta = ZETAS[zeta_index]
            zeta_index += 1
            for j in range(start, start + length):
                t = (zeta * result[j + length]) % Q
                upper = result[j]
                result[j + length] = (upper - t) % Q
                result[j] = (upper + t) % Q
        length //= 2

    if zeta_index != 128:
        raise AssertionError(f"NTT consumed {zeta_index - 1} zetas, expected 127")
    return result


def intt(ntt_poly: Sequence[int]) -> list[int]:
    """FIPS 203 Algorithm 10."""

    _check_poly(ntt_poly, "INTT input")
    result = list(ntt_poly)
    zeta_index = 127
    length = 2

    while length <= 128:
        for start in range(0, N, 2 * length):
            zeta = ZETAS[zeta_index]
            zeta_index -= 1
            for j in range(start, start + length):
                t = result[j]
                result[j] = (t + result[j + length]) % Q
                result[j + length] = (zeta * (result[j + length] - t)) % Q
        length *= 2

    if zeta_index != 0:
        raise AssertionError(f"INTT left zeta index at {zeta_index}, expected 0")
    return [(value * 3303) % Q for value in result]


def base_case_multiply(
    a0: int, a1: int, b0: int, b1: int, gamma: int
) -> tuple[int, int]:
    """FIPS 203 Algorithm 12."""

    c0 = (a0 * b0 + a1 * b1 * gamma) % Q
    c1 = (a0 * b1 + a1 * b0) % Q
    return c0, c1


def multiply_ntts(a_ntt: Sequence[int], b_ntt: Sequence[int]) -> list[int]:
    """FIPS 203 Algorithm 11."""

    _check_poly(a_ntt, "MultiplyNTTs input A")
    _check_poly(b_ntt, "MultiplyNTTs input B")
    result = [0] * N

    for pair in range(128):
        c0, c1 = base_case_multiply(
            a_ntt[2 * pair],
            a_ntt[2 * pair + 1],
            b_ntt[2 * pair],
            b_ntt[2 * pair + 1],
            gamma_for_pair(pair),
        )
        result[2 * pair] = c0
        result[2 * pair + 1] = c1

    return result


def self_test() -> None:
    """Fast deterministic sanity checks used by the vector generator."""

    zero = [0] * N
    unit = [1] + [0] * (N - 1)
    ramp = [index % Q for index in range(N)]

    for name, poly in (("zero", zero), ("unit", unit), ("ramp", ramp)):
        recovered = intt(ntt(poly))
        if recovered != poly:
            raise AssertionError(f"NTT/INTT round-trip failed for {name}")

    product = multiply_ntts(ntt(unit), ntt(ramp))
    if intt(product) != ramp:
        raise AssertionError("MultiplyNTTs identity test failed")


if __name__ == "__main__":
    self_test()
    print("NTT_REFERENCE_SELF_TEST: PASS")
