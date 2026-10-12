// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LARP} from "../src/LARP.sol";
import {IMDNames} from "../src/IMDNames.sol";
import {LARPLinks} from "../src/LARPLinks.sol";
import {LARPBurner} from "../src/LARPBurner.sol";

/// @dev What IMD's `evm_contracts` launch needs: four contracts created in one transaction, constructor arguments
/// only, nothing called.
contract LaunchTest is Test {
    address constant IDENTITY = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address constant POOL4_HOOK = 0xc6C965Bd164c483e87d0B550671798e9A3602840;
    address constant LAUNCHER = 0xfF03410d0Fe5fa8f7F59F743de35E333D9857120;
    address constant ARTIST = 0x35dA9C0303507ddf708E87F2568EdDf12c47a059;
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant IMD6900 = 0x0000198C940D8cD70Cb9ACeC5E3af8216ac57d2F;
    address constant PAIR_HOOK = 0x667f4621030aCfAfb1bD0B64d33610A8567f2A44;

    function _burnerArgs() internal pure returns (bytes memory) {
        return abi.encode(
            POOL_MANAGER,
            IMD,
            uint24(10_000),
            uint24(60),
            POOL4_HOOK,
            uint24(10_000),
            uint24(200),
            IMD6900,
            uint24(0),
            uint24(60),
            PAIR_HOOK
        );
    }

    function _launch() internal returns (LARPBurner burner, LARP larp, IMDNames names, LARPLinks links) {
        burner = new LARPBurner(POOL_MANAGER, IMD, 10_000, 60, POOL4_HOOK, 10_000, 200, IMD6900, 0, 60, PAIR_HOOK);
        larp = new LARP(IDENTITY);
        names = new IMDNames(IDENTITY, larp, address(burner), ARTIST, INTAKE, ORACLE_SIGNER);
        links = new LARPLinks(IDENTITY, LAUNCHER, larp, names, address(burner));
    }

    function test_DeploysOnAFreshChain() public {
        // nothing exists at any of these addresses here: the constructors call nothing
        assertEq(
            IDENTITY.code.length + POOL_MANAGER.code.length + LAUNCHER.code.length + IMD.code.length
                + IMD6900.code.length + INTAKE.code.length,
            0
        );
        (LARPBurner burner, LARP larp, IMDNames names, LARPLinks links) = _launch();
        assertEq(address(burner.POOL_MANAGER()), POOL_MANAGER);
        assertEq(burner.IMD(), IMD);
        assertEq(burner.POOL4_HOOK(), POOL4_HOOK);
        assertEq(burner.POOL4_FEE(), 10_000);
        assertEq(burner.POOL4_SPACING(), 60);
        assertEq(burner.BACKUP_FEE(), 10_000);
        assertEq(burner.BACKUP_SPACING(), 200);
        assertEq(burner.IMD6900(), IMD6900);
        assertEq(burner.PAIR_FEE(), 0);
        assertEq(burner.PAIR_SPACING(), 60);
        assertEq(burner.PAIR_HOOK(), PAIR_HOOK);
        assertEq(larp.IDENTITY(), IDENTITY);
        assertEq(names.IDENTITY(), IDENTITY);
        assertEq(address(names.LARP()), address(larp));
        assertEq(names.BURNER(), address(burner));
        assertEq(names.artist(), ARTIST);
        assertEq(names.INTAKE(), INTAKE);
        assertEq(names.ORACLE_SIGNER(), ORACLE_SIGNER);
        assertEq(names.priceOf(bytes32("frens")), 0.00069 ether);
        assertEq(names.crewPrice(), 0.00069 ether);
        assertEq(links.IDENTITY(), IDENTITY);
        assertEq(links.LAUNCHER(), LAUNCHER);
        assertEq(address(links.LARP()), address(larp));
        assertEq(address(links.NAMES()), address(names));
        assertEq(links.BURNER(), address(burner));
    }

    function test_FitsOneTransaction() public {
        uint256 g = gasleft();
        _launch();
        uint256 used = g - gasleft();
        emit log_named_uint("launch gas, four creations", used);
        // IMD's launcher adds about 0.8M, and the creation code is calldata (EIP-7623: up to 40 gas a byte): 2^24 cap
        assertLt(used + 800_000 + 40 * _initcodeBytes(), 1 << 24);
    }

    function _initcodeBytes() internal pure returns (uint256) {
        return type(LARPBurner).creationCode.length + type(LARP).creationCode.length
            + type(IMDNames).creationCode.length + type(LARPLinks).creationCode.length;
    }

    function test_PassesTheAdmissionScan() public {
        (LARPBurner burner, LARP larp, IMDNames names, LARPLinks links) = _launch();
        _scan(bytes.concat(type(LARPBurner).creationCode, _burnerArgs()), "LARPBurner creation code");
        _scan(bytes.concat(type(LARP).creationCode, abi.encode(IDENTITY)), "LARP creation code");
        _scan(
            bytes.concat(
                type(IMDNames).creationCode, abi.encode(IDENTITY, larp, burner, ARTIST, INTAKE, ORACLE_SIGNER)
            ),
            "IMDNames creation code"
        );
        _scan(
            bytes.concat(type(LARPLinks).creationCode, abi.encode(IDENTITY, LAUNCHER, larp, names, burner)),
            "LARPLinks creation code"
        );
        _scan(address(burner).code, "LARPBurner");
        _scan(address(larp).code, "LARP");
        _scan(address(names).code, "IMDNames");
        _scan(address(links).code, "LARPLinks");
    }

    /// @dev IMD reads code as instructions (PUSH data skipped) and refuses CALLCODE, DELEGATECALL and SELFDESTRUCT
    function _scan(bytes memory code, string memory what) internal pure {
        uint256 hits;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0xf2 || op == 0xf4 || op == 0xff) ++hits;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        assertEq(hits, 0, what);
    }

    function test_UnderTheCodeSizeLimit() public {
        (LARPBurner burner, LARP larp, IMDNames names, LARPLinks links) = _launch();
        assertLt(address(burner).code.length, 24_576);
        assertLt(address(larp).code.length, 24_576);
        assertLt(address(names).code.length, 24_576);
        assertLt(address(links).code.length, 24_576);
    }
}
