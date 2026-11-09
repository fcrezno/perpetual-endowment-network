// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IAccessControl} from "openzeppelin-contracts/contracts/access/IAccessControl.sol";

import {Strategy} from "@snapshot-x/types.sol";

import {BondingTranche} from "../src/BondingTranche.sol";
import {PrincipalManager} from "../src/PrincipalManager.sol";
import {SeatToken} from "../src/SeatToken.sol";

import {PENDeploymentScriptBase, PENDeploymentHelper, IOwnable, ISpaceManager} from "./PENDeploymentScriptBase.s.sol";
import {ISpaceConfigView, IAvatarExecConfigView, ITimelockExecConfigView} from "./BootstrapPEN.s.sol";

/// @dev The Safe views the verifier reads. Declared locally to keep the Safe sources out of
///      this compilation unit; all exist on Safe v1.4.1 (the singleton PEN deploys).
interface ISafeView {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function isModuleEnabled(address module) external view returns (bool);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
    function VERSION() external view returns (string memory);
}

interface IVotesView {
    function delegates(address account) external view returns (address);
}

/// @notice Shared plumbing for the two verifiers: manifest loading, result counters, and
///         PASS / FAIL / NOTE / SKIP reporting. Every check reports and continues, so one run
///         lists every problem instead of stopping at the first.
///
///         Severity:
///         - FAIL: the live system differs from the intended setup in a way that matters
///                 (wrong wiring, wrong holder of a privileged role, an insolvent treasury).
///         - NOTE: a difference governance is allowed to make after launch (reserve target,
///                 principal vault, appended tranches, pause). Reported, never fatal.
///         - SKIP: the check needs input that is not available (e.g. no sx-evm deployments
///                 file for this chain).
abstract contract PENVerifierBase is PENDeploymentScriptBase {
    error VerificationFailed(uint256 failures);
    error Phase2Pending(string path);
    error MissingDeploymentFile(string path);

    address internal constant SENTINEL = address(0x1);

    // ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1).
    bytes32 internal constant ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // Safe v1.4.1 storage slots (GuardManager / FallbackManager).
    bytes32 internal constant SAFE_GUARD_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;
    bytes32 internal constant SAFE_FALLBACK_HANDLER_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant BONDING_ROLE = keccak256("BONDING_ROLE");
    bytes32 internal constant RECLAIMER_ROLE = keccak256("RECLAIMER_ROLE");

    struct Manifest {
        address safeSingleton;
        address safeProxyFactory;
        address safe;
        address seatToken;
        address principalManager;
        address bondingTranche;
        address space;
        address execStrategy;
    }

    uint256 internal _passes;
    uint256 internal _failures;
    uint256 internal _notes;
    uint256 internal _skips;

    // ── Manifest ─────────────────────────────────────────────────────────────────────────

    function _manifestPath() internal view returns (string memory) {
        try vm.envString("DEPLOYMENT_FILE") returns (string memory path) {
            if (bytes(path).length != 0) return path;
        } catch {}
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    function _readManifest() internal view returns (Manifest memory m) {
        string memory path = _manifestPath();
        string memory json;
        try vm.readFile(path) returns (string memory contents) {
            json = contents;
        } catch {
            revert MissingDeploymentFile(path);
        }
        // A Phase 1-only artifact has zero Space / exec-strategy addresses and this flag.
        // Nothing past Phase 1 can be verified, so stop with a clear message.
        if (vm.keyExistsJson(json, ".phase2Pending") && vm.parseJsonBool(json, ".phase2Pending")) {
            revert Phase2Pending(path);
        }
        m.safeSingleton = vm.parseJsonAddress(json, ".safeSingleton");
        m.safeProxyFactory = vm.parseJsonAddress(json, ".safeProxyFactory");
        m.safe = vm.parseJsonAddress(json, ".safe");
        m.seatToken = vm.parseJsonAddress(json, ".seatToken");
        m.principalManager = vm.parseJsonAddress(json, ".principalManager");
        m.bondingTranche = vm.parseJsonAddress(json, ".bondingTranche");
        m.space = vm.parseJsonAddress(json, ".space");
        m.execStrategy = vm.parseJsonAddress(json, ".execStrategy");
        console2.log("Manifest:", path);
    }

    // ── Reporting ────────────────────────────────────────────────────────────────────────

    function _section(string memory title) internal pure {
        console2.log("");
        console2.log(string.concat("== ", title));
    }

    function _pass(string memory what) internal {
        _passes++;
        console2.log(string.concat("[PASS] ", what));
    }

    function _fail(string memory what) internal {
        _failures++;
        console2.log(string.concat("[FAIL] ", what));
    }

    function _note(string memory what) internal {
        _notes++;
        console2.log(string.concat("[NOTE] ", what));
    }

    function _skip(string memory what) internal {
        _skips++;
        console2.log(string.concat("[SKIP] ", what));
    }

    function _info(string memory what) internal pure {
        console2.log(string.concat("       ", what));
    }

    function _check(bool ok, string memory what) internal {
        if (ok) _pass(what);
        else _fail(what);
    }

    function _eqAddress(string memory what, address actual, address expected) internal {
        if (actual == expected) {
            _pass(string.concat(what, " = ", vm.toString(actual)));
        } else {
            _fail(string.concat(what, ": expected ", vm.toString(expected), ", got ", vm.toString(actual)));
        }
    }

    function _eqUint(string memory what, uint256 actual, uint256 expected) internal {
        if (actual == expected) {
            _pass(string.concat(what, " = ", vm.toString(actual)));
        } else {
            _fail(string.concat(what, ": expected ", vm.toString(expected), ", got ", vm.toString(actual)));
        }
    }

    function _eqString(string memory what, string memory actual, string memory expected) internal {
        if (keccak256(bytes(actual)) == keccak256(bytes(expected))) {
            _pass(string.concat(what, ' = "', actual, '"'));
        } else {
            _fail(string.concat(what, ': expected "', expected, '", got "', actual, '"'));
        }
    }

    /// @dev Governance may legitimately change these after launch, so a difference is a NOTE.
    function _eqUintOrNote(string memory what, uint256 actual, uint256 configured) internal {
        if (actual == configured) {
            _pass(string.concat(what, " = ", vm.toString(actual)));
        } else {
            _note(
                string.concat(
                    what,
                    " is ",
                    vm.toString(actual),
                    " (.env says ",
                    vm.toString(configured),
                    "; governance can change this)"
                )
            );
        }
    }

    function _hasRole(address target, bytes32 role, address account) internal view returns (bool) {
        return IAccessControl(target).hasRole(role, account);
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967_IMPLEMENTATION_SLOT))));
    }

    function _decodeToken(bytes memory params) internal pure returns (address) {
        if (params.length < 20) return address(0);
        return address(bytes20(params));
    }

    /// @dev If a section reverts part-way, FAIL lines it printed before the revert are rolled
    ///      back with it and replaced by one "section reverted" FAIL, so the printed FAIL lines
    ///      can outnumber the final count.
    function _finish(string memory name) internal view {
        console2.log("");
        console2.log("=======================================================");
        console2.log(
            string.concat(
                name,
                ": ",
                vm.toString(_passes),
                " passed, ",
                vm.toString(_failures),
                " failed, ",
                vm.toString(_notes),
                " notes, ",
                vm.toString(_skips),
                " skipped"
            )
        );
        console2.log("=======================================================");
        if (_failures != 0) revert VerificationFailed(_failures);
    }
}

