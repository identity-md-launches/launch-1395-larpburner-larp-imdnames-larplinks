// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base, MockIMD, MockDistributor} from "./Base.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {ILARP} from "../src/ILARP.sol";
import {IIMDNames} from "../src/IIMDNames.sol";
import {MockNFT} from "./Mocks.sol";

/// @dev LARP links at its edges: the constructor, every default, each refusal of the crew and fren writes, the jeet
/// board's unreadable inputs, and its arithmetic fuzzed.
contract LARPLinksEdgesTest is Base {
    event FrenAskCleared(uint256 indexed from, uint256 indexed to);
    event CrewInvited(uint256 indexed crewId, uint256 indexed imdId, bool invited);

    uint256 constant CREW = 0.00069 ether;

    function setUp() public {
        _deploy();
        _fillPool4();
        identity.mint(alice, 0);
        identity.mint(alice, 1);
        identity.mint(bob, 2);
        identity.mint(carol, 3);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(carol, 10 ether);
    }

    function _found(address who, uint256 captain, string memory name, bool open) internal returns (uint256) {
        vm.prank(who);
        return links.foundCrew{value: CREW}(captain, _label(name), open, 0);
    }

    // --- the constructor and defaults ---

    function test_ConstructorRefusesZeroAddresses() public {
        vm.expectRevert(LARPLinks.ZeroAddress.selector);
        new LARPLinks(address(0), address(launcher), larp, names, address(burner));
        vm.expectRevert(LARPLinks.ZeroAddress.selector);
        new LARPLinks(address(identity), address(0), larp, names, address(burner));
        vm.expectRevert(LARPLinks.ZeroAddress.selector);
        new LARPLinks(address(identity), address(launcher), ILARP(address(0)), names, address(burner));
        vm.expectRevert(LARPLinks.ZeroAddress.selector);
        new LARPLinks(address(identity), address(launcher), larp, IIMDNames(address(0)), address(burner));
        vm.expectRevert(LARPLinks.ZeroAddress.selector);
        new LARPLinks(address(identity), address(launcher), larp, names, address(0));
    }

    function test_Defaults() public view {
        assertEq(links.IDENTITY(), address(identity));
        assertEq(links.LAUNCHER(), address(launcher));
        assertEq(address(links.LARP()), address(larp));
        assertEq(address(links.NAMES()), address(names));
        assertEq(links.BURNER(), address(burner));
        assertEq(links.crewCount(), 0);
        assertEq(links.crewOf(0), 0);
        assertEq(links.crewByName(_label("crew")), 0);
        (uint256 captain, bytes32 name, uint256 members, bool open, bool alive) = links.crew(0);
        assertEq(captain, 0);
        assertEq(name, 0);
        assertEq(members, 0);
        assertFalse(open);
        assertFalse(alive);
        assertFalse(links.isFren(0, 2));
        assertFalse(links.asked(0, 2));
        assertEq(links.frenCount(0), 0);
        assertFalse(links.invited(1, 0));
        assertEq(links.allocOf(alice, address(launcher), 0), 0);
        assertEq(links.launchCount(alice), 0);
        (uint256 level, uint256 points) = links.jeetOf(alice);
        assertEq(level, 0);
        assertEq(points, 0);
        assertEq(links.jeetOfRange(alice, 0, 10), 0);
        assertEq(links.titleOf(6), "Lurker");
        assertEq(links.titleOf(255), "Lurker");
    }

    function test_AnIdentityNobodyHolds() public view {
        (address holder, uint256 level, uint256 points, uint8 tier) = links.rankOf(99);
        assertEq(holder, address(0));
        assertEq(level + points + tier, 0);
        LARPLinks.Card memory c = links.cardOf(99);
        assertEq(c.holder, address(0));
        assertEq(c.name, "");
        assertEq(c.title, "Lurker");
        assertEq(c.crewId, 0);
        assertEq(c.frens, 0);
    }

    function test_ACardWithALiveFace() public {
        MockNFT masks = new MockNFT("mask://");
        masks.mint(alice, 7);
        vm.prank(alice);
        larp.setFace(0, address(masks), 7);
        LARPLinks.Card memory c = links.cardOf(0);
        assertEq(c.faceCollection, address(masks));
        assertEq(c.faceTokenId, 7);
        assertTrue(c.faceLive);
        assertFalse(c.captain);
        // sold: the card is the new holder's, the face is dark
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        c = links.cardOf(0);
        assertEq(c.holder, bob);
        assertFalse(c.faceLive);
    }

    // --- frens ---

    function test_UnfrenWithNothingDoesNothing() public {
        vm.recordLogs();
        vm.prank(alice);
        links.unfren(0, 2);
        assertEq(vm.getRecordedLogs().length, 0);
        vm.prank(bob);
        vm.expectRevert(LARPLinks.NotYourIdentity.selector);
        links.unfren(0, 2);
    }

    function test_UnfrenClearsBothAsksAtOnce() public {
        vm.prank(alice);
        links.fren(0, 2);
        vm.prank(bob);
        links.fren(2, 0); // frens now
        vm.prank(bob);
        links.fren(2, 1); // and bob asks alice's other identity
        vm.prank(alice);
        links.unfren(1, 2); // alice turns it down from identity 1
        assertFalse(links.asked(2, 1));
        assertTrue(links.isFren(0, 2), "identity 0's friendship is separate");
        vm.prank(alice);
        links.unfren(0, 2);
        assertFalse(links.isFren(2, 0));
        assertEq(links.frenCount(2), 0);
    }

    function test_AnAskSurvivesASaleOfEitherIdentity() public {
        vm.prank(alice);
        links.fren(0, 2);
        vm.prank(bob);
        identity.transferFrom(bob, carol, 2);
        vm.prank(carol);
        links.fren(2, 0); // the new holder of 2 says yes
        assertTrue(links.isFren(0, 2));
    }

    // --- crews: the refusals ---

    function test_InviteRules() public {
        uint256 id = _found(alice, 0, "crew", false);
        vm.prank(alice);
        vm.expectRevert(LARPLinks.NoSuchIdentity.selector);
        links.invite(id, 99, true);
        vm.prank(bob);
        vm.expectRevert(LARPLinks.NotCaptain.selector);
        links.invite(id, 2, true);
        vm.prank(alice);
        vm.expectRevert(LARPLinks.NoSuchCrew.selector);
        links.invite(id + 1, 2, true);
        // invited, then uninvited: can't join
        vm.prank(alice);
        links.invite(id, 2, true);
        vm.expectEmit(address(links));
        emit CrewInvited(id, 2, false);
        vm.prank(alice);
        links.invite(id, 2, false);
        vm.prank(bob);
        vm.expectRevert(LARPLinks.NotInvited.selector);
        links.join(2, id);
    }

    function test_JoinLeaveRules() public {
        vm.prank(bob);
        vm.expectRevert(LARPLinks.NoSuchCrew.selector);
        links.join(2, 0);
        vm.prank(bob);
        vm.expectRevert(LARPLinks.NoSuchCrew.selector);
        links.join(2, 7);
        vm.prank(bob);
        vm.expectRevert(LARPLinks.NotInCrew.selector);
        links.leave(2);
        uint256 id = _found(alice, 0, "crew", true);
        vm.prank(carol);
        vm.expectRevert(LARPLinks.NotYourIdentity.selector);
        links.join(2, id); // bob's identity
        vm.prank(alice);
        vm.expectRevert(LARPLinks.InACrew.selector);
        links.join(0, id); // the captain is already in
        // a closed crew's invitation outlives being kicked? no: joining consumed it
        vm.prank(alice);
        links.setOpen(id, false);
        vm.prank(alice);
        links.invite(id, 2, true);
        vm.prank(bob);
        links.join(2, id);
        vm.prank(alice);
        links.kick(id, 2);
        vm.prank(bob);
        vm.expectRevert(LARPLinks.NotInvited.selector);
        links.join(2, id);
    }

    function test_CaptainRules() public {
        uint256 id = _found(alice, 0, "crew", true);
        vm.prank(bob);
        links.join(2, id);
        vm.startPrank(bob);
        vm.expectRevert(LARPLinks.NotCaptain.selector);
        links.passCaptain(id, 2);
        vm.expectRevert(LARPLinks.NotCaptain.selector);
        links.disband(id);
        vm.expectRevert(LARPLinks.NotCaptain.selector);
        links.invite(id, 3, true);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(LARPLinks.CaptainStays.selector);
        links.kick(id, 0);
        // passing to oneself changes nothing
        vm.prank(alice);
        links.passCaptain(id, 0);
        (uint256 captain,, uint256 members,,) = links.crew(id);
        assertEq(captain, 0);
        assertEq(members, 2);
    }

    function test_ADisbandedCrewIsGone() public {
        uint256 id = _found(alice, 0, "crew", true);
        vm.prank(bob);
        links.join(2, id);
        vm.prank(alice);
        links.disband(id);
        vm.startPrank(alice);
        vm.expectRevert(LARPLinks.NoSuchCrew.selector);
        links.disband(id);
        vm.expectRevert(LARPLinks.NoSuchCrew.selector);
        links.setOpen(id, true);
        vm.expectRevert(LARPLinks.NoSuchCrew.selector);
        links.kick(id, 2);
        vm.expectRevert(LARPLinks.NoSuchCrew.selector);
        links.passCaptain(id, 2);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(LARPLinks.NotInCrew.selector);
        links.leave(2);
        (uint256 captain, bytes32 name, uint256 members, bool open, bool alive) = links.crew(id);
        assertEq(captain, 0, "the record stays readable");
        assertEq(name, _label("crew"));
        assertEq(members, 0);
        assertTrue(open);
        assertFalse(alive);
        assertEq(links.crewCount(), 1, "ids are never reused");
        LARPLinks.Card memory c = links.cardOf(2);
        assertEq(c.crewId, 0);
    }

    function test_MembersCountFollowsEveryMove() public {
        uint256 id = _found(alice, 0, "crew", true);
        vm.prank(bob);
        links.join(2, id);
        vm.prank(carol);
        links.join(3, id);
        vm.prank(alice);
        links.join(1, id);
        (,, uint256 members,,) = links.crew(id);
        assertEq(members, 4);
        vm.prank(bob);
        links.leave(2);
        vm.prank(alice);
        links.kick(id, 3);
        vm.prank(alice);
        links.passCaptain(id, 1);
        vm.prank(alice);
        links.leave(0);
        (uint256 captain,, uint256 left,,) = links.crew(id);
        assertEq(captain, 1);
        assertEq(left, 1);
    }

    function test_CrewNamesAtTheEdges() public {
        _found(alice, 0, "0123456789abcdefghijklmnopqrstuv", true);
        _found(bob, 2, "x", true);
        vm.prank(carol);
        vm.expectRevert(LARPLinks.BadName.selector);
        links.foundCrew{value: CREW}(3, bytes32(0), true, 0);
        vm.prank(carol);
        vm.expectRevert(LARPLinks.BadName.selector);
        links.foundCrew{value: CREW}(3, _label("x-"), true, 0);
    }

    function test_FoundCrewWithImdRefusals() public {
        imd.mint(alice, 1_000 ether);
        vm.prank(alice);
        vm.expectRevert(LARPBurner.NoPrice.selector); // only POOL4 is live
        links.foundCrewWithImd(0, _label("crew"), true, 1_000 ether);
        _fillBackup();
        vm.prank(alice);
        vm.expectRevert(LARPLinks.WrongPrice.selector); // no allowance
        links.foundCrewWithImd(0, _label("crew"), true, 1_000 ether);
        assertEq(links.crewCount(), 0, "nothing was founded");
        vm.prank(alice);
        imd.approve(address(links), type(uint256).max);
        vm.prank(alice);
        links.foundCrewWithImd(0, _label("crew"), true, 1_000 ether);
        assertEq(links.crewOf(0), 1);
        assertEq(imd.balanceOf(address(links)), 0);
    }

    function test_FoundCrewWithTheWrongValue() public {
        vm.prank(alice);
        vm.expectRevert(LARPLinks.WrongPrice.selector);
        links.foundCrew{value: CREW - 1}(0, _label("crew"), true, 0);
        vm.prank(alice);
        vm.expectRevert(LARPLinks.WrongPrice.selector);
        links.foundCrew{value: CREW + 1}(0, _label("crew"), true, 0);
        vm.prank(alice);
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        links.foundCrew{value: CREW}(0, _label("crew"), true, 1_000_000 ether);
    }

    // --- the jeet board: the edges ---

    function _leaf(address wallet, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(wallet, amount))));
    }

    /// @dev A launch whose round `round` allots exactly one wallet (the root is the leaf; the proof is empty).
    function _soloLaunch(uint64 number, uint256 round, address wallet, uint256 amount)
        internal
        returns (MockIMD token, MockDistributor d)
    {
        token = new MockIMD();
        d = new MockDistributor(address(token));
        d.setRoot(round, _leaf(wallet, amount));
        launcher.set(number, address(d));
    }

    function test_AnEmptyProofForASoloRound() public {
        (, MockDistributor d) = _soloLaunch(1, 0, alice, 5e18);
        links.proveAlloc(1, 0, alice, 5e18, new bytes32[](0));
        assertEq(links.allocOf(alice, address(d), 0), 5e18);
    }

    function test_AllocationBounds() public {
        _soloLaunch(1, 0, alice, uint256(type(uint128).max) + 1);
        vm.expectRevert(LARPLinks.BadAlloc.selector);
        links.proveAlloc(1, 0, alice, uint256(type(uint128).max) + 1, new bytes32[](0));
        _soloLaunch(2, 0, alice, type(uint128).max);
        links.proveAlloc(2, 0, alice, type(uint128).max, new bytes32[](0));
        assertEq(links.launchCount(alice), 1);
    }

    function test_ALauncherAnsweringGarbageIsUnknown() public {
        _soloLaunch(1, 0, alice, 5e18);
        // the launcher answers a word that is not an address
        vm.mockCall(
            address(launcher),
            abi.encodeWithSelector(0x6c637492, uint64(1)),
            abi.encode(uint256(1) << 200 | uint256(uint160(address(launcher))))
        );
        vm.expectRevert(LARPLinks.UnknownLaunch.selector);
        links.proveAlloc(1, 0, alice, 5e18, new bytes32[](0));
        vm.clearMockedCalls();
        // or nothing at all
        vm.etch(address(launcher), hex"fe");
        vm.expectRevert(LARPLinks.UnknownLaunch.selector);
        links.proveAlloc(1, 0, alice, 5e18, new bytes32[](0));
    }

    function test_ADistributorWithoutARootIsUnknown() public {
        (, MockDistributor d) = _soloLaunch(1, 0, alice, 5e18);
        vm.mockCall(address(d), abi.encodeWithSelector(0xc7c38091, uint256(0)), abi.encode(bytes32(0), 0, 0, 0));
        vm.expectRevert(LARPLinks.UnknownRound.selector);
        links.proveAlloc(1, 0, alice, 5e18, new bytes32[](0));
    }

    function test_TwoRoundsOfOneLaunchAreOneLevel() public {
        (MockIMD token, MockDistributor d) = _soloLaunch(1, 0, alice, 5e18);
        d.setRoot(1, _leaf(alice, 3e18));
        links.proveAlloc(1, 0, alice, 5e18, new bytes32[](0));
        links.proveAlloc(1, 1, alice, 3e18, new bytes32[](0));
        assertEq(links.launchCount(alice), 1);
        LARPLinks.LaunchJeet memory j = links.launchJeet(alice, 0);
        assertEq(j.allocated, 8e18);
        assertEq(j.claimed, 0);
        assertEq(j.token, address(0), "no token read until something is claimed");
        // only round 0 claimed and all sold: 5 of 8 jeeted
        d.claim(0, alice, 5e18);
        vm.prank(alice);
        token.transfer(address(0xdead), 5e18);
        j = links.launchJeet(alice, 0);
        assertEq(j.claimed, 5e18);
        assertEq(j.held, 0);
        assertEq(j.jeetBps, 6_250);
    }

    function test_ADistributorWithoutATokenCountsAsHeld() public {
        (MockIMD token, MockDistributor d) = _soloLaunch(1, 0, alice, 5e18);
        links.proveAlloc(1, 0, alice, 5e18, new bytes32[](0));
        d.claim(0, alice, 5e18);
        vm.prank(alice);
        token.transfer(address(0xdead), 5e18);
        vm.mockCallRevert(address(d), abi.encodeWithSelector(0xfc0c546a), "no token");
        LARPLinks.LaunchJeet memory j = links.launchJeet(alice, 0);
        assertEq(j.token, address(0));
        assertEq(j.held, 5e18);
        assertEq(j.jeetBps, 0);
    }

    function test_LaunchJeetPastTheEndReverts() public {
        vm.expectRevert();
        links.launchJeet(alice, 0);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_JeetBpsIsTheSoldShareOfTheAllocation(uint128 allocated, uint256 kept, bool claimed) public {
        allocated = uint128(bound(allocated, 1, type(uint128).max));
        kept = bound(kept, 0, uint256(allocated) * 2);
        (MockIMD token, MockDistributor d) = _soloLaunch(1, 0, alice, allocated);
        links.proveAlloc(1, 0, alice, allocated, new bytes32[](0));
        if (claimed) {
            d.claim(0, alice, allocated);
            vm.prank(alice);
            token.transfer(address(0xdead), allocated);
            token.mint(alice, kept);
        }
        LARPLinks.LaunchJeet memory j = links.launchJeet(alice, 0);
        assertEq(j.allocated, allocated);
        assertEq(j.claimed, claimed ? allocated : 0);
        if (!claimed) {
            assertEq(j.held, 0);
            assertEq(j.jeetBps, 0, "never claimed is never jeeted");
            return;
        }
        uint256 held = kept < allocated ? kept : allocated;
        assertEq(j.held, held);
        assertEq(j.jeetBps, (uint256(allocated) - held) * 10_000 / allocated);
        assertLe(j.jeetBps, 10_000);
        (uint256 level, uint256 points) = links.jeetOf(alice);
        assertEq(level, 1);
        assertEq(points, j.jeetBps);
        (,,, uint8 tier) = links.rankOf(0);
        assertEq(tier, links.tierOf(1, points));
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_TiersAreMonotoneInJeetPoints(uint256 level, uint256 a, uint256 b) public view {
        level = bound(level, 1, 1_000);
        a = bound(a, 0, level * 10_000);
        b = bound(b, a, level * 10_000);
        uint8 ta = links.tierOf(level, a);
        uint8 tb = links.tierOf(level, b);
        assertLe(ta, tb, "more jeeted never ranks better");
        assertGe(ta, 1);
        assertLe(tb, 5);
        assertEq(links.tierOf(0, a), 0, "no launch proven: Lurker whatever the points");
    }
}
