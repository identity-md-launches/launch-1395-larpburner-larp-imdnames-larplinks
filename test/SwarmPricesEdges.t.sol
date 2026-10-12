// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base} from "./Base.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {SwarmPrices, Attestation} from "../src/SwarmPrices.sol";
import {Attest} from "./SwarmPrices.invariant.t.sol";

/// @dev Swarm prices at their edges: the exact guardrail boundaries (fuzzed against the documented rule), every way
/// a verdict's content can fall short, the execution windows at their last second, and conformance with IMD's
/// oracle protocol: the protocol's own published signature verifies here.
contract SwarmPricesEdgesTest is Base {
    address proposer = makeAddr("proposer");

    function setUp() public {
        _deploy();
        _fillPool4();
        imd.mint(proposer, 100 ether);
        vm.prank(proposer);
        imd.approve(address(names), type(uint256).max);
    }

    function _p(uint64 s, uint64 f, uint64 l, uint64 c) internal pure returns (SwarmPrices.Prices memory) {
        return SwarmPrices.Prices(s, f, l, c);
    }

    function _propose(SwarmPrices.Prices memory next) internal returns (bytes32 id) {
        vm.prank(proposer);
        id = names.propose(next, 0.5 ether);
    }

    function _attest(bool yes, uint8 answerType, bytes memory answer, uint256 chainId, uint64 expiresAt)
        internal
        view
        returns (Attestation memory a, bytes memory sig)
    {
        a = Attestation({
            requestId: bytes32(bytes16(keccak256("uuid"))),
            chainId: chainId,
            questionHash: keccak256("q"),
            answerType: answerType,
            answer: answer.length == 0 ? abi.encode(yes) : answer,
            figure: 0,
            fromBlock: 0,
            toBlock: uint64(block.number),
            blockHash: 0,
            panelJobId: 0,
            panelSize: 9,
            quorum: 7,
            agreed: 9,
            issuedAt: uint64(block.timestamp),
            expiresAt: expiresAt
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(oracleKey, Attest.digest(a, address(names)));
        sig = abi.encodePacked(r, s, v);
    }

    function _status(bytes32 id) internal view returns (SwarmPrices.Status) {
        return names.proposal(id).status;
    }

    // --- the guardrails at their boundaries ---

    function test_ExactlyTwiceAndExactlyHalfAreAllowed() public {
        _propose(_p(0.0138 ether, 0.00338 ether, 0.00138 ether, 0.00138 ether));
        _propose(_p(0.00345 ether, 0.000845 ether, 0.000345 ether, 0.000345 ether));
        _propose(_p(0.0069 ether, 0.00169 ether, 0.00069 ether, 0.00069 ether)); // no change at all
        _propose(_p(0.00345 ether, 0.00338 ether, 0.00138 ether, 0.00069 ether)); // every step allowed, in order
        assertEq(names.proposalCount(), 4);
        vm.prank(proposer);
        vm.expectRevert(SwarmPrices.OutOfBounds.selector);
        names.propose(_p(0.0138 ether + 1, 0.00338 ether, 0.00138 ether, 0.00138 ether), 0.5 ether);
        vm.prank(proposer);
        vm.expectRevert(SwarmPrices.OutOfBounds.selector);
        names.propose(_p(0.00345 ether - 1, 0.000845 ether, 0.000345 ether, 0.000345 ether), 0.5 ether);
        // every step allowed, but 4 letter names under 5+ letter names
        vm.prank(proposer);
        vm.expectRevert(SwarmPrices.OutOfBounds.selector);
        names.propose(_p(0.00345 ether, 0.000845 ether, 0.00138 ether, 0.00069 ether), 0.5 ether);
    }

    /// @dev The documented rule: in [MIN_PRICE, MAX_PRICE], at most 2x up or down from the price now, 1-3 letter names
    /// never under 4 letter names, those never under 5+ letter names. A proposal goes through exactly when it holds.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_TheGuardrailsAreExactlyTheDocumentedRule(uint64 s, uint64 f, uint64 l, uint64 c) public {
        s = uint64(bound(s, 0.003 ether, 0.015 ether));
        f = uint64(bound(f, 0.0007 ether, 0.0035 ether));
        l = uint64(bound(l, 0.0003 ether, 0.0015 ether));
        c = uint64(bound(c, 0, 0.0015 ether));
        SwarmPrices.Prices memory next = _p(s, f, l, c);
        uint64[4] memory now_ =
            [uint64(0.0069 ether), uint64(0.00169 ether), uint64(0.00069 ether), uint64(0.00069 ether)];
        uint64[4] memory to = [s, f, l, c];
        bool ok = s >= f && f >= l;
        for (uint256 i; i < 4; ++i) {
            if (to[i] < 0.00001 ether || to[i] > 1 ether) ok = false;
            if (uint256(to[i]) > uint256(now_[i]) * 2 || uint256(to[i]) * 2 < now_[i]) ok = false;
        }
        vm.prank(proposer);
        if (!ok) vm.expectRevert(SwarmPrices.OutOfBounds.selector);
        names.propose(next, 0.5 ether);
        assertEq(names.proposalCount(), ok ? 1 : 0);
    }

    function test_ProposingNeedsTheProposersImd() public {
        address broke = makeAddr("broke");
        vm.prank(broke);
        vm.expectRevert(SwarmPrices.PaymentFailed.selector);
        names.propose(_p(0.0069 ether, 0.00169 ether, 0.00069 ether, 0.00069 ether), 0.5 ether);
        imd.mint(broke, 1 ether); // has it, never approved
        vm.prank(broke);
        vm.expectRevert(SwarmPrices.PaymentFailed.selector);
        names.propose(_p(0.0069 ether, 0.00169 ether, 0.00069 ether, 0.00069 ether), 0.5 ether);
    }

    function test_OverpayingTheOracleIsTheProposersChoice() public {
        vm.prank(proposer);
        names.propose(_p(0.0069 ether, 0.00169 ether, 0.00069 ether, 0.00069 ether), 2 ether);
        assertEq(imd.balanceOf(intake.treasury()), 2 ether);
        assertEq(imd.balanceOf(address(names)), 0);
    }

    // --- what a verdict's content must be ---

    function test_AnUnknownProposalIsNone() public view {
        SwarmPrices.Proposal memory p = names.proposal(keccak256("nothing"));
        assertEq(uint8(p.status), uint8(SwarmPrices.Status.None));
        assertEq(p.number, 0);
        assertEq(p.next.short, 0);
    }

    function test_ExecutingNothingOrAPendingProposalIsRefused() public {
        vm.expectRevert(SwarmPrices.NotApproved.selector);
        names.execute(keccak256("nothing"));
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        vm.expectRevert(SwarmPrices.NotApproved.selector);
        names.execute(id);
    }

    function test_TheAnswerMustBeABoolTrueAboutThisChain() public {
        bytes32[4] memory ids;
        for (uint256 i; i < 4; ++i) {
            ids[i] = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        }
        uint64 ttl = uint64(block.timestamp + 1 days);
        (Attestation memory a, bytes memory sig) = _attest(true, 3, "", block.chainid, ttl); // a uint256 answer
        assertTrue(intake.deliver(ids[0], a, sig));
        assertEq(uint8(_status(ids[0])), uint8(SwarmPrices.Status.Rejected), "not a bool");
        (a, sig) = _attest(true, 0, abi.encode(uint256(2)), block.chainid, ttl); // a "bool" that is not 0 or 1
        assertTrue(intake.deliver(ids[1], a, sig));
        assertEq(uint8(_status(ids[1])), uint8(SwarmPrices.Status.Rejected), "not true");
        (a, sig) = _attest(true, 0, abi.encode(true, true), block.chainid, ttl); // two words
        assertTrue(intake.deliver(ids[2], a, sig));
        assertEq(uint8(_status(ids[2])), uint8(SwarmPrices.Status.Rejected), "not one word");
        (a, sig) = _attest(true, 0, "", block.chainid + 1, ttl); // about another chain
        assertTrue(intake.deliver(ids[3], a, sig));
        assertEq(uint8(_status(ids[3])), uint8(SwarmPrices.Status.Rejected), "another chain");
    }

    function test_AVerdictExpiringThisSecondStillCounts() public {
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        (Attestation memory a, bytes memory sig) = _attest(true, 0, "", block.chainid, uint64(block.timestamp));
        assertTrue(intake.deliver(id, a, sig));
        assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Approved));
        assertEq(names.proposal(id).decidedAt, block.timestamp);
    }

    function test_AFailureAfterAVerdictIsRefused() public {
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        (Attestation memory a, bytes memory sig) = _attest(false, 0, "", block.chainid, uint64(block.timestamp + 1));
        intake.deliver(id, a, sig);
        assertFalse(intake.fail(id, 1, bytes32("body_invalid")), "settled: NotPending");
        assertEq(uint8(_status(id)), uint8(SwarmPrices.Status.Rejected));
        // and a failure of an unknown request is refused too
        vm.prank(address(intake));
        vm.expectRevert(SwarmPrices.NotPending.selector);
        names.onNoVerdict(keccak256("nothing"), 1, bytes32("body_invalid"), 0, 0, "");
    }

    function test_TwoProposalsOneVerdictEach() public {
        bytes32 first = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        bytes32 second = _propose(_p(0.006 ether, 0.0015 ether, 0.0006 ether, 0.0006 ether));
        (Attestation memory a, bytes memory sig) = _attest(true, 0, "", block.chainid, uint64(block.timestamp + 1));
        assertTrue(intake.deliver(first, a, sig));
        assertTrue(intake.deliver(second, a, sig), "the same signed answer may settle the other pending proposal: L-08");
        assertFalse(intake.deliver(first, a, sig), "but never the same one twice");
        assertEq(names.proposal(first).number, 1);
        assertEq(names.proposal(second).number, 2);
    }

    // --- the windows at their last second ---

    function _approved(SwarmPrices.Prices memory next) internal returns (bytes32 id) {
        id = _propose(next);
        (Attestation memory a, bytes memory sig) = _attest(true, 0, "", block.chainid, uint64(block.timestamp + 1 days));
        intake.deliver(id, a, sig);
    }

    function test_TheLastSecondOfTheExecuteWindow() public {
        bytes32 id = _approved(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        vm.warp(block.timestamp + 14 days);
        names.execute(id);
        assertEq(names.lastChange(), block.timestamp);
        assertEq(names.epoch(), 1);
    }

    function test_TheLastSecondOfTheCooldown() public {
        names.execute(_approved(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether)));
        uint64 changed = names.lastChange();
        bytes32 second = _approved(_p(0.004 ether, 0.001 ether, 0.0004 ether, 0.0004 ether));
        vm.warp(changed + 7 days - 1);
        vm.expectRevert(SwarmPrices.Cooling.selector);
        names.execute(second);
        vm.warp(changed + 7 days);
        names.execute(second);
        assertEq(names.epoch(), 2);
    }

    function test_TheFirstChangeHasNoCooldown() public {
        bytes32 id = _approved(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        assertEq(names.lastChange(), 0);
        names.execute(id); // at once
        assertEq(names.priceOf(bytes32("frens")), 0.0005 ether);
    }

    function test_PricesAfterTwoChangesStayWithinTheRailsOfEach() public {
        names.execute(_approved(_p(0.0138 ether, 0.00338 ether, 0.00138 ether, 0.00138 ether)));
        vm.warp(block.timestamp + 7 days);
        // the next step is judged against the new prices: 4x the start is now exactly 2x
        bytes32 id = _approved(_p(0.0276 ether, 0.00676 ether, 0.00276 ether, 0.00276 ether));
        names.execute(id);
        assertEq(names.priceOf(bytes32("kek")), 0.0276 ether);
        assertEq(names.crewPrice(), 0.00276 ether);
        vm.prank(proposer);
        vm.expectRevert(SwarmPrices.OutOfBounds.selector);
        names.propose(_p(0.0276 ether, 0.00676 ether, 0.00276 ether, 0.00276 ether * 2 + 1), 0.5 ether);
    }

    // --- conformance with IMD's oracle protocol ---

    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    address constant VECTOR_SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant VECTOR_SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant VECTOR_ISSUED_AT = 1800000000;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";

    /// @dev The protocol's published attestation vector: a bytes32[] answer, figure 12345, blocks 100-200, a panel of
    /// five with a quorum of four, unanimous.
    function _vector() internal pure returns (Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000002,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: VECTOR_ISSUED_AT,
            expiresAt: VECTOR_ISSUED_AT + 3600
        });
        a.panelJobId = 0x0000000000004000800000000000000200000000000000000000000000000000;
    }

    /// @dev IMD Names deployed at the vector's address on the vector's chain, trusting the vector's signer, with one
    /// pending proposal.
    function _vectorNames() internal returns (IMDNames v, bytes32 id) {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(VECTOR_ISSUED_AT);
        deployCodeTo(
            "IMDNames.sol:IMDNames",
            abi.encode(address(identity), larp, address(burner), artist, address(intake), VECTOR_SIGNER),
            VECTOR_CONSUMER
        );
        v = IMDNames(VECTOR_CONSUMER);
        vm.prank(proposer);
        imd.approve(address(v), type(uint256).max);
        vm.prank(proposer);
        id = v.propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether), 0.5 ether);
    }

    /// @notice The struct, the type string and the domain are the protocol's: its own signature verifies here. The
    /// vector's answer is a list, not a bool, so the verdict is a rejection, not a revert (a bad signature reverts).
    function test_TheProtocolsOwnSignatureVerifies() public {
        (IMDNames v, bytes32 id) = _vectorNames();
        assertTrue(intake.deliver(id, _vector(), VECTOR_SIGNATURE), "the protocol's signature was refused");
        assertEq(uint8(v.proposal(id).status), uint8(SwarmPrices.Status.Rejected));
    }

    function test_TheProtocolsSignatureOnATamperedVectorIsRefused() public {
        (IMDNames v, bytes32 id) = _vectorNames();
        Attestation memory a = _vector();
        a.agreed = 4;
        assertFalse(intake.deliver(id, a, VECTOR_SIGNATURE));
        a = _vector();
        a.figure = 12346;
        assertFalse(intake.deliver(id, a, VECTOR_SIGNATURE));
        assertEq(uint8(v.proposal(id).status), uint8(SwarmPrices.Status.Pending));
    }

    /// @notice A bool answer by the vector's signer, in the protocol's domain for this contract, approves.
    function test_TheVectorsSignerApprovesWithABoolAnswer() public {
        (IMDNames v, bytes32 id) = _vectorNames();
        Attestation memory a = _vector();
        a.answerType = 0;
        a.answer = abi.encode(true);
        a.chainId = VECTOR_CHAIN;
        a.panelSize = 9;
        a.quorum = 7;
        a.agreed = 8;
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(VECTOR_SIGNER_KEY, Attest.digest(a, VECTOR_CONSUMER));
        assertTrue(intake.deliver(id, a, abi.encodePacked(r, s, sv)));
        assertEq(uint8(v.proposal(id).status), uint8(SwarmPrices.Status.Approved));
    }

    /// @notice The callbacks' parameter layouts are the protocol's: `onVerdict` is the canonical callback tuple under
    /// this contract's own name, and the Intake is told exactly these selectors.
    function test_TheCallbackSelectorsAreTheProtocolsLayout() public {
        bytes4 verdict = bytes4(
            keccak256(
                "onVerdict(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
            )
        );
        bytes4 failure = bytes4(keccak256("onNoVerdict(bytes32,uint8,bytes32,uint16,uint16,bytes)"));
        assertEq(names.onVerdict.selector, verdict);
        assertEq(names.onNoVerdict.selector, failure);
        bytes32 id = _propose(_p(0.005 ether, 0.0012 ether, 0.0005 ether, 0.0005 ether));
        (address payer,, address target, bytes4 selector, bytes4 onFailure, uint256 amount) = intake.asks(id);
        assertEq(payer, address(names));
        assertEq(target, address(names));
        assertEq(selector, verdict);
        assertEq(onFailure, failure);
        assertEq(amount, 0.5 ether);
    }
}