/// @notice Read-only state verifier (README Step 9). Cross-checks the addresses in the
///         deployment manifest against the Shutter PEN config in `.env` and live on-chain
///         state. It never broadcasts and needs no deployer key, salt or nonce.
///
///         DEPLOYMENT_FILE=deployments/<chainId>.json \
///           forge script script/VerifyPENSystem.s.sol:VerifyPENSystem --rpc-url "$RPC_URL"
///
///         Optional env:
///         - DEPLOYER            also confirm the deployer EOA kept no role and no Safe seat.
///         - SX_DEPLOYMENTS_FILE sx-evm address book for the implementation check. Defaults to
///                               lib/sx-evm/deployments/{ethereum,sepolia}.json by chain id.
///
///         It deliberately calls no optional, version-specific function (for example
///         `BondingTranche.multiPurchase`), so older PEN deployments verify against the same
///         setup plan.
contract VerifyPENSystem is Script {
    function run() external {
        // The checks live in a helper deployed only inside this local simulation (nothing is
        // broadcast). Calling each section externally lets a revert, for example from a
        // manifest address that is not the contract it should be, become one FAIL line while
        // the later sections still run.
        PENStateChecks c = new PENStateChecks();
        (PENVerifierBase.Manifest memory m, PENDeploymentHelper.DeploymentConfig memory cfg) = c.prepare();

        try c.checkBytecode(m) {}
        catch {
            c.sectionReverted("Bytecode presence");
        }
        try c.checkSeatToken(m, cfg.core) {}
        catch {
            c.sectionReverted("SeatToken");
        }
        try c.checkPrincipalManager(m, cfg.core) {}
        catch {
            c.sectionReverted("PrincipalManager");
        }
        try c.checkBondingTranche(m, cfg.core) {}
        catch {
            c.sectionReverted("BondingTranche");
        }
        try c.checkRoleHolders(m) {}
        catch {
            c.sectionReverted("Role holders");
        }
        try c.checkSafe(m) {}
        catch {
            c.sectionReverted("Safe");
        }
        try c.checkSpace(m, cfg.governance) {}
        catch {
            c.sectionReverted("Space");
        }
        try c.checkExecStrategy(m, cfg.governance) {}
        catch {
            c.sectionReverted("Exec strategy");
        }
        try c.checkImplementations(m, cfg.governance) {}
        catch {
            c.sectionReverted("Proxy implementations");
        }
        try c.checkSolvency(m) {}
        catch {
            c.sectionReverted("Treasury solvency");
        }

        c.finish("VerifyPENSystem");
    }
}

