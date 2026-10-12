// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey as V4PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LARPBurner} from "../src/LARPBurner.sol";
import {MockIMD, MockIMD6900, LiquidityAdder} from "./Base.sol";

/// @dev Adds liquidity to a v4 pool in one tick range, paid by the caller (the Base adder is full range only).
contract RangeAdder {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function add(V4PoolKey memory key, int24 lower, int24 upper, int256 liquidity) external payable {
        pm.unlock(abi.encode(key, lower, upper, liquidity, msg.sender));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (V4PoolKey memory key, int24 lower, int24 upper, int256 liquidity, address payer) =
            abi.decode(data, (V4PoolKey, int24, int24, int256, address));
        (BalanceDelta delta,) = pm.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, liquidity, 0), "");
        _pay(key.currency0, uint256(uint128(-delta.amount0())), payer);
        _pay(key.currency1, uint256(uint128(-delta.amount1())), payer);
        if (address(this).balance > 0) payable(payer).transfer(address(this).balance);
        return "";
    }

    function _pay(Currency currency, uint256 amount, address payer) internal {
        if (amount == 0) return;
        if (Currency.unwrap(currency) == address(0)) {
            pm.settle{value: amount}();
        } else {
            pm.sync(currency);
            MockIMD(Currency.unwrap(currency)).transferFrom(payer, address(pm), amount);
            pm.settle();
        }
    }

    receive() external payable {}
}

