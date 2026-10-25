"""Shared ML-KEM-768/1024 constants used by the report-3 golden model.

The NTT constants are the canonical representatives from FIPS 203,
Appendix A.  They are intentionally not the signed/Montgomery constants
used by some older Kyber reference implementations.
"""

N = 256
Q = 3329

MLKEM_768 = {
    "k": 3,
    "eta1": 2,
    "eta2": 2,
    "du": 10,
    "dv": 4,
    "ek_bytes": 1184,
    "dk_bytes": 2400,
    "ct_bytes": 1088,
    "ss_bytes": 32,
}

MLKEM_1024 = {
    "k": 4,
    "eta1": 2,
    "eta2": 2,
    "du": 11,
    "dv": 5,
    "ek_bytes": 1568,
    "dk_bytes": 3168,
    "ct_bytes": 1568,
    "ss_bytes": 32,
}

# zeta^(BitRev7(i)) mod q for i = 0..127, with zeta = 17.
ZETAS = [
    1, 1729, 2580, 3289, 2642, 630, 1897, 848,
    1062, 1919, 193, 797, 2786, 3260, 569, 1746,
    296, 2447, 1339, 1476, 3046, 56, 2240, 1333,
    1426, 2094, 535, 2882, 2393, 2879, 1974, 821,
    289, 331, 3253, 1756, 1197, 2304, 2277, 2055,
    650, 1977, 2513, 632, 2865, 33, 1320, 1915,
    2319, 1435, 807, 452, 1438, 2868, 1534, 2402,
    2647, 2617, 1481, 648, 2474, 3110, 1227, 910,
    17, 2761, 583, 2649, 1637, 723, 2288, 1100,
    1409, 2662, 3281, 233, 756, 2156, 3015, 3050,
    1703, 1651, 2789, 1789, 1847, 952, 1461, 2687,
    939, 2308, 2437, 2388, 733, 2337, 268, 641,
    1584, 2298, 2037, 3220, 375, 2549, 2090, 1645,
    1063, 319, 2773, 757, 2099, 561, 2466, 2594,
    2804, 1092, 403, 1026, 1143, 2150, 2775, 886,
    1722, 1212, 1874, 1029, 2110, 2935, 885, 2154,
]


def mode_parameters(mode_1024: bool) -> dict[str, int]:
    """Return a copy so callers cannot mutate the module constants."""

    return dict(MLKEM_1024 if mode_1024 else MLKEM_768)


def gamma_for_pair(index: int) -> int:
    """Return zeta^(2*BitRev7(index)+1) mod q for MultiplyNTTs."""

    if not 0 <= index < 128:
        raise ValueError("MultiplyNTTs pair index must be in [0, 127]")
    zeta = ZETAS[64 + index // 2]
    return zeta if index % 2 == 0 else (-zeta) % Q
