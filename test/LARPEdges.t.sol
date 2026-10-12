// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LARP} from "../src/LARP.sol";
import {ILARP} from "../src/ILARP.sol";
import {MockNFT} from "./Mocks.sol";
import {Mock1155} from "./Base.sol";

/// @dev An ERC-1271 wallet that approves nothing.
contract RefusingWallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}

/// @dev An ERC-1271 wallet whose answer is too short to be one.
contract MumblingWallet {
    fallback() external {
        assembly {
            mstore(0, 0x1626ba7e)
            return(0, 4)
        }
    }
}

/// @dev The registry at its edges: constants, the domain, agents of nothing, reads of empty spots, the slot encoding
/// for very large identity ids, and who may take what off.
contract LARPEdgesTest is Test {
    MockNFT identity;
    MockNFT masks;
    Mock1155 potions;
    LARP larp;

    uint256 ownerKey = 0xA11CE5;
    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address agent = makeAddr("agent");

    function setUp() public {
        identity = new MockNFT("identity://");
        masks = new MockNFT("mask://");
        potions = new Mock1155();
        larp = new LARP(address(identity));
        owner = vm.addr(ownerKey);
        identity.mint(owner, 7);
        identity.mint(owner, 8);
        identity.mint(alice, 0);
        identity.mint(bob, 2);
        masks.mint(alice, 1);
        masks.mint(owner, 2);
        potions.mint(alice, 5, 2);
    }

    function _sign(uint256 key, uint256 imdId, address who, address holder, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("SetAgent(uint256 imdId,address agent,address holder,uint256 nonce,uint256 deadline)"),
                imdId,
                who,
                holder,
                nonce,
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(key, keccak256(abi.encodePacked("\x19\x01", larp.DOMAIN_SEPARATOR(), structHash)));
        return abi.encodePacked(r, s, v);
    }

    // --- constants and the domain ---

    function test_ConstantsAndDomain() public {
        assertEq(larp.IDENTITY(), address(identity));
        assertEq(larp.SLOTS(), 8);
        assertEq(larp.nonces(owner), 0);
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LARP"),
                keccak256("1"),
                block.chainid,
                address(larp)
            )
        );
        assertEq(larp.DOMAIN_SEPARATOR(), expected);
        vm.chainId(1);
        assertTrue(larp.DOMAIN_SEPARATOR() != expected, "bound to the chain");
        LARP other = new LARP(address(identity));
        assertTrue(other.DOMAIN_SEPARATOR() != larp.DOMAIN_SEPARATOR(), "bound to the contract");
    }

    function test_ASignatureFromAnotherChainIsRefused() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sign(ownerKey, 7, agent, owner, 0, deadline);
        vm.chainId(1);
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, sig);
    }

    // --- agents of nothing ---

    function test_AgentsOfNothing() public {
        (address a, bool live) = larp.agentOf(7);
        assertEq(a, address(0));
        assertFalse(live);
        (uint256 imdId, bool l) = larp.identityOfAgent(agent);
        assertEq(imdId, 0);
        assertFalse(l);
        (bool ok, address holder) = larp.canAct(99, alice);
        assertFalse(ok);
        assertEq(holder, address(0), "no such identity");
        (ok, holder) = larp.canAct(7, address(0));
        assertFalse(ok, "address(0) acts for nobody");
        assertEq(holder, owner);
        vm.prank(agent);
        vm.expectRevert(ILARP.NotTheAgent.selector);
        larp.resignAgent(7);
        vm.expectRevert(ILARP.NoSuchIdentity.selector);
        larp.setAgentBySig(99, agent, block.timestamp + 1, hex"");
        vm.prank(alice);
        vm.expectRevert(ILARP.NotYourIdentity.selector);
        larp.setAgent(99, agent);
    }

    function test_RemovingAnAgentBumpsTheNonce() public {
        vm.prank(owner);
        larp.setAgent(7, agent);
        assertEq(larp.nonces(owner), 1);
        vm.prank(owner);
        larp.setAgent(7, address(0));
        assertEq(larp.nonces(owner), 2);
        (address a, bool live) = larp.agentOf(7);
        assertEq(a, address(0));
        assertFalse(live);
        (uint256 imdId, bool l) = larp.identityOfAgent(agent);
        assertEq(imdId, 7, "the last identity it was named for is remembered");
        assertFalse(l);
        // a signature can remove too
        vm.prank(owner);
        larp.setAgent(7, agent);
        bytes memory sig = _sign(ownerKey, 7, address(0), owner, 3, block.timestamp + 1);
        larp.setAgentBySig(7, address(0), block.timestamp + 1, sig);
        (a,) = larp.agentOf(7);
        assertEq(a, address(0));
        assertEq(larp.nonces(owner), 4);
    }

    function test_OneAgentForTwoIdentities() public {
        vm.startPrank(owner);
        larp.setAgent(7, agent);
        larp.setAgent(8, agent);
        vm.stopPrank();
        (bool ok,) = larp.canAct(7, agent);
        assertTrue(ok);
        (ok,) = larp.canAct(8, agent);
        assertTrue(ok);
        (uint256 imdId, bool live) = larp.identityOfAgent(agent);
        assertEq(imdId, 8, "the reverse record is the last one");
        assertTrue(live);
        vm.prank(agent);
        larp.resignAgent(8);
        (imdId, live) = larp.identityOfAgent(agent);
        assertEq(imdId, 8);
        assertFalse(live, "resigned there, though still identity 7's agent");
        (ok,) = larp.canAct(7, agent);
        assertTrue(ok);
    }

    function test_ResigningDoesNotBumpTheNonce() public {
        // I-02: an unused signature before its deadline still works after a resignation
        vm.prank(owner);
        larp.setAgent(7, agent);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sign(ownerKey, 7, agent, owner, 1, deadline);
        vm.prank(agent);
        larp.resignAgent(7);
        assertEq(larp.nonces(owner), 1);
        larp.setAgentBySig(7, agent, deadline, sig);
        (, bool live) = larp.agentOf(7);
        assertTrue(live, "the owner's standing signature brought the agent back");
    }

    function test_ContractWalletsThatRefuseOrMumble() public {
        RefusingWallet refusing = new RefusingWallet();
        identity.mint(address(refusing), 20);
        bytes memory sig = _sign(ownerKey, 20, agent, address(refusing), 0, block.timestamp + 1);
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(20, agent, block.timestamp + 1, sig);
        MumblingWallet mumbling = new MumblingWallet();
        identity.mint(address(mumbling), 21);
        sig = _sign(ownerKey, 21, agent, address(mumbling), 0, block.timestamp + 1);
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(21, agent, block.timestamp + 1, sig);
    }

    function test_OddSignatureBytes() public {
        uint256 deadline = block.timestamp + 1;
        (, bytes32 r, bytes32 s) = vm.sign(
            ownerKey,
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    larp.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            keccak256(
                                "SetAgent(uint256 imdId,address agent,address holder,uint256 nonce,uint256 deadline)"
                            ),
                            uint256(7),
                            agent,
                            owner,
                            uint256(0),
                            deadline
                        )
                    )
                )
            )
        );
        // v as 0 or 1 (the raw recovery id) is refused; so is a 64-byte compact signature
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, abi.encodePacked(r, s, uint8(0)));
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, abi.encodePacked(r, s));
        vm.expectRevert(ILARP.BadSignature.selector);
        larp.setAgentBySig(7, agent, deadline, abi.encodePacked(r, s, uint8(27), uint8(0)));
        // the deadline is inclusive
        bytes memory sig = _sign(ownerKey, 7, agent, owner, 0, block.timestamp);
        larp.setAgentBySig(7, agent, block.timestamp, sig);
        (, bool live) = larp.agentOf(7);
        assertTrue(live);
    }

    // --- reading what isn't there ---

    function test_EmptySpots() public {
        (address holder, address collection, uint256 tokenId, bool live) = larp.faceOf(0);
        assertEq(holder, address(0));
        assertEq(collection, address(0));
        assertEq(tokenId, 0);
        assertFalse(live);
        (holder, collection, tokenId,, live) = larp.itemOf(0, 8);
        assertEq(holder, address(0));
        assertFalse(live);
        assertEq(larp.avatarOf(0), "");
        assertEq(larp.faceURI(0), "identity://0", "the identity's own art");
        assertEq(larp.faceURI(99), identity.tokenURI(99), "no face: whatever the identity collection answers");
        assertEq(larp.itemURI(0, 1), "");
        vm.expectRevert(ILARP.BadSlot.selector);
        larp.itemURI(0, 0);
        vm.expectRevert(ILARP.BadSlot.selector);
        larp.itemURI(0, 9);
        (uint256 imdId, uint256 slot, bool worn) = larp.wearerOf(address(masks), 1);
        assertEq(imdId + slot, 0);
        assertFalse(worn);
    }

    function test_TakingOffAnEmptySlotIsSilent() public {
        vm.recordLogs();
        vm.prank(bob); // not even the owner: there is nothing to refuse
        larp.unequip(0, 3);
        vm.prank(bob);
        larp.clearFace(0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_ThePlacerTakesOffWhatItPlacedAfterSellingTheIdentity() public {
        vm.prank(alice);
        larp.equip(0, 1, address(potions), 5, ILARP.Kind.ERC1155);
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        vm.prank(alice); // no longer the owner, still the placer
        larp.unequip(0, 1);
        (address holder,,,,) = larp.itemOf(0, 1);
        assertEq(holder, address(0));
        // a stranger can't
        vm.prank(bob);
        identity.transferFrom(bob, alice, 0);
        vm.prank(alice);
        larp.equip(0, 1, address(potions), 5, ILARP.Kind.ERC1155);
        vm.prank(bob);
        vm.expectRevert(ILARP.NotYourPlacement.selector);
        larp.unequip(0, 1);
    }

    function test_AnAgentTakesOffThePreviousOwnersItems() public {
        vm.prank(alice);
        larp.equip(0, 1, address(potions), 5, ILARP.Kind.ERC1155);
        vm.prank(alice);
        identity.transferFrom(alice, owner, 0);
        vm.prank(owner);
        larp.setAgent(0, agent);
        vm.prank(agent);
        larp.unequip(0, 1);
        (address holder,,,,) = larp.itemOf(0, 1);
        assertEq(holder, address(0));
    }

    function test_ACopyPlacedTwiceIsCountedTwice() public {
        vm.startPrank(alice);
        larp.equip(0, 1, address(potions), 5, ILARP.Kind.ERC1155);
        larp.equip(0, 2, address(potions), 5, ILARP.Kind.ERC1155);
        vm.expectRevert(ILARP.NotYours.selector);
        larp.equip(0, 3, address(potions), 5, ILARP.Kind.ERC1155); // two copies, two slots: no third
        vm.stopPrank();
        (,,,, bool live) = larp.itemOf(0, 1);
        assertTrue(live);
        (,,,, live) = larp.itemOf(0, 2);
        assertTrue(live);
    }

    /// @dev The ERC-721 index packs 1 + imdId * 16 + slot: large ids round-trip, and slots never collide.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_WearerOfRoundTripsForAnyIdentityId(uint256 imdId, uint8 slot) public {
        imdId = bound(imdId, 0, type(uint256).max / 16 - 1);
        slot = uint8(bound(slot, 0, 8));
        identity.mint(alice, imdId);
        if (slot == 0) {
            vm.prank(alice);
            larp.setFace(imdId, address(masks), 1);
        } else {
            vm.prank(alice);
            larp.equip(imdId, slot, address(masks), 1, ILARP.Kind.ERC721);
        }
        (uint256 i, uint256 s, bool live) = larp.wearerOf(address(masks), 1);
        assertEq(i, imdId);
        assertEq(s, slot);
        assertTrue(live);
    }

    function test_SupportsInterfaceIsPure() public view {
        assertTrue(larp.supportsInterface(type(ILARP).interfaceId));
        assertFalse(larp.supportsInterface(0x2a55205a), "no royalties: it holds nothing");
    }
}