/// @dev A third party trading on the pools the burner uses: exact-input swaps either way, paid by the caller.
contract Trader {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function swap(V4PoolKey memory key, bool zeroForOne, uint256 amountIn) external payable {
        pm.unlock(abi.encode(key, zeroForOne, amountIn, msg.sender));
        if (address(this).balance > 0) payable(msg.sender).transfer(address(this).balance);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (V4PoolKey memory key, bool zeroForOne, uint256 amountIn, address payer) =
            abi.decode(data, (V4PoolKey, bool, uint256, address));
        BalanceDelta d = pm.swap(
            key,
            SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        _settle(key.currency0, d.amount0(), payer);
        _settle(key.currency1, d.amount1(), payer);
        return "";
    }

    function _settle(Currency currency, int128 amount, address payer) internal {
        if (amount == 0) return;
        if (amount > 0) {
            pm.take(currency, payer, uint128(amount));
            return;
        }
        uint256 owed = uint128(-amount);
        if (Currency.unwrap(currency) == address(0)) {
            pm.settle{value: owed}();
        } else {
            pm.sync(currency);
            MockIMD(Currency.unwrap(currency)).transferFrom(payer, address(pm), owed);
            pm.settle();
        }
    }

    receive() external payable {}
}

/// @dev Drives the burner at random: ETH and $IMD arrive, anyone burns with any `minImd`, a trader moves POOL4 in and
/// out of its liquidity range (so routes fail and fall back), and now and then the PoolManager refuses every unlock
/// (so the ETH parks). Ghost totals record what came in and what the PoolManager received.
contract BurnerHandler is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LARPBurner public burner;
    MockIMD public imd;
    MockIMD6900 public imd6900;
    PoolManager public pm;
    Trader public trader;
    V4PoolKey public pool4;
    V4PoolKey public backup;
    V4PoolKey public pair;

    // --- ghosts ---
    uint256 public ethIn; // ETH that arrived at the burner (donations and burn values that went through)
    uint256 public ethToPm; // ETH the PoolManager gained during the burner's calls
    uint256 public imdIn; // $IMD minted straight to the burner
    uint256 public imdFromPm; // $IMD the burner bought (burn's return values)
    uint256 public imdToPm; // $IMD the burner spent on IMD6900 (the PoolManager's gain during its calls)
    uint256 public imdSinceLastBurn; // $IMD donated since the last burn that went through
    uint256 public imd6900Burned; // IMD6900 supply lost during the burner's calls
    uint256 public deadHighWater;
    uint256 public burns;
    uint256 public parked;
    uint256 public fellBack;
    uint256 public refused;

    address[3] public callers = [address(0xA11CE), address(0xB0B), address(0xCA401)];

    constructor(
        LARPBurner burner_,
        MockIMD imd_,
        MockIMD6900 imd6900_,
        PoolManager pm_,
        Trader trader_,
        V4PoolKey memory pool4_,
        V4PoolKey memory backup_,
        V4PoolKey memory pair_
    ) {
        burner = burner_;
        imd = imd_;
        imd6900 = imd6900_;
        pm = pm_;
        trader = trader_;
        pool4 = pool4_;
        backup = backup_;
        pair = pair_;
        imd.mint(address(this), 1e30);
        imd.approve(address(trader), type(uint256).max);
    }

    receive() external payable {}

    function donateEth(uint256 amount) external {
        amount = bound(amount, 1, 0.5 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(burner).call{value: amount}("");
        assertTrue(ok, "receive() takes any ETH");
        ethIn += amount;
    }

    function donateImd(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        imd.mint(address(burner), amount);
        imdIn += amount;
        imdSinceLastBurn += amount;
    }

    function burn(uint256 who, uint256 value, uint256 minImd, bool starve) external {
        value = bound(value, 0, 0.3 ether);
        minImd = bound(minImd, 0, 300 ether);
        address caller = callers[who % 3];
        vm.deal(caller, value);
        if (starve) vm.mockCallRevert(address(pm), abi.encodeWithSelector(IPoolManager.unlock.selector), "closed");
        _burn(caller, value, minImd);
        if (starve) vm.clearMockedCalls();
    }

    function burnImd(uint256 who) external {
        address caller = callers[who % 3];
        uint256 pmImd = imd.balanceOf(address(pm));
        uint256 held = imd.balanceOf(address(burner));
        uint256 supply = imd6900.totalSupply();
        vm.prank(caller);
        burner.burnImd();
        _afterImdBurn(held, pmImd, supply);
    }

    /// @dev Sells ETH into POOL4 (pushing its price down, possibly out of its range) or buys it back. A trade the pool
    /// itself refuses (its price already at the limit) is simply not made: the trader is scenery, not the subject.
    function trade(bool sellEth, uint256 amount) external {
        if (sellEth) {
            amount = bound(amount, 0.01 ether, 3 ether);
            vm.deal(address(this), amount);
            try trader.swap{value: amount}(pool4, true, amount) {} catch {}
        } else {
            amount = bound(amount, 1 ether, 6_000 ether);
            try trader.swap(pool4, false, amount) {} catch {}
        }
    }

    function _burn(address caller, uint256 value, uint256 minImd) internal {
        uint256 ethBefore = address(burner).balance + value;
        uint256 pmEth = address(pm).balance;
        uint256 pmImd = imd.balanceOf(address(pm));
        uint256 held = imd.balanceOf(address(burner));
        uint256 supply = imd6900.totalSupply();
        uint256 expectSpend = ethBefore > burner.MAX_BURN() ? burner.MAX_BURN() : ethBefore;

        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory err) = address(burner).call{value: value}(abi.encodeCall(burner.burn, (minImd)));
        if (!ok) {
            ++refused;
            assertEq(bytes4(err), LARPBurner.TooLittleIMD.selector, "with gas to spare, only minImd refuses a burn");
            assertEq(address(burner).balance, ethBefore - value, "a refused burn moves no ETH");
            assertEq(imd.balanceOf(address(burner)), held, "a refused burn moves no IMD");
            return;
        }
        ++burns;
        ethIn += value;
        uint256 bought = abi.decode(err, (uint256));
        uint256 spent = ethBefore - address(burner).balance;
        uint256 pmGain = address(pm).balance - pmEth;
        assertEq(spent, pmGain, "every wei that leaves the burner lands in the PoolManager");
        assertTrue(spent == 0 || spent == expectSpend, "the sale is exact (up to MAX_BURN) or nothing");
        assertTrue((spent == 0) == (bought == 0), "ETH is spent exactly when IMD is bought");
        assertGe(bought, minImd, "the caller's floor holds");
        ethToPm += spent;
        imdFromPm += bought;
        if (spent == 0 && ethBefore != 0) ++parked;
        // which route took it, from the Bought event (route 1 is the hookless pool)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == keccak256("Bought(uint256,uint256,uint8)")) {
                (uint256 eth, uint256 got, uint8 route) = abi.decode(logs[i].data, (uint256, uint256, uint8));
                assertEq(eth, spent);
                assertEq(got, bought);
                if (route == 1) ++fellBack;
            }
        }
        _afterImdBurn(held + bought, pmImd - bought, supply);
    }

    /// @dev After any burn: nothing stays, the IMD6900 share is 6.9% or nothing, and the rest is at DEAD.
    function _afterImdBurn(uint256 held, uint256 pmImdBefore, uint256 supplyBefore) internal {
        assertEq(imd.balanceOf(address(burner)), 0, "no $IMD stays in the burner");
        assertEq(imd6900.balanceOf(address(burner)), 0, "no IMD6900 stays in the burner");
        uint256 spent = imd.balanceOf(address(pm)) - pmImdBefore;
        uint256 share = held * burner.POOL_SHARE_BPS() / 10_000;
        assertTrue(spent == 0 || spent == share, "the IMD6900 leg takes exactly the share or nothing");
        uint256 burned6900 = supplyBefore - imd6900.totalSupply();
        assertTrue((spent == 0) == (burned6900 == 0), "IMD6900 burns exactly when the share was spent");
        imdToPm += spent;
        imd6900Burned += burned6900;
        imdSinceLastBurn = 0;
        uint256 dead = imd.balanceOf(DEAD);
        assertGe(dead, deadHighWater, "DEAD never loses $IMD");
        deadHighWater = dead;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract LARPBurnerInvariantTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockIMD imd;
    MockIMD6900 imd6900;
    PoolManager pm;
    LARPBurner burner;
    BurnerHandler handler;
    V4PoolKey pool4;
    V4PoolKey backup;
    V4PoolKey pair;
    uint256 supplyAtStart;
    uint256 pmEthAtStart;

    function setUp() public {
        imd = new MockIMD();
        imd6900 = new MockIMD6900();
        pm = new PoolManager(address(this));
        LiquidityAdder adder = new LiquidityAdder(IPoolManager(address(pm)));
        RangeAdder ranged = new RangeAdder(IPoolManager(address(pm)));
        Trader trader = new Trader(IPoolManager(address(pm)));
        pool4 = V4PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 60, IHooks(address(0)));
        backup = V4PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 200, IHooks(address(0)));
        pm.initialize(pool4, TickMath.getSqrtPriceAtTick(76_020));
        pm.initialize(backup, TickMath.getSqrtPriceAtTick(76_000));
        bool imdIs0 = address(imd) < address(imd6900);
        pair = imdIs0
            ? V4PoolKey(Currency.wrap(address(imd)), Currency.wrap(address(imd6900)), 0, 60, IHooks(address(0)))
            : V4PoolKey(Currency.wrap(address(imd6900)), Currency.wrap(address(imd)), 0, 60, IHooks(address(0)));
        pm.initialize(pair, TickMath.getSqrtPriceAtTick(imdIs0 ? int24(92_100) : int24(-92_100)));

        burner = new LARPBurner(
            address(pm), address(imd), 10_000, 60, address(0), 10_000, 200, address(imd6900), 0, 60, address(0)
        );

        imd.mint(address(this), 1e30);
        imd.approve(address(adder), type(uint256).max);
        imd.approve(address(ranged), type(uint256).max);
        imd6900.mint(address(this), 1e33);
        imd6900.approve(address(adder), type(uint256).max);
        vm.deal(address(this), 10_000 ether);
        // POOL4 concentrated around its price (a trader can push it out of range), the backup full range, the pair full
        ranged.add{value: 1_000 ether}(pool4, 75_000, 77_040, 1e21);
        adder.add{value: 1_000 ether}(backup, 1e21);
        adder.add(pair, 1e23);
        supplyAtStart = imd6900.totalSupply();
        pmEthAtStart = address(pm).balance;

        handler = new BurnerHandler(burner, imd, imd6900, pm, trader, pool4, backup, pair);
        targetContract(address(handler));
    }

    receive() external payable {}

    /// @dev ETH only ever leaves the burner as a swap: what arrived equals what it holds plus what the PoolManager got.
    function invariant_EthLeavesOnlyAsASwap() public view {
        assertEq(address(burner).balance + handler.ethToPm(), handler.ethIn());
    }

    /// @dev $IMD is conserved: everything that arrived (minted or bought) is at DEAD, in the pair pool (as the IMD6900
    /// buy), or still in the burner waiting for the next burn.
    function invariant_ImdGoesOnlyToDeadOrTheIMD6900Buy() public view {
        assertEq(
            imd.balanceOf(address(burner)) + imd.balanceOf(DEAD) + handler.imdToPm(),
            handler.imdIn() + handler.imdFromPm()
        );
    }

    /// @dev The burner holds exactly the $IMD donated since the last burn: a burn leaves none behind.
    function invariant_NoImdOutlivesABurn() public view {
        assertEq(imd.balanceOf(address(burner)), handler.imdSinceLastBurn());
    }

    /// @dev IMD6900 only ever leaves circulation, and only through the burner's calls.
    function invariant_Imd6900OnlyBurns() public view {
        assertEq(supplyAtStart - imd6900.totalSupply(), handler.imd6900Burned());
        assertEq(imd6900.balanceOf(address(burner)), 0);
    }

    /// @dev Nothing but $IMD at DEAD: the burner never sends ETH or IMD6900 there.
    function invariant_DeadHoldsOnlyImd() public view {
        assertEq(DEAD.balance, 0);
        assertEq(imd6900.balanceOf(DEAD), 0);
    }
}
