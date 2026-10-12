// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @dev The few Uniswap v4 PoolManager types and calls the burner needs (ABI-identical to v4-core's).
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManagerLike {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function sync(address currency) external;
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IBurnable {
    function burn(uint256 amount) external;
}

/// @title LARP burner: every fee buys $IMD and burns it, by the IMD6900 frens
/// @notice Every fee and royalty of the LARP protocol ends here, as ETH or as $IMD, and leaves only burned.
/// - ETH buys $IMD: on POOL4, IMD's ETH/$IMD pool, so every fee is volume there; if POOL4 can't take the trade, on the
///   hookless ETH/$IMD pool (1%, tick spacing 200), which nobody can close; if neither can, the ETH waits here for
///   anyone's next `burn`.
/// - Of the $IMD, POOL_SHARE_BPS (6.9%) buys IMD6900 on the IMD6900/$IMD pool, buying pressure, and that IMD6900 is
///   burned (its supply shrinks). The rest goes to 0x…dEaD, where nobody can ever move it. If the IMD6900 buy can't
///   happen, that share goes to 0x…dEaD too.
/// @dev No owner, no roles, no upgrades. At most MAX_BURN of ETH is spent per call: small trades aren't worth
/// sandwiching against these pools' fees.
contract LARPBurner {
    /// @notice Where $IMD goes: nobody holds this key.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice The most ETH one call spends (more waits for the next call).
    uint256 public constant MAX_BURN = 0.1 ether;
    /// @notice The share of the $IMD that buys IMD6900 on the IMD6900/$IMD pool, in basis points.
    uint256 public constant POOL_SHARE_BPS = 690;
    /// @dev v4-core TickMath.MIN_SQRT_PRICE + 1 and MAX_SQRT_PRICE - 1: trade as far as the pool goes.
    uint160 internal constant MIN_PRICE_LIMIT = 4295128740;
    uint160 internal constant MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;
    uint256 private constant _LOCK = uint256(keccak256("larp.burner.lock"));
    uint8 internal constant TO_PAIR = 2;

    /// @notice Uniswap v4's PoolManager.
    IPoolManagerLike public immutable POOL_MANAGER;
    /// @notice $IMD.
    address public immutable IMD;
    /// @notice The first ETH route, POOL4: fee, tick spacing and hook.
    uint24 public immutable POOL4_FEE;
    int24 public immutable POOL4_SPACING;
    address public immutable POOL4_HOOK;
    /// @notice The second ETH route, the hookless pool: fee and tick spacing.
    uint24 public immutable BACKUP_FEE;
    int24 public immutable BACKUP_SPACING;
    /// @notice IMD6900, and its $IMD pool: fee, tick spacing and hook.
    address public immutable IMD6900;
    uint24 public immutable PAIR_FEE;
    int24 public immutable PAIR_SPACING;
    address public immutable PAIR_HOOK;

    /// @notice `eth` bought `imd` $IMD on route `route` (0 = POOL4, 1 = the hookless pool).
    event Bought(uint256 eth, uint256 imd, uint8 route);
    /// @notice No route could take `eth`: it waits here for the next `burn`.
    event Parked(uint256 eth);
    /// @notice `imdSpent` $IMD bought `imd6900Burned` IMD6900, burned; `imdBurned` $IMD went to DEAD.
    event Burned(uint256 imdBurned, uint256 imdSpent, uint256 imd6900Burned);

    error ZeroAddress();
    error NotPoolManager();
    error TooLittleIMD();
    error TooLittleGas();
    error Reentered();
    error Unfilled();
    error NoPrice();
    error TransferFailed();
    /// @notice A tick spacing above Uniswap v4's largest (32767).
    error BadSpacing();

    constructor(
        address poolManager,
        address imd,
        uint24 pool4Fee,
        uint24 pool4Spacing,
        address pool4Hook,
        uint24 backupFee,
        uint24 backupSpacing,
        address imd6900,
        uint24 pairFee,
        uint24 pairSpacing,
        address pairHook
    ) {
        if (poolManager == address(0) || imd == address(0) || imd6900 == address(0)) {
            revert ZeroAddress();
        }
        POOL_MANAGER = IPoolManagerLike(poolManager);
        IMD = imd;
        POOL4_FEE = pool4Fee;
        POOL4_SPACING = _spacing(pool4Spacing);
        POOL4_HOOK = pool4Hook;
        BACKUP_FEE = backupFee;
        BACKUP_SPACING = _spacing(backupSpacing);
        IMD6900 = imd6900;
        PAIR_FEE = pairFee;
        PAIR_SPACING = _spacing(pairSpacing);
        PAIR_HOOK = pairHook;
    }

    /// @dev A tick spacing, taken unsigned (deployers' manifests take no signed constructor arguments) and stored as the
    /// int24 every PoolKey uses. v4's spacings run from 1 to 32767 (TickMath.MAX_TICK_SPACING).
    function _spacing(uint24 s) private pure returns (int24) {
        if (s > 32767) revert BadSpacing();
        return int24(s);
    }

    /// @dev One burn at a time: a burn can't run inside a burn.
    modifier locked() {
        uint256 slot = _LOCK;
        bool busy;
        assembly {
            busy := tload(slot)
        }
        if (busy) revert Reentered();
        assembly {
            tstore(slot, 1)
        }
        _;
        assembly {
            tstore(slot, 0)
        }
    }

    /// @notice Fees and royalties in ETH arrive here; anyone can send.
    receive() external payable {}

    /// @notice Spends the ETH here (with what is sent), up to MAX_BURN, on $IMD (POOL4, else the hookless pool), then
    /// burns all the $IMD here (6.9% through IMD6900). Reverts if the ETH bought less than `minImd`; with no route,
    /// the ETH waits and this reverts only if `minImd` is set.
    function burn(uint256 minImd) external payable locked returns (uint256 imd) {
        uint256 eth = address(this).balance;
        if (eth > MAX_BURN) eth = MAX_BURN;
        if (eth != 0) {
            for (uint8 route; route < 2; ++route) {
                (bool ok, bytes memory result) = _tryUnlock(route, eth);
                if (ok) {
                    imd = abi.decode(result, (uint256));
                    emit Bought(eth, imd, route);
                    break;
                }
            }
            if (imd == 0) emit Parked(eth);
        }
        if (imd < minImd) revert TooLittleIMD();
        _burnImd();
    }

    /// @notice Burns all the $IMD here: 6.9% buys IMD6900, burned; the rest to DEAD. Fees paid in $IMD land here and
    /// are burned at once; anyone can call it.
    function burnImd() external locked {
        _burnImd();
    }

    /// @notice What `eth` is worth in $IMD now: the higher of POOL4's and the hookless pool's spot quotes (moving one
    /// pool can't lower it). Reverts unless both pools have liquidity in range.
    function quoteImd(uint256 eth) external view returns (uint256) {
        uint256 a = _spot(PoolKey(address(0), IMD, POOL4_FEE, POOL4_SPACING, POOL4_HOOK), eth);
        uint256 b = _spot(PoolKey(address(0), IMD, BACKUP_FEE, BACKUP_SPACING, address(0)), eth);
        if (a == 0 || b == 0) revert NoPrice();
        return a > b ? a : b;
    }

    /// @notice The PoolManager's callback: route 0 or 1 sells exactly `amount` ETH for $IMD (to here); route 2 sells
    /// exactly `amount` $IMD for IMD6900 and burns it. All of it or nothing.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (uint8 route, uint256 amount) = abi.decode(data, (uint8, uint256));
        if (route == TO_PAIR) {
            bool imdIs0 = IMD < IMD6900;
            PoolKey memory pair = imdIs0
                ? PoolKey(IMD, IMD6900, PAIR_FEE, PAIR_SPACING, PAIR_HOOK)
                : PoolKey(IMD6900, IMD, PAIR_FEE, PAIR_SPACING, PAIR_HOOK);
            int256 delta = POOL_MANAGER.swap(
                pair, SwapParams(imdIs0, -int256(amount), imdIs0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT), ""
            );
            (int128 imdDelta, int128 outDelta) =
                imdIs0 ? (int128(delta >> 128), int128(delta)) : (int128(delta), int128(delta >> 128));
            if (imdDelta != -int128(int256(amount)) || outDelta <= 0) revert Unfilled();
            POOL_MANAGER.sync(IMD);
            _send(IMD, address(POOL_MANAGER), amount);
            POOL_MANAGER.settle();
            uint256 out = uint128(outDelta);
            POOL_MANAGER.take(IMD6900, address(this), out);
            IBurnable(IMD6900).burn(out);
            return abi.encode(out);
        }
        PoolKey memory key = route == 0
            ? PoolKey(address(0), IMD, POOL4_FEE, POOL4_SPACING, POOL4_HOOK)
            : PoolKey(address(0), IMD, BACKUP_FEE, BACKUP_SPACING, address(0));
        int256 d = POOL_MANAGER.swap(key, SwapParams(true, -int256(amount), MIN_PRICE_LIMIT), "");
        int128 ethDelta = int128(d >> 128);
        int128 bought = int128(d);
        if (ethDelta != -int128(int256(amount)) || bought <= 0) revert Unfilled();
        POOL_MANAGER.settle{value: amount}();
        POOL_MANAGER.take(IMD, address(this), uint128(bought));
        return abi.encode(uint256(uint128(bought)));
    }

    /// @dev 6.9% of the $IMD here buys IMD6900 (burned) if the pair pool takes it; everything left goes to DEAD.
    function _burnImd() internal {
        uint256 held = _imdHeld();
        if (held == 0) return;
        uint256 share = held * POOL_SHARE_BPS / 10_000;
        uint256 burned6900;
        if (share != 0) {
            (bool ok, bytes memory result) = _tryUnlock(TO_PAIR, share);
            if (ok) burned6900 = abi.decode(result, (uint256));
            else share = 0;
        }
        uint256 rest = _imdHeld();
        _send(IMD, DEAD, rest);
        emit Burned(rest, share, burned6900);
    }

    /// @dev One unlock that may fail; a failure that ran out of gas reverts the call instead, so a caller can't skip a
    /// route (or the IMD6900 buy) by sending too little gas. A genuine revert hands nearly all the gas back. An
    /// out-of-gas hands back only what the frames above it kept, 1/64 each (EIP-150): about d/64 of the gas when the
    /// failure is d frames deep. The work runs deep here (unlock, unlockCallback, swap, the hook, the token, a proxy),
    /// so the line is drawn at a quarter: a try that failed with no more than 1/4 of its gas left ran out of gas,
    /// anywhere down to 18 frames. A caller who is refused for a real revert after that much work sends more gas.
    function _tryUnlock(uint8 route, uint256 amount) internal returns (bool ok, bytes memory result) {
        uint256 gasBefore = gasleft();
        try POOL_MANAGER.unlock(abi.encode(route, amount)) returns (bytes memory r) {
            return (true, r);
        } catch {
            if (gasleft() <= gasBefore / 4) revert TooLittleGas();
            return (false, "");
        }
    }

    /// @dev `eth` in $IMD at a pool's spot price, or 0 if the pool has no price or no liquidity in range.
    function _spot(PoolKey memory key, uint256 eth) internal view returns (uint256) {
        bytes32 state = keccak256(abi.encode(keccak256(abi.encode(key)), uint256(6))); // PoolManager pools slot
        uint160 sqrtPrice = uint160(uint256(POOL_MANAGER.extsload(state)));
        uint128 liquidity = uint128(uint256(POOL_MANAGER.extsload(bytes32(uint256(state) + 3))));
        if (sqrtPrice == 0 || liquidity == 0) return 0;
        return FullMath.mulDiv(FullMath.mulDiv(eth, sqrtPrice, 1 << 96), sqrtPrice, 1 << 96);
    }

    function _imdHeld() internal view returns (uint256 held) {
        (bool ok, bytes memory r) = IMD.staticcall(abi.encodeWithSelector(0x70a08231, address(this)));
        if (ok && r.length >= 32) held = abi.decode(r, (uint256));
    }

    function _send(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory r) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (r.length != 0 && !abi.decode(r, (bool)))) revert TransferFailed();
    }
}
