# atstake

All the solidity contracts used by Atstake are in the 'contracts' directory. Read the comments at the top of AgreementManager.sol for an overview of all contracts.

Agreements that use only ETH are managed by AgreementManagerETH_Simple.sol. Its deployed address is 0x6FDE4cd3c359a5aCedce58D01eDF2dB26eDB44ff.

Agreements that use at least one ERC-20 token are managed by AgreementManagerERC20_Simple.sol. Its deployed address is 0xed3d71f2d333cf5ed93C2e229FCCE39540d08FE5.

To verify that the code in this repository matches the contract deployed on the Ethereum network for the above addresses, do the following:

1. Visit https://kovan.etherscan.io/, search for one of the above addresses and click on it to view its details.
1. Click the 'contracts' tab. Note that Etherscan has verified that the contract code is an exact match for the code that we've uploaded to Etherscan.
1. Verify that the code in this github repository matches the code on Etherscan.

Alternatively if you don't want to trust Etherscan you can use any other block explorer to get the bytecode of the contracts, then compile the code in this repository with the following options and verify that the bytecodes match:
* Optimization on
* 1000 runs
* targeting the Byzantium EVM

If you have any feedback or concerns about these contracts, contact support@atstake.net.
