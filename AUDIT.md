# LARP audit (2026-10-12, before the swarm launch)

Scope: `src/` at this commit: `LARPBurner`, `LARP` / `ILARP`, `IMDNames` / `IIMDNames` with `SwarmPrices`,
`LARPLinks`, `SafeReads`, `Labels`. Four contracts on Ethereum.
- No owner, no admin, no upgrades.
- The one role is the names' **artist**, who can change only the art (tokenURI's renderer) and can lock it forever.

**Result: no critical, high or medium findings open.** 150 offline tests, plus 11 on an Ethereum fork. Five findings
fixed (L-01, L-02 before the launch; L-09, L-10, L-11 at the launch review, two of them rated medium there), each held
by a test that fails without the fix (see `ADAPTATION.md`). The rest acknowledged and documented.

## Trust: what LARP depends on, and what happens if it fails

| dependency | who controls it | if it fails or turns hostile |
|---|---|---|
| identity.md `0x0000eC93…` | its contract | inherent: LARP is about these tokens |
| Uniswap v4 PoolManager | nobody (immutable) | — |
| POOL4 (ETH/$IMD 1%, hook `0xc6C9…`) | IMD's treasury owns the hook (it can `closeMarket`) | the burner falls to route 2, whether the hook refuses or eats all its gas (the leg runs on a 3M gas budget, L-09) |
| hookless ETH/$IMD pool (1%, spacing 200) | nobody (no hook); its LPs can withdraw | the ETH waits in the burner; anyone burns it later |
| IMD6900/$IMD pool (hook `0x667f…2A44`) | the IMD6900 ETH timelock owns the hook | the 6.9% that buys IMD6900 goes to `0x…dEaD` as $IMD instead |
| IMD6900 (`0x0000198C…`, upgradeable) | the IMD6900 ETH timelock | if its `burn` refuses, or eats all the gas it is given (a hostile or buggy upgrade), the same: the share goes to `0x…dEaD` as $IMD; the leg runs on a 3M gas budget, so it can't halt the burner (L-09) |
| WETH9 (`0xC02a…6Cc2`, immutable) | nobody | royalties paid in WETH are unwrapped on each `burn`; if WETH refused, they would wait there |
| $IMD (LayerZero OFT, owner `0x047F…`) | IMD's treasury (peers) | $IMD at `0x…dEaD` can never move, whatever the token's owner does |
| IMD's launcher `distributorOf` | immutable contract; IMD writes the airdrop roots | jeet ranks are only as true as IMD's airdrops; nothing else depends on it |
| the names' renderer | the artist, until locked | art only; a failing renderer falls back to the built-in card |
| IMD's oracle (attester `0x5598…2982`, Intake `0xa43e…de82`, owned by IMD's treasury) | IMD | price changes only. A verdict needs its signature, for this contract, on the contract's own proposal; a bad one can move prices at most 2x a week, within 0.00001-1 ETH and short >= long. If IMD stops answering, prices stay. |

**Not used, on purpose:** IMD's BurnExecutor (`0xe293…c750`). Its owner can `rescueToken`, `rescueETH` and redirect
the burn (`setBaseBurnReceiver`), so $IMD sent there isn't trustlessly burned. LARP sends to `0x…dEaD` instead. The
cost: IMD's dashboard won't count these burns as IMD's own.

## Fixed

### L-01 A fee could skip its route by starving the swap of gas (LARPBurner)

Each route's swap runs in a try. A swap that runs out of gas inside it keeps 1/64 of the gas, so a caller who could
make the swap eat its 63/64 could skip POOL4 for the backup, or park the fee.

