// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base, MockIMD6900} from "./Base.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary, PoolKey as V4PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev A PoolManager whose swap burns all the gas it is given, as a heavy hook could.
contract GasHogPoolManager {
    function unlock(bytes calldata) external pure returns (bytes memory) {
        while (true) {}
        return "";
    }
}

/// @dev An IMD6900 whose `burn` does about 800k gas of work first: on Ethereum the IMD6900 leg runs the pair hook and
/// an upgradeable token's burn, three to five frames below the burner, and its cost isn't known in advance.
contract HeavyIMD6900 is MockIMD6900 {
    function burn(uint256 amount) external override {
        bytes32 h;
        for (uint256 i; i < 5_000; ++i) {
            h = keccak256(abi.encode(h, i));
        }
        _burn(msg.sender, amount);
    }
}

/// @dev An IMD6900 whose `burn` never returns: the real one is a proxy, one upgrade away from this.
contract GasHogIMD6900 is MockIMD6900 {
    function burn(uint256) external pure override {
        while (true) {}
    }
}

/// @dev A v4 hook that eats all the gas it is given, whatever is called.
contract GasHogHook {
    fallback() external payable {
        while (true) {}
    }
}

/// @dev WETH9 as far as the burner uses it: `balanceOf`, `withdraw` (paying with a 2300-gas transfer, as WETH9 does).
contract MockWETH {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        payable(msg.sender).transfer(amount);
    }
}

/// @dev A searcher's batch: `burn(0)` many times in one transaction.
contract Batcher {
    function batch(LARPBurner burner, uint256 calls) external {
        for (uint256 i; i < calls; ++i) {
            try burner.burn(0) {} catch {}
        }
    }
}

/// @dev A PoolManager that calls the burner back during unlock.
contract ReenteringPoolManager {
    LARPBurner public burner;
    bytes public lastError;

    function aim(LARPBurner b) external {
        burner = b;
    }

    function unlock(bytes calldata) external returns (bytes memory) {
        try burner.burn(0) {}
        catch (bytes memory e) {
            lastError = e;
        }
        return abi.encode(uint256(0));
    }
}

