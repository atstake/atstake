# Ethereum contracts used by Atstake

This repository contains all of the Ethereum contracts used by Atstake. We encourage our users to carefully review these contracts to gain confidence in the security of your agreements.

All the solidity contracts are in the 'contracts' directory. Read the comments at the top of AgreementManager.sol for an overview of all contracts.

Agreements that use only ETH are managed by AgreementManagerETH_Simple.sol. Its deployed address is [0x6FDE4cd3c359a5aCedce58D01eDF2dB26eDB44ff](https://kovan.etherscan.io/address/0x6fde4cd3c359a5acedce58d01edf2db26edb44ff).

Agreements that use at least one ERC-20 token are managed by AgreementManagerERC20_Simple.sol. Its deployed address is [0xed3d71f2d333cf5ed93C2e229FCCE39540d08FE5](https://kovan.etherscan.io/address/0xed3d71f2d333cf5ed93c2e229fcce39540d08fe5).

To verify that the code in this repository matches the contract deployed on the Ethereum network for the above addresses, do the following:

1. Follow the link for the contract you're interested in above (ETH_Simple is used for agreements where all participants are using only Ether. ERC20_Simple is used for all other agreements).
1. Click the 'contracts' tab. Note that Etherscan has verified that the contract code is an exact match for the code that we've uploaded to Etherscan.
1. Verify that the code in this github repository matches the code on Etherscan.

Alternatively if you don't want to trust Etherscan you can use any other block explorer to get the bytecode of the contracts, then compile the code in this repository with the following options and verify that the bytecodes match:
* Solidity version 0.5.3
* Optimization on
* 1000 runs
* targeting the Byzantium EVM

If you have any feedback or concerns about these contracts, contact support@atstake.net.
