//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Currency, CurrencyLibrary} from "pancake-v4-core/src/types/Currency.sol";
import {IHooks} from "pancake-v4-core/src/interfaces/IHooks.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IVault, Vault} from "pancake-v4-core/src/Vault.sol";
import {MockDeltaResolver} from "./mocks/MockDeltaResolver.sol";
import {TokenFixture} from "pancake-v4-core/test/helpers/TokenFixture.sol";

contract DeltaResolverTest is Test, GasSnapshot, TokenFixture {
    using CurrencyLibrary for Currency;

    IVault vault;
    MockDeltaResolver resolver;

    function setUp() public {
        initializeTokens();
        vault = new Vault();
        resolver = new MockDeltaResolver(vault);

        // make sure vault has some funds
        deal(address(vault), 1 ether);
        currency0.transfer(address(vault), 1 ether);
    }

    function test_settle_native_succeeds(uint256 amount) public {
        amount = bound(amount, 1, address(vault).balance);

        resolver.executeTest(CurrencyLibrary.NATIVE, amount);

        // check `pay` was not called
        assertEq(resolver.payCallCount(), 0);
    }

    function test_settle_token_succeeds(uint256 amount) public {
        amount = bound(amount, 1, currency0.balanceOf(address(vault)));

        // the tokens will be taken to this contract, so an approval is needed for the settle
        ERC20(Currency.unwrap(currency0)).approve(address(resolver), type(uint256).max);

        resolver.executeTest(currency0, amount);

        // check `pay` was called
        assertEq(resolver.payCallCount(), 1);
    }
}
