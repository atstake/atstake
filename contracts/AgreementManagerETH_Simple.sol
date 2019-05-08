pragma solidity 0.5.7;

import "./AgreementManagerETH.sol";
import "./SimpleArbitrationInterface.sol";

/**
    @notice
    See AgreementManager for comments on the overall nature of this contract.

    This is the contract defining how ETH-only agreements with simple (non-ERC792) 
    arbitration work.
    
    @dev
    The relevant part of the inheritance tree is:
    AgreementManager
        AgreementManagerETH
            AgreementManagerETH_Simple

    We also inherit from SimpleArbitrationInterface, a very simple interface that lets us avoid
    a small amount of code duplication for non-ERC792 arbitration.

    There should be no risk of re-entrancy attacks in this contract, since it makes no external
    calls aside from ETH transfers which always occur at the end of functions.
*/

contract AgreementManagerETH_Simple is AgreementManagerETH, SimpleArbitrationInterface {
    // -------------------------------------------------------------------------------------------
    // ------------------------------------- events ----------------------------------------------
    // -------------------------------------------------------------------------------------------

    event ArbitratorResolved(uint32 indexed agreementID, uint resolution);

    // -------------------------------------------------------------------------------------------
    // ---------------------------- external getter functions ------------------------------------
    // -------------------------------------------------------------------------------------------

    /// @return the full state of an agreement.
    /// Return value interpretation is self explanatory if you look at the code
    function getState(
        uint agreementID
    ) 
        external 
        view 
        returns (address[3] memory, uint[16] memory, bool[11] memory, bytes memory) 
    { 
        if (agreementID >= agreements.length) {
            address[3] memory zeroAddrs;
            uint[16] memory zeroUints;
            bool[11] memory zeroBools;
            bytes memory zeroBytes;
            return (zeroAddrs, zeroUints, zeroBools, zeroBytes);
        }
        
        AgreementDataETH storage agreement = agreements[agreementID];

        address[3] memory addrs = [
            agreement.partyAAddress, 
            agreement.partyBAddress, 
            agreement.arbitratorAddress
        ];
        uint[16] memory uints = [
            resolutionToWei(agreement.partyAResolution),
            resolutionToWei(agreement.partyBResolution),
            resolutionToWei(agreement.resolution),
            resolutionToWei(agreement.automaticResolution),
            toWei(agreement.partyAStakeAmount),
            toWei(agreement.partyBStakeAmount),
            toWei(agreement.partyAInitialArbitratorFee),
            toWei(agreement.partyBInitialArbitratorFee),
            toWei(agreement.disputeFee),
            agreement.nextArbitrationStepAllowedAfterTimestamp,
            agreement.autoResolveAfterTimestamp,
            agreement.daysToRespondToArbitrationRequest,
            // Return a bunch of zeroes where the ERC792 arbitration data is so we can have the 
            // same API for all contracts.
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
            // same API for all contracts.
            false,
            false
        ];
        // Return empty bytes value to keep the same API as for the ERC792 version
        bytes memory bytesVal; 
        
        return (addrs, uints, boolVals, bytesVal);
    }

    // -------------------------------------------------------------------------------------------
    // -------------------- main external functions that affect state ----------------------------
    // -------------------------------------------------------------------------------------------

    /// @notice Called by arbitrator to report their resolution. 
    /// Can only be called after arbitrator is asked to arbitrate by both parties.
    /// @param resolutionWei The amount of wei that the caller thinks should go to party A.
    /// The remaining amount of wei staked for this agreement would go to party B.
    function resolveAsArbitrator(uint agreementID, uint resolutionWei) external {
        AgreementDataETH storage agreement = agreements[agreementID];

        require(agreementIsOpen(agreement), "Agreement not open.");
        require(agreementIsLockedIn(agreement), "Agreement not locked in.");

        uint48 res = toMillionth(resolutionWei);

        require(
            msg.sender == agreement.arbitratorAddress, 
            "resolveAsArbitrator can only be called by arbitrator."
        );
        require(
            res <= add(agreement.partyAStakeAmount, agreement.partyBStakeAmount), 
            "Resolution out of range."
        );
        require(
            (
                partyRequestedArbitration(agreement, Party.A) && 
                partyRequestedArbitration(agreement, Party.B)
            ), 
            "Arbitration not requested by both parties."
        );

        setArbitratorResolved(agreement, true);

        emit ArbitratorResolved(uint32(agreementID), resolutionWei);

        agreement.resolution = res;
    }

    /// @notice Request that the arbitrator get involved to settle the disagreement.
    /// Each party needs to pay the full arbitration fee when calling this. However they will be
    /// refunded the full fee if the arbitrator agrees with them.
    /// If one party calls this and the other refuses to, the party who called this function can
    /// eventually call requestDefaultJudgment. 
    function requestArbitration(uint agreementID) external payable {
        AgreementDataETH storage agreement = agreements[agreementID];

        require(agreementIsOpen(agreement), "Agreement not open.");
        require(agreementIsLockedIn(agreement), "Agreement not locked in.");
        require(agreement.arbitratorAddress != address(0), "Arbitration is disallowed.");
        require(msg.value == toWei(agreement.disputeFee), "Arbitration fee amount is incorrect.");

        Party callingParty = getCallingParty(agreement);
        require(
            RESOLUTION_NULL != partyResolution(agreement, callingParty), 
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
    }

    /// @notice Allow the arbitrator to indicate they're working on the dispute by withdrawing the
    /// funds. We can't prevent dishonest arbitrator from taking funds without doing work, because
    /// they can always call 'rule' quickly. So just avoid the case where we send funds to a
    /// nonresponsive arbitrator.
    function withdrawDisputeFee(uint agreementID) external {
        AgreementDataETH storage agreement = agreements[agreementID];

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
                agreement.partyAResolution, 
                agreement.partyBResolution, 
                Party.A
            ),
            "partyA and partyB already resolved their dispute."
        );
        require(!arbitratorWithdrewDisputeFee(agreement), "Already withdrew dispute fee.");

        setArbitratorWithdrewDisputeFee(agreement, true);

        emit DisputeFeeWithdrawn(uint32(agreementID));

        msg.sender.transfer(toWei(agreement.disputeFee));
    }

    // -------------------------------------------------------------------------------------------
    // ----------------------------- internal helper functions -----------------------------------
    // -------------------------------------------------------------------------------------------

    /// @dev This function is NOT untrusted in this contract.
    /// @return whether the given party has paid the arbitration fee in full. 
    function partyFullyPaidDisputeFee_SometimesUntrusted(
        uint, /*agreementID is unused in this version*/ 
        AgreementDataETH storage agreement, 
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
        AgreementDataETH storage agreement, 
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
            return toWei(agreement.disputeFee);
        }

        // Beyond this point we know that both parties paid the full arbitration fee.
        // This implies they've also both resolved.

        // If the arbitrator didn't resolve or withdraw, that means they weren't paid. 
        // And they can never be paid, because we'll only call this function after a final 
        // resolution has been determined. So we should get our fee back.
        if (!arbitratorResolved(agreement) && !arbitratorWithdrewDisputeFee(agreement)) {
            return toWei(agreement.disputeFee);
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
                agreement.partyAResolution, 
                agreement.partyBResolution, 
                Party.A
            )
        ) { 
            if (partyResolvedLast(agreement, party)) {
                return 0;
            } else {
                return toWei(agreement.disputeFee); 
            }
        }

        // Beyond this point we know A and B's resolutions are incompatible. If either of them
        // agree with the arbiter they should get a refund, leaving the other person with nothing.
        if (
            resolutionsAreCompatibleBothExist(
                partyResolution(agreement, party), 
                agreement.resolution, 
                party
            )
        ) {
            return toWei(agreement.disputeFee);
        }

        if (
            resolutionsAreCompatibleBothExist(
                partyResolution(agreement, otherParty), 
                agreement.resolution, 
                otherParty
            )
        ) {
            return 0;
        }

        // A and B's resolutions are different but both incompatible with the overall resolution. 
        // Neither party was "right", so they can both split the dispute fee.
        return toWei(agreement.disputeFee/2);
    }
}