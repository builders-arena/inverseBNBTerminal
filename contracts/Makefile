-include .env

.PHONY: deps build test test-ci fmt snapshot clean deploy-testnet

## Install Solidity dependencies (forge-std + OpenZeppelin v5)
deps:
	forge install foundry-rs/forge-std --no-git
	forge install OpenZeppelin/openzeppelin-contracts@v5.1.0 --no-git

build:
	forge build

test:
	forge test -vvv

## Heavier fuzz/invariant runs
test-ci:
	FOUNDRY_PROFILE=ci forge test -vv

fmt:
	forge fmt

snapshot:
	forge snapshot

clean:
	forge clean

## Example: make deploy-testnet
deploy-testnet:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(BSC_TESTNET_RPC_URL) \
		--broadcast --verify -vvvv
