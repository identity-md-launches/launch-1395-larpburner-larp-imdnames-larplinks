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

Nothing in interfaces, constructor arguments, ownership or economics changed. Every change below is in `LARPBurner`
(and one comment in `SwarmPrices`), each from a finding that reproduced: one from the launch audit of the imported
code, then three from the independent review of the first adaptation.

## 1. `src/LARPBurner.sol`: legs that run third-party code get a fixed gas budget

**Findings.**
- Launch audit, id `66b70136…` (low): AUDIT.md L-01's guard reverted a failed route only when it left at most 1/63 of
  its gas, which is what the PoolManager itself leaves when it runs out. The real work runs two to five frames deeper
  (`unlock` → `unlockCallback` → `swap` → the hook / the token / IMD6900's `burn` through its proxy), and each frame in
  between keeps 1/64 of its gas and hands it back when it reverts, so an out-of-gas that deep left the burner 3/64 to
  5/64: the guard passed, the leg counted as failed, and the call went on without the IMD6900 buy. Reproduced with its
  proof (an IMD6900 whose `burn` costs ~800k gas, `burn{gas: 1_000_000}`: the call succeeded, `Burned(rest, 0, 0)`).
  The first adaptation answered it by moving the line to 1/4 of the gas for every leg.
- Launch review, id `0a267c38…` (medium): with the 1/4 line, a leg that eats all the gas it is given, at any limit (an
  IMD6900 `burn` that loops, one upgrade away on the real proxy; a hook that does the same), always leaves the catch
  with at most 1/64, so `burn` and `burnImd` always reverted `TooLittleGas` and every paid entry point of `IMDNames`
  and `LARPLinks` halted, with no owner or route switch to recover. Reproduced with its proof (both tests failed with
  `TooLittleGas`, 0x5dd42bb6, at 30M gas). AUDIT.md's trust table had promised the opposite.

**Change** (`_tryUnlock`; constants `LEG_GAS` = 3M and `AFTER_GAS` = 150k): the legs that run code a third party
controls (route 0 through POOL4's hook; the IMD6900 leg through the pair hook and IMD6900) are called with a fixed gas
budget, `unlock{gas: LEG_GAS}`. Unless the call can fund the whole budget (plus the 1/64 EIP-150 keeps and what
follows the leg) it is refused with `TooLittleGas` **before** the leg runs, so the leg gets the same gas whatever the
caller sent: a caller still cannot skip POOL4 or the IMD6900 buy by starving it (the brief's rule, L-01). A leg that
spends all of its budget failed on its own account and is skipped like any other refusal: the IMD6900 share burns as
$IMD at `0x…dEaD`, route 0 falls to the hookless pool, exactly what the trust table says for a hostile IMD6900 or
POOL4. The hookless route runs only the immutable PoolManager and $IMD, so it keeps forwarding all the gas with the 1/4
rule: an out-of-gas there can only be the caller's doing and reverts the call (`test_ASwapOutOfGasReverts`, unchanged
in meaning). The budget is several times the heaviest leg measured (~800k, the proofs' heavy IMD6900), against a full
path of ~215k.

**Cost:** a burn needs a gas limit of about 3.35M (measured: 3.31M for POOL4 plus the IMD6900 leg, 3.21M for
`burnImd`), and so do `register`, `link`, `foundCrew` and their $IMD twins. Above that the outcome no longer depends
on the limit, so `eth_estimateGas` finds it. Gas used is unchanged; only a hostile leg actually spends its 3M. A
refused call moves nothing.

**Tests** (`test/LARPBurner.t.sol`):
- New: `test_AGasEatingIMD6900IsSkippedNotFatal` (the review's case: an IMD6900 whose `burn` loops forever; `burn` at
  30M gas spends the ETH and burns all the $IMD, `burnImd` burns everything to DEAD, 1M gas is refused, not skipped) and
  `test_AGasEatingPool4HookFallsToTheHooklessPool` (a v4 hook etched at a flagged address that loops forever: the fee is
  bought on route 1 at 10M gas, refused at 1M). Both fail on the 1/4 guard.
- Adjusted to the budget: `test_ASwapOutOfGasReverts` (10M gas: route 0's budget is eaten and skipped, the hookless
  route's out-of-gas reverts; 3M is refused before trying), `test_NoGasLimitSkipsARoute` (sweep 100k to 4.5M),
  `test_AnIMD6900LegOutOfGasDeepDownReverts` (refused at 1M and at 3.2M, buys at 5M),
  `test_NoGasLimitSkipsAHeavyIMD6900Leg` (sweep 2.5M to 5M; both outcomes occur, no call skips the leg),
  `test_AGenuineFailureIsNotMistakenForTooLittleGas` (an empty pair pool's genuine revert is skipped at 5M, refused at
  300k). Helpers: `_heavyBurner` now uses `_burnerOn(token)`; `test/Base.sol`'s `MockIMD6900.burn` is `virtual`.
- Both proofs (`Proof_66b7013646b9`, `Proof_0a267c38212c`) pass with the change.

## 2. `src/LARPBurner.sol`: ETH already waiting leaves at most `MAX_BURN` per block

**Finding** (launch review, id `bb9c523e…`, medium): `MAX_BURN` capped one call, not one transaction. ETH waiting in
the burner (royalties through `receive`, parked fees, the remainder of a fee above the cap) could be sold in one
transaction by calling `burn(0)` repeatedly between a front-run and a back-run on POOL4. Reproduced with its proof on
the repository's own pool depth: 1 ETH waiting, ten calls, the searcher's 10 ETH became 10.347 ETH and DEAD got 51%
less; the same sandwich around one call lost.

**Change** (`burn`; two internal storage fields `_burnBlock`, `_burnedInBlock`, one slot): what the caller sends goes
first, up to `MAX_BURN`; the rest of the call's cap comes from the ETH that was already waiting, of which at most
`MAX_BURN` leaves per block over all calls. Each call still spends at most `MAX_BURN` (the documented cap); a caller's
own fee always goes through, so no registration is blocked by what others burned in the block; the storage is written
only when waiting ETH is spent, so a plain fee costs nothing more. A sandwich can therefore cover at most one cap per
block, below L-04's break-even; a searcher's own `msg.value` is burned. No interface or event changed.

**Tests:** `test_BurnCallsBatchedInOneTransactionSellOneCap` (ten `burn(0)` calls from one contract sell 0.1 ETH of
1 ETH waiting; POOL4 moves as for one trade), `test_AtMostMaxBurnPerCallAndPerBlockOfWaitingEth` (replaces
`test_AtMostMaxBurnPerCall`: the rest leaves one cap per block), `test_AFeeAlwaysGoesThroughWhateverTheBlockSpent`
(a fee in a block whose allowance is spent is bought exactly; a fee above the cap buys `MAX_BURN`, the rest waits). The
proof `Proof_bb9c523ef0e5` passes with the change. AUDIT.md: L-10, L-04 updated.

## 3. `src/LARPBurner.sol`: WETH royalties are unwrapped and sold

**Finding** (launch review, id `1c125369…`, low): `IMDNames.royaltyInfo` names the burner, accepted offers on Seaport
and Blur settle in WETH, and the burner could move only ETH and $IMD: WETH royalties were stuck forever, with no owner
or sweep (and no upgrade, by the launch rules). Reproduced: a WETH mock's balance for the burner survives `burn` and
`burnImd` on the code as it was.

**Change** (`_unwrapWeth`, called first in `burn`; constant `WETH` = WETH9 `0xC02a…6Cc2`, since constructor arguments
may not change): if WETH9 holds a balance for the burner, `withdraw` it (WETH9 pays through `receive`), so it joins the
waiting ETH and leaves `MAX_BURN` a block. Where WETH has no code (a test chain) or refuses, nothing happens; the
constructor still calls nothing. **Test:** `test_WethRoyaltiesAreUnwrappedAndSold` (a WETH9-like mock etched at the
constant). AUDIT.md: L-11, I-10, a trust-table row.

## 4. `src/SwarmPrices.sol`: the documented callback selector

**Finding** (launch review, id `b22f8b5d…`, info): the comment on `Attestation` and AUDIT.md cited `0x510379c7`, the
selector of IMD's example name `onOracleResult`; this contract's callback is `onVerdict`, `0x8bf09c1b`, which
`propose` registers. Reproduced (`cast sig`). **Change:** comment and AUDIT.md name the contract's own selector and
say the name is the consumer's. No code changed.

## Review findings not acted on, and why

- id `e903f8dd…` (low): a proposal equal to the current prices (or 1 wei away) passes the guardrails, is approved, and
  its `execute` bumps the epoch and restarts the cooldown. Reproduced as described. Not changed: the suggested fixes
  (reject identical prices; bump the epoch only on a change) leave the 1-wei proposal, and a minimum step leaves a
  weekly ping-pong, because the root is the design the requester chose, in which the swarm judges whether prices are
  acceptable rather than which proposal is best, so among approved proposals the first executed wins the week. Every
  price such a griefer can set is one the swarm found within the guidelines; prices never leave the guardrails; the
  stall is one week per 0.5 IMD, and the site can execute an approved proposal the block it becomes executable.
  Documented as AUDIT.md L-12.
- id `cfb40c35…` (low): `MAX_PRICE` (1 ETH) above `MAX_BURN` (0.1 ETH) means a fee above the cap is bought `MAX_BURN`
  at a time under the payer's `minImd`, the rest waiting. Reproduced as described. Not changed: capping `MAX_PRICE` at
  `MAX_BURN` would cap 1-3 letter names, whose guideline ("at least 10x a 5+ letter name") has no upper bound, and
  buying the whole fee in one call or a loop would recreate finding 2's exposure on the payer's own fee. With change 2
  the remainder now leaves one cap per block, each below break-even. `burn`'s NatSpec says `minImd` covers what the
  call buys (the first `MAX_BURN`), and the site should quote accordingly. Documented as AUDIT.md L-13.
- The launch audit's informational coverage note (id `e5d2347b…`) reports no defect; its reading of the 138 entry
  points and of the constructors agrees with `test/Launch.t.sol`.
- AUDIT.md's own fixes (L-01 as it was, L-02 `jeetOfRange`) and acknowledged items were checked against their tests and
  left alone; L-01 is the one refined above.

## Documentation

- `AUDIT.md`: the trust table (POOL4's hook, IMD6900, WETH9), L-01 as it stands and its history, L-09 to L-11 fixed,
  L-12 and L-13 acknowledged, L-04, I-10, I-11, the selector line, "Checked and holding", test count 150.
- `README.md`: the burner paragraph (per-block cap, WETH, the gas limit) and the test count.

## Checks run

`forge build --offline`; `forge test --offline` with an empty environment (`env -i`): 150 passed, 0 failed, 11 skipped
(the Ethereum fork suite skips itself without `MAINNET_RPC_URL`). The three proofs, copied to `test/scratch/`, pass
with the changes (6 tests). `forge build --sizes`: every runtime under EIP-170 (LARPBurner 6,582 bytes). No change to
`foundry.toml`, `remappings.txt`, `lib/` or any dependency; `launch.json` is not written.
