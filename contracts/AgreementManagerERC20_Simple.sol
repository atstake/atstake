pragma solidity 0.5.7;

import "./AgreementManagerERC20.sol";
import "./SimpleArbitrationInterface.sol";

/**
    @notice
    See AgreementManager for comments on the overall nature of this contract.

    This is the contract defining how ERC20 agreements with simple (non-ERC792) 
    arbitration work.
    
    @dev
    The relevant part of the inheritance tree is:
    AgreementManager
        AgreementManagerERC20
            AgreementManagerERC20_Simple

    We also inherit from SimpleArbitrationInterface, a very simple interface that lets us avoid
    a small amount of code duplication for non-ERC792 arbitration.

    Note on re-entrancy: We continue to call ERC20 contracts only at the end of functions defined
    here. We don't introduce any other external calls, so if AgreementManagerERC20 is safe from
    reentrancy so is this contract.
*/

contract AgreementManagerERC20_Simple is AgreementManagerERC20, SimpleArbitrationInterface {
    // -------------------------------------------------------------------------------------------
    // ------------------------------------- events ----------------------------------------------
    // -------------------------------------------------------------------------------------------

    event ArbitratorResolved(
        uint32 indexed agreementID, 
        uint resolutionTokenA, 
        uint resolutionTokenB
    );

    // -------------------------------------------------------------------------------------------
    // ---------------------------- external getter functions ------------------------------------
    // -------------------------------------------------------------------------------------------

    // Return a bunch of arrays representing the entire state of the agreement. 
    function getState(
        uint agreementID
    ) 
        external 
        view 
        returns (address[6] memory, uint[23] memory, bool[11] memory, bytes memory) 
    {
        if (agreementID >= agreements.length) {
            address[6] memory zeroAddrs;
            uint[23] memory zeroUints;
            bool[11] memory zeroBools;
            bytes memory zeroBytes;
            return (zeroAddrs, zeroUints, zeroBools, zeroBytes);
        }
        
        AgreementDataERC20 storage agreement = agreements[agreementID];

        address[6] memory addrs = [
            agreement.partyAAddress, 
            agreement.partyBAddress, 
            agreement.arbitratorAddress,
            agreement.partyAToken,
            agreement.partyBToken,
            agreement.arbitratorToken
        ];
        uint[23] memory uints = [
            resolutionToWei(agreement.partyAResolutionTokenA, agreement.partyATokenPower),
            resolutionToWei(agreement.partyAResolutionTokenB, agreement.partyBTokenPower),
            resolutionToWei(agreement.partyBResolutionTokenA, agreement.partyATokenPower),
            resolutionToWei(agreement.partyBResolutionTokenB, agreement.partyBTokenPower),
            resolutionToWei(agreement.resolutionTokenA, agreement.partyATokenPower),
            resolutionToWei(agreement.resolutionTokenB, agreement.partyBTokenPower),
            resolutionToWei(agreement.automaticResolutionTokenA, agreement.partyATokenPower),
            resolutionToWei(agreement.automaticResolutionTokenB, agreement.partyBTokenPower),
            toWei(agreement.partyAStakeAmount, agreement.partyATokenPower),
            toWei(agreement.partyBStakeAmount, agreement.partyBTokenPower),
            toWei(agreement.partyAInitialArbitratorFee, agreement.arbitratorTokenPower),
            toWei(agreement.partyBInitialArbitratorFee, agreement.arbitratorTokenPower),
            toWei(agreement.disputeFee, agreement.arbitratorTokenPower),
            agreement.nextArbitrationStepAllowedAfterTimestamp, 
            agreement.autoResolveAfterTimestamp,
            agreement.daysToRespondToArbitrationRequest,
            agreement.partyATokenPower,
            agreement.partyBTokenPower,
            agreement.arbitratorTokenPower,
            // Return a bunch of zeroes where the ERC792 arbitration data is so we can have the 
            // same API for both
            0,
            0,
            0,
            0
        ];
        bool[11] memory boolVals = [
            partyStakePaid(agreement, Party.A),
            partyStakePaid(agreement, Party.B),
            partyRequestedArbitration(agreement, Party.A),
            partyRequestedArbitration(agreement, Party.B),
            partyWithdrew(agreement, Party.A),
            partyWithdrew(agreement, Party.B),
            partyAResolvedLast(agreement),
            arbitratorResolved(agreement),
            arbitratorWithdrewDisputeFee(agreement),
            // Return some false values where the ERC792 arbitration data is so we can have the 
            // same API for both
            false,
            false
        ];
        // Return empty bytes value to keep the same API as for the ERC792 version
        bytes memory bytesVal; 

        return (addrs, uints, boolVals, bytesVal);
    }

    // -------------------------------------------------------------------------------------------
    // -------------------- main external/public functions that affect state ---------------------
    // -------------------------------------------------------------------------------------------

    /// @notice Called by arbitrator to report their resolution. 
    /// Can only be called after arbitrator is asked to arbitrate by both parties.
    /// We separate the staked funds of party A and party B because they might use different 
    /// tokens.
    /// @param resTokenA The amount of party A's staked funds that the caller thinks should go to
    ///  party A. The remaining amount of wei staked for this agreement would go to party B.
    /// @param resTokenB The amount of party B's staked funds that the caller thinks should go to
    ///  party A. The remaining amount of wei staked for this agreement would go to party B.
    function resolveAsArbitrator(uint agreementID, uint resTokenA, uint resTokenB) external {
        AgreementDataERC20 storage agreement = agreements[agreementID];

        require(agreementIsOpen(agreement), "Agreement not open.");
        require(agreementIsLockedIn(agreement), "Agreement not locked in.");

        uint48 resA = toLargerUnit(resTokenA, agreement.partyATokenPower);
        uint48 resB = toLargerUnit(resTokenB, agreement.partyBTokenPower);

        require(
            msg.sender == agreement.arbitratorAddress, 
            "resolveAsArbitrator can only be called by arbitrator."
        );
        require(resA <= agreement.partyAStakeAmount, "Resolution out of range for token A.");
        require(resB <= agreement.partyBStakeAmount, "Resolution out of range for token B.");
        require(
            (
                partyRequestedArbitration(agreement, Party.A) && 
                partyRequestedArbitration(agreement, Party.B)
            ), 
            "Arbitration not requested by both parties."
        );

        setArbitratorResolved(agreement, true);

        emit ArbitratorResolved(uint32(agreementID), resA, resB);

        agreement.resolutionTokenA = resA;
        agreement.resolutionTokenB = resB;
    }

    /// @notice Request that the arbitrator get involved to settle the disagreement.
    /// Each party needs to pay the full arbitration fee when calling this. However they will be
    /// refunded the full fee if the arbitrator agrees with them.
    /// If one party calls this and the other refuses to, the party who called this function can
    /// eventually call requestDefaultJudgment. 
    function requestArbitration(uint agreementID) external payable {
        AgreementDataERC20 storage agreement = agreements[agreementID];

        require(agreementIsOpen(agreement), "Agreement not open.");
        require(agreementIsLockedIn(agreement), "Agreement not locked in.");
        require(agreement.arbitratorAddress != address(0), "Arbitration is disallowed.");
        // Make sure people don't accidentally send ETH when the only required tokens are ERC20
        if (agreement.arbitratorToken != address(0)) {
            require(msg.value == 0, "ETH was sent, but none was needed.");
        }

        Party callingParty = getCallingParty(agreement);
        require(
            !partyResolutionIsNull(agreement, callingParty), 
            "Need to enter a resolution before requesting arbitration."
        );
        require(
            !partyRequestedArbitration(agreement, callingParty), 
            "This party already requested arbitration."
        );

        bool firstArbitrationRequest = 
            !partyRequestedArbitration(agreement, Party.A) && 
            !partyRequestedArbitration(agreement, Party.B);

        require(
            (
                !firstArbitrationRequest || 
                block.timestamp > agreement.nextArbitrationStepAllowedAfterTimestamp
            ), 
            "Arbitration not allowed yet."
        );

        setPartyRequestedArbitration(agreement, callingParty, true);

        emit ArbitrationRequested(uint32(agreementID));
    
        if (firstArbitrationRequest) {
            // update the deadline for the other party to pay
            agreement.nextArbitrationStepAllowedAfterTimestamp = 
                toUint32(
                    add(
                        block.timestamp, 
                        mul(agreement.daysToRespondToArbitrationRequest, (1 days))
                    )
                );
        } else {
            // Both parties have requested arbitration. Emit this event to conform to ERC1497.
            emit Dispute(
                Arbitrator(agreement.arbitratorAddress), 
                agreementID, 
                agreementID, 
                agreementID
            );
        }

        receiveFunds_Untrusted(
            agreement.arbitratorToken, 
            toWei(agreement.disputeFee, agreement.arbitratorTokenPower)
        );
    }

    /// @notice Allow the arbitrator to indicate they're working on the dispute by withdrawing the
    /// funds. We can't prevent dishonest arbitrator from taking funds without doing work, because
    /// they can always call 'rule' quickly. So just avoid the case where we send funds to a
    /// nonresponsive arbitrator.
    function withdrawDisputeFee(uint agreementID) external {
        AgreementDataERC20 storage agreement = agreements[agreementID];

        require(
            (
                partyRequestedArbitration(agreement, Party.A) && 
                partyRequestedArbitration(agreement, Party.B)
            ), 
            "Arbitration not requested"
        );
        require(
            msg.sender == agreement.arbitratorAddress, 
            "withdrawDisputeFee can only be called by Arbitrator."
        );
        require(
            !resolutionsAreCompatibleBothExist(
                agreement, 
                agreement.partyAResolutionTokenA, 
                agreement.partyAResolutionTokenB,
                agreement.partyBResolutionTokenA, 
                agreement.partyBResolutionTokenB, 
                Party.A
            ), 
            "partyA and partyB already resolved their dispute."
        );
        require(!arbitratorWithdrewDisputeFee(agreement), "Already withdrew dispute fee.");

        setArbitratorWithdrewDisputeFee(agreement, true);

        emit DisputeFeeWithdrawn(uint32(agreementID));

        sendFunds_Untrusted(
            agreement.arbitratorAddress, 
            agreement.arbitratorToken, 
            toWei(agreement.disputeFee, agreement.arbitratorTokenPower)
        );
    }

    // -------------------------------------------------------------------------------------------
    // ----------------------------- internal helper functions -----------------------------------
    // -------------------------------------------------------------------------------------------

    /// @dev This functions is a no-op in this version of the contract. It exists because we use 
    /// inheritance.
    function checkContractSpecificConditionsForCreation(address arbitratorToken) internal { }

    /// @dev This function is NOT untrusted in this contract.
    /// @return whether the given party has paid the arbitration fee in full. 
    function partyFullyPaidDisputeFee_SometimesUntrusted(
        uint, /*agreementID is unused in this version*/ 
        AgreementDataERC20 storage agreement, 
        Party party) internal returns (bool) {
            
        // Since the arbitration fee can't change mid-agreement in simple arbitration,
        // having requested arbitration means the dispute fee is paid.
        return partyRequestedArbitration(agreement, party);     
    }

    /// @notice See comments in AgreementManagerETH to understand the goal of this complex and 
    /// important function.
    /// @dev We don't use the first argument (agreementID) in this version, but it's there because
    /// we use inheritance.
    function getPartyArbitrationRefundInWei(
        uint, 
        AgreementDataERC20 storage agreement, 
        Party party
    ) 
        internal 
        view 
        returns (uint) 
    {
        Party otherParty = getOtherParty(party);

        // If the calling party never requested arbitration then they never paid in an arbitration 
        // fee, so they should never get an arbitration refund.
        if (!partyRequestedArbitration(agreement, party)) {
            return 0;
        }

        // Beyond this point, we know the caller requested arbitration and paid an arbitration fee
        // (if disputeFee was nonzero).

        // If the other party didn't request arbitration, then the arbitrator couldn't have been 
        // paid because the arbitrator is only paid when both parties have paid the full 
        // arbitration fee. So in that case the calling party is entitled to a full refund of what
        // they paid in.
        if (!partyRequestedArbitration(agreement, otherParty)) {
            return toWei(agreement.disputeFee, agreement.arbitratorTokenPower);
        }
        
        // Beyond this point we know that both parties paid the full arbitration fee.
        // This implies they've also both resolved.

        // If the arbitrator didn't resolve or withdraw, that means they weren't paid. 
        // And they can never be paid, because we'll only call this function after a final 
        // resolution has been determined. So we should get our fee back.
        if (!arbitratorResolved(agreement) && !arbitratorWithdrewDisputeFee(agreement)) {
            return toWei(agreement.disputeFee, agreement.arbitratorTokenPower);
        }
        
        // Beyond this point, we know the arbitrator either was already paid or is entitled to 
        // withdraw the full arbitration fee. So party A and party B only have a single 
        // arbitration fee to split between themselves. We need to figure out how to split up 
        // that fee.
        
        // If A and B have compatible resolutions, then whichever of them resolved latest 
        // should have to pay the full fee (because if they had resolved earlier, the arbitrator 
        // would never have had to be called). See comments for PARTY_A_RESOLVED_LAST.
        if (
            resolutionsAreCompatibleBothExist(
                agreement, 
                agreement.partyAResolutionTokenA, 
                agreement.partyAResolutionTokenB,
                agreement.partyBResolutionTokenA, 
                agreement.partyBResolutionTokenB, 
                Party.A
            )
        ) {
            if (partyResolvedLast(agreement, party)) {
                return 0;
            } else {
                return toWei(agreement.disputeFee, agreement.arbitratorTokenPower);
            }
        }

        // Beyond this point we know A and B's resolutions are incompatible. If either of them
        // agree with the arbiter they should get a refund, leaving the other person with nothing.
        (uint resA, uint resB) = partyResolution(agreement, party);
        if (
            resolutionsAreCompatibleBothExist(
                agreement, 
                resA, 
                resB, 
                agreement.resolutionTokenA, 
                agreement.resolutionTokenB, 
                party
            )
        ) {
            return toWei(agreement.disputeFee, agreement.arbitratorTokenPower);
        }

        (resA, resB) = partyResolution(agreement, otherParty);
        if (
            resolutionsAreCompatibleBothExist(
                agreement, 
                resA, 
                resB, 
                agreement.resolutionTokenA, 
                agreement.resolutionTokenB, 
                otherParty
            )
        ) {
            return 0;
        }

        // A and B's resolutions are incompatible with each other and with the overall resolution. 
        // Neither party was "right", so they can both split the dispute fee.
        return toWei(agreement.disputeFee/2, agreement.arbitratorTokenPower);
    }
}
