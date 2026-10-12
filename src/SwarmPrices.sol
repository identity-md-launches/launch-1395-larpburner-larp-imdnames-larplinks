// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @dev IMD's oracle Intake: takes a payment in $IMD and a question in one call; IMD's swarm answers it and the plane
/// delivers the signed answer to the callback.
interface IIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external returns (bytes32 requestId);
}

/// @dev IMD's OracleAttestation, field for field: the callback's selector depends on this layout. The callback's name
/// is the consumer's, only the parameter types are the protocol's: this contract's is `onVerdict`, selector 0x8bf09c1b
/// (IMD's example `onOracleResult` with the same parameters is 0x510379c7), and `propose` registers that one.
struct Attestation {
    bytes32 requestId;
    uint256 chainId;
    bytes32 questionHash;
    uint8 answerType;
    bytes answer;
    uint256 figure;
    uint64 fromBlock;
    uint64 toBlock;
    bytes32 blockHash;
    bytes32 panelJobId;
    uint16 panelSize;
    uint16 quorum;
    uint16 agreed;
    uint64 issuedAt;
    uint64 expiresAt;
}

/// @title Swarm prices: the IMD swarm judges every price change, anyone executes it, by the IMD6900 frens
/// @notice LARP's prices (names by length, crews) change only by the IMD swarm's verdict:
/// 1. Anyone proposes new prices with `propose`, paying IMD's oracle in $IMD. The contract writes the question itself
///    (the proposal and LARP's pricing guidelines) and asks it through IMD's Intake.
/// 2. A panel of at least 9 IMD agents judges it against LARP's pricing guidelines (at the 24-hour median ETH/USD
///    price: a 5+ letter name and a crew each between 1 and 5 US dollars, 1-3 letter names at least 10x and 4 letter
///    names at least 2x a 5+ letter name). The verdict counts only if at least 7 of them give the same answer, signed
///    by IMD's oracle for this contract.
/// 3. Anyone applies an approved proposal with `execute`, once a week at most, while the prices it was made against
///    still stand.
/// Guardrails bound what any verdict can do: every price stays between MIN_PRICE and MAX_PRICE, moves at most 2x up
/// or down per change, and short names never cost less than long ones.
/// @dev The verdict rests on IMD's oracle signer and the panel. If IMD stops answering, prices stay where they are.
abstract contract SwarmPrices {
    /// @notice ETH prices: 1-3 letter names, 4 letter names, 5+ letter names, crews.
    struct Prices {
        uint64 short;
        uint64 four;
        uint64 long;
        uint64 crew;
    }

    enum Status {
        None,
        Pending,
        Approved,
        Rejected,
        Failed,
        Executed
    }

    struct Proposal {
        Prices next;
        uint64 number;
        uint64 epoch;
        uint64 decidedAt;
        Status status;
    }

    /// @notice "oracle.request@oracle-1", the oracle action LARP buys.
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    /// @notice No price goes below this or above MAX_PRICE.
    uint256 public constant MIN_PRICE = 0.00001 ether;
    uint256 public constant MAX_PRICE = 1 ether;
    /// @notice At least this long between two applied changes.
    uint256 public constant COOLDOWN = 7 days;
    /// @notice An approved proposal can be executed for this long after its verdict.
    uint256 public constant EXECUTE_WINDOW = 14 days;
    /// @notice The smallest panel and the fewest matching answers a verdict needs.
    uint16 public constant MIN_PANEL = 9;
    uint16 public constant MIN_QUORUM = 7;

    bytes32 internal constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 internal constant HALF_N = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    /// @notice IMD's oracle Intake.
    address public immutable INTAKE;
    /// @notice IMD's oracle signer: verdicts must carry its signature, made for this contract.
    address public immutable ORACLE_SIGNER;

    /// @notice The prices now.
    Prices public prices;
    /// @notice Bumped by every applied change: a proposal is only good against the prices it was made for.
    uint64 public epoch;
    /// @notice When the prices last changed.
    uint64 public lastChange;
    /// @notice Proposals made so far.
    uint64 public proposalCount;
    mapping(bytes32 requestId => Proposal) internal _proposals;

    event Proposed(bytes32 indexed requestId, uint256 indexed number, address indexed proposer, Prices next);
    event Verdict(bytes32 indexed requestId, bool approved, uint16 agreed, uint16 panelSize);
    event NoVerdict(bytes32 indexed requestId, uint8 status, bytes32 reason);
    event PricesChanged(bytes32 indexed requestId, Prices prices);

    error OutOfBounds();
    error NotIntake();
    error NotPending();
    error NotApproved();
    error Cooling();
    error Stale();
    error BadVerdictSignature();
    error PaymentFailed();

    constructor(address intake, address oracleSigner, Prices memory start) {
        INTAKE = intake;
        ORACLE_SIGNER = oracleSigner;
        _checkBounds(start);
        prices = start;
    }

    /// @notice A proposal by IMD request id: its prices, number, the epoch it was made against, when it was decided
    /// and its status.
    function proposal(bytes32 requestId) external view returns (Proposal memory) {
        return _proposals[requestId];
    }

    /// @notice Proposes `next` for the swarm to judge, paying IMD's oracle `fee` $IMD (its price, 0.5 IMD today)
    /// from the caller, who approves this contract first. Anyone can.
    function propose(Prices calldata next, uint256 fee) external returns (bytes32 requestId) {
        _checkBounds(next);
        Prices memory now_ = prices;
        _checkStep(now_.short, next.short);
        _checkStep(now_.four, next.four);
        _checkStep(now_.long, next.long);
        _checkStep(now_.crew, next.crew);

        uint64 number = ++proposalCount;
        bytes memory body = _body(number, now_, next);
        address imd = _imd();
        _call(imd, abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), fee)); // transferFrom
        _call(imd, abi.encodeWithSelector(0x095ea7b3, INTAKE, fee)); // approve
        requestId = IIntake(INTAKE)
            .requestWithFailure(
                ACTION,
                body,
                IIntake.Callback(address(this), this.onVerdict.selector),
                this.onNoVerdict.selector,
                imd,
                fee
            );
        _proposals[requestId] = Proposal(next, number, epoch, 0, Status.Pending);
        emit Proposed(requestId, number, msg.sender, next);
    }

    /// @notice IMD's Intake delivers the swarm's verdict on one of this contract's own proposals. It counts as an
    /// approval only if IMD's oracle signed it for this contract, the answer is `true`, the panel had at least
    /// MIN_PANEL members and at least MIN_QUORUM of them (and 7 in 9) gave it, and it hasn't expired.
    function onVerdict(bytes32 requestId, Attestation calldata a, bytes calldata signature) external {
        if (msg.sender != INTAKE) revert NotIntake();
        Proposal storage p = _proposals[requestId];
        if (p.status != Status.Pending) revert NotPending();
        if (!_signedByOracle(a, signature)) revert BadVerdictSignature();
        bool approved = a.answerType == 0 && a.chainId == block.chainid && a.panelSize >= MIN_PANEL
            && a.quorum >= MIN_QUORUM && uint256(a.quorum) * 9 >= uint256(a.panelSize) * 7 && a.agreed >= a.quorum
            && block.timestamp <= a.expiresAt && a.answer.length == 32 && uint256(bytes32(a.answer)) == 1;
        p.status = approved ? Status.Approved : Status.Rejected;
        p.decidedAt = uint64(block.timestamp);
        emit Verdict(requestId, approved, a.agreed, a.panelSize);
    }

    /// @notice IMD's Intake reports that a proposal got no verdict (refused, or the panel split). Unsigned, so it only
    /// closes the proposal.
    function onNoVerdict(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata) external {
        if (msg.sender != INTAKE) revert NotIntake();
        Proposal storage p = _proposals[requestId];
        if (p.status != Status.Pending) revert NotPending();
        p.status = Status.Failed;
        emit NoVerdict(requestId, status, reason);
    }

    /// @notice Applies an approved proposal. Anyone can, once COOLDOWN has passed since the last change, within
    /// EXECUTE_WINDOW of the verdict, and while the prices it was made against still stand.
    function execute(bytes32 requestId) external {
        Proposal storage p = _proposals[requestId];
        if (p.status != Status.Approved || block.timestamp > p.decidedAt + EXECUTE_WINDOW) revert NotApproved();
        if (p.epoch != epoch) revert Stale();
        if (lastChange != 0 && block.timestamp < lastChange + COOLDOWN) revert Cooling();
        p.status = Status.Executed;
        prices = p.next;
        ++epoch;
        lastChange = uint64(block.timestamp);
        emit PricesChanged(requestId, p.next);
    }

    // ------------------------------------------------------------------ internals

    /// @dev $IMD: the asset IMD's oracle is paid in.
    function _imd() internal view virtual returns (address);

    function _checkBounds(Prices memory p) internal pure {
        if (
            p.short < MIN_PRICE || p.four < MIN_PRICE || p.long < MIN_PRICE || p.crew < MIN_PRICE || p.short > MAX_PRICE
                || p.four > MAX_PRICE || p.long > MAX_PRICE || p.crew > MAX_PRICE || p.short < p.four || p.four < p.long
        ) revert OutOfBounds();
    }

    /// @dev At most 2x up or down.
    function _checkStep(uint256 from, uint256 to) internal pure {
        if (to > from * 2 || to * 2 < from) revert OutOfBounds();
    }

    function _signedByOracle(Attestation calldata a, bytes calldata signature) internal view returns (bool) {
        if (signature.length != 65) return false;
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(
                    ATTESTATION_TYPEHASH,
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
            abi.encode(DOMAIN_TYPEHASH, keccak256("IdentityMD Oracle"), keccak256("2"), block.chainid, address(this))
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domain, structHash));
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        if (uint256(s) > HALF_N || (v != 27 && v != 28)) return false;
        address signer = ecrecover(digest, v, r, s);
        return signer != address(0) && signer == ORACLE_SIGNER;
    }

    /// @dev The question the swarm judges: the proposal and LARP's pricing guidelines, as an oracle body.
    function _body(uint64 number, Prices memory from, Prices memory to) internal view returns (bytes memory) {
        return bytes.concat(
            '{"v":1,"question":"LARP price proposal #',
            bytes(_decimal(number)),
            " for name.imd names and crews on Ethereum. Current prices in ETH: ",
            bytes(_list(from)),
            ". Proposed prices in ETH: ",
            bytes(_list(to)),
            ". At the median Coinbase, Kraken and Binance ETH/USD price over the last 24 hours, do the proposed prices meet all of LARP's pricing guidelines: a 5+ letter name costs between 1 and 5 US dollars, a crew costs between 1 and 5 US dollars, a 1-3 letter name costs at least 10 times a 5+ letter name, and a 4 letter name costs at least 2 times a 5+ letter name? Answer true if all four hold, false otherwise.\",",
            '"chainId":',
            bytes(_decimal(block.chainid)),
            ',"window":{"hours":24},"answerType":"bool","evidence":"panel","panelSize":9,"quorum":7,',
            '"validForSeconds":86400,"allowAmbiguous":true,"definitions":{',
            '"guidelines":"LARP keeps names usable for IMD agents (about 1 to 5 US dollars for a 5+ letter name or a crew) and short names costly enough that nobody can cheaply register them all. If a guideline cannot be checked, answer false.",',
            '"ETH/USD":"The median of the Coinbase, Kraken and Binance ETH/USD spot prices over the last 24 hours of the window."',
            "}}"
        );
    }

    function _list(Prices memory p) internal pure returns (string memory) {
        return string.concat(
            "1-3 letter names ",
            _eth(p.short),
            ", 4 letter names ",
            _eth(p.four),
            ", 5+ letter names ",
            _eth(p.long),
            ", crews ",
            _eth(p.crew)
        );
    }

    /// @dev Wei as a decimal ETH amount: 690000000000000 -> "0.00069".
    function _eth(uint256 wei_) internal pure returns (string memory) {
        uint256 whole = wei_ / 1 ether;
        uint256 frac = wei_ % 1 ether;
        if (frac == 0) return _decimal(whole);
        bytes memory digits = new bytes(18);
        for (uint256 i = 18; i > 0; --i) {
            digits[i - 1] = bytes1(uint8(48 + frac % 10));
            frac /= 10;
        }
        uint256 end = 18;
        while (digits[end - 1] == "0") --end;
        bytes memory trimmed = new bytes(end);
        for (uint256 i; i < end; ++i) {
            trimmed[i] = digits[i];
        }
        return string.concat(_decimal(whole), ".", string(trimmed));
    }

    function _decimal(uint256 value) internal pure virtual returns (string memory) {
        if (value == 0) return "0";
        uint256 digits;
        for (uint256 v = value; v != 0; v /= 10) {
            ++digits;
        }
        bytes memory out = new bytes(digits);
        for (; value != 0; value /= 10) {
            out[--digits] = bytes1(uint8(48 + value % 10));
        }
        return string(out);
    }

    function _call(address token, bytes memory data) internal {
        (bool ok, bytes memory r) = token.call(data);
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert PaymentFailed();
    }
}