contract LARPBurnerTest is Base {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for V4PoolKey;

    event Bought(uint256 eth, uint256 imd, uint8 route);
    event Parked(uint256 eth);
    event Burned(uint256 imdBurned, uint256 imdSpent, uint256 imd6900Burned);

    function setUp() public {
        _deploy();
    }

    function _slot0(V4PoolKey memory key) internal view returns (uint160 price) {
        (price,,,) = IPoolManager(address(pm)).getSlot0(key.toId());
    }

    // --- ETH to $IMD ---

    function test_SpacingsAreTakenUnsignedAndKeptAsInt24() public {
        LARPBurner b = _newBurner(address(pm));
        assertEq(int256(b.POOL4_SPACING()), 60);
        assertEq(int256(b.BACKUP_SPACING()), 200);
        assertEq(int256(b.PAIR_SPACING()), 60);
    }

    function test_SpacingAboveV4sLargestReverts() public {
        vm.expectRevert(LARPBurner.BadSpacing.selector);
        new LARPBurner(
            address(pm), address(imd), 10_000, 32_768, address(0), 10_000, 200, address(imd6900), 0, 60, address(0)
        );
        vm.expectRevert(LARPBurner.BadSpacing.selector);
        new LARPBurner(
            address(pm),
            address(imd),
            10_000,
            60,
            address(0),
            10_000,
            200,
            address(imd6900),
            0,
            type(uint24).max,
            address(0)
        );
        LARPBurner ok = new LARPBurner(
            address(pm), address(imd), 10_000, 32_767, address(0), 10_000, 200, address(imd6900), 0, 60, address(0)
        );
        assertEq(int256(ok.POOL4_SPACING()), 32_767);
    }

    function test_BuysOnPool4First() public {
        _fillPool4();
        _fillBackup();
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.05 ether, 0, 0);
        uint256 got = burner.burn{value: 0.05 ether}(0);
        assertApproxEqRel(got, 99 ether, 0.02e18, "0.05 ETH at ~2,000 IMD per ETH, less 1%");
        assertEq(address(burner).balance, 0);
        assertEq(imd.balanceOf(address(burner)), 0, "nothing stays");
    }

    function test_TheHooklessPoolIfPool4CantTakeIt() public {
        _fillBackup(); // POOL4 stays empty
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.05 ether, 0, 1);
        assertGt(burner.burn{value: 0.05 ether}(0), 0);
    }

    function test_ParkedWhenNoPoolCanAndBurnedLater() public {
        vm.expectEmit(address(burner));
        emit Parked(0.05 ether);
        assertEq(burner.burn{value: 0.05 ether}(0), 0);
        assertEq(address(burner).balance, 0.05 ether, "it waits");
        _fillPool4();
        vm.prank(carol); // anyone
        assertGt(burner.burn(0), 0);
        assertEq(address(burner).balance, 0);
    }

    function test_MinImd() public {
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn{value: 0.05 ether}(1); // no pool: parking refused
        _fillPool4();
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        burner.burn{value: 0.05 ether}(200 ether);
    }

    function test_AtMostMaxBurnPerCallAndPerBlockOfWaitingEth() public {
        _fillPool4();
        vm.deal(address(burner), 0.35 ether);
        burner.burn(0);
        assertEq(address(burner).balance, 0.25 ether, "one call spends at most MAX_BURN");
        burner.burn(0);
        burner.burn(0);
        assertEq(address(burner).balance, 0.25 ether, "the block's MAX_BURN of waiting ETH is spent: the rest waits");
        vm.roll(vm.getBlockNumber() + 1);
        burner.burn(0);
        assertEq(address(burner).balance, 0.15 ether);
        vm.roll(vm.getBlockNumber() + 1);
        burner.burn(0);
        vm.roll(vm.getBlockNumber() + 1);
        burner.burn(0);
        assertEq(address(burner).balance, 0);
    }

    /// @dev The batched sandwich: ETH that arrived through `receive` (royalties) can't be sold in one transaction by
    /// calling `burn(0)` repeatedly; only MAX_BURN of it goes, the rest waits for later blocks (one burn at a time is
    /// below POOL4's sandwich break-even, AUDIT.md L-04).
    function test_BurnCallsBatchedInOneTransactionSellOneCap() public {
        _fillPool4();
        vm.deal(address(burner), 1 ether);
        uint256 price = _slot0(pool4);
        new Batcher().batch(burner, 10);
        assertEq(address(burner).balance, 0.9 ether, "ten calls in one transaction sold what one call does");
        uint256 moved = _slot0(pool4) < price ? price - _slot0(pool4) : _slot0(pool4) - price;
        assertLt(moved, price / 100, "POOL4 moved as for one 0.1 ETH trade");
    }

    /// @dev A caller's own fee always goes through, up to MAX_BURN, whatever was spent this block; what is above the
    /// cap waits and leaves with the waiting ETH, MAX_BURN a block.
    function test_AFeeAlwaysGoesThroughWhateverTheBlockSpent() public {
        _fillPool4();
        vm.deal(address(burner), 0.5 ether); // royalties waiting
        vm.prank(carol);
        burner.burn(0); // this block's MAX_BURN of waiting ETH
        assertEq(address(burner).balance, 0.4 ether);

        vm.deal(alice, 1 ether);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.0069 ether, 0, 0);
        vm.prank(alice);
        assertGt(burner.burn{value: 0.0069 ether}(0), 0, "a fee in the same block is bought");
        assertEq(address(burner).balance, 0.4 ether, "exactly the fee, no waiting ETH");

        vm.deal(bob, 1 ether);
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.1 ether, 0, 0);
        vm.prank(bob);
        burner.burn{value: 0.15 ether}(0);
        assertEq(address(burner).balance, 0.45 ether, "a fee above the cap: MAX_BURN bought, the rest waits");

        vm.roll(vm.getBlockNumber() + 1);
        burner.burn(0);
        assertEq(address(burner).balance, 0.35 ether, "the next block: MAX_BURN of the waiting ETH again");
    }

    /// @dev A royalty paid in WETH (an accepted offer on Seaport or Blur settles in WETH) is unwrapped on the next
    /// burn and sold like the ETH. The test chain's WETH is a mock etched at WETH9's Ethereum address.
    function test_WethRoyaltiesAreUnwrappedAndSold() public {
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        vm.etch(weth, address(new MockWETH()).code);
        MockWETH(weth).deposit{value: 0.69 ether}();
        MockWETH(weth).transfer(address(burner), 0.69 ether);
        _fillPool4();
        vm.expectEmit(true, false, true, false, address(burner));
        emit Bought(0.1 ether, 0, 0);
        vm.prank(carol);
        burner.burn(0);
        assertEq(MockWETH(weth).balanceOf(address(burner)), 0, "the WETH was unwrapped");
        assertEq(address(burner).balance, 0.59 ether, "and joined the waiting ETH, sold MAX_BURN a block");
        assertGt(imd.balanceOf(DEAD), 0);
    }

    function test_RoyaltiesArriveByPlainTransfer() public {
        payable(address(burner)).transfer(0.01 ether);
        (bool ok,) = address(burner).call{value: 0.02 ether}("");
        assertTrue(ok);
        assertEq(address(burner).balance, 0.03 ether);
    }

    // --- $IMD: 6.9% buys IMD6900, burned; the rest to DEAD ---

    function test_ShareBuysIMD6900AndBurnsIt() public {
        _fillPool4();
        _fillPair();
        uint256 supply = imd6900.totalSupply();
        uint160 pairBefore = _slot0(pair);

        uint256 got = burner.burn{value: 0.05 ether}(0);

        uint256 share = got * 690 / 10_000;
        assertEq(imd.balanceOf(DEAD), got - share, "93.1% to 0x..dEaD");
        assertLt(imd6900.totalSupply(), supply, "IMD6900 bought and burned");
        assertApproxEqRel(supply - imd6900.totalSupply(), share * 10_000, 0.02e18, "at ~10,000 IMD6900 per IMD");
        assertTrue(_slot0(pair) != pairBefore, "the pair pool's price moved: buying pressure");
        assertEq(imd.balanceOf(address(burner)), 0);
        assertEq(imd6900.balanceOf(address(burner)), 0);
    }

    function test_AnEmptyPairPoolMeansItAllBurnsAsIMD() public {
        _fillPool4(); // no pair liquidity
        uint256 got = burner.burn{value: 0.05 ether}(0);
        assertEq(imd.balanceOf(DEAD), got, "the share went to 0x..dEaD too");
        assertEq(imd.balanceOf(address(burner)), 0);
    }

    function test_AnIMD6900ThatWontBurnMeansItAllBurnsAsIMD() public {
        _fillPool4();
        _fillPair();
        vm.mockCallRevert(address(imd6900), abi.encodeWithSignature("burn(uint256)"), "no");
        uint256 got = burner.burn{value: 0.05 ether}(0);
        assertEq(imd.balanceOf(DEAD), got);
    }

    function test_BurnImdBurnsWhatArrivesInIMD() public {
        _fillPair();
        imd.mint(address(burner), 100 ether);
        uint256 supply = imd6900.totalSupply();
        vm.expectEmit(true, true, false, false, address(burner));
        emit Burned(93.1 ether, 6.9 ether, 0);
        vm.prank(carol); // anyone
        burner.burnImd();
        assertEq(imd.balanceOf(DEAD), 93.1 ether);
        assertLt(imd6900.totalSupply(), supply);
    }

    // --- quoting $IMD for payments ---

    function test_QuoteIsTheHigherOfTheTwoPools() public {
        _fillPool4();
        _fillBackup();
        // POOL4 at tick 76,020 and the backup at 76,000: the higher IMD amount is POOL4's, ~2,000 per ETH
        uint256 q = burner.quoteImd(1 ether);
        assertApproxEqRel(q, 2000 ether, 0.01e18);
        // buying IMD on POOL4 (fewer IMD per ETH there) can't lower the quote below the backup's
        uint256 backupOnly = 1 ether * uint256(_slot0(backup)) / (1 << 96) * uint256(_slot0(backup)) / (1 << 96);
        burner.burn{value: 0.1 ether}(0);
        assertGe(burner.quoteImd(1 ether), backupOnly * 999 / 1000);
    }

    function test_NoQuoteWithoutBothPools() public {
        _fillPool4();
        vm.expectRevert(LARPBurner.NoPrice.selector);
        burner.quoteImd(1 ether);
    }

    // --- safety ---

    function test_OnlyThePoolManagerCallsBack() public {
        vm.expectRevert(LARPBurner.NotPoolManager.selector);
        burner.unlockCallback(abi.encode(uint8(0), uint256(1 ether)));
    }

    /// @dev A PoolManager that eats all its gas: route 0 spends its budget and is skipped; the hookless route gets all
    /// the gas, runs out, and the call reverts rather than parking the fee.
    function test_ASwapOutOfGasReverts() public {
        LARPBurner hogged = _newBurner(address(new GasHogPoolManager()));
        (bool ok, bytes memory err) =
            address(hogged).call{value: 0.05 ether, gas: 10_000_000}(abi.encodeCall(hogged.burn, (0)));
        assertFalse(ok);
        assertEq(bytes4(err), LARPBurner.TooLittleGas.selector);
        (ok, err) = address(hogged).call{value: 0.05 ether, gas: 3_000_000}(abi.encodeCall(hogged.burn, (0)));
        assertFalse(ok, "too little to fund route 0's budget: refused before trying");
        assertEq(bytes4(err), LARPBurner.TooLittleGas.selector);
    }

    /// @dev With any gas limit, a burn goes through POOL4 and the IMD6900 buy, or reverts: too little gas can't push
    /// it to the backup, nor skip the IMD6900 buy. Below the two legs' budgets (~3.35M) every call is refused.
    function test_NoGasLimitSkipsARoute() public {
        _fillPool4();
        _fillBackup();
        _fillPair();
        uint160 backupPrice = _slot0(backup);
        uint256 burned;
        for (uint256 gas = 100_000; gas < 4_500_000; gas += 100_000) {
            uint256 deadBefore = imd.balanceOf(DEAD);
            uint256 supplyBefore = imd6900.totalSupply();
            (bool ok,) = address(burner).call{value: 0.001 ether, gas: gas}(abi.encodeCall(burner.burn, (0)));
            assertEq(_slot0(backup), backupPrice, "the backup is never used while POOL4 can take the trade");
            if (ok) {
                ++burned;
                assertGt(imd.balanceOf(DEAD), deadBefore);
                assertLt(imd6900.totalSupply(), supplyBefore, "the IMD6900 buy was never skipped");
            }
        }
        assertGt(burned, 0);
    }

    /// @dev The burner on an IMD6900 whose burn costs ~800k gas, with POOL4 and its pair pool filled.
    function _heavyBurner() internal returns (LARPBurner heavy, HeavyIMD6900 token) {
        token = new HeavyIMD6900();
        heavy = _burnerOn(token);
    }

    /// @dev A burner on another IMD6900, with POOL4 and that token's pair pool filled.
    function _burnerOn(MockIMD6900 token) internal returns (LARPBurner b) {
        bool imdIs0 = address(imd) < address(token);
        V4PoolKey memory heavyPair = imdIs0
            ? V4PoolKey(Currency.wrap(address(imd)), Currency.wrap(address(token)), 0, 60, IHooks(address(0)))
            : V4PoolKey(Currency.wrap(address(token)), Currency.wrap(address(imd)), 0, 60, IHooks(address(0)));
        pm.initialize(heavyPair, TickMath.getSqrtPriceAtTick(imdIs0 ? int24(92_100) : int24(-92_100)));
        token.mint(address(this), 1e33);
        token.approve(address(adder), type(uint256).max);
        adder.add(heavyPair, 1e23);
        _fillPool4();
        b = new LARPBurner(
            address(pm), address(imd), 10_000, 60, address(0), 10_000, 200, address(token), 0, 60, address(0)
        );
    }

    /// @dev The audited window (an IMD6900 leg of ~800k gas, a 1M gas limit) used to go through with the buy skipped.
    /// Now a call that can't fund a leg's budget is refused before the leg runs: at 1M before POOL4, at 3.2M (enough
    /// for POOL4's leg, not for the IMD6900 leg after it) with the ETH handed back. With enough gas it buys and burns.
    function test_AnIMD6900LegOutOfGasDeepDownReverts() public {
        (LARPBurner heavy, HeavyIMD6900 token) = _heavyBurner();
        uint256 supplyBefore = token.totalSupply();
        (bool ok, bytes memory err) =
            address(heavy).call{value: 0.001 ether, gas: 1_000_000}(abi.encodeCall(heavy.burn, (0)));
        assertFalse(ok, "the starved call went through");
        assertEq(bytes4(err), LARPBurner.TooLittleGas.selector);
        (ok, err) = address(heavy).call{value: 0.001 ether, gas: 3_200_000}(abi.encodeCall(heavy.burn, (0)));
        assertFalse(ok, "POOL4's leg funded but not the IMD6900 leg: the whole call is refused");
        assertEq(bytes4(err), LARPBurner.TooLittleGas.selector);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(address(heavy).balance, 0, "the ETH came back with the revert");
        assertEq(imd.balanceOf(DEAD), 0, "nothing went to DEAD");
        // with enough gas the same call buys and burns IMD6900
        heavy.burn{value: 0.001 ether, gas: 5_000_000}(0);
        assertLt(token.totalSupply(), supplyBefore);
        assertGt(imd.balanceOf(DEAD), 0);
    }

    /// @dev Across gas limits from 2.5M to 5M (the legs' budgets are funded from ~3.35M), a burn against a heavy
    /// IMD6900 leg either buys and burns IMD6900 or is refused: no limit skips the leg.
    function test_NoGasLimitSkipsAHeavyIMD6900Leg() public {
        (LARPBurner heavy, HeavyIMD6900 token) = _heavyBurner();
        uint256 burned;
        uint256 refused;
        for (uint256 gas = 2_500_000; gas <= 5_000_000; gas += 50_000) {
            uint256 supplyBefore = token.totalSupply();
            uint256 deadBefore = imd.balanceOf(DEAD);
            (bool ok, bytes memory err) =
                address(heavy).call{value: 0.001 ether, gas: gas}(abi.encodeCall(heavy.burn, (0)));
            if (ok) {
                ++burned;
                assertGt(imd.balanceOf(DEAD), deadBefore);
                assertLt(token.totalSupply(), supplyBefore, "the IMD6900 buy was skipped");
            } else {
                ++refused;
                assertEq(bytes4(err), LARPBurner.TooLittleGas.selector, "a starved burn reverts with TooLittleGas");
                assertEq(imd.balanceOf(DEAD), deadBefore, "a refused burn moves nothing");
            }
        }
        assertGt(burned, 0, "the sweep reached a gas limit that works");
        assertGt(refused, 0, "the sweep covered the starved window");
    }

    /// @dev A genuine revert of the IMD6900 leg (an empty pair pool: the swap walks the whole tick range and fills
    /// nothing, ~340k gas of work before `Unfilled`) is skipped once the leg's budget is funded: the share goes to
    /// DEAD and the call goes through. A call that can't fund the budget is refused, never left to the leg's gas.
    function test_AGenuineFailureIsNotMistakenForTooLittleGas() public {
        _fillPool4(); // no pair liquidity
        uint256 deadBefore = imd.balanceOf(DEAD);
        (bool ok,) = address(burner).call{value: 0.001 ether, gas: 5_000_000}(abi.encodeCall(burner.burn, (0)));
        assertTrue(ok, "a failed leg that reverted for a real reason is skipped, not refused");
        assertGt(imd.balanceOf(DEAD), deadBefore);
        assertEq(imd.balanceOf(address(burner)), 0);
        bytes memory err;
        (ok, err) = address(burner).call{value: 0.001 ether, gas: 300_000}(abi.encodeCall(burner.burn, (0)));
        assertFalse(ok);
        assertEq(bytes4(err), LARPBurner.TooLittleGas.selector, "the budget isn't funded: refused, nothing skipped");
    }

    /// @dev An IMD6900 whose `burn` eats every unit of gas (the real one is a proxy: one upgrade away) can't halt the
    /// burner: the leg spends its budget and is skipped, the share burns as $IMD at DEAD, and every paid entry point
    /// (register, link, foundCrew and their $IMD twins all end in `burn` or `burnImd`) keeps working.
    function test_AGasEatingIMD6900IsSkippedNotFatal() public {
        LARPBurner b = _burnerOn(new GasHogIMD6900());
        (bool ok, bytes memory err) = address(b).call{value: 0.0069 ether, gas: 30_000_000}(abi.encodeCall(b.burn, (0)));
        assertTrue(ok, string.concat("burn reverted: ", vm.toString(err)));
        assertGt(imd.balanceOf(DEAD), 0, "all the $IMD burned at DEAD");
        assertEq(address(b).balance, 0, "the ETH was spent");

        uint256 dead = imd.balanceOf(DEAD);
        imd.mint(address(b), 10 ether);
        vm.expectEmit(true, true, true, false, address(b));
        emit Burned(10 ether, 0, 0);
        (ok, err) = address(b).call{gas: 30_000_000}(abi.encodeCall(b.burnImd, ()));
        assertTrue(ok, string.concat("burnImd reverted: ", vm.toString(err)));
        assertEq(imd.balanceOf(DEAD), dead + 10 ether);

        // a caller still can't starve the leg: too little to fund its budget is refused, not skipped
        imd.mint(address(b), 10 ether);
        (ok, err) = address(b).call{gas: 1_000_000}(abi.encodeCall(b.burnImd, ()));
        assertFalse(ok);
        assertEq(bytes4(err), LARPBurner.TooLittleGas.selector);
    }

    /// @dev A POOL4 hook that eats all its gas (IMD's treasury owns it): route 0 spends its budget and the fee falls
    /// to the hookless pool, as AUDIT.md's trust table says; a caller who can't fund the budget is refused.
    function test_AGasEatingPool4HookFallsToTheHooklessPool() public {
        // a hook address needs a permission flag: BEFORE_SWAP (bit 7)
        address hog = address(uint160((1 << 159) | 0x80));
        vm.etch(hog, address(new GasHogHook()).code);
        V4PoolKey memory hooked =
            V4PoolKey(Currency.wrap(address(0)), Currency.wrap(address(imd)), 10_000, 60, IHooks(hog));
        pm.initialize(hooked, TickMath.getSqrtPriceAtTick(76_020));
        adder.add{value: 1_000 ether}(hooked, 1e21);
        _fillBackup();
        LARPBurner b = new LARPBurner(
            address(pm), address(imd), 10_000, 60, hog, 10_000, 200, address(imd6900), 0, 60, address(0)
        );
        vm.expectEmit(true, false, true, false, address(b));
        emit Bought(0.05 ether, 0, 1);
        (bool ok, bytes memory err) = address(b).call{value: 0.05 ether, gas: 10_000_000}(abi.encodeCall(b.burn, (0)));
        assertTrue(ok, string.concat("burn reverted: ", vm.toString(err)));
        assertEq(address(b).balance, 0);
        (ok, err) = address(b).call{value: 0.05 ether, gas: 1_000_000}(abi.encodeCall(b.burn, (0)));
        assertFalse(ok);
        assertEq(bytes4(err), LARPBurner.TooLittleGas.selector);
    }

    function test_NoReentry() public {
        ReenteringPoolManager evil = new ReenteringPoolManager();
        LARPBurner b = _newBurner(address(evil));
        evil.aim(b);
        b.burn{value: 0.01 ether}(0);
        assertEq(bytes4(evil.lastError()), LARPBurner.Reentered.selector);
    }
}