**Fix, as it stands (third version, with L-09):** a leg is skipped only for a failure of its own, never for the gas
the caller sent.
- The legs that run code a third party controls (route 0 through POOL4's hook; the IMD6900 leg through the pair hook
  and IMD6900's proxy) run on a fixed budget, `LEG_GAS` = 3M, several times the heaviest leg measured (~800k). Unless
  the call can fund the whole budget (3M, plus the 1/64 EIP-150 keeps, plus 150k for what follows) it is refused with
  `TooLittleGas` before the leg runs, so the leg gets the same gas whatever the caller sent. A leg that spends all of
  it failed on its own account and is skipped like any other refusal (L-09).
- The hookless route runs only the immutable PoolManager and $IMD, so it gets all the gas, and a failure that left no
  more than 1/4 of it ran out of gas and reverts the call (an out-of-gas d frames deep hands back about d/64 of the
  gas; a genuine revert hands back nearly all).

The first version drew the line at 1/63 for every leg, which is what is left when the PoolManager itself runs out of
gas. The launch audit (2026-10-12) showed that is not where the work runs: the swap, the hook, the token transfers and
IMD6900's `burn` are two to five frames below the burner, and every frame in between keeps 1/64 of its gas and hands
it back when it reverts, so an out-of-gas that deep left the burner 3/64 to 5/64 of the gas. The 1/63 guard passed,
the leg counted as failed, and with a heavy IMD6900 leg (~800k gas) every gas limit from ~758k to ~1.97M went through
with the IMD6900 buy skipped. The second version drew the line at 1/4 for every leg; the launch review showed that a
leg which eats all the gas it is given, at any limit, then always looks starved, so one hostile upgrade of IMD6900 (or
of a hook) made every burn revert `TooLittleGas` and halted every paid entry point (L-09). The budget settles both: a
caller can't starve a leg, and a leg can't hold the burner hostage.

**Cost:** a burn needs a gas limit of about 3.35M (measured locally: 3.31M for POOL4 plus the IMD6900 leg, 3.21M for
`burnImd`), and so do `register`, `link`, `foundCrew` and their $IMD twins; `eth_estimateGas` finds it, since above the
threshold the outcome no longer depends on the limit. Gas used does not change (~215k for a full burn); only in the
hostile case does a leg actually spend its 3M. A refused call moves nothing.

**Tests:**
- `test_ASwapOutOfGasReverts` (a PoolManager that burns all gas): route 0 spends its budget and is skipped, the
  hookless route runs out and the call reverts; below the budget it is refused before trying.
- `test_NoGasLimitSkipsARoute` sweeps gas limits from 100k to 4.5M: the backup pool's price never moves while POOL4
  can take the trade, and no call that goes through skips the IMD6900 buy.
- `test_AnIMD6900LegOutOfGasDeepDownReverts` (an IMD6900 whose `burn` costs ~800k gas): refused at 1M and at 3.2M
  (POOL4's leg funded, the IMD6900 leg not), with the ETH handed back; buys and burns at 5M.
  `test_NoGasLimitSkipsAHeavyIMD6900Leg` sweeps 2.5M to 5M: every call buys IMD6900 or is refused, and both occur.
- `test_AGenuineFailureIsNotMistakenForTooLittleGas`: an empty pair pool's genuine revert is skipped at 5M gas and
  the call is refused, not degraded, at 300k.

### L-02 The jeet board's reads grow without bound (LARPLinks)

`jeetOf` reads every proven launch of a wallet. **Fix:** `jeetOfRange(wallet, start, count)` pages it.
**Test:** `test_JeetsInPages`.

### L-09 A gas-eating IMD6900 or hook halted every burn (LARPBurner; launch review, rated medium)

With the 1/4 guard on every leg, an IMD6900 whose `burn` (behind its proxy, one upgrade away) or a hook that eats all
the gas it is given made the catch see at most 1/64 of the gas at any limit, so `burn` and `burnImd` always reverted
`TooLittleGas`, and with them `register`, `registerWithImd`, `link`, `linkWithImd`, `foundCrew` and `foundCrewWithImd`,
which have no other payment path and no owner to switch routes. The trust table's promise (a hostile IMD6900 only
costs its share; a hostile POOL4 falls to the hookless pool) held only for a refusal that reverted cheaply.

**Fix:** the legs that run third-party code get the fixed budget described under L-01; a leg that eats all of it is
skipped (the IMD6900 share burns as $IMD; route 0 falls to the hookless pool). **Tests:**
`test_AGasEatingIMD6900IsSkippedNotFatal` (an IMD6900 whose `burn` loops forever: `burn` at 30M gas spends the ETH and
burns all the $IMD, `burnImd` burns everything to DEAD, and 1M gas is refused, not skipped) and
`test_AGasEatingPool4HookFallsToTheHooklessPool` (a v4 hook that loops forever: the fee is bought on route 1).

### L-10 Batched `burn(0)` calls sold all the waiting ETH at one price (LARPBurner; launch review, rated medium)

`MAX_BURN` capped one call, not one transaction: whoever found more than 0.1 ETH waiting (royalties through `receive`,
parked fees, the remainder of a fee above the cap) could wrap ten `burn(0)` calls between a front-run and a back-run on
POOL4 and keep a large share of the value meant for the burn (measured on the test pools: 1 ETH waiting, the searcher
+0.35 ETH, DEAD -51%).

**Fix:** of the ETH that was already waiting, at most `MAX_BURN` leaves per block, over all calls; a caller's own fee
(up to `MAX_BURN`) always goes through in its own call, so no registration is blocked by what others burned. Each call
still spends at most `MAX_BURN`. A sandwich can therefore cover at most one cap per block, which L-04 shows is below
break-even; the searcher's own ETH, if sent as `msg.value`, is burned. **Tests:** `test_BurnCallsBatchedInOneTransactionSellOneCap`
(ten calls in one transaction sell 0.1 ETH, POOL4 moves as for one trade), `test_AtMostMaxBurnPerCallAndPerBlockOfWaitingEth`,
`test_AFeeAlwaysGoesThroughWhateverTheBlockSpent` (a fee in a block whose allowance is spent is bought exactly; a fee
above the cap buys `MAX_BURN` and the rest waits).

### L-11 Royalties paid in WETH were stuck (LARPBurner; launch review)

`royaltyInfo` names the burner, and accepted offers on Seaport and Blur settle in WETH, which the burner (ETH and $IMD
only, no owner, no sweep) could never move. **Fix:** `burn` first unwraps any WETH9 the burner holds (WETH9 is a
constant: constructor arguments did not change), so WETH royalties join the waiting ETH and leave `MAX_BURN` a block.
Where WETH has no code (a test chain) or refuses, nothing happens. **Test:** `test_WethRoyaltiesAreUnwrappedAndSold`.

## Acknowledged

- **L-07 Paying in $IMD uses spot prices.**
  - **The quote:** `quoteImd` charges the higher of the two pools' spot quotes, and needs both pools live (otherwise
    pay in ETH).
  - **Why one pool can't be gamed:** moving POOL4 alone (shallow, concentrated) can never lower the price.
  - **Moving both:** this means moving the hookless pool too (~600 ETH deep). Their 1% fees each way make that cost
    about what it saves, even for a batch of names in one transaction.
