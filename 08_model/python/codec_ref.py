"""FIPS 203 coefficient compression and byte encoding helpers."""

from __future__ import annotations

from collections.abc import Sequence

from mlkem_params import N, Q


SUPPORTED_D = (1, 4, 5, 10, 11, 12)


def compress(coefficient: int, d: int) -> int:
    """FIPS 203 Compress_d for one canonical coefficient."""

    if d not in SUPPORTED_D:
        raise ValueError(f"unsupported d={d}")
    if not 0 <= coefficient < Q:
        raise ValueError("coefficient must be canonical")
    return ((coefficient * (1 << d) + Q // 2) // Q) % (1 << d)


def decompress(encoded: int, d: int) -> int:
    """FIPS 203 Decompress_d for one d-bit value."""

    if d not in SUPPORTED_D:
        raise ValueError(f"unsupported d={d}")
    if not 0 <= encoded < (1 << d):
        raise ValueError("encoded value does not fit d bits")
    return (encoded * Q + (1 << (d - 1))) >> d


def byte_encode(values: Sequence[int], d: int) -> bytes:
    """FIPS 203 ByteEncode_d using least-significant-bit-first packing."""

    if len(values) != N:
        raise ValueError(f"ByteEncode input must contain {N} values")
    limit = Q if d == 12 else 1 << d
    if any(not 0 <= value < limit for value in values):
        raise ValueError("ByteEncode value outside its encoding domain")

    accumulator = 0
    bit_count = 0
    output = bytearray()
    for value in values:
        accumulator |= value << bit_count
        bit_count += d
        while bit_count >= 8:
            output.append(accumulator & 0xFF)
            accumulator >>= 8
            bit_count -= 8

    if bit_count != 0:
        raise AssertionError("256*d must be a multiple of eight")
    return bytes(output)


def byte_decode(encoded: bytes, d: int) -> list[int]:
    """FIPS 203 ByteDecode_d."""

    expected_size = 32 * d
    if len(encoded) != expected_size:
        raise ValueError(f"ByteDecode input must contain {expected_size} bytes")

    mask = (1 << d) - 1
    accumulator = 0
    bit_count = 0
    byte_index = 0
    output: list[int] = []

    while len(output) < N:
        while bit_count < d:
            accumulator |= encoded[byte_index] << bit_count
            bit_count += 8
            byte_index += 1
        value = accumulator & mask
        accumulator >>= d
        bit_count -= d
        output.append(value % Q if d == 12 else value)

    return output


def self_test() -> None:
    for d in SUPPORTED_D:
        limit = Q if d == 12 else 1 << d
        values = [(index * 17 + 3) % limit for index in range(N)]
        if byte_decode(byte_encode(values, d), d) != values:
            raise AssertionError(f"ByteEncode/ByteDecode failed for d={d}")

    for coefficient in range(Q):
        for d in SUPPORTED_D:
            encoded = compress(coefficient, d)
            if not 0 <= encoded < (1 << d):
                raise AssertionError("Compress result outside d-bit range")
            decoded = decompress(encoded, d)
            if not 0 <= decoded <= Q:
                raise AssertionError("Decompress result outside expected range")


if __name__ == "__main__":
    self_test()
    print("CODEC_REFERENCE_SELF_TEST: PASS")
