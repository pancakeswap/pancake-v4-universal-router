# Infinity universal-router

## Running test

1. Install dependencies with `forge install`

2. Grab a RPC (eg. from nodereal) with history 
```bash
// testnet fork test for infinity, mainnet fork test for v2/v3 
export FORK_URL=https://bsc-mainnet.nodereal.io/v1/xxx
export TESTNET_FORK_URL=https://bsc-testnet.nodereal.io/v1/xxx
```

3. Run test with `forge test`

## Update dependencies

1. Run `forge update`

## Deploying 

Ensure `script/deployParameters/Deploy{chain}.s.sol` is updated 

```bash
// set rpc url
export RPC_URL=https://

// private key need to be prefixed with 0x
export PRIVATE_KEY=0x

// replace with the respective chain eg. DeployArbitrum.s.sol:DeployArbitrum
forge script script/deployParameters/DeployArbitrum.s.sol:DeployArbitrum -vvv \
    --rpc-url $RPC_URL \
    --broadcast \
    --slow 
``` 

Remember to call `.acceptOwnership()` to be the owner of universal router

## Verifying

Each script includes a verification command. Verification needs to be performed separately since the contract is deployed using the create3 method.

```bash
export ETHERSCAN_API_KEY=xx

forge verify-contract <address> UniversalRouter --watch --chain 97 --constructor-args-path example_args.txt
```

The file `example_args.txt` contains all the parameters specified in RouterParams.

Example
```solidity
params = RouterParameters({
    permit2: 0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768,
    weth9: 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd,
    ...
})
```

then `example_args.txt` would be (0x31c2F6fcFf4F8759b3Bd5Bf0e1084A055615c768, 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd,...)
