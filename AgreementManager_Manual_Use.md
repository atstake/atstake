If the Atstake website is ever offline, you can use the following instructions to continue interacting with the AgreementManager contracts.

**(1) Determine whether you're using the AgreementManagerETH_Simple or AgreementManagerERC20_Simple contract**

If you, your counterparty, and the arbitrator are all either staking or being paid in ETH, then you're using AgreementManagerETH_Simple. If any of you is using any ERC20 token, you're using AgreementManagerERC20_Simple.

If you're unsure, you can scan through the transaction history the address you used to participate in the agreement on https://etherscan.io/. Just search for your address and find whichever of the following contracts you've sent transactions to during the time period in question:

The AgreementManagerETH_Simple contract: https://kovan.etherscan.io/address/0x6fde4cd3c359a5acedce58d01edf2db26edb44ff

The AgreementManagerERC20_Simple contract: https://kovan.etherscan.io/address/0xed3d71f2d333cf5ed93c2e229fcce39540d08fe5

**(2) Figure out the agreement ID**

By viewing the transactions between your address (or your counterparty's address) and the AgreementManager contract address on Etherscan during the relevant time period, you can see the agreement ID since this value is displayed by events that are emitted from all the contract functions. When you find such a transaction, click on the 'Event Logs' tab and look at the value of the agreementID parameter for one of the events. Convert it from hex to decimal using Etherscan's interface to get the agreementID.

**(3) Use Etherscan to interact with the contract**

Go to the contract's page on Etherscan (one of the two links above), click on the 'Contracts' tab, then click on either the 'Read Contract' or 'Write Contract' sub-tabs depending on what you want to do. If you're not sure which actions are available to you, you'll want to go to 'Read Contract' and query the getState function using your agreementID as the input parameter. 

To interpret the output of getState, you'll need to look at the code for the relevant contract. The data structures AgreementDataETH and AgreementDataERC20 are commented heavily. Read these comments, then look at the code for getState() to see in which order these values are returned.

To write to the contract, go to the 'Write Contract' tab. You'll need to understand the output of the getState() call described previously to know which functions you can call. You'll also need to have some idea of what the functions do, which you can figure out by reading the code comments. Even if you're not a programmer we've written lots of code comments to help you understand how things work at a high level.

You'll need to pass in the agreement ID to most of these functions. Some functions also require a 'resolution', which is the amount of funds that the party who created the agreement (referred to as "party A" in the code) should recieve. The remaining funds are understood to be owed to the other party. If you're unsure who is "party A", call "getState" as described above. The first three addresses listed will represent party A, party B, and the arbitrator.

The most commonly used functions are: createAgreementA and depositB (which allow A and B to stake their funds), and resolveAsParty (which A and B call to enter their resolutions), and requestArbitration (used to summon the arbitrator if you can't agree with your counterparty). 

If the above instructions don't work, you can also try using https://mycrypto.com/contracts/interact or https://remix.ethereum.org to interact with the contract. If you need to use Remix to compile the code, use the compilation options in the general README.md file at the root of this repository.

You can also try emailing us at support@atstake.net, although if Atstake has gone offline it's possible that we won't be able to respond.
