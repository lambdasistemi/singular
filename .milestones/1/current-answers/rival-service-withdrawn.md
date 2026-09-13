# Valid-rival service — CLOSURE WITHDRAWN 2026-09-12T20:10Z

> **Item (2) is NOT closed. The rival domain below is wrong in both directions.**
>
> - `bStateIn` uses a **different state script/currency** (`B_POLICY`) — a **foreign-script**
>   control, not a rival cage under this script.
> - `bSlotIn` **duplicates A's `SPAN_CAGE` asset** — a second copy of A's unique NFT is **not an
>   independently bootstrapped cage**. Calling it "slot-matched" does not supply provenance.
>
> **The actual valid rival:** the **SAME** ddfc MPFS state policy ID and script address as A, with a
> **DIFFERENT authentic cage token name**, minted from **B's own distinct spent bootstrap seed**.
> `validateMint` uses `assetName(seed)`, so another seed creates another cage **under this same
> script**. And the application helper checks only the script hash and that **exactly one** token
> name exists under that policy — **it never compares which token name** — so a different authentic
> cage token qualifies directly. **No A-token duplication is necessary.**
>
> **Different `representative_policy` is not different state policy.**
>
> The 11 CEK observations below are **retained at their actual scope** as foreign-script and
> duplicate-asset controls, and as fold input-order diagnostics. **They are not relabelled as the
> corrected domain**, and they do not substitute for the commissioned target: **retire A using ONLY
> B's state, with A's state absent.**

# (superseded framing follows)

# Valid-rival service: witnessed. Input order decides which cage the app trusts.

**Executed at `9a87b27`, `DdfcRival.lean`, 11-leg guard against `ddfc4e9`.** Disposition `TESTED`,
`ESTABLISHED (bounded)`. This closes the long-open **item (2) valid-rival service**, which had been
source-established only and untestable while abstract.

## The finding

`application.ak`'s `expected_rep_policy` `find`s **the first** input at the MPFS state address
holding one state-policy token. So with a rival **slot-matched** to A (A's address and token, B's
datum):

| leg | outcome |
|---|---|
| **B-first + LYING datum, honest fold** | **ERROR — the gap. Input order decides trust, no copy required.** |
| **A-first + lying datum, honest fold** | **HALT — A shields.** |

**Same rival present in both. Only position differs.** An attacker who controls input arrangement
controls which cage the official application reads.

## Why copied-policy B behaved differently than expected

- `B-first + copied datum, honest fold` → **HALT — a true copy is invisible.**

A *faithful* copy of A's `representative_policy` is indistinguishable from A at that check, so
nothing breaks. **That is exactly why a policy-comparison repair would never catch it** — and why
the mandatory copied-policy case was worth keeping even though the *lying* variant is what exposes
the gap.

Also recorded: `B-first + copied B-fold` ERROR (expected = A-via-copy), `A-first + copied B-fold`
ERROR, and `Arep-under-B mint` ERROR (redirect refused).

## Cases 1 and 2 behave correctly

- **ordinary rival** (B own address/policy/token): honest-A HALT with B present; B-name confusion
  ERRORs at identity.
- **forged-count**: honest-A HALT with forged B present; no-state ERROR.

Order is **moot** for both — B is invisible at its own address, which is why those legs keep the
B-own-address shape.

## Bounds, stated in the cell

**CEK scope only** — constructed contexts, **not** ledger-validity. Singleton redeemer maps.
Synthetic inputs. Finite execution. **The ledger leg remains named debt.**

## Consequence for epic 17's registry association

The association cannot rest on **which input appears first**, and cannot be repaired by **comparing
`representative_policy`** — the true-copy leg shows that check passing on a rival. Root's chosen
direction, binding to the **full native asset identity**, is consistent with this witness; this
supplies the executed evidence that the gap is real rather than theoretical.
