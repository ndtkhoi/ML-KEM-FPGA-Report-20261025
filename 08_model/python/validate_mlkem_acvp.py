"""Doi chieu mo hinh ML-KEM voi test vector FIPS 203 chinh thuc cua NIST."""

from __future__ import annotations

import json
from pathlib import Path

from mlkem_full_ref import (
    MLKEM_768,
    MLKEM_1024,
    Params,
    decaps_internal,
    encaps_internal,
    keygen_internal,
)


ROOT = Path(__file__).resolve().parents[2]
VECTOR_ROOT = ROOT / "03_vectors" / "acvp"
PARAMETERS: dict[str, Params] = {
    MLKEM_768.name: MLKEM_768,
    MLKEM_1024.name: MLKEM_1024,
}


def from_hex(value: str) -> bytes:
    return bytes.fromhex(value)


def validate_keygen() -> int:
    data = json.loads((VECTOR_ROOT / "keygen.json").read_text(encoding="utf-8"))
    count = 0
    for group in data["testGroups"]:
        params = PARAMETERS.get(group["parameterSet"])
        if params is None:
            continue
        for test in group["tests"]:
            ek, dk = keygen_internal(from_hex(test["d"]), from_hex(test["z"]), params)
            if ek != from_hex(test["ek"]) or dk != from_hex(test["dk"]):
                raise AssertionError(f"keyGen tcId={test['tcId']} {params.name} failed")
            count += 1
    return count


def validate_encap_decap() -> tuple[int, int]:
    data = json.loads((VECTOR_ROOT / "encap_decap.json").read_text(encoding="utf-8"))
    encap_count = 0
    decap_count = 0
    for group in data["testGroups"]:
        params = PARAMETERS.get(group["parameterSet"])
        if params is None:
            continue
        function = group["function"]
        if function == "encapsulation":
            for test in group["tests"]:
                key, ciphertext = encaps_internal(
                    from_hex(test["ek"]), from_hex(test["m"]), params
                )
                if key != from_hex(test["k"]) or ciphertext != from_hex(test["c"]):
                    raise AssertionError(
                        f"encapsulation tcId={test['tcId']} {params.name} failed"
                    )
                encap_count += 1
        elif function == "decapsulation":
            for test in group["tests"]:
                key = decaps_internal(
                    from_hex(test["dk"]), from_hex(test["c"]), params
                )
                if key != from_hex(test["k"]):
                    raise AssertionError(
                        f"decapsulation tcId={test['tcId']} {params.name} failed"
                    )
                decap_count += 1
    return encap_count, decap_count


if __name__ == "__main__":
    keygen_cases = validate_keygen()
    encaps_cases, decaps_cases = validate_encap_decap()
    print(
        "NIST_ACVP_MLKEM_768_1024: PASS "
        f"keygen={keygen_cases} encaps={encaps_cases} decaps={decaps_cases}"
    )
