# Adaptation for the `evm_contracts` launch on Ethereum (2026-10-12)

LARP arrived launch-shaped. Its four contracts are deployed in the brief's order with the brief's constructor
arguments (`LARPBurner`, `LARP`, `IMDNames`, `LARPLinks`; see README's launch table), and the repository already holds
the launch's constraints as tests in `test/Launch.t.sol`:

- `test_DeploysOnAFreshChain`: the constructors store addresses and call nothing (they run on an empty chain).
- `test_PassesTheAdmissionScan`: no CALLCODE, DELEGATECALL or SELFDESTRUCT in any creation or runtime code.
- `test_FitsOneTransaction` and `test_UnderTheCodeSizeLimit`: one transaction, every runtime under EIP-170.
- No owner, no admin, no upgrades, no proxy, no initializer; nothing takes `msg.sender` or `tx.origin` as an owner. The
  one role (the names' artist, `0x35dA…a059`) is a constructor argument the brief names. The tick spacings are already
  `uint24` arguments (commit 0b0e260). Every library function the contracts call is internal.

Nothing in interfaces, constructor arguments, ownership or economics changed. One change was needed, from the launch
audit's low finding, which reproduced.

## 1. `src/LARPBurner.sol`: the TooLittleGas guard sees an out-of-gas at any depth

**Finding** (audit of the imported code, id `66b70136…`, low): AUDIT.md L-01's guard reverted a failed route only when
it left at most 1/63 of its gas, which is what the PoolManager itself leaves when it runs out. The real work runs two to
five frames deeper (`unlock` → `unlockCallback` → `swap` → the hook / the token / IMD6900's `burn` through its proxy),
and each frame in between keeps 1/64 of its gas and hands it back when it reverts, so an out-of-gas that deep left the
burner 3/64 to 5/64: the guard passed, the leg counted as failed, and the call went on without it. For the IMD6900 leg
that is exactly the "skip the IMD6900 buy" L-01 meant to stop; for route 0 it skips POOL4 for the backup pool.

**Reproduced:** the attached proof (an IMD6900 whose `burn` costs ~800k gas, `burn{gas: 1_000_000}`) fails on the
code as it arrived: the call succeeds, `Burned(rest, 0, 0)`, IMD6900's supply unchanged, the whole $IMD at `0x…dEaD`.

**Change** (`_tryUnlock`, one constant): a failed try that left no more than **1/4** of its gas reverts `TooLittleGas`
(was 1/63). A genuine revert hands back everything it did not use; an out-of-gas hands back about d/64 for a failure
d frames deep, so the quarter catches it down to 18 frames. This keeps the brief's rule that out-of-gas swaps revert,
and the behaviour that a route or the IMD6900 leg that fails for a real reason (closed pool, empty pool, a hook that
refuses, an IMD6900 that won't burn) is skipped, not fatal. The fixed-gas-budget alternative was not taken: it would
make an IMD6900 leg that outgrows the budget silently skippable forever, with no owner to raise it, and the real pair
hook's and upgradeable IMD6900's cost is not known offline.

**Cost:** a leg that reverts for a real reason after heavy work (an empty pool whose swap walks the whole tick range,
~340k gas) now needs a gas limit about a third above that work: measured on the local pools, a burn with an empty pair
pool after POOL4 first goes through at a 590k limit (was 350k); the full path is unchanged (180k). Gas used does not
change, a refused call moves nothing, and `eth_estimateGas` finds the limit since success only ever rises with gas.

**Tests** (`test/LARPBurner.t.sol`; all three fail with the 1/63 guard and pass with the fix):
- `test_AnIMD6900LegOutOfGasDeepDownReverts`: the proof's case, `HeavyIMD6900` at 1M gas reverts `TooLittleGas`, the
  ETH comes back, nothing goes to DEAD; with 5M gas the same call buys and burns IMD6900.
- `test_NoGasLimitSkipsAHeavyIMD6900Leg`: gas limits swept from 500k to 2.5M in 20k steps against the heavy leg; every
  call that goes through burned IMD6900, every refusal is `TooLittleGas` and moved nothing, and both outcomes occur.
- `test_AGenuineFailureIsNotMistakenForTooLittleGas`: an empty pair pool's genuine `Unfilled` revert is skipped at 1M
  gas (the share burns as $IMD), and refused rather than skipped at 300k.
- `test/Base.sol`: `MockIMD6900.burn` made `virtual` so `HeavyIMD6900` can override it. No other test changed; the 18
  existing burner tests, including L-01's `test_ASwapOutOfGasReverts` and `test_NoGasLimitSkipsARoute`, still pass.

## Documentation

- `AUDIT.md` L-01: the strengthened guard, why 1/4, its cost and the new tests. Test count 145.
- `README.md`: test count 145 (142 before this change plus the three above).

## Audit findings not acted on

- The informational coverage note (id `e5d2347b…`) reports no defect. Its reading of the 138 entry points and of the
  constructors (call nothing, order matches the manifest) agrees with `test/Launch.t.sol`.
- AUDIT.md's own fixes (L-01 as it was, L-02 `jeetOfRange`) and acknowledged items were checked against their tests
  and left alone; L-01 is the one refined above.

## Checks run

`forge build`; `forge test --offline` with an empty environment (`env -i`): 145 passed, 0 failed, 11 skipped (the
Ethereum fork suite skips itself without `MAINNET_RPC_URL`). The audit's proof, copied to `test/scratch/`, passes with
the fix. No change to `foundry.toml`, `remappings.txt`, `lib/` or any dependency; `launch.json` is not written.
