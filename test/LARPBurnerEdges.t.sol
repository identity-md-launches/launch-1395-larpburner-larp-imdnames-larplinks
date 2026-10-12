// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {RangeAdder} from "./LARPBurner.invariant.t.sol";
import {MockWETH} from "./LARPBurner.t.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolKey as V4PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev WETH that reports a balance for everyone and refuses every withdrawal.
contract StuckWETH {
    function balanceOf(address) external pure returns (uint256) {
        return 1 ether;
    }

    function withdraw(uint256) external pure {
        revert("stuck");
    }
}

/// @dev WETH whose every answer is 16 bytes long.
contract ShortWETH {
    fallback() external payable {
        assembly {
            mstore(0, 0)
            return(0, 0x10)
        }
    }
}

/// @dev The burner at its edges: the constructor's refusals, its constants, one wei, exactly MAX_BURN, the block's
/// allowance for waiting ETH, the gas budget, WETH that misbehaves, a partial fill, pools that don't exist, and the
/// arithmetic of the share, fuzzed.
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
        // one wei over MAX_BURN, in the same block: the block's MAX_BURN of waiting ETH is already spent, so nothing
        // sells (and nothing parks: there was nothing to sell)
        vm.deal(address(burner), 0.1 ether + 1);
        assertEq(burner.burn(0), 0);
        assertEq(address(burner).balance, 0.1 ether + 1);
        // the next block: exactly MAX_BURN again, the wei stays
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.1 ether, 0, 0);
        burner.burn(0);
        assertEq(address(burner).balance, 1);
    }

    /// @dev The block's allowance is only for ETH that was already waiting: a caller's own ETH (up to MAX_BURN) is
    /// never counted against it, and what the caller's own ETH leaves of the call's cap is what the waiting ETH gets.
    function test_TheBlockAllowanceCountsOnlyTheWaitingEth() public {
        _fillPool4();
        vm.deal(address(burner), 0.3 ether); // royalties waiting
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.1 ether, 0, 0);
        burner.burn{value: 0.05 ether}(0); // 0.05 own + 0.05 waiting
        assertEq(address(burner).balance, 0.25 ether);
        // the block has 0.05 of its allowance left for the waiting ETH
        vm.prank(carol);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.05 ether, 0, 0);
        burner.burn(0);
        assertEq(address(burner).balance, 0.2 ether);
        // and then none, however many calls, while a fee still goes through whole
        assertEq(burner.burn(0), 0);
        assertEq(address(burner).balance, 0.2 ether);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.1 ether, 0, 0);
        burner.burn{value: 0.1 ether}(0);
        assertEq(address(burner).balance, 0.2 ether, "bob's own 0.1 went, nothing of the waiting ETH");
        // a fee above the cap: the excess joins the waiting ETH
        vm.prank(bob);
        burner.burn{value: 0.12 ether}(0);
        assertEq(address(burner).balance, 0.22 ether);
    }

    /// forge-config: default.fuzz.runs = 192
    /// @dev Two burns in one block, from the NatSpec: a caller's own ETH (up to MAX_BURN) always goes through, no
    /// call spends more than MAX_BURN, no more than MAX_BURN of the waiting ETH leaves in the block, and every wei
    /// that leaves lands in the PoolManager.
    function testFuzz_TwoBurnsInOneBlockSellAtMostOneCapOfWaitingEth(uint256 waiting, uint256 v1, uint256 v2) public {
        _fillPool4();
        _fillPair();
        waiting = bound(waiting, 1e12, 0.5 ether);
        v1 = bound(v1, 0, 0.3 ether);
        v2 = bound(v2, 0, 0.3 ether);
        vm.deal(address(burner), waiting);
        vm.deal(address(this), v1 + v2);
        uint256 pmBefore = address(pm).balance;
        uint256 max = burner.MAX_BURN();

        uint256 before = address(burner).balance + v1;
        burner.burn{value: v1}(0);
        uint256 sold1 = before - address(burner).balance;
        assertGe(sold1, v1 < max ? v1 : max, "the first caller's own ETH goes through");
        assertLe(sold1, max, "no call spends more than MAX_BURN");
        uint256 fromWaiting = sold1 - (v1 < max ? v1 : max);

        before = address(burner).balance + v2;
        burner.burn{value: v2}(0);
        uint256 sold2 = before - address(burner).balance;
        assertGe(sold2, v2 < max ? v2 : max, "the second caller's own ETH goes through");
        assertLe(sold2, max, "no call spends more than MAX_BURN");
        fromWaiting += sold2 - (v2 < max ? v2 : max);

        assertLe(fromWaiting, max, "at most MAX_BURN of the waiting ETH leaves per block");
        assertEq(address(pm).balance - pmBefore, sold1 + sold2, "ETH leaves only into the PoolManager");
        assertEq(address(burner).balance, waiting + v1 + v2 - sold1 - sold2);
        assertEq(imd.balanceOf(address(burner)), 0, "no $IMD stays");
    }

    // --- the gas budget at its edges ---

    /// @dev A leg that runs third-party code gets a fixed 3M budget, and a call that can't fund it is refused before
    /// the leg runs: with ETH to sell, or with enough $IMD for a share, a 1M-gas call reverts TooLittleGas and moves
    /// nothing. With nothing to sell and no share to buy, no leg runs and no budget is needed.
    function test_BelowTheLegBudgetABurnIsRefusedBeforeAnyLegRuns() public {
        _fillPool4();
        _fillPair();
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory err) =
            address(burner).call{value: 0.05 ether, gas: 1_000_000}(abi.encodeCall(burner.burn, (0)));
        assertFalse(ok);
        assertEq(bytes4(err), LARPBurner.TooLittleGas.selector);
        assertEq(address(burner).balance, 0, "a refused burn keeps nothing of the fee");
        assertEq(alice.balance, 1 ether);
        assertEq(imd.balanceOf(DEAD), 0);

        // nothing to sell, nothing held: the call does nothing and needs no budget
        (ok,) = address(burner).call{gas: 150_000}(abi.encodeCall(burner.burn, (0)));
        assertTrue(ok, "an empty burn runs no leg");

        // 14 wei of $IMD: the share rounds to 0, so no leg runs and 150k gas burns it all to DEAD
        imd.mint(address(burner), 14);
        (ok,) = address(burner).call{gas: 150_000}(abi.encodeCall(burner.burnImd, ()));
        assertTrue(ok, "no share, no leg, no budget");
        assertEq(imd.balanceOf(DEAD), 14);
        assertEq(imd.balanceOf(address(burner)), 0);

        // 15 wei: a share of 1 wei needs the IMD6900 leg, which needs its budget
        imd.mint(address(burner), 15);
        (ok, err) = address(burner).call{gas: 1_000_000}(abi.encodeCall(burner.burnImd, ()));
        assertFalse(ok);
        assertEq(bytes4(err), LARPBurner.TooLittleGas.selector);
        assertEq(imd.balanceOf(address(burner)), 15, "refused: nothing moved");
        burner.burnImd(); // with gas to spare it goes
        assertEq(imd.balanceOf(address(burner)), 0);
    }

    // --- WETH that does not behave ---

    /// @dev WETH that reports a balance but refuses to unwrap it: the burn goes on with the ETH it has, and the WETH
    /// stays where it is.
    function test_AWethThatRefusesToUnwrapIsIgnored() public {
        _fillPool4();
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        vm.etch(weth, address(new StuckWETH()).code);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.01 ether, 0, 0);
        assertGt(burner.burn{value: 0.01 ether}(0), 0);
        assertEq(address(burner).balance, 0);
        assertEq(StuckWETH(weth).balanceOf(address(burner)), 1 ether, "still there");
    }

    /// @dev WETH whose `balanceOf` answers fewer than 32 bytes: read as nothing to unwrap.
    function test_AWethAnsweringShortIsIgnored() public {
        _fillPool4();
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        vm.etch(weth, address(new ShortWETH()).code);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.01 ether, 0, 0);
        assertGt(burner.burn{value: 0.01 ether}(0), 0);
        assertEq(address(burner).balance, 0);
    }

    /// @dev Unwrapped WETH is waiting ETH, not the caller's own: it leaves MAX_BURN a block.
    function test_UnwrappedWethIsWaitingEth() public {
        _fillPool4();
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        vm.etch(weth, address(new MockWETH()).code);
        MockWETH(weth).deposit{value: 0.25 ether}();
        MockWETH(weth).transfer(address(burner), 0.25 ether);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.1 ether, 0, 0);
        burner.burn(0);
        assertEq(MockWETH(weth).balanceOf(address(burner)), 0);
        assertEq(address(burner).balance, 0.15 ether, "unwrapped, MAX_BURN sold");
        assertEq(burner.burn(0), 0, "the block's allowance is spent");
        assertEq(address(burner).balance, 0.15 ether);
        vm.roll(vm.getBlockNumber() + 1);
        burner.burn(0);
        assertEq(address(burner).balance, 0.05 ether);
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