- **L-08 Price governance trusts IMD's oracle.**
  - **What it rests on:** a verdict rests on IMD's attester key and its 9-agent panel (7 must agree).
  - **What IMD's writer can do:** it can't forge a verdict. It can withhold one, or pair it with the wrong one of this
    contract's own pending proposals; the guardrails bound both.
  - **The question hash isn't pinned:** IMD computes it off chain (`oracleQuestionHash`), so the binding is the Intake's
    request id, as IMD documents for consumers on the asking chain.
  - **How it was validated:** the contract writes the whole question, and IMD's free quote accepted it (status
    `quoted`). Proposing costs the proposer 0.5 IMD, which IMD's Intake forwards to IMD's treasury.
- **I-11 The IMD6900 buy is small and bounded.**
  - **Size:** it is 6.9% of at most 0.1 ETH of $IMD per burn, against the pair pool's 6.9% fee each way, so it isn't
    worth sandwiching.
  - **Where its fee goes:** the pair hook keeps its own 6.9% fee as protocol liquidity.
  - **If it fails:** an empty pair pool, a hook that refuses, an IMD6900 that won't burn, or one that eats all the
    gas it is given, all send the share to `0x…dEaD` (`test_AnEmptyPairPoolMeansItAllBurnsAsIMD`,
    `test_AnIMD6900ThatWontBurnMeansItAllBurnsAsIMD`, `test_AGasEatingIMD6900IsSkippedNotFatal`).

