// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Base, MockIMD, MockIntake} from "./Base.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {SwarmPrices, Attestation} from "../src/SwarmPrices.sol";

/// @dev Signs attestations as IMD's oracle would (EIP-712 "IdentityMD Oracle" v2, for one contract).
library Attest {
    function digest(Attestation memory a, address forContract) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    keccak256(
                        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
                    ),
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock,
                    a.toBlock
                ),
                abi.encode(a.blockHash, a.panelJobId, a.panelSize, a.quorum, a.agreed, a.issuedAt, a.expiresAt)
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("IdentityMD Oracle"),
                keccak256("2"),
                block.chainid,
                forContract
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }
}

/// @dev Three proposers propose prices in and around the guardrails; IMD's writer (the mock Intake) delivers verdicts
/// of every strength, failures, forgeries and strangers' callbacks; anyone executes; time passes. Ghosts record every
/// change the handler saw go through, and the status each proposal was last seen in.
contract SwarmHandler is Test {
    IMDNames public names;
    MockIntake public intake;
    MockIMD public imd;
    uint256 immutable oracleKey;

    address[3] public proposers = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    bytes32[] public ids;
    mapping(bytes32 => SwarmPrices.Status) public lastSeen;
    mapping(bytes32 => bool) public sawValidApproval; // the handler itself delivered a valid, strong "yes"

    // --- ghosts ---
    uint256 public proposals;
    uint256 public executions;
    uint256 public lastChangeSeen;
    SwarmPrices.Prices public expected; // what the prices must be now: the start, or the last executed proposal's
    uint256 public verdicts;
    uint256 public forgeriesRefused;

    constructor(IMDNames names_, MockIntake intake_, MockIMD imd_, uint256 oracleKey_) {
        names = names_;
        intake = intake_;
        imd = imd_;
        oracleKey = oracleKey_;
        (expected.short, expected.four, expected.long, expected.crew) = names.prices();
        for (uint256 i; i < 3; ++i) {
            imd.mint(proposers[i], 1_000 ether);
            vm.prank(proposers[i]);
            imd.approve(address(names), type(uint256).max);
        }
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    /// @dev Each price is drawn from a third of the current one to triple it, so most proposals sit at the 2x edges.
    function propose(uint256 who, uint256 s, uint256 f, uint256 l, uint256 c, uint256 fee) external {
        (uint64 cs, uint64 cf, uint64 cl, uint64 cc) = names.prices();
        SwarmPrices.Prices memory next = SwarmPrices.Prices(
            uint64(bound(s, cs / 3, uint256(cs) * 3)),
            uint64(bound(f, cf / 3, uint256(cf) * 3)),
            uint64(bound(l, cl / 3, uint256(cl) * 3)),
            uint64(bound(c, cc / 3, uint256(cc) * 3))
        );
        fee = bound(fee, 0.4 ether, 0.6 ether);
        bool withinRails = _withinRails(SwarmPrices.Prices(cs, cf, cl, cc), next);
        address proposer = proposers[who % 3];
        uint256 treasury = imd.balanceOf(intake.treasury());
        vm.prank(proposer);
        try names.propose(next, fee) returns (bytes32 id) {
            assertTrue(withinRails, "a proposal outside the guardrails went through");
            assertGe(fee, 0.5 ether, "the oracle was underpaid");
            assertEq(imd.balanceOf(intake.treasury()), treasury + fee, "the fee reached IMD's oracle");
            assertEq(imd.balanceOf(address(names)), 0, "nothing stays in the names contract");
            ids.push(id);
            lastSeen[id] = SwarmPrices.Status.Pending;
            ++proposals;
            SwarmPrices.Proposal memory p = names.proposal(id);
            assertEq(uint8(p.status), uint8(SwarmPrices.Status.Pending));
            assertEq(p.epoch, names.epoch());
            assertEq(p.number, proposals);
        } catch (bytes memory err) {
            if (bytes4(err) == SwarmPrices.OutOfBounds.selector) {
                assertFalse(withinRails, "a proposal within the guardrails was refused as out of bounds");
            } else {
                assertLt(fee, 0.5 ether, "only an underpaid oracle refuses otherwise");
            }
        }
    }

    /// @dev IMD's writer delivers a verdict of any strength, signed by the oracle for this contract.
    function verdict(uint256 which, bool yes, uint16 panel, uint16 quorum, uint16 agreed, uint256 ttl) external {
        if (ids.length == 0) return;
        bytes32 id = ids[which % ids.length];
        panel = uint16(bound(panel, 7, 12));
        quorum = uint16(bound(quorum, 5, panel));
        agreed = uint16(bound(agreed, 4, panel));
        ttl = bound(ttl, 0, 2 days);
        bool expired = ttl == 0;
        uint64 expiresAt = uint64(expired ? block.timestamp - 1 : block.timestamp + ttl);
        (Attestation memory a, bytes memory sig) = _attest(yes, panel, quorum, agreed, expiresAt, oracleKey);
        bool strong = yes && panel >= 9 && quorum >= 7 && uint256(quorum) * 9 >= uint256(panel) * 7 && agreed >= quorum
            && !expired;
        SwarmPrices.Status before = names.proposal(id).status;
        bool ok = intake.deliver(id, a, sig);
        SwarmPrices.Status after_ = names.proposal(id).status;
        if (before != SwarmPrices.Status.Pending) {
            assertFalse(ok, "a settled proposal took another verdict");
            assertEq(uint8(after_), uint8(before));
            return;
        }
        assertTrue(ok, "a verdict on a pending proposal must fit the Intake's gas and be taken");
        ++verdicts;
        if (strong) {
            assertEq(uint8(after_), uint8(SwarmPrices.Status.Approved), "a strong yes approves");
            sawValidApproval[id] = true;
        } else {
            assertEq(uint8(after_), uint8(SwarmPrices.Status.Rejected), "anything weaker rejects");
        }
        lastSeen[id] = after_;
    }

    /// @dev A forged verdict: another key, or the oracle's key for another contract. Never changes anything.
    function forge(uint256 which, bool otherKey) external {
        if (ids.length == 0) return;
        bytes32 id = ids[which % ids.length];
        (Attestation memory a, bytes memory sig) = otherKey
            ? _attest(true, 9, 7, 9, uint64(block.timestamp + 1 days), 0xBAD)
            : _attestFor(true, 9, 7, 9, uint64(block.timestamp + 1 days), oracleKey, address(intake));
        SwarmPrices.Status before = names.proposal(id).status;
        bool ok = intake.deliver(id, a, sig);
        assertFalse(ok, "a forged verdict was taken");
        assertEq(uint8(names.proposal(id).status), uint8(before));
        ++forgeriesRefused;
    }

    /// @dev Someone other than the Intake calls the callbacks with a perfectly good verdict.
    function stranger(uint256 which, uint256 who) external {
        if (ids.length == 0) return;
        bytes32 id = ids[which % ids.length];
        (Attestation memory a, bytes memory sig) = _attest(true, 9, 7, 9, uint64(block.timestamp + 1 days), oracleKey);
        vm.prank(proposers[who % 3]);
        vm.expectRevert(SwarmPrices.NotIntake.selector);
        names.onVerdict(id, a, sig);
        vm.prank(proposers[who % 3]);
        vm.expectRevert(SwarmPrices.NotIntake.selector);
        names.onNoVerdict(id, 2, bytes32("disagreed"), 0, 0, "");
    }

    function fail(uint256 which, uint8 status) external {
        if (ids.length == 0) return;
        bytes32 id = ids[which % ids.length];
        SwarmPrices.Status before = names.proposal(id).status;
        bool ok = intake.fail(id, status, bytes32("body_refused"));
        if (before == SwarmPrices.Status.Pending) {
            assertTrue(ok);
            assertEq(uint8(names.proposal(id).status), uint8(SwarmPrices.Status.Failed));
            lastSeen[id] = SwarmPrices.Status.Failed;
        } else {
            assertFalse(ok, "a settled proposal took a failure");
            assertEq(uint8(names.proposal(id).status), uint8(before));
        }
    }

    function execute(uint256 which, uint256 who) external {
        if (ids.length == 0) return;
        bytes32 id = ids[which % ids.length];
        SwarmPrices.Proposal memory p = names.proposal(id);
        (uint64 s, uint64 f, uint64 l, uint64 c) = names.prices();
        SwarmPrices.Prices memory before = SwarmPrices.Prices(s, f, l, c);
        uint64 epochBefore = names.epoch();
        uint64 lastChange = names.lastChange();
        bool may = p.status == SwarmPrices.Status.Approved && block.timestamp <= p.decidedAt + 14 days
            && p.epoch == epochBefore && (lastChange == 0 || block.timestamp >= lastChange + 7 days);
        vm.prank(proposers[who % 3]);
        try names.execute(id) {
            assertTrue(may, "an execution the rules forbid went through");
            assertTrue(sawValidApproval[id], "an executed proposal the oracle never validly approved");
            (s, f, l, c) = names.prices();
            assertEq(s, p.next.short);
            assertEq(f, p.next.four);
            assertEq(l, p.next.long);
            assertEq(c, p.next.crew);
            assertTrue(_withinRails(before, p.next), "an applied change broke a guardrail");
            assertEq(names.epoch(), epochBefore + 1);
            assertEq(names.lastChange(), block.timestamp);
            assertEq(uint8(names.proposal(id).status), uint8(SwarmPrices.Status.Executed));
            if (lastChangeSeen != 0) assertGe(block.timestamp - lastChangeSeen, 7 days, "two changes within a week");
            lastChangeSeen = block.timestamp;
            lastSeen[id] = SwarmPrices.Status.Executed;
            expected = p.next;
            ++executions;
        } catch {
            assertFalse(may, "an execution the rules allow was refused");
            (s, f, l, c) = names.prices();
            assertEq(s, before.short);
            assertEq(f, before.four);
            assertEq(l, before.long);
            assertEq(c, before.crew);
        }
    }

    function pass(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 9 days));
    }

    // --- helpers ---

    /// @dev The guardrails as documented: every price in [MIN_PRICE, MAX_PRICE], at most 2x up or down, and 1-3 letter
    /// names never under 4 letter names, which are never under 5+ letter names.
    function _withinRails(SwarmPrices.Prices memory from, SwarmPrices.Prices memory to) internal view returns (bool) {
        uint256 lo = names.MIN_PRICE();
        uint256 hi = names.MAX_PRICE();
        uint64[4] memory a = [from.short, from.four, from.long, from.crew];
        uint64[4] memory b = [to.short, to.four, to.long, to.crew];
        for (uint256 i; i < 4; ++i) {
            if (b[i] < lo || b[i] > hi) return false;
            if (uint256(b[i]) > uint256(a[i]) * 2 || uint256(b[i]) * 2 < a[i]) return false;
        }
        return to.short >= to.four && to.four >= to.long;
    }

    function _attest(bool yes, uint16 panel, uint16 quorum, uint16 agreed, uint64 expiresAt, uint256 key)
        internal
        view
        returns (Attestation memory, bytes memory)
    {
        return _attestFor(yes, panel, quorum, agreed, expiresAt, key, address(names));
    }

    function _attestFor(
        bool yes,
        uint16 panel,
        uint16 quorum,
        uint16 agreed,
        uint64 expiresAt,
        uint256 key,
        address forContract
    ) internal view returns (Attestation memory a, bytes memory sig) {
        a = Attestation({
            requestId: keccak256(abi.encode("uuid", verdicts, block.timestamp)),
            chainId: block.chainid,
            questionHash: keccak256("the question"),
            answerType: 0,
            answer: abi.encode(yes),
            figure: 0,
            fromBlock: 0,
            toBlock: uint64(block.number),
            blockHash: bytes32(0),
            panelJobId: bytes32(0),
            panelSize: panel,
            quorum: quorum,
            agreed: agreed,
            issuedAt: uint64(block.timestamp),
            expiresAt: expiresAt
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, Attest.digest(a, forContract));
        sig = abi.encodePacked(r, s, v);
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmPricesInvariantTest is Base {
    SwarmHandler handler;

    function setUp() public {
        _deploy();
        handler = new SwarmHandler(names, intake, imd, oracleKey);
        targetContract(address(handler));
    }

    function _prices() internal view returns (SwarmPrices.Prices memory p) {
        (p.short, p.four, p.long, p.crew) = names.prices();
    }

    /// @dev Prices are exactly what the last executed proposal set (or the start): nothing else moves them.
    function invariant_PricesChangeOnlyByExecution() public view {
        (uint64 s, uint64 f, uint64 l, uint64 c) = handler.expected();
        SwarmPrices.Prices memory p = _prices();
        assertEq(p.short, s);
        assertEq(p.four, f);
        assertEq(p.long, l);
        assertEq(p.crew, c);
        assertEq(names.priceOf(bytes32("kek")), s);
        assertEq(names.priceOf(bytes32("pepe")), f);
        assertEq(names.priceOf(bytes32("frens")), l);
        assertEq(names.crewPrice(), c);
    }

    /// @dev Every price within [MIN_PRICE, MAX_PRICE], short names never under 4 letter names, those never under long.
    function invariant_PricesWithinTheGuardrails() public view {
        SwarmPrices.Prices memory p = _prices();
        uint64[4] memory all = [p.short, p.four, p.long, p.crew];
        for (uint256 i; i < 4; ++i) {
            assertGe(all[i], names.MIN_PRICE());
            assertLe(all[i], names.MAX_PRICE());
        }
        assertGe(p.short, p.four);
        assertGe(p.four, p.long);
    }

    /// @dev The epoch counts applied changes, the proposal counter counts proposals, and the last change is the one
    /// the handler saw.
    function invariant_CountersMatchWhatHappened() public view {
        assertEq(names.epoch(), handler.executions());
        assertEq(names.proposalCount(), handler.proposals());
        assertEq(names.lastChange(), handler.lastChangeSeen());
    }

    /// @dev A proposal's status only moves forward: Pending to a decision, Approved to Executed; a settled one never
    /// reopens, and Rejected or Failed never becomes Executed.
    function invariant_NoProposalReopens() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.ids(i);
            SwarmPrices.Status now_ = names.proposal(id).status;
            SwarmPrices.Status seen = handler.lastSeen(id);
            assertEq(uint8(now_), uint8(seen), "the status moved without the handler seeing it");
            assertTrue(now_ != SwarmPrices.Status.None);
            if (now_ == SwarmPrices.Status.Executed) assertTrue(handler.sawValidApproval(id));
        }
    }

    /// @dev The names contract keeps no $IMD and no ETH: fees pass straight through.
    function invariant_NamesHoldsNothing() public view {
        assertEq(imd.balanceOf(address(names)), 0);
        assertEq(address(names).balance, 0);
    }
}
