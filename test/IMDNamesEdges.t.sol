// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {IIMDNames} from "../src/IIMDNames.sol";
import {ILARP} from "../src/ILARP.sol";
import {LARPBurner} from "../src/LARPBurner.sol";
import {SwarmPrices} from "../src/SwarmPrices.sol";

contract Receiver {
    bytes public lastData;

    function onERC721Received(address, address, uint256, bytes calldata data) external returns (bytes4) {
        lastData = data;
        return 0x150b7a02;
    }
}

contract NotAReceiver {}

contract EmptyRenderer {
    function render(uint256, string calldata, uint256) external pure returns (string memory) {
        return "";
    }
}

/// @dev IMD Names at its edges: the constructor, every constant, the whole ERC-721 surface a market uses, and the
/// refusals of each write.
contract IMDNamesEdgesTest is Base {
    uint256 kek;

    function setUp() public {
        _deploy();
        _fillPool4();
        identity.mint(alice, 0);
        identity.mint(alice, 1);
        identity.mint(bob, 2);
        kek = _register(alice, "kekmaster");
    }

    // --- the constructor and constants ---

    function test_ConstructorRefusesZeroAddresses() public {
        vm.expectRevert(IMDNames.ZeroAddress.selector);
        new IMDNames(address(0), larp, address(burner), artist, address(intake), oracleSigner);
        vm.expectRevert(IMDNames.ZeroAddress.selector);
        new IMDNames(address(identity), ILARP(address(0)), address(burner), artist, address(intake), oracleSigner);
        vm.expectRevert(IMDNames.ZeroAddress.selector);
        new IMDNames(address(identity), larp, address(0), artist, address(intake), oracleSigner);
        // the artist may be nobody: then the art is final from the start
        IMDNames noArtist =
            new IMDNames(address(identity), larp, address(burner), address(0), address(intake), oracleSigner);
        assertEq(noArtist.artist(), address(0));
        vm.prank(address(0));
        vm.expectRevert(IIMDNames.NotArtist.selector);
        noArtist.setRenderer(address(1));
    }

    function test_Constants() public view {
        assertEq(names.TLD(), ".imd");
        assertEq(names.ROYALTY_BPS(), 690);
        assertEq(names.ACTION(), bytes32("oracle.request@oracle-1"));
        assertEq(
            names.ACTION(), 0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000, "as IMD documents it"
        );
        assertEq(names.MIN_PRICE(), 0.00001 ether);
        assertEq(names.MAX_PRICE(), 1 ether);
        assertEq(names.COOLDOWN(), 7 days);
        assertEq(names.EXECUTE_WINDOW(), 14 days);
        assertEq(names.MIN_PANEL(), 9);
        assertEq(names.MIN_QUORUM(), 7);
        assertEq(names.INTAKE(), address(intake));
        assertEq(names.ORACLE_SIGNER(), oracleSigner);
        assertEq(names.IDENTITY(), address(identity));
        assertEq(address(names.LARP()), address(larp));
        assertEq(names.BURNER(), address(burner));
        assertEq(names.name(), "IMD Names");
        assertEq(names.symbol(), "IMDNAME");
        assertEq(names.renderer(), address(0));
        assertFalse(names.rendererLocked());
        assertEq(names.epoch(), 0);
        assertEq(names.lastChange(), 0);
        assertEq(names.proposalCount(), 0);
        assertFalse(names.supportsInterface(0xffffffff));
        assertTrue(names.supportsInterface(0x01ffc9a7));
    }

    // --- ERC-721: what markets call ---

    function test_ApprovalsAndOperatorTransfers() public {
        vm.prank(bob);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        names.approve(bob, kek);
        vm.prank(bob);
        vm.expectRevert(ERC721.NotOwnerNorApproved.selector);
        names.transferFrom(alice, bob, kek);

        vm.prank(alice);
        names.approve(bob, kek);
        assertEq(names.getApproved(kek), bob);
        vm.prank(bob);
        names.transferFrom(alice, carol, kek);
        assertEq(names.ownerOf(kek), carol);
        assertEq(names.getApproved(kek), address(0), "a transfer clears the approval");
        assertEq(names.balanceOf(alice), 0);
        assertEq(names.balanceOf(carol), 1);
        assertEq(names.tollOf(kek), 0.00069 ether, "a new owner owes the toll");

        vm.prank(carol);
        names.setApprovalForAll(bob, true);
        assertTrue(names.isApprovedForAll(carol, bob));
        vm.prank(bob);
        names.safeTransferFrom(carol, alice, kek);
        assertEq(names.ownerOf(kek), alice);
        assertEq(names.tollOf(kek), 0, "back with the one who paid");
        vm.prank(carol);
        names.setApprovalForAll(bob, false);
        assertFalse(names.isApprovedForAll(carol, bob));
    }

    function test_SafeTransfersCheckTheReceiver() public {
        Receiver good = new Receiver();
        NotAReceiver bad = new NotAReceiver();
        vm.prank(alice);
        vm.expectRevert(ERC721.TransferToNonERC721ReceiverImplementer.selector);
        names.safeTransferFrom(alice, address(bad), kek);
        vm.prank(alice);
        names.safeTransferFrom(alice, address(good), kek, hex"c0ffee");
        assertEq(names.ownerOf(kek), address(good));
        assertEq(good.lastData(), hex"c0ffee");
        // a plain transfer does not ask
        vm.prank(address(good));
        names.transferFrom(address(good), address(bad), kek);
        assertEq(names.ownerOf(kek), address(bad));
    }

    function test_TransferRules() public {
        vm.prank(alice);
        vm.expectRevert(ERC721.TransferFromIncorrectOwner.selector);
        names.transferFrom(bob, carol, kek);
        vm.prank(alice);
        vm.expectRevert(ERC721.TransferToZeroAddress.selector);
        names.transferFrom(alice, address(0), kek);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        names.ownerOf(uint256(_label("nothing")));
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        names.getApproved(uint256(_label("nothing")));
        vm.expectRevert(ERC721.BalanceQueryForZeroAddress.selector);
        names.balanceOf(address(0));
        vm.prank(alice);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        names.transferFrom(alice, bob, uint256(_label("nothing")));
    }

    function test_ASaleDarkensTheLinkAndTheTextStays() public {
        vm.prank(alice);
        names.link(kek, 0, 0);
        vm.prank(alice);
        names.setText(0, "url", "https://kek");
        vm.prank(alice);
        names.safeTransferFrom(alice, bob, kek);
        assertEq(names.nameOf(0), "", "the identity shows no name");
        assertEq(names.text(0, "url"), "https://kek", "texts belong to the identity's holder, not the name");
        (uint256 imdId, bool live) = names.identityOf(kek);
        assertEq(imdId, 0);
        assertFalse(live);
    }

    // --- registering: the edges ---

    function test_RegisterRefusesLessThanThePrice() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(IIMDNames.WrongPrice.selector);
        names.register{value: 0.00069 ether - 1}(_label("underpaid"), bob, 0);
        vm.prank(bob);
        vm.expectRevert(IIMDNames.WrongPrice.selector);
        names.register(_label("unpaid"), bob, 0);
    }

    function test_RegisterWithAFloorTheBurnCannotMeet() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(LARPBurner.TooLittleIMD.selector);
        names.register{value: 0.00069 ether}(_label("floored"), bob, 1_000_000 ether);
        (bool exists,,,) = names.resolve(_label("floored"));
        assertFalse(exists, "the whole registration reverted");
    }

    function test_TheLongestAndShortestNames() public {
        uint256 longest = _register(bob, "0123456789abcdefghijklmnopqrstuv");
        assertEq(names.nameOfToken(longest), "0123456789abcdefghijklmnopqrstuv.imd");
        uint256 shortest = _register(bob, "x");
        assertEq(names.nameOfToken(shortest), "x.imd");
        assertEq(names.tollOf(shortest), 0);
        (bool exists, address owner,,) = names.resolveName("x");
        assertTrue(exists);
        assertEq(owner, bob);
    }

    function test_RegisterWithImdNeedsAnAllowance() public {
        _fillBackup();
        imd.mint(carol, 1_000 ether);
        vm.prank(carol);
        vm.expectRevert(IIMDNames.WrongPrice.selector);
        names.registerWithImd(_label("no-allowance"), carol, 1_000 ether);
        vm.prank(carol);
        imd.approve(address(names), 1);
        vm.prank(carol);
        vm.expectRevert(IIMDNames.WrongPrice.selector);
        names.registerWithImd(_label("no-allowance"), carol, 1_000 ether);
    }

    function test_TheTollInImdRespectsMaxImd() public {
        _fillBackup();
        _fillPair();
        vm.prank(alice);
        names.transferFrom(alice, bob, kek);
        imd.mint(bob, 1_000 ether);
        vm.prank(bob);
        imd.approve(address(names), type(uint256).max);
        uint256 due = burner.quoteImd(names.tollOf(kek));
        vm.prank(bob);
        vm.expectRevert(IIMDNames.TooMuchImd.selector);
        names.linkWithImd(kek, 2, due - 1);
        vm.prank(bob);
        names.linkWithImd(kek, 2, due);
        assertEq(names.nameOf(2), "kekmaster.imd");
    }

    // --- links, primaries, texts: the refusals ---

    function test_UnlinkingNothingDoesNothing() public {
        vm.recordLogs();
        vm.prank(carol); // anyone, since there is nothing to unlink
        names.unlink(0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_AStrangerCannotUnlink() public {
        vm.prank(alice);
        names.link(kek, 0, 0);
        vm.prank(carol);
        vm.expectRevert(IIMDNames.NotYours.selector);
        names.unlink(0);
    }

    function test_AnAgentLinksUnlinksAndWrites() public {
        address agent = makeAddr("agent");
        vm.prank(alice);
        larp.setAgent(0, agent);
        vm.prank(agent);
        names.link(kek, 0, 0);
        assertEq(names.nameOf(0), "kekmaster.imd");
        vm.prank(agent);
        names.unlink(0);
        assertEq(names.nameOf(0), "");
        vm.prank(agent);
        names.setText(0, "x", "@agent");
        assertEq(names.text(0, "x"), "@agent");
        // the agent lapses with a sale and can do none of it
        vm.prank(alice);
        identity.transferFrom(alice, bob, 0);
        vm.prank(agent);
        vm.expectRevert(IIMDNames.NotYourIdentity.selector);
        names.setText(0, "x", "@agent");
    }

    function test_PrimaryAndTextRefusals() public {
        vm.prank(bob);
        vm.expectRevert(IIMDNames.NotYourIdentity.selector);
        names.setPrimary(0);
        vm.prank(bob);
        vm.expectRevert(IIMDNames.NotYourIdentity.selector);
        names.setText(0, "x", "@bob");
        vm.prank(bob);
        vm.expectRevert(IIMDNames.NotYourIdentity.selector);
        names.setPrimary(99); // no such identity
        assertEq(names.text(0, "x"), "");
        assertEq(names.text(99, "x"), "");
        (uint256 imdId, string memory full, bool live) = names.primaryOf(bob);
        assertEq(imdId, 0);
        assertEq(full, "");
        assertFalse(live);
    }

    function test_APrimaryWithoutANameIsLiveAndNameless() public {
        vm.prank(bob);
        names.setPrimary(2);
        (uint256 imdId, string memory full, bool live) = names.primaryOf(bob);
        assertEq(imdId, 2);
        assertEq(full, "");
        assertTrue(live);
        // a wallet's primary is the last it set
        identity.mint(bob, 3);
        vm.prank(bob);
        names.setPrimary(3);
        (imdId,,) = names.primaryOf(bob);
        assertEq(imdId, 3);
    }

    // --- reading what isn't there ---

    function test_ReadingNames() public {
        vm.expectRevert(IIMDNames.NoSuchName.selector);
        names.tollOf(uint256(_label("nothing")));
        (bool exists, address owner, uint256 imdId, bool linked) = names.resolve(_label("nothing"));
        assertFalse(exists);
        assertEq(owner, address(0));
        assertEq(imdId, 0);
        assertFalse(linked);
        (imdId, linked) = names.identityOf(kek);
        assertEq(imdId, 0);
        assertFalse(linked, "registered, not linked");
        assertEq(names.nameOf(0), "");
        assertEq(names.nameOf(99), "");
        assertEq(names.nameOfToken(uint256(_label("kekmaster"))), "kekmaster.imd");
    }

    function test_ResolveNameSpellings() public view {
        string[9] memory notFound = [
            "",
            ".imd",
            "Kekmaster.imd",
            "kekmaster.imd.imd",
            "kekmaster.eth",
            "kek master",
            "-kekmaster",
            "0123456789abcdefghijklmnopqrstuvw", // 33 characters
            "0123456789abcdefghijklmnopqrstuvw.imd"
        ];
        for (uint256 i; i < notFound.length; ++i) {
            (bool exists,,,) = names.resolveName(notFound[i]);
            assertFalse(exists, notFound[i]);
        }
        (bool found, address owner,,) = names.resolveName("kekmaster");
        assertTrue(found);
        assertEq(owner, alice);
        (found, owner,,) = names.resolveName("kekmaster.imd");
        assertTrue(found);
        (found,,,) = names.resolveName("kekmasters.imd");
        assertFalse(found);
    }

    function test_RoyaltyRounding() public view {
        (address to, uint256 amount) = names.royaltyInfo(kek, 0);
        assertEq(to, address(burner));
        assertEq(amount, 0);
        (, amount) = names.royaltyInfo(kek, 1);
        assertEq(amount, 0, "rounds down");
        (, amount) = names.royaltyInfo(kek, 10_000);
        assertEq(amount, 690);
        (, amount) = names.royaltyInfo(uint256(_label("nothing")), 1 ether);
        assertEq(amount, 0.069 ether, "ERC-2981 answers for any id");
    }

    // --- the art ---

    function test_TheCardOfAnUnlinkedName() public view {
        string memory uri = names.tokenURI(kek);
        string memory json = _decoded(uri);
        assertTrue(_contains(json, '"name":"kekmaster.imd"'));
        assertTrue(_contains(json, '"trait_type":"Length","value":9}'));
        assertFalse(_contains(json, "Identity"), "no identity trait while unlinked");
    }

    function test_ARendererThatAnswersNothingFallsBack() public {
        string memory card = names.tokenURI(kek);
        EmptyRenderer empty = new EmptyRenderer();
        vm.prank(artist);
        names.setRenderer(address(empty));
        assertEq(names.tokenURI(kek), card);
    }

    function test_TheArtistRenouncesAndTheArtIsFinal() public {
        vm.prank(bob);
        vm.expectRevert(IIMDNames.NotArtist.selector);
        names.setArtist(bob);
        vm.prank(bob);
        vm.expectRevert(IIMDNames.NotArtist.selector);
        names.lockRenderer();
        vm.prank(artist);
        names.setArtist(address(0));
        assertEq(names.artist(), address(0));
        vm.prank(artist);
        vm.expectRevert(IIMDNames.NotArtist.selector);
        names.setRenderer(address(1));
        vm.prank(artist);
        vm.expectRevert(IIMDNames.NotArtist.selector);
        names.lockRenderer();
    }

    function test_LockingIsIdempotentAndKeepsTheRenderer() public {
        EmptyRenderer empty = new EmptyRenderer();
        vm.startPrank(artist);
        names.setRenderer(address(empty));
        names.lockRenderer();
        names.lockRenderer();
        vm.expectRevert(IIMDNames.Locked.selector);
        names.setRenderer(address(0));
        vm.stopPrank();
        assertTrue(names.rendererLocked());
        assertTrue(names.renderer() != address(0));
    }

    // --- helpers ---

    function _decoded(string memory uri) internal pure returns (string memory) {
        bytes memory b = bytes(uri);
        bytes memory o = new bytes(b.length - 29);
        for (uint256 i; i < o.length; ++i) {
            o[i] = b[i + 29];
        }
        return string(_base64Decode(o));
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool m = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }

    function _base64Decode(bytes memory data) internal pure returns (bytes memory) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint8[128] memory rev;
        for (uint8 i; i < 64; ++i) {
            rev[uint8(table[i])] = i;
        }
        uint256 pad;
        if (data.length > 0 && data[data.length - 1] == "=") ++pad;
        if (data.length > 1 && data[data.length - 2] == "=") ++pad;
        bytes memory out = new bytes(data.length / 4 * 3 - pad);
        uint256 k;
        for (uint256 i; i < data.length; i += 4) {
            uint256 n = (uint256(rev[uint8(data[i])]) << 18) | (uint256(rev[uint8(data[i + 1])]) << 12)
                | (uint256(data[i + 2] == "=" ? 0 : rev[uint8(data[i + 2])]) << 6)
                | uint256(data[i + 3] == "=" ? 0 : rev[uint8(data[i + 3])]);
            for (uint256 j; j < 3 && k < out.length; ++j) {
                out[k++] = bytes1(uint8(n >> (16 - 8 * j)));
            }
        }
        return out;
    }
}