- **L-03 Name sniping.** A pending `register` can be front-run. There is no commit-reveal, and the sniper pays the full
  price (burned). The site should send registrations through a private mempool.
- **L-04 Sandwiching a burn.** At most `MAX_BURN` (0.1 ETH) is spent per call, and at most `MAX_BURN` of the ETH
  that was already waiting leaves per block however many calls (L-10), below POOL4's ~0.24 ETH sandwich break-even,
  and far below the hookless pool's (23x POOL4's liquidity). Callers can set `minImd`; the site should pass a quote.
- **L-12 A proposal that changes nothing (or 1 wei) consumes the week.** `_checkStep` allows `to == from`, so anyone
  can propose the current prices; the swarm judges guideline compliance, which they meet, and `execute` then bumps
  the epoch and restarts the cooldown: every other approved proposal is `Stale`, and a real change waits a week. Cost
  0.5 IMD a week. Acknowledged, not changed: rejecting identical prices would leave the 1-wei proposal, and a minimum
  step would leave a weekly ping-pong, because the root is the design, in which the swarm judges whether prices are
  acceptable, not which proposal is best, so among approved proposals the first executed wins the week. Every price
  such a griefer can set is one the swarm found within the guidelines, prices never leave the guardrails, and the stall
  is one week per 0.5 IMD. The site should execute an approved proposal in the block it becomes executable.
- **L-13 A fee above `MAX_BURN` is bought in parts.** `MAX_PRICE` (1 ETH) is above `MAX_BURN` (0.1 ETH), so after
  four swarm-approved doublings of a price (outside the stated guidelines at today's ETH price, but possible) a fee is
  bought `MAX_BURN` at a time: the payer's `minImd` covers the first `MAX_BURN`, and the rest waits and leaves
  `MAX_BURN` a block through anyone's `burn(0)`, each below L-04's break-even. Acknowledged, not changed: capping
  `MAX_PRICE` at `MAX_BURN` would cap 1-3 letter names, whose guideline has no upper bound, and buying the whole fee
  in one call or in a loop would recreate L-10's exposure on the payer's own fee. The site should quote `minImd` for
  `min(price, MAX_BURN)`; `burn`'s NatSpec says so.
- **L-05 The rank reads live balances.** A flash loan inside one transaction can make a wallet look like it holds.
  `rankOf` is for display; a contract that pays on rank must snapshot it.
- **L-06 Royalties are voluntary on markets.** ERC-2981's 6.9% reaches the burner only where markets pay royalties.
  What no market can skip is the toll: a name's new owner pays its price once to link it to an identity, and that is
  burned.
- **I-01 An agent has the identity's whole social hand.** It can place the owner's NFTs, link the owner's names, set
  texts, fren, and run (or disband) the owner's crews. It can't move any token or ETH. The owner revokes it, and a
  sale ends it.
- **I-02 A returning identity brings its agent back.** If the owner who named an agent sells the identity and buys it
  back, the agent is live again. So is any unused agent signature still before its deadline (`test_AnAgentLapsesOnASale`).
- **I-03 The toll counts every change of hands,** including moves between the owner's own wallets.
- **I-04 The artist's renderer can show anything** in a name's metadata (it is still only metadata). Lock it when the
  art is final.
- **I-05 Fake collections.** LARP proves what a collection's `ownerOf` / `balanceOf` answers, as ENS avatars do.
- **I-06 Hybrid tokens** (both `ownerOf` and `balanceOf(account, id)`) can be placed once each way.
- **I-07 Views forward all gas to collections the holder chose.** On-chain consumers should cap gas.
- **I-08 Prices are in ETH.** They change only through the swarm, within the guardrails.
- **I-09 Hook launches can't be proven.** IMD's v4-hook launcher has no `distributorOf`.
- **I-10** ETH force-sent to LARP, IMDNames or LARPLinks (no `receive`) stays there; the burner has one and burns it.
  WETH sent to the burner is unwrapped and burned too (L-11); any other token sent to the burner stays there.

## Checked and holding

- **6.9% buys IMD6900, and it is burned.**
  - **Where it buys:** the IMD6900/$IMD pool, through the real hook's per-trade IMD6900 allowance.
  - **How it burns:** with IMD6900's own `burn`, so the supply drops.
  - **On the fork:** a 0.0069 ETH name fee burned 16,849 IMD6900 and sent 1.81 $IMD to `0x…dEaD`.
  - **Gas:** across gas limits, no call skips the IMD6900 buy, even when the leg is heavy: the leg runs on a fixed
    budget, and a call that can't fund it is refused (`test_NoGasLimitSkipsARoute`,
    `test_NoGasLimitSkipsAHeavyIMD6900Leg`). A leg that eats its whole budget is skipped, not fatal (L-09).
