// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {RangeAdder} from "./LARPBurner.invariant.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolKey as V4PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev The burner at its edges: the constructor's refusals, its constants, one wei, exactly MAX_BURN, a partial fill,
/// pools that don't exist, and the arithmetic of the share, fuzzed.
contract LARPBurnerEdgesTest is Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for V4PoolKey;

    event Parked(uint256 eth);
    event Bought(uint256 eth, uint256 imd, uint8 route);

    function setUp() public {
        _deploy();
    }

    // --- the constructor and constants ---

    function test_ConstructorRefusesZeroAddresses() public {
        vm.expectRevert(LARPBurner.ZeroAddress.selector);
        new LARPBurner(
            address(0), address(imd), 10_000, 60, address(0), 10_000, 200, address(imd6900), 0, 60, address(0)
        );
        vm.expectRevert(LARPBurner.ZeroAddress.selector);
        new LARPBurner(
            address(pm), address(0), 10_000, 60, address(0), 10_000, 200, address(imd6900), 0, 60, address(0)
        );
        vm.expectRevert(LARPBurner.ZeroAddress.selector);
        new LARPBurner(address(pm), address(imd), 10_000, 60, address(0), 10_000, 200, address(0), 0, 60, address(0));
        // the hooks may be zero: the hookless pool has none
        LARPBurner b = new LARPBurner(
            address(pm), address(imd), 10_000, 60, address(0), 10_000, 200, address(imd6900), 0, 60, address(0)
        );
        assertEq(b.POOL4_HOOK(), address(0));
        assertEq(b.PAIR_HOOK(), address(0));
    }

    function test_Constants() public view {
        assertEq(burner.DEAD(), 0x000000000000000000000000000000000000dEaD);
        assertEq(burner.MAX_BURN(), 0.1 ether);
        assertEq(burner.POOL_SHARE_BPS(), 690);
        assertEq(address(burner.POOL_MANAGER()), address(pm));
        assertEq(burner.IMD(), address(imd));
        assertEq(burner.IMD6900(), address(imd6900));
        assertEq(burner.POOL4_FEE(), 10_000);
        assertEq(burner.BACKUP_FEE(), 10_000);
        assertEq(burner.PAIR_FEE(), 0);
    }

    function test_ReceiveTakesEmptyCallsOnly() public {
        (bool ok,) = address(burner).call{value: 1}("");
        assertTrue(ok, "receive()");
        (ok,) = address(burner).call{value: 1}(hex"deadbeef");
        assertFalse(ok, "no fallback: a call with data is refused");
        assertEq(address(burner).balance, 1);
    }

    // --- amounts at the edges ---

    function test_OneWeiParks() public {
        _fillPool4();
        _fillBackup();
        // a wei is all fee: no pool gives $IMD for it, so it waits (and minImd 0 lets it)
        vm.expectEmit(address(burner));
        emit Parked(1);
        assertEq(burner.burn{value: 1}(0), 0);
        assertEq(address(burner).balance, 1);
    }

    function test_ExactlyMaxBurnInOneCall() public {
        _fillPool4();
        vm.deal(address(burner), 0.1 ether);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.1 ether, 0, 0);
        burner.burn(0);
        assertEq(address(burner).balance, 0);
        // one wei over MAX_BURN: the wei stays
        vm.deal(address(burner), 0.1 ether + 1);
        burner.burn(0);
        assertEq(address(burner).balance, 1);
    }

    function test_NothingToBurnIsNotAnError() public {
        _fillPool4();
        assertEq(burner.burn(0), 0, "no ETH, no $IMD: nothing happens");
        burner.burnImd();
        assertEq(imd.balanceOf(DEAD), 0);
        // but a floor with nothing to sell is refused
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn(1);
    }

    /// @dev POOL4's liquidity sits in a narrow range: a sale too big for it fills only partly, which the burner refuses
    /// (all or nothing), so the hookless pool takes the whole trade instead and POOL4's price does not move.
    function test_APartialFillOnPool4FallsToTheHooklessPool() public {
        RangeAdder ranged = new RangeAdder(IPoolManager(address(pm)));
        imd.approve(address(ranged), type(uint256).max);
        ranged.add{value: 100 ether}(pool4, 76_020 - 60, 76_020 + 60, 1e19); // thin, and only around the price
        _fillBackup();
        (uint160 pool4Before,,,) = IPoolManager(address(pm)).getSlot0(pool4.toId());
        // a small sale fits POOL4
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.0001 ether, 0, 0);
        burner.burn{value: 0.0001 ether}(0);
        // a large one would run off POOL4's range: it goes whole to the hookless pool
        (pool4Before,,,) = IPoolManager(address(pm)).getSlot0(pool4.toId());
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.1 ether, 0, 1);
        uint256 got = burner.burn{value: 0.1 ether}(0);
        assertGt(got, 0);
        (uint160 pool4After,,,) = IPoolManager(address(pm)).getSlot0(pool4.toId());
        assertEq(pool4After, pool4Before, "POOL4 was left alone: no partial fill");
        assertEq(address(burner).balance, 0);
    }

    function test_AWrongPool4KeyFallsToTheHooklessPool() public {
        // a burner whose POOL4 (a hook nobody initialized a pool with) does not exist on the PoolManager
        LARPBurner b = new LARPBurner(
            address(pm), address(imd), 10_000, 60, makeAddr("hook"), 10_000, 200, address(imd6900), 0, 60, address(0)
        );
        _fillBackup();
        vm.expectEmit(true, false, true, false, address(b));
        emit Bought(0.01 ether, 0, 1);
        assertGt(b.burn{value: 0.01 ether}(0), 0);
        // and no quote, since POOL4 has no price
        vm.expectRevert(LARPBurner.NoPrice.selector);
        b.quoteImd(1 ether);
    }

    function test_NoPoolAtAllParksAndQuotesNothing() public {
        // a fee tier no pool was initialized with
        LARPBurner b = new LARPBurner(
            address(pm), address(imd), 3_000, 60, address(0), 3_000, 200, address(imd6900), 0, 60, address(0)
        );
        _fillPool4();
        _fillBackup();
        vm.expectEmit(address(b));
        emit Parked(0.01 ether);
        b.burn{value: 0.01 ether}(0);
        assertEq(address(b).balance, 0.01 ether);
        vm.expectRevert(LARPBurner.NoPrice.selector);
        b.quoteImd(1 ether);
    }

    // --- quotes ---

    function test_QuoteOfTheSmallestPrice() public {
        _fillPool4();
        _fillBackup();
        uint256 q = burner.quoteImd(0.00001 ether); // MIN_PRICE
        assertApproxEqRel(q, 0.02 ether, 0.02e18, "0.00001 ETH at ~2,000 IMD per ETH");
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_QuoteIsLinearAndMonotone(uint256 a, uint256 b) public {
        _fillPool4();
        _fillBackup();
        a = bound(a, 1e12, 10 ether);
        b = bound(b, a, 10 ether);
        uint256 qa = burner.quoteImd(a);
        uint256 qb = burner.quoteImd(b);
        assertLe(qa, qb, "more ETH never quotes less $IMD");
        assertApproxEqRel(qa, a * 2_000, 0.02e18, "spot, no fee");
    }

    // --- the share, fuzzed ---

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_SixPointNinePercentBuysIMD6900AndTheRestBurns(uint256 held) public {
        _fillPair();
        held = bound(held, 1, 1e24);
        imd.mint(address(burner), held);
        uint256 pmImd = imd.balanceOf(address(pm));
        uint256 supply = imd6900.totalSupply();
        burner.burnImd();
        uint256 share = held * 690 / 10_000;
        assertEq(imd.balanceOf(address(pm)) - pmImd, share, "exactly the share went to the pair pool");
        assertEq(imd.balanceOf(DEAD), held - share, "the rest to DEAD");
        assertEq(imd.balanceOf(address(burner)), 0);
        assertEq(imd6900.balanceOf(address(burner)), 0);
        if (share == 0) assertEq(imd6900.totalSupply(), supply, "under 15 wei there is no share");
        else assertLt(imd6900.totalSupply(), supply);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzz_ABurnSpendsMinOfBalanceAndMaxBurn(uint256 eth, uint256 value) public {
        _fillPool4();
        _fillPair();
        eth = bound(eth, 0, 0.5 ether);
        value = bound(value, 0, 0.5 ether);
        vm.deal(address(burner), eth);
        vm.deal(address(this), value);
        uint256 all = eth + value;
        uint256 expect = all > 0.1 ether ? 0.1 ether : all;
        uint256 got = burner.burn{value: value}(0);
        if (all < 1e9) {
            // dust: it may buy nothing and park
            assertTrue(address(burner).balance == all - expect || address(burner).balance == all);
            return;
        }
        assertGt(got, 0);
        assertEq(address(burner).balance, all - expect);
        assertEq(imd.balanceOf(address(burner)), 0);
    }
}
