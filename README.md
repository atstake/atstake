# Ethereum contracts used by Atstake

This repository contains all of the Ethereum contracts used by [Atstake](https://atstake.net). We encourage our users to carefully review these contracts to gain confidence in the security of your agreements.

All the solidity contracts are in the 'contracts' directory. Read the comments at the top of AgreementManager.sol for an overview of all contracts.

Agreements that use only ETH are managed by AgreementManagerETH_Simple.sol. Its deployed address is [0x4C0fC7abfa8d2a44B379704a8Dc1e5b6169F8454](https://etherscan.io/address/0x4C0fC7abfa8d2a44B379704a8Dc1e5b6169F8454).

Agreements that use at least one ERC-20 token are managed by AgreementManagerERC20_Simple.sol. Its deployed address is [0xba5a6e8bbcda99932e86a0aa3f87ebdbe4b20c28](https://etherscan.io/address/0xba5a6e8bbcda99932e86a0aa3f87ebdbe4b20c28).

To verify that the code in this repository matches the contract deployed on the Ethereum network for the above addresses, do the following:

1. Follow the link for the contract you're interested in (based on whether your agreement uses an ERC20 token or not).
1. Click the 'contracts' tab. Note that Etherscan has verified that the contract code is an exact match for the code that we've uploaded to Etherscan.
1. Verify that the code in this github repository matches the code on Etherscan.

Alternatively if you don't want to trust Etherscan you can use any other block explorer to get the bytecode of the contracts, then compile the code in this repository with the following options and verify that the bytecodes match:
* Solidity version 0.5.3
* Optimization on
* 1000 runs
* targeting the Byzantium EVM

If you have any feedback or concerns about these contracts, contact support@atstake.net.
