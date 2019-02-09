If the Atstake website is ever offline, you can use the following instructions to continue interacting with the AgreementManager contracts.

**(1) Determine whether you're using the AgreementManager or AgreementManagerERC20 contract**

If you, your counterparty, and the arbitrator are all either staking or being paid in ETH, then you're using AgreementManager. If any of you is using any ERC20 token, you're using AgreementManagerERC20.

If you're unsure, you can scan through the transaction history the address you used to participate in the agreement on https://etherscan.io/. Just search for your address and find whichever of the following contracts you've sent transactions to during the time period in question:

The AgreementManager contract: https://rinkeby.etherscan.io/address/0xb06f781f8a57dd5b8c019889a270ee3cc7eb5e1b

The AgreementManagerERC20 contract: https://rinkeby.etherscan.io/address/0x2e495a5e5a78d2d5c53d58440a40a398308b09c8

**(2) Figure out the agreement ID**

By viewing the transactions between your address (or your counterparty's address) and the AgreementManager contract address on Etherscan, you can see the agreement ID since this value is passed in as an argument to all functions except for createAgreementA.

If createAgreementA is the only function that has been called so far, you can get the agreement ID by looking at the Events tab of the AgreementManager contract on Etherscan. Look for AgreementCreated events with the 'sender' argument as whoever created this agreement. The second argument to the event is the agreement ID.

**(3) Use Remix to interact with the contract**

Go to https://remix.ethereum.org, paste the contract code listed on Etherscan into the code window on Remix. Make sure the compiler version matches the compiler version at the top of the code file, then compile the code on Remix.

Go to the 'run' tab on Remix and paste the address of the contract after the 'At Address' label. Click 'At Address'. The contract should now appear under 'deployed contracts'. Expand this contract to see the functions you can call.

You'll need to pass in the agreement ID to most of these functions. Some functions also require a 'resolution', which is the amount of funds that the party who created the agreement (referred to as "party A" in the code) should recieve. If you're unsure who is "party A", use Remix to call "getState" and it will list the addresses of the agreement in the order: party A, party B, arbitrator.

You may have to read the code to understand under whcih circumstances each function can be called. The most commonly used functions are: createAgreementA and depositB (which allow A and B to stake their funds), resolveAsParty (which A and B call to enter their resolutions), and withdraw. 


