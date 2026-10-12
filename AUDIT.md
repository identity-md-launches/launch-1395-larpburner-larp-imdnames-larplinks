# LARP audit (2026-10-12, before the swarm launch)

Scope: `src/` at this commit: `LARPBurner`, `LARP` / `ILARP`, `IMDNames` / `IIMDNames` with `SwarmPrices`,
`LARPLinks`, `SafeReads`, `Labels`. Four contracts on Ethereum.
- No owner, no admin, no upgrades.
- The one role is the names' **artist**, who can change only the art (tokenURI's renderer) and can lock it forever.

**Result: no critical, high or medium findings.** 145 offline tests, plus 11 on an Ethereum fork. Two low findings fixed, each held by a test that fails without the
fix (L-01's guard was strengthened at the launch audit; see `ADAPTATION.md`). The rest acknowledged and documented.

## Trust: what LARP depends on, and what happens if it fails

| dependency | who controls it | if it fails or turns hostile |
|---|---|---|
| identity.md `0x0000eC93…` | its contract | inherent: LARP is about these tokens |
| Uniswap v4 PoolManager | nobody (immutable) | — |
| POOL4 (ETH/$IMD 1%, hook `0xc6C9…`) | IMD's treasury owns the hook (it can `closeMarket`) | the burner falls to route 2 |
| hookless ETH/$IMD pool (1%, spacing 200) | nobody (no hook); its LPs can withdraw | the ETH waits in the burner; anyone burns it later |
| IMD6900/$IMD pool (hook `0x667f…2A44`) | the IMD6900 ETH timelock owns the hook | the 6.9% that buys IMD6900 goes to `0x…dEaD` as $IMD instead |
| IMD6900 (`0x0000198C…`, upgradeable) | the IMD6900 ETH timelock | if its `burn` refuses, the same: the share goes to `0x…dEaD` as $IMD |
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

**Fix:** a route that fails with no more than 1/4 of its gas left reverts the call (`TooLittleGas`).

The first version of this fix drew the line at 1/63, which is what is left when the PoolManager itself runs out of
gas. The launch audit (2026-10-12) showed that is not where the work runs: the swap, the hook, the token transfers and
IMD6900's `burn` are two to five frames below the burner, and every frame in between keeps 1/64 of its gas and hands
it back when it reverts, so an out-of-gas that deep left the burner 3/64 to 5/64 of the gas. The 1/63 guard passed,
the leg counted as failed, and with a heavy IMD6900 leg (~800k gas) every gas limit from ~758k to ~1.97M went through
with the IMD6900 buy skipped (its share burned as $IMD at `0x…dEaD`). At 1/4 the guard catches an out-of-gas down to
18 frames, while a genuine revert, which hands back everything it did not use, still passes whenever the caller left a
quarter to spare. The cost: a call whose leg reverts for a real reason after heavy work (an empty pool whose swap walks
the whole tick range, ~340k gas) needs a gas limit about a third higher than the work itself (590k instead of 350k for
an empty pair pool after POOL4); gas used does not change, and a refused call moves nothing.
**Tests:**
- `test_ASwapOutOfGasReverts` (a PoolManager that burns all gas) fails without the fix.
- `test_NoGasLimitSkipsARoute` sweeps gas limits from 100k to 1.5M: the backup pool's price never moves while POOL4
  can take the trade, and no call that goes through skips the IMD6900 buy.
- `test_AnIMD6900LegOutOfGasDeepDownReverts` (an IMD6900 whose `burn` costs ~800k gas, 1M gas limit) and
  `test_NoGasLimitSkipsAHeavyIMD6900Leg` (the same, gas limits swept from 500k to 2.5M) fail with the 1/63 guard.
- `test_AGenuineFailureIsNotMistakenForTooLittleGas`: an empty pair pool's genuine revert is skipped at 1M gas and
  refused, not skipped, at 300k.

### L-02 The jeet board's reads grow without bound (LARPLinks)

`jeetOf` reads every proven launch of a wallet. **Fix:** `jeetOfRange(wallet, start, count)` pages it.
**Test:** `test_JeetsInPages`.

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
  - **If it fails:** an empty pair pool, a hook that refuses, or an IMD6900 that won't burn all send the share to
    `0x…dEaD` (`test_AnEmptyPairPoolMeansItAllBurnsAsIMD`, `test_AnIMD6900ThatWontBurnMeansItAllBurnsAsIMD`).

- **L-03 Name sniping.** A pending `register` can be front-run. There is no commit-reveal, and the sniper pays the full
  price (burned). The site should send registrations through a private mempool.
- **L-04 Sandwiching a burn.** At most `MAX_BURN` (0.1 ETH) is spent per call, below POOL4's ~0.24 ETH sandwich
  break-even, and far below the hookless pool's (23x POOL4's liquidity). Callers can set `minImd`; the site should
  pass a quote.
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

## Checked and holding

- **6.9% buys IMD6900, and it is burned.**
  - **Where it buys:** the IMD6900/$IMD pool, through the real hook's per-trade IMD6900 allowance.
  - **How it burns:** with IMD6900's own `burn`, so the supply drops.
  - **On the fork:** a 0.0069 ETH name fee burned 16,849 IMD6900 and sent 1.81 $IMD to `0x…dEaD`.
  - **Gas:** across gas limits, no call skips the IMD6900 buy, even when the leg is heavy and runs out of gas frames
    below the burner (`test_NoGasLimitSkipsARoute`, `test_NoGasLimitSkipsAHeavyIMD6900Leg`).
- **The burner's ETH leaves only as a swap.** The sale is exact or nothing; a partial fill reverts the route. $IMD
  goes only to `0x…dEaD`. Only the PoolManager calls back, and only for the burner's own unlock. A transient lock
  refuses a burn inside a burn (`test_NoReentry`).
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
  - **Signatures:** IMD's EIP-712 `OracleAttestation`, domain "IdentityMD Oracle" v2, for this contract. The callback
    selector `0x510379c7` matches IMD's docs.
  - **Refused:** another key, another contract, a tampered signature, a weak panel (under 9, quorum under 7, fewer
    agreed than the quorum, under 7 in 9), and an expired verdict.
  - **Callbacks:** only from the Intake, and only for the contract's own proposals.
  - **Execution:** one change a week, stale after another change, within two weeks of the verdict, once.
  - **On the fork:** the real Intake path (`test_APriceProposalThroughIMDsRealIntake`).
- **Merkle proofs** and **placement bookkeeping** as before (`test_AnInnerNodeIsNotALeaf`, three invariants).
- **Launch constraints.** The constructors call nothing, and no CALLCODE / DELEGATECALL / SELFDESTRUCT appears anywhere.
  The four contracts take about 8.6M gas together, in one transaction (`test/Launch.t.sol`).