/// @notice The state checks behind `VerifyPENSystem`. Not a script on its own.
contract PENStateChecks is PENVerifierBase {
    function prepare() external view returns (Manifest memory m, DeploymentConfig memory cfg) {
        m = _readManifest();
        cfg = _loadConfig();
        console2.log("Chain id:", block.chainid);
        console2.log("Block:   ", block.number);
    }

    /// @dev For tests that build the manifest themselves instead of reading DEPLOYMENT_FILE.
    function loadConfig() external view returns (DeploymentConfig memory) {
        return _loadConfig();
    }

    function failures() external view returns (uint256) {
        return _failures;
    }

    function sectionReverted(string memory section) external {
        _fail(string.concat(section, ": a call reverted, so the rest of this section did not run"));
    }

    function finish(string memory name) external view {
        _finish(name);
    }

    // ── 1. Bytecode presence ─────────────────────────────────────────────────────────────

    function checkBytecode(Manifest memory m) external {
        _section("Bytecode presence");
        _hasCode("SafeSingleton", m.safeSingleton);
        _hasCode("SafeProxyFactory", m.safeProxyFactory);
        _hasCode("Safe", m.safe);
        _hasCode("SeatToken", m.seatToken);
        _hasCode("PrincipalManager", m.principalManager);
        _hasCode("BondingTranche", m.bondingTranche);
        _hasCode("Space", m.space);
        _hasCode("ExecStrategy", m.execStrategy);
    }

    function _hasCode(string memory name, address target) internal {
        _check(
            target != address(0) && target.code.length != 0, string.concat(name, " has code at ", vm.toString(target))
        );
    }

    // ── 2. Core contracts: parameters and wiring ─────────────────────────────────────────

    function checkSeatToken(Manifest memory m, CoreConfig memory c) external {
        _section("SeatToken");
        SeatToken seat = SeatToken(m.seatToken);
        _eqString("name", seat.name(), c.seatName);
        _eqString("symbol", seat.symbol(), c.seatSymbol);
        _eqUint("decimals", seat.decimals(), 0);
        _eqUint("supplyCap", seat.supplyCap(), c.seatSupplyCap);
        _eqUint("inactivityPeriod (s)", seat.inactivityPeriod(), c.inactivityPeriod);
        _eqAddress("expectedOwner (the Safe)", seat.expectedOwner(), m.safe);

        // Permanent SeatToken -> Space binding: bound to the manifest Space, locked, and the
        // one-shot bootstrap slot consumed so no one can ever rebind it.
        _eqAddress("space", seat.space(), m.space);
        _check(seat.spaceLocked(), "spaceLocked = true (binding is permanent)");
        _eqAddress("bootstrap slot consumed", seat.bootstrap(), address(0));

        uint256 supply = seat.totalSupply();
        _check(supply <= seat.supplyCap(), string.concat("totalSupply ", vm.toString(supply), " <= supplyCap"));
    }

    function checkPrincipalManager(Manifest memory m, CoreConfig memory c) external {
        _section("PrincipalManager");
        PrincipalManager pm = PrincipalManager(m.principalManager);
        _eqAddress("asset (PAYMENT_ASSET)", address(pm.asset()), c.paymentAsset);
        _eqUintOrNote("liquidReserveTarget", pm.liquidReserveTarget(), c.liquidReserveTarget);

        address vault = address(pm.principalVault());
        if (vault == c.principalVault) {
            _pass(string.concat("principalVault = ", vm.toString(vault)));
        } else {
            _note(
                string.concat(
                    "principalVault is ",
                    vm.toString(vault),
                    " (.env says ",
                    vm.toString(c.principalVault),
                    "; governance can set it)"
                )
            );
        }
        if (vault != address(0)) {
            _eqAddress("principalVault.asset() == PAYMENT_ASSET", IERC4626(vault).asset(), c.paymentAsset);
        }

        if (pm.paused()) _note("PrincipalManager is PAUSED (purchases and refunds are blocked)");
        else _pass("PrincipalManager is not paused");
    }

    function checkBondingTranche(Manifest memory m, CoreConfig memory c) external {
        _section("BondingTranche");
        BondingTranche bt = BondingTranche(m.bondingTranche);
        _eqAddress("seatToken", address(bt.seatToken()), m.seatToken);
        _eqAddress("principalManager", address(bt.principalManager()), m.principalManager);
        _eqAddress("asset", address(bt.asset()), c.paymentAsset);
        _eqUint("refundPrice", bt.refundPrice(), c.refundPrice);

        // The .env schedule must be the on-chain prefix. Governance may APPEND tranches
        // (`extendTranches`) but can never edit or remove existing ones.
        uint256 onchainCount = bt.trancheCount();
        uint256 configured = c.trancheUpperBounds.length;
        if (onchainCount < configured) {
            _fail(
                string.concat(
                    "tranche count: .env has ", vm.toString(configured), ", chain has ", vm.toString(onchainCount)
                )
            );
            return;
        }
        bool prefixOk = true;
        for (uint256 i; i < configured; ++i) {
            (uint256 bound, uint256 price) = bt.tranche(i);
            if (bound != c.trancheUpperBounds[i] || price != c.tranchePrices[i]) {
                prefixOk = false;
                _fail(
                    string.concat(
                        "tranche ",
                        vm.toString(i),
                        ": expected ",
                        vm.toString(c.trancheUpperBounds[i]),
                        " @ ",
                        vm.toString(c.tranchePrices[i]),
                        ", got ",
                        vm.toString(bound),
                        " @ ",
                        vm.toString(price)
                    )
                );
            }
        }
        if (prefixOk) _pass(string.concat("tranche schedule matches .env (", vm.toString(configured), " tranches)"));
        if (onchainCount > configured) {
            _note(string.concat(vm.toString(onchainCount - configured), " tranche(s) appended by governance"));
        }
    }

    // ── 3. Role holders ──────────────────────────────────────────────────────────────────
    // OpenZeppelin AccessControl is not enumerable, so this checks the expected holders
    // and every known system address for roles it must NOT hold. The complete census of
    // all holders, including unknown addresses, needs logs: see `verify-pen.sh`.

    function checkRoleHolders(Manifest memory m) external {
        _section("Role holders");
        address deployer = _envOrZeroAddress("DEPLOYER");

        // Expected holders.
        _check(_hasRole(m.seatToken, MINTER_ROLE, m.bondingTranche), "SeatToken MINTER_ROLE held by BondingTranche");
        _check(_hasRole(m.seatToken, BURNER_ROLE, m.bondingTranche), "SeatToken BURNER_ROLE held by BondingTranche");
        _check(
            _hasRole(m.principalManager, BONDING_ROLE, m.bondingTranche),
            "PrincipalManager BONDING_ROLE held by BondingTranche"
        );
        _check(
            _hasRole(m.principalManager, DEFAULT_ADMIN_ROLE, m.safe), "PrincipalManager DEFAULT_ADMIN_ROLE held by Safe"
        );
        _check(_hasRole(m.bondingTranche, DEFAULT_ADMIN_ROLE, m.safe), "BondingTranche DEFAULT_ADMIN_ROLE held by Safe");
        _check(_hasRole(m.bondingTranche, RECLAIMER_ROLE, m.safe), "BondingTranche RECLAIMER_ROLE held by Safe");

        // SeatToken's admin role is deliberately unheld: it freezes the MINTER / BURNER
        // assignments forever. No system address may hold it.
        address[] memory known = _knownAddresses(m, deployer);
        bool adminClean = true;
        for (uint256 i; i < known.length; ++i) {
            if (known[i] != address(0) && _hasRole(m.seatToken, DEFAULT_ADMIN_ROLE, known[i])) {
                adminClean = false;
                _fail(string.concat("SeatToken DEFAULT_ADMIN_ROLE is held by ", vm.toString(known[i])));
            }
        }
        if (adminClean) _pass("SeatToken DEFAULT_ADMIN_ROLE held by no known address");

        // Nothing else that could act on the system may hold a privileged role.
        _assertNoRole(m.seatToken, "SeatToken", MINTER_ROLE, "MINTER_ROLE", known, m.bondingTranche);
        _assertNoRole(m.seatToken, "SeatToken", BURNER_ROLE, "BURNER_ROLE", known, m.bondingTranche);
        _assertNoRole(m.principalManager, "PrincipalManager", BONDING_ROLE, "BONDING_ROLE", known, m.bondingTranche);
        _assertNoRole(m.principalManager, "PrincipalManager", DEFAULT_ADMIN_ROLE, "DEFAULT_ADMIN_ROLE", known, m.safe);
        _assertNoRole(m.bondingTranche, "BondingTranche", DEFAULT_ADMIN_ROLE, "DEFAULT_ADMIN_ROLE", known, m.safe);
        _assertNoRole(m.bondingTranche, "BondingTranche", RECLAIMER_ROLE, "RECLAIMER_ROLE", known, m.safe);

        if (deployer == address(0)) {
            _skip("deployer role check (set DEPLOYER to include the deployer EOA)");
        }
    }

    function _knownAddresses(Manifest memory m, address deployer) internal pure returns (address[] memory known) {
        known = new address[](9);
        known[0] = m.safe;
        known[1] = m.seatToken;
        known[2] = m.principalManager;
        known[3] = m.bondingTranche;
        known[4] = m.space;
        known[5] = m.execStrategy;
        known[6] = m.safeSingleton;
        known[7] = m.safeProxyFactory;
        known[8] = deployer;
    }

    function _assertNoRole(
        address target,
        string memory targetName,
        bytes32 role,
        string memory roleName,
        address[] memory known,
        address allowed
    ) internal {
        bool clean = true;
        for (uint256 i; i < known.length; ++i) {
            address who = known[i];
            if (who == address(0) || who == allowed) continue;
            if (_hasRole(target, role, who)) {
                clean = false;
                _fail(string.concat(targetName, " ", roleName, " is also held by ", vm.toString(who)));
            }
        }
        if (clean) _pass(string.concat(targetName, " ", roleName, ": no other known holder"));
    }

    // ── 4. Safe ──────────────────────────────────────────────────────────────────────────

    function checkSafe(Manifest memory m) external {
        _section("Safe");
        ISafeView safe = ISafeView(m.safe);

        // A Safe proxy keeps its singleton (masterCopy) in storage slot 0.
        _eqAddress("singleton (slot 0)", address(uint160(uint256(vm.load(m.safe, bytes32(0))))), m.safeSingleton);
        try safe.VERSION() returns (string memory version) {
            _info(string.concat("Safe version ", version));
        } catch {}

        // Treasury control path: exactly one owner, the exec strategy, threshold 1, so every
        // Safe action must come through a passed governance proposal.
        address[] memory owners = safe.getOwners();
        _check(
            owners.length == 1 && owners[0] == m.execStrategy,
            string.concat("owners == [execStrategy] (", vm.toString(owners.length), " owner(s))")
        );
        for (uint256 i; i < owners.length; ++i) {
            if (owners[i] != m.execStrategy) _fail(string.concat("unexpected Safe owner ", vm.toString(owners[i])));
        }
        _eqUint("threshold", safe.getThreshold(), 1);

        // Modules can move funds without owner signatures, so the module list must be exact.
        (address[] memory modules, address next) = safe.getModulesPaginated(SENTINEL, 10);
        _check(
            modules.length == 1 && modules[0] == m.execStrategy && next == SENTINEL,
            string.concat("modules == [execStrategy] (", vm.toString(modules.length), " module(s) on first page)")
        );
        for (uint256 i; i < modules.length; ++i) {
            if (modules[i] != m.execStrategy) _fail(string.concat("unexpected Safe module ", vm.toString(modules[i])));
        }

        address guard = address(uint160(uint256(vm.load(m.safe, SAFE_GUARD_SLOT))));
        _eqAddress("transaction guard", guard, address(0));
        address fallbackHandler = address(uint160(uint256(vm.load(m.safe, SAFE_FALLBACK_HANDLER_SLOT))));
        _eqAddress("fallback handler", fallbackHandler, address(0));

        address deployer = _envOrZeroAddress("DEPLOYER");
        if (deployer != address(0)) {
            for (uint256 i; i < owners.length; ++i) {
                if (owners[i] == deployer) _fail("deployer EOA is still a Safe owner");
            }
            _check(!safe.isModuleEnabled(deployer), "deployer EOA is not a Safe module");
        }
    }

    // ── 5. Space ─────────────────────────────────────────────────────────────────────────

    function checkSpace(Manifest memory m, GovernanceConfig memory g) external {
        _section("Space");
        ISpaceConfigView sp = ISpaceConfigView(m.space);
        _eqAddress("owner (the Safe)", IOwnable(m.space).owner(), m.safe);

        _check(sp.authenticators(g.sxEthTxAuthenticator) != 0, "EthTxAuthenticator is whitelisted");
        _checkOtherAuthenticators(sp);

        // Voting: exactly one active strategy, stock OZVotes over this SeatToken.
        (address vsAddr, bytes memory vsParams) = sp.votingStrategies(0);
        _eqAddress("voting strategy 0", vsAddr, g.sxOzVotesStrategy);
        _eqAddress("voting strategy 0 token", _decodeToken(vsParams), m.seatToken);
        _eqUint("activeVotingStrategies (bitmap)", sp.activeVotingStrategies(), 1);
        _eqUint("nextVotingStrategyIndex", sp.nextVotingStrategyIndex(), 1);

        // Proposal validation: Proposition Power with the configured seat threshold, counted
        // with the same OZVotes / SeatToken strategy.
        (address pvAddr, bytes memory pvParams) = sp.proposalValidationStrategy();
        _eqAddress("proposal validation strategy", pvAddr, g.sxPropositionPowerValidation);
        if (pvAddr == g.sxPropositionPowerValidation) {
            (uint256 threshold, Strategy[] memory strats) = abi.decode(pvParams, (uint256, Strategy[]));
            _eqUint("proposer seat threshold", threshold, g.proposerSeatThreshold);
            _check(
                strats.length == 1 && strats[0].addr == g.sxOzVotesStrategy
                    && _decodeToken(strats[0].params) == m.seatToken,
                "proposal validation counts OZVotes over SeatToken"
            );
        }

        // Voting windows are BLOCK counts in Snapshot X, not seconds.
        _eqUint("votingDelay (blocks)", sp.votingDelay(), g.votingDelay);
        _eqUint("minVotingDuration (blocks)", sp.minVotingDuration(), g.minVotingDuration);
        _eqUint("maxVotingDuration (blocks)", sp.maxVotingDuration(), g.maxVotingDuration);
    }

    /// @dev Uses the sx-evm address book to test the other stock authenticators. A
    ///      VanillaAuthenticator does no signature check at all, so having it enabled is a
    ///      FAIL. EthSig is a legitimate stock authenticator, so it is only a NOTE.
    function _checkOtherAuthenticators(ISpaceConfigView sp) internal {
        (bool ok, string memory book) = _sxAddressBook();
        if (!ok) {
            _skip("other stock authenticators (no sx-evm deployments file for this chain)");
            return;
        }
        if (vm.keyExistsJson(book, ".VanillaAuthenticator")) {
            address vanilla = vm.parseJsonAddress(book, ".VanillaAuthenticator");
            _check(sp.authenticators(vanilla) == 0, "VanillaAuthenticator (no signature check) is NOT whitelisted");
        }
        if (vm.keyExistsJson(book, ".EthSigAuthenticator")) {
            address ethSig = vm.parseJsonAddress(book, ".EthSigAuthenticator");
            if (sp.authenticators(ethSig) != 0) _note("EthSigAuthenticator is also whitelisted");
            else _pass("EthSigAuthenticator is not whitelisted (EthTx only)");
        }
    }

    // ── 6. Exec strategy ─────────────────────────────────────────────────────────────────

    function checkExecStrategy(Manifest memory m, GovernanceConfig memory g) external {
        _section(g.timelockEnabled ? "Exec strategy (Timelock)" : "Exec strategy (Avatar / Safe module)");
        _eqAddress("owner (the Safe)", IOwnable(m.execStrategy).owner(), m.safe);
        _eqUint("isSpaceEnabled(space)", ISpaceManager(m.execStrategy).isSpaceEnabled(m.space), 1);

        if (g.timelockEnabled) {
            ITimelockExecConfigView tl = ITimelockExecConfigView(m.execStrategy);
            _eqUint("timelockDelay (s)", tl.timelockDelay(), g.timelockDelay);
            _eqUint("quorum", tl.quorum(), g.avatarQuorum);
            _eqAddress("vetoGuardian", tl.vetoGuardian(), address(0));
        } else {
            IAvatarExecConfigView av = IAvatarExecConfigView(m.execStrategy);
            _eqAddress("target (the Safe)", av.target(), m.safe);
            _eqUint("quorum", av.quorum(), g.avatarQuorum);
        }
    }

    // ── 7. Proxy implementations ─────────────────────────────────────────────────────────
    // The Space and the exec strategy are ERC-1967 proxies created by snapshot.box. Their
    // logic lives in shared sx-evm implementations; confirm both point at the canonical
    // ones, so an auditor following the treasury's ownership chain lands on known code.

    function checkImplementations(Manifest memory m, GovernanceConfig memory g) external {
        _section("Proxy implementations (sx-evm address book)");
        (bool ok, string memory book) = _sxAddressBook();
        if (!ok) {
            _skip("no sx-evm deployments file for this chain (set SX_DEPLOYMENTS_FILE)");
            _info(string.concat("Space implementation:        ", vm.toString(_implementationOf(m.space))));
            _info(string.concat("ExecStrategy implementation: ", vm.toString(_implementationOf(m.execStrategy))));
            return;
        }
        _eqAddress(
            "Space implementation", _implementationOf(m.space), vm.parseJsonAddress(book, ".SpaceImplementation")
        );
        string memory key =
            g.timelockEnabled ? ".TimelockExecutionStrategyImplementation" : ".AvatarExecutionStrategyImplementation";
        _eqAddress("ExecStrategy implementation", _implementationOf(m.execStrategy), vm.parseJsonAddress(book, key));
        _eqAddress(
            "SX_OZ_VOTES_STRATEGY in address book",
            g.sxOzVotesStrategy,
            vm.parseJsonAddress(book, ".OZVotesVotingStrategy")
        );
        _eqAddress(
            "SX_ETH_TX_AUTHENTICATOR in address book",
            g.sxEthTxAuthenticator,
            vm.parseJsonAddress(book, ".EthTxAuthenticator")
        );
        _eqAddress(
            "SX_PROPOSITION_POWER_VALIDATION in address book",
            g.sxPropositionPowerValidation,
            vm.parseJsonAddress(book, ".PropositionPowerProposalValidationStrategy")
        );
    }

    function _sxAddressBook() internal view returns (bool ok, string memory json) {
        string memory path;
        try vm.envString("SX_DEPLOYMENTS_FILE") returns (string memory p) {
            path = p;
        } catch {
            if (block.chainid == 1) path = "lib/sx-evm/deployments/ethereum.json";
            else if (block.chainid == 11_155_111) path = "lib/sx-evm/deployments/sepolia.json";
            else return (false, "");
        }
        try vm.readFile(path) returns (string memory contents) {
            return (true, contents);
        } catch {
            return (false, "");
        }
    }

    // ── 8. Treasury solvency ─────────────────────────────────────────────────────────────

    function checkSolvency(Manifest memory m) external {
        _section("Treasury solvency");
        PrincipalManager pm = PrincipalManager(m.principalManager);
        BondingTranche bt = BondingTranche(m.bondingTranche);

        uint256 supply = IERC20(m.seatToken).totalSupply();
        uint256 obligation = supply * bt.refundPrice();
        uint256 managed = pm.totalManagedAssets();

        _info(string.concat("seats outstanding:  ", vm.toString(supply)));
        _info(string.concat("liquid assets:      ", vm.toString(pm.liquidAssets())));
        _info(string.concat("deployed in vault:  ", vm.toString(pm.deployedAssets())));
        _info(string.concat("accountedPrincipal: ", vm.toString(pm.accountedPrincipal())));
        _info(string.concat("available yield:    ", vm.toString(pm.availableYield())));
        _info(string.concat("(amounts in smallest units of ", _assetLabel(address(pm.asset())), ")"));

        // The same inequality `BondingTranche.refund` enforces before every burn: managed
        // assets must cover a refund of every outstanding seat at the fixed refund price.
        _check(
            managed >= obligation,
            string.concat(
                "totalManagedAssets ",
                vm.toString(managed),
                " >= refund obligation ",
                vm.toString(obligation),
                " (seats x refundPrice)"
            )
        );
        if (managed < pm.accountedPrincipal()) {
            _note("totalManagedAssets is below accountedPrincipal (vault loss or rounding)");
        }
    }

    function _assetLabel(address asset) internal view returns (string memory) {
        try IERC20Metadata(asset).symbol() returns (string memory symbol) {
            return symbol;
        } catch {
            return vm.toString(asset);
        }
    }
}

