// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

import {PENStateChecks, PENVerifierBase} from "../script/VerifyPENSystem.s.sol";
import {PENDeploymentHelper} from "../script/PENDeploymentScriptBase.s.sol";

/// @notice Runs the state verifier against the live Shutter PEN deployment on Ethereum mainnet.
///         Skipped unless MAINNET_RPC_URL is set, so it never breaks an offline `forge test`.
///
///           MAINNET_RPC_URL=<archive-capable RPC> forge test --match-contract VerifyPENSystemForkTest
///
///         The fork is pinned to MAINNET_FORK_BLOCK (default below) so results are reproducible;
///         the RPC must serve state at that block.
contract VerifyPENSystemForkTest is Test {
    uint256 internal constant DEFAULT_FORK_BLOCK = 26_378_366;

    PENStateChecks internal checks;
    PENVerifierBase.Manifest internal m;
    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr("MAINNET_FORK_BLOCK", DEFAULT_FORK_BLOCK));
        forked = true;

        // Canonical Shutter PEN values (.env.example). Set explicitly so a local .env for a
        // different PEN cannot change what this test checks.
        // Every test sets the SAME values, so the process-wide vm.setEnv is safe under parallel runs.
        vm.setEnv("SEAT_TOKEN_NAME", "Shutter PEN Seat");
        vm.setEnv("SEAT_TOKEN_SYMBOL", "SEAT");
        vm.setEnv("SEAT_TOKEN_SUPPLY_CAP", "10000000");
        vm.setEnv("SEAT_TOKEN_INACTIVITY_PERIOD", "31536000");
        vm.setEnv("REFUND_PRICE", "500000");
        vm.setEnv("LIQUID_RESERVE_TARGET", "50000000");
        vm.setEnv("PAYMENT_ASSET", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
        vm.setEnv("PRINCIPAL_VAULT", "0x0000000000000000000000000000000000000000");
        vm.setEnv("TRANCHE_UPPER_BOUNDS", "2000000,4000000,6000000,8000000,10000000");
        vm.setEnv("TRANCHE_PRICES", "1000000,1250000,1750000,2500000,3500000");
        vm.setEnv("SX_PROXY_FACTORY", "0x4B4F7f64Be813Ccc66AEFC3bFCe2baA01188631c");
        vm.setEnv("SX_PROPOSITION_POWER_VALIDATION", "0x6D9d6D08EF6b26348Bd18F1FC8D953696b7cf311");
        vm.setEnv("SX_OZ_VOTES_STRATEGY", "0x2c8631584474E750CEdF2Fb6A904f2e84777Aefe");
        vm.setEnv("SX_ETH_TX_AUTHENTICATOR", "0xBA06E6cCb877C332181A6867c05c8b746A21Aed1");
        vm.setEnv("VOTING_DELAY", "7200");
        vm.setEnv("MIN_VOTING_DURATION", "21600");
        vm.setEnv("MAX_VOTING_DURATION", "21600");
        vm.setEnv("AVATAR_QUORUM", "10");
        vm.setEnv("PROPOSER_SEAT_THRESHOLD", "1");
        vm.setEnv("TIMELOCK_ENABLED", "true");
        vm.setEnv("TIMELOCK_DELAY", "86400");
        vm.setEnv("DEPLOYER", "0xb4A5af3D872c002C09BfBA654153a950E52B52c7");
        vm.setEnv("SX_DEPLOYMENTS_FILE", "lib/sx-evm/deployments/ethereum.json");

        // Shutter PEN mainnet deployment (redeploy of 2026-08-10).
        m = PENVerifierBase.Manifest({
            safeSingleton: 0x35f376B629114Bb6f4e6039a68F2fC7aE450956e,
            safeProxyFactory: 0x7e054a3b8821AcA280E759b8CBB526DB15D19A56,
            safe: 0xB7f69C3cd9E3dFB4aE0Ed9ee65eb2Ed42EdeECE3,
            seatToken: 0xe2F401A0fb40dA191b9fa8C44Fa09D31cE17374c,
            principalManager: 0x4517651c7071fecDA97Eb656a9d3A50B92b84517,
            bondingTranche: 0x652a9A770f9Cfe26e409Aa63E84B8a4e21abe1e5,
            space: 0xC85cf8400ABB7056088279c122912E7e19634885,
            execStrategy: 0x4D52DFCde316FEC3364749C077600d71B7093746
        });
        checks = new PENStateChecks();
    }

    function _runAll(PENVerifierBase.Manifest memory manifest) internal {
        _runAll(manifest, checks.loadConfig());
    }

    function _runAll(PENVerifierBase.Manifest memory manifest, PENDeploymentHelper.DeploymentConfig memory cfg)
        internal
    {
        try checks.checkBytecode(manifest) {}
            catch {
            checks.sectionReverted("Bytecode presence");
        }
        try checks.checkSeatToken(manifest, cfg.core) {}
            catch {
            checks.sectionReverted("SeatToken");
        }
        try checks.checkPrincipalManager(manifest, cfg.core) {}
            catch {
            checks.sectionReverted("PrincipalManager");
        }
        try checks.checkBondingTranche(manifest, cfg.core) {}
            catch {
            checks.sectionReverted("BondingTranche");
        }
        try checks.checkRoleHolders(manifest) {}
            catch {
            checks.sectionReverted("Role holders");
        }
        try checks.checkSafe(manifest) {}
            catch {
            checks.sectionReverted("Safe");
        }
        try checks.checkSpace(manifest, cfg.governance) {}
            catch {
            checks.sectionReverted("Space");
        }
        try checks.checkExecStrategy(manifest, cfg.governance) {}
            catch {
            checks.sectionReverted("Exec strategy");
        }
        try checks.checkImplementations(manifest, cfg.governance) {}
        catch {
            checks.sectionReverted("Proxy implementations");
        }
        try checks.checkSolvency(manifest) {}
            catch {
            checks.sectionReverted("Treasury solvency");
        }
    }

    /// The live deployment passes every state check.
    function test_fork_liveDeploymentPasses() public {
        if (!forked) vm.skip(true);
        _runAll(m);
        assertEq(checks.failures(), 0, "live deployment should have no FAIL");
        checks.finish("VerifyPENSystem (fork)");
    }

    /// A config value that differs from the chain is reported as a FAIL, and finish() reverts.
    function test_fork_wrongVotingDelayFails() public {
        if (!forked) vm.skip(true);
        // Change a copy of the config, not the environment: vm.setEnv is process-wide and tests
        // run in parallel, so an env change here would leak into the other tests.
        PENDeploymentHelper.DeploymentConfig memory cfg = checks.loadConfig();
        cfg.governance.votingDelay = 7201;
        _runAll(m, cfg);
        assertEq(checks.failures(), 1, "exactly the voting delay should fail");
        vm.expectRevert(abi.encodeWithSelector(PENVerifierBase.VerificationFailed.selector, 1));
        checks.finish("VerifyPENSystem (fork)");
    }

    /// A manifest that names the wrong contract as the Safe is caught, and the run survives the
    /// reverts that follow from calling Safe views on a non-Safe.
    function test_fork_wrongSafeAddressFails() public {
        if (!forked) vm.skip(true);
        PENVerifierBase.Manifest memory bad = m;
        bad.safe = m.bondingTranche;
        _runAll(bad);
        assertGt(checks.failures(), 0, "a wrong Safe address must fail");
    }

    /// A Space that also whitelisted the no-signature VanillaAuthenticator would be a FAIL.
    function test_fork_vanillaAuthenticatorWouldFail() public {
        if (!forked) vm.skip(true);
        // Mock the Space's authenticators(VanillaAuthenticator) view to return "enabled".
        vm.mockCall(
            m.space,
            abi.encodeWithSignature("authenticators(address)", 0xb9BE0a0093933968E3B4c4fC5d939B6c1Fe45142),
            abi.encode(uint256(1))
        );
        PENDeploymentHelper.DeploymentConfig memory cfg = checks.loadConfig();
        checks.checkSpace(m, cfg.governance);
        assertEq(checks.failures(), 1, "VanillaAuthenticator must be reported");
    }
}