- **The burner's ETH leaves only as a swap.** The sale is exact or nothing; a partial fill reverts the route. $IMD
  goes only to `0x…dEaD`. Only the PoolManager calls back, and only for the burner's own unlock. A transient lock
  refuses a burn inside a burn (`test_NoReentry`). Of the ETH already waiting, at most `MAX_BURN` leaves per block
  (L-10).
- **Agent signatures** use EIP-712 over (identity, agent, holder, nonce, deadline), bound to the chain and contract.
  - Malleable (high-s) signatures are refused.
  - A per-holder nonce, bumped by every agent change, voids unused signatures.
  - Contract wallets sign through ERC-1271.
  - An EOA path is tried first, so EIP-7702 accounts work.
  (`test/LARPAgents.t.sol`: 14 tests.)
- **Names.**
  - Two-way links: one name per identity, one identity per name.
  - Live only while the linker owns both.
  - The toll is due whenever the owner isn't the one who last paid.
  - A broken, gas-hungry or code-less renderer falls back to the card.
  (`test/IMDNames.t.sol`: 28 tests, including payments in $IMD.)
- **Swarm prices.** All checked in `test/SwarmPrices.t.sol` (15 tests):
  - **Signatures:** IMD's EIP-712 `OracleAttestation`, domain "IdentityMD Oracle" v2, for this contract. The callback's
    parameters are IMD's; its name is this contract's: `onVerdict`, selector `0x8bf09c1b`, which `propose` registers
    with the Intake (IMD's example name `onOracleResult` with the same parameters would be `0x510379c7`).
  - **Refused:** another key, another contract, a tampered signature, a weak panel (under 9, quorum under 7, fewer
    agreed than the quorum, under 7 in 9), and an expired verdict.
  - **Callbacks:** only from the Intake, and only for the contract's own proposals.
  - **Execution:** one change a week, stale after another change, within two weeks of the verdict, once.
  - **On the fork:** the real Intake path (`test_APriceProposalThroughIMDsRealIntake`).
- **Merkle proofs** and **placement bookkeeping** as before (`test_AnInnerNodeIsNotALeaf`, three invariants).
- **Launch constraints.** The constructors call nothing, and no CALLCODE / DELEGATECALL / SELFDESTRUCT appears anywhere.
  The four contracts take about 8.6M gas together, in one transaction (`test/Launch.t.sol`).