/// @notice Log-based checks that a single state read cannot do. Run through
///         `script/verify-pen.sh`, which passes FROM_BLOCK.
///
///         - Role census: replays every RoleGranted / RoleRevoked on SeatToken,
///           PrincipalManager and BondingTranche and requires the final holder set of every
///           role to be exactly the intended one, so a stray holder at ANY address shows.
///         - Space changes: flags every configuration event the Space emitted after the
///           block it was created in (authenticators, strategies, validation, windows,
///           ownership, upgrades).
///         - Exec strategy: replays SpaceEnabled / SpaceDisabled (only the PEN Space may stay
///           enabled) and flags ownership transfers or upgrades after creation.
///         - Seat-holder census: rebuilds every balance from mint / burn events, checks each
///           against `balanceOf` and the sum against `totalSupply`, and counts inactive seats.
///
///         Env: FROM_BLOCK (required; the Phase 1 deploy block), TO_BLOCK (default: latest),
///         LOG_CHUNK (blocks per eth_getLogs call, default 10000; halves itself if the RPC
///         rejects a range), MAX_HOLDERS_LISTED (default 25).
contract VerifyPENHistory is PENVerifierBase {
    error LogQueryFailed(address target, uint256 fromBlock, uint256 toBlock);

    bytes32 internal constant ROLE_GRANTED = keccak256("RoleGranted(bytes32,address,address)");
    bytes32 internal constant ROLE_REVOKED = keccak256("RoleRevoked(bytes32,address,address)");
    bytes32 internal constant TRANSFER = keccak256("Transfer(address,address,uint256)");
    bytes32 internal constant SPACE_ENABLED = keccak256("SpaceEnabled(address)");
    bytes32 internal constant SPACE_DISABLED = keccak256("SpaceDisabled(address)");
    bytes32 internal constant OWNERSHIP_TRANSFERRED = keccak256("OwnershipTransferred(address,address)");
    bytes32 internal constant UPGRADED = keccak256("Upgraded(address)");
    bytes32 internal constant TIMELOCK_SETUP =
        keccak256("TimelockExecutionStrategySetUp(address,address,address[],uint256,uint256)");
    bytes32 internal constant AVATAR_SETUP =
        keccak256("AvatarExecutionStrategySetUp(address,address,address[],uint256)");

    struct RoleEntry {
        address target;
        bytes32 role;
        address account;
        bool held;
    }

    struct SpaceEventName {
        bytes32 topic;
        string name;
    }

    Manifest internal _m;
    uint256 internal _toBlock;
    uint256 internal _chunk;

    RoleEntry[] internal _roles;
    uint256 internal _roleEvents;

    SpaceEventName[] internal _spaceConfigEvents;
    uint256 internal _spaceCreationBlock;
    uint256 internal _spaceLogs;
    uint256 internal _spaceChanges;

    address[] internal _enabledSpaces;
    uint256 internal _execCreationBlock;

    address[] internal _holders;
    mapping(address => uint256) internal _balance;
    mapping(address => bool) internal _seen;
    uint256 internal _mints;
    uint256 internal _burns;

    function run() external {
        _m = _readManifest();
        uint256 fromBlock = vm.envUint("FROM_BLOCK");
        _toBlock = _envUintOr("TO_BLOCK", block.number);
        _chunk = _envUintOr("LOG_CHUNK", 10_000);
        _registerSpaceConfigEvents();

        console2.log("Chain id:", block.chainid);
        console2.log(string.concat("Blocks:   ", vm.toString(fromBlock), " .. ", vm.toString(_toBlock)));

        _scan(_m.seatToken, fromBlock, _onSeatTokenLog);
        _scan(_m.principalManager, fromBlock, _onRoleLog);
        _scan(_m.bondingTranche, fromBlock, _onRoleLog);
        _scan(_m.space, fromBlock, _onSpaceLog);
        _scan(_m.execStrategy, fromBlock, _onExecLog);

        _reportRoles();
        _reportSpace();
        _reportExec();
        _reportHolders();

        _finish("VerifyPENHistory");
    }

    // ── Log scanning ─────────────────────────────────────────────────────────────────────

    function _scan(address target, uint256 fromBlock, function(Vm.EthGetLogs memory) internal handler) internal {
        bytes32[] memory anyTopic = new bytes32[](0);
        uint256 start = fromBlock;
        uint256 chunk = _chunk;
        while (start <= _toBlock) {
            uint256 end = start + chunk - 1;
            if (end > _toBlock) end = _toBlock;
            try vm.eth_getLogs(start, end, target, anyTopic) returns (Vm.EthGetLogs[] memory logs) {
                for (uint256 i; i < logs.length; ++i) {
                    handler(logs[i]);
                }
                start = end + 1;
            } catch {
                // Most providers cap the block range or result size of eth_getLogs.
                if (chunk == 1) revert LogQueryFailed(target, start, end);
                chunk = chunk / 2;
            }
        }
    }

    // ── Roles ────────────────────────────────────────────────────────────────────────────

    function _onSeatTokenLog(Vm.EthGetLogs memory log) internal {
        if (log.topics.length == 0) return;
        if (log.topics[0] == TRANSFER) _onTransfer(log);
        else _onRoleLog(log);
    }

    function _onRoleLog(Vm.EthGetLogs memory log) internal {
        if (log.topics.length < 3) return;
        bool granted = log.topics[0] == ROLE_GRANTED;
        if (!granted && log.topics[0] != ROLE_REVOKED) return;
        _roleEvents++;
        bytes32 role = log.topics[1];
        address account = address(uint160(uint256(log.topics[2])));
        for (uint256 i; i < _roles.length; ++i) {
            RoleEntry storage e = _roles[i];
            if (e.target == log.emitter && e.role == role && e.account == account) {
                e.held = granted;
                return;
            }
        }
        _roles.push(RoleEntry({target: log.emitter, role: role, account: account, held: granted}));
    }

    function _reportRoles() internal {
        _section("Role census (all RoleGranted / RoleRevoked since FROM_BLOCK)");
        _info(string.concat(vm.toString(_roleEvents), " role events replayed"));

        // Intended final holders.
        _expectHolders(_m.seatToken, "SeatToken", DEFAULT_ADMIN_ROLE, "DEFAULT_ADMIN_ROLE", address(0));
        _expectHolders(_m.seatToken, "SeatToken", MINTER_ROLE, "MINTER_ROLE", _m.bondingTranche);
        _expectHolders(_m.seatToken, "SeatToken", BURNER_ROLE, "BURNER_ROLE", _m.bondingTranche);
        _expectHolders(_m.principalManager, "PrincipalManager", DEFAULT_ADMIN_ROLE, "DEFAULT_ADMIN_ROLE", _m.safe);
        _expectHolders(_m.principalManager, "PrincipalManager", BONDING_ROLE, "BONDING_ROLE", _m.bondingTranche);
        _expectHolders(_m.bondingTranche, "BondingTranche", DEFAULT_ADMIN_ROLE, "DEFAULT_ADMIN_ROLE", _m.safe);
        _expectHolders(_m.bondingTranche, "BondingTranche", RECLAIMER_ROLE, "RECLAIMER_ROLE", _m.safe);

        // Any role outside the five known ones is unexpected on its own.
        for (uint256 i; i < _roles.length; ++i) {
            RoleEntry storage e = _roles[i];
            if (!e.held || _isKnownRole(e.role)) continue;
            _fail(
                string.concat(
                    "unknown role ",
                    vm.toString(e.role),
                    " on ",
                    vm.toString(e.target),
                    " held by ",
                    vm.toString(e.account)
                )
            );
        }
    }

    /// @dev `expected == address(0)` means the role must have no holder at all.
    function _expectHolders(
        address target,
        string memory targetName,
        bytes32 role,
        string memory roleName,
        address expected
    ) internal {
        bool expectedHeld;
        bool clean = true;
        for (uint256 i; i < _roles.length; ++i) {
            RoleEntry storage e = _roles[i];
            if (e.target != target || e.role != role || !e.held) continue;
            // Cross-check the replay against live state.
            if (!_hasRole(target, role, e.account)) {
                _fail(
                    string.concat(
                        targetName, " ", roleName, ": logs say held by ", vm.toString(e.account), ", chain says no"
                    )
                );
                clean = false;
                continue;
            }
            if (e.account == expected) {
                expectedHeld = true;
            } else {
                clean = false;
                _fail(string.concat(targetName, " ", roleName, " has a stray holder ", vm.toString(e.account)));
            }
        }
        if (expected != address(0) && !expectedHeld) {
            clean = false;
            _fail(
                string.concat(
                    targetName, " ", roleName, ": intended holder ", vm.toString(expected), " not found in logs"
                )
            );
        }
        if (clean) {
            _pass(
                string.concat(
                    targetName,
                    " ",
                    roleName,
                    expected == address(0) ? ": no holder" : string.concat(": only ", vm.toString(expected))
                )
            );
        }
    }

    function _isKnownRole(bytes32 role) internal pure returns (bool) {
        return role == DEFAULT_ADMIN_ROLE || role == MINTER_ROLE || role == BURNER_ROLE || role == BONDING_ROLE
            || role == RECLAIMER_ROLE;
    }

    // ── Space ────────────────────────────────────────────────────────────────────────────

    function _registerSpaceConfigEvents() internal {
        _addSpaceEvent("AuthenticatorsAdded(address[])");
        _addSpaceEvent("AuthenticatorsRemoved(address[])");
        _addSpaceEvent("VotingStrategiesAdded((address,bytes)[],string[])");
        _addSpaceEvent("VotingStrategiesRemoved(uint8[])");
        _addSpaceEvent("ProposalValidationStrategyUpdated((address,bytes),string)");
        _addSpaceEvent("VotingDelayUpdated(uint32)");
        _addSpaceEvent("MinVotingDurationUpdated(uint32)");
        _addSpaceEvent("MaxVotingDurationUpdated(uint32)");
        _addSpaceEvent("OwnershipTransferred(address,address)");
        _addSpaceEvent("Upgraded(address)");
    }

    function _addSpaceEvent(string memory signature) internal {
        _spaceConfigEvents.push(SpaceEventName({topic: keccak256(bytes(signature)), name: signature}));
    }

    function _onSpaceLog(Vm.EthGetLogs memory log) internal {
        if (log.topics.length == 0) return;
        _spaceLogs++;
        // The first block the Space emits in is its creation (initialize) block; events in
        // that block are the initial configuration, not later changes.
        if (_spaceCreationBlock == 0) _spaceCreationBlock = log.blockNumber;
        if (log.blockNumber == _spaceCreationBlock) return;
        for (uint256 i; i < _spaceConfigEvents.length; ++i) {
            if (log.topics[0] == _spaceConfigEvents[i].topic) {
                _spaceChanges++;
                _fail(
                    string.concat(
                        "Space changed after creation: ",
                        _spaceConfigEvents[i].name,
                        " in block ",
                        vm.toString(uint256(log.blockNumber)),
                        " tx ",
                        vm.toString(log.transactionHash)
                    )
                );
                return;
            }
        }
    }

    function _reportSpace() internal {
        _section("Space history");
        if (_spaceCreationBlock == 0) {
            _fail("no Space logs found in range (is FROM_BLOCK before the Space was created?)");
            return;
        }
        _info(string.concat("created in block ", vm.toString(_spaceCreationBlock)));
        _info(string.concat(vm.toString(_spaceLogs), " Space logs scanned"));
        uint256 nextId = ISpaceView(_m.space).nextProposalId();
        _info(string.concat("proposals so far: ", vm.toString(nextId == 0 ? 0 : nextId - 1)));
        if (_spaceChanges == 0) _pass("no configuration change to the Space after creation");
        else _info(string.concat(vm.toString(_spaceChanges), " post-creation change(s), listed above"));
    }

    // ── Exec strategy ────────────────────────────────────────────────────────────────────

    function _onExecLog(Vm.EthGetLogs memory log) internal {
        if (log.topics.length == 0) return;
        if (_execCreationBlock == 0) _execCreationBlock = log.blockNumber;
        bytes32 topic = log.topics[0];
        if (topic == TIMELOCK_SETUP || topic == AVATAR_SETUP) {
            // `setUp` enables its initial spaces directly and emits NO SpaceEnabled for them;
            // they appear only in this event's `spaces` array (checked against the deployed
            // 0xf2A1…Ebc4 timelock implementation on mainnet).
            address[] memory spaces =
                topic == TIMELOCK_SETUP ? _timelockSetUpSpaces(log.data) : _avatarSetUpSpaces(log.data);
            for (uint256 i; i < spaces.length; ++i) {
                _setEnabledSpace(spaces[i], true);
            }
        } else if (topic == SPACE_ENABLED || topic == SPACE_DISABLED) {
            address space = abi.decode(log.data, (address));
            _setEnabledSpace(space, topic == SPACE_ENABLED);
        } else if ((topic == OWNERSHIP_TRANSFERRED || topic == UPGRADED) && log.blockNumber != _execCreationBlock) {
            _fail(
                string.concat(
                    "ExecStrategy ",
                    topic == UPGRADED ? "upgraded" : "ownership transferred",
                    " after creation in block ",
                    vm.toString(uint256(log.blockNumber))
                )
            );
        }
    }

    function _timelockSetUpSpaces(bytes memory data) internal pure returns (address[] memory spaces) {
        (,, spaces,,) = abi.decode(data, (address, address, address[], uint256, uint256));
    }

    function _avatarSetUpSpaces(bytes memory data) internal pure returns (address[] memory spaces) {
        (,, spaces,) = abi.decode(data, (address, address, address[], uint256));
    }

    function _setEnabledSpace(address space, bool enabled) internal {
        for (uint256 i; i < _enabledSpaces.length; ++i) {
            if (_enabledSpaces[i] == space) {
                if (!enabled) {
                    _enabledSpaces[i] = _enabledSpaces[_enabledSpaces.length - 1];
                    _enabledSpaces.pop();
                }
                return;
            }
        }
        if (enabled) _enabledSpaces.push(space);
    }

    function _reportExec() internal {
        _section("Exec strategy history");
        if (_execCreationBlock == 0) {
            _fail("no ExecStrategy logs found in range (is FROM_BLOCK before it was created?)");
            return;
        }
        _info(string.concat("created in block ", vm.toString(_execCreationBlock)));
        bool onlyPen = _enabledSpaces.length == 1 && _enabledSpaces[0] == _m.space;
        _check(
            onlyPen, string.concat("enabled spaces == [PEN Space] (", vm.toString(_enabledSpaces.length), " enabled)")
        );
        for (uint256 i; i < _enabledSpaces.length; ++i) {
            if (_enabledSpaces[i] != _m.space) {
                _fail(string.concat("another Space can execute through the treasury: ", vm.toString(_enabledSpaces[i])));
            }
        }
    }

    // ── Seat holders ─────────────────────────────────────────────────────────────────────

    function _onTransfer(Vm.EthGetLogs memory log) internal {
        if (log.topics.length < 3) return;
        address from = address(uint160(uint256(log.topics[1])));
        address to = address(uint160(uint256(log.topics[2])));
        uint256 value = abi.decode(log.data, (uint256));
        if (from == address(0)) {
            _mints++;
        } else if (_balance[from] >= value) {
            _balance[from] -= value;
        } else {
            // A burn larger than the replayed balance means FROM_BLOCK starts after some mints.
            _balance[from] = 0;
            _fail(
                string.concat(
                    "burn exceeds replayed balance (is FROM_BLOCK too late?) tx ", vm.toString(log.transactionHash)
                )
            );
        }
        if (to == address(0)) {
            _burns++;
        } else {
            _balance[to] += value;
            if (!_seen[to]) {
                _seen[to] = true;
                _holders.push(to);
            }
        }
        // SeatToken disables transfer / transferFrom, so a seat should only ever move by
        // mint (purchase) or burn (refund / reclaim).
        if (from != address(0) && to != address(0)) {
            _fail(string.concat("seat moved between holders in tx ", vm.toString(log.transactionHash)));
        }
    }

    function _reportHolders() internal {
        _section("Seat-holder census");
        IERC20 seat = IERC20(_m.seatToken);
        uint256 listed = _envUintOr("MAX_HOLDERS_LISTED", 25);
        uint256 sum;
        uint256 current;
        uint256 inactive;
        bool balancesMatch = true;
        for (uint256 i; i < _holders.length; ++i) {
            address holder = _holders[i];
            uint256 replayed = _balance[holder];
            uint256 live = seat.balanceOf(holder);
            if (replayed != live) {
                balancesMatch = false;
                _fail(
                    string.concat(
                        "balance mismatch for ",
                        vm.toString(holder),
                        ": logs ",
                        vm.toString(replayed),
                        ", chain ",
                        vm.toString(live)
                    )
                );
            }
            if (live == 0) continue;
            sum += live;
            current++;
            bool isInactive = SeatToken(_m.seatToken).isInactive(holder);
            if (isInactive) inactive++;
            if (current <= listed) {
                address delegatee = IVotesView(_m.seatToken).delegates(holder);
                _info(
                    string.concat(
                        vm.toString(holder),
                        "  seats ",
                        vm.toString(live),
                        isInactive ? "  INACTIVE (reclaimable)" : "  active",
                        delegatee == holder ? "" : "  not self-delegated"
                    )
                );
            }
        }
        if (current > listed) _info(string.concat("... and ", vm.toString(current - listed), " more"));

        _info(string.concat("mints: ", vm.toString(_mints), "  burns: ", vm.toString(_burns)));
        _info(string.concat("current holders: ", vm.toString(current), "  inactive: ", vm.toString(inactive)));
        _check(balancesMatch, "every replayed balance equals balanceOf");
        _eqUint("sum of holder balances == totalSupply", sum, seat.totalSupply());
    }

    // ── Env ──────────────────────────────────────────────────────────────────────────────

    function _envUintOr(string memory key, uint256 fallbackValue) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallbackValue;
        }
    }
}

interface ISpaceView {
    function nextProposalId() external view returns (uint256);
}
