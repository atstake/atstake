pragma solidity 0.5.8;

import "./AgreementManagerERC20.sol";
import "./ERC792ArbitrationInterface.sol";

/**
    @notice
    See AgreementManager for comments on the overall nature of this contract.

    This is the contract defining how ERC20 agreements with ERC792 arbitration work.

    @dev
    The relevant part of the inheritance tree is:
    AgreementManager
        AgreementManagerERC20
            AgreementManagerERC20_ERC792

    We also inherit from ERC792ArbitrationInterface, a very simple interface that lets us avoid
    a small amount of code duplication for ERC792 arbitration.

    Notes on reentrancy: The only non-ERC20 external calls are Arbitrator.arbitrationCost and
    Arbitrator.createDispute. The PENDING_EXTERNAL_CALL variable is used to guard these calls, and
    block calls to this contract's sensitive functions while PENDING_EXTERNAL_CALL is set.
    We don't introduce new ERC20 calls with requestArbitration, because ERC792 arbitration can
    only be requested using ETH (if this ever changes, a modified version of this contract should
    be heavily reviewed).
    The only functions that indirectly call arbitrationCost or createDispute require the agreement
    to be 'locked in', so we don't need to protect functions that aren't callable after the
    agreement is locked in (like earlyWithdrawA and depositB)

    For ease of review, functions that call untrusted external functions (even via multiple calls)
    will have "_Untrusted" or "_SometimesUntrusted" appended to the function name, except if that
    function is directly callable by an external party.
*/

contract AgreementManagerERC20_ERC792 is AgreementManagerERC20, ERC792ArbitrationInterface {
    // -------------------------------------------------------------------------------------------
    // ----------------------------------- constructor -------------------------------------------
    // -------------------------------------------------------------------------------------------

    constructor() public {
        // We don't want agreementID 0 to be valid, since the map of disputeIDs to agreementIDs
        // will map to 0 if the dispute ID doesn't exist.
        AgreementDataERC20 memory dummyAgreement;
        agreements.push(dummyAgreement);
    }

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
        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];

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
            arbData.weiPaidIn[uint(Party.A)],
            arbData.weiPaidIn[uint(Party.B)],
            arbData.weiPaidToArbitrator,
            arbData.disputeID
        ];
        bool[11] memory boolVals = [
            partyStakePaid(agreement, Party.A),
            partyStakePaid(agreement, Party.B),
            partyRequestedArbitration(agreement, Party.A),
            partyRequestedArbitration(agreement, Party.B),
            partyReceivedDistribution(agreement, Party.A),
            partyReceivedDistribution(agreement, Party.B),
            partyAResolvedLast(agreement),
            arbitratorResolved(agreement),
            arbitratorWithdrewDisputeFee(agreement),
            true, // Indicates whether this uses ERC792 arbitration
            arbData.disputeCreated
        ];
        bytes memory bytesVal = arbitrationExtraData[agreementID];

        return (addrs, uints, boolVals, bytesVal);
    }

    // -------------------------------------------------------------------------------------------
    // -------------------- main external/public functions that affect state ---------------------
    // -------------------------------------------------------------------------------------------

    /// @notice The function that an ERC792 arbitration service calls to report their resolution.
    /// Can only be called after a dispute is created, which only happens if arbitration is
    /// requested by both parties.
    /// Note that this function doesn't automatically distribute funds, so parties will need to
    /// manually call 'withdraw' after an ERC792 ruling. The reason is that we can't be sure that
    /// an ERC792 arbitrator will be able to call 'rule' again if funds distribution fails.
    /// @param dispute_id the dispute id that was returned when we called Arbitrator.createDispute
    /// @param ruling The ruling of the arbitration service. The interpretation of the possible
    /// rulings should have been given in the MetaEvidence event that was emitted when the
    /// agreement was created
    function rule(uint dispute_id, uint ruling) public {
        uint agreementID = disputeToAgremeentID[msg.sender][dispute_id];
        require(agreementID > 0, "Dispute doesn't correspond to a valid agreement.");

        AgreementDataERC20 storage agreement = agreements[agreementID];

        require(!pendingExternalCall(agreement), "Reentrancy protection is on.");
        require(agreementIsOpen(agreement), "Agreement not open.");
        require(agreementIsLockedIn(agreement), "Agreement not locked in.");

        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];

        require(arbData.disputeCreated, "Arbitration not requested.");
        require(ruling <= NUM_STANDARD_RESOLUTION_TYPES, "Ruling out of range.");

        setArbitratorResolved(agreement, true);

        emit Ruling(Arbitrator(msg.sender), dispute_id, ruling);

        // We only allow a set of predefined resolutions for ERC792 arbitration services for now.
        if (ruling == uint(PredefinedResolution.None)) {
            // Do nothing. We already updated state with setArbitratorResolved.
            // Resolving as None can be interpreted as the arbitrator refusing to rule.
        } else if (ruling == uint(PredefinedResolution.Refund)) {
            finalizeResolution(
                agreementID,
                agreement,
                agreement.partyAStakeAmount,
                0,
                false
            );
        } else if (ruling == uint(PredefinedResolution.EverythingToA)) {
            finalizeResolution(
                agreementID,
                agreement,
                agreement.partyAStakeAmount,
                agreement.partyBStakeAmount,
                false
            );
        } else if (ruling == uint(PredefinedResolution.EverythingToB)) {
            finalizeResolution(
                agreementID,
                agreement,
                0,
                0,
                false
            );
        } else if (ruling == uint(PredefinedResolution.Swap)) {
            finalizeResolution(
                agreementID,
                agreement,
                0,
                agreement.partyBStakeAmount,
                false
            );
        } else if (ruling == uint(PredefinedResolution.FiftyFifty)) {
            finalizeResolution(
                agreementID,
                agreement,
                agreement.partyAStakeAmount/2,
                agreement.partyBStakeAmount/2,
                false
            );
        } else {
            require(false, "Hit unreachable code in rule.");
        }
    }

    /// @notice Request that the ERC792 arbitrator get involved to settle the disagreement.
    /// A dispute will be created immediately once both parties pay the full arbitration fee.
    /// The parties will be refunded the full fee if the arbitrator agrees with them.
    /// The logic of this function is somewhat tricky, because fees can rise in between the time
    /// that the two parties call this. We allow parties to overpay this fee if they like, to be
    /// ready for any possible fee increases. Any unused overpayment will be refunded.
    /// If one party calls this and the other refuses to, the party who called this function can
    /// eventually call requestDefaultJudgment.
    function requestArbitration(uint agreementID) external payable {
        AgreementDataERC20 storage agreement = agreements[agreementID];

        require(!pendingExternalCall(agreement), "Reentrancy protection is on..");
        require(agreementIsOpen(agreement), "Agreement not open.");
        require(agreementIsLockedIn(agreement), "Agreement not locked in.");
        require(agreement.arbitratorAddress != address(0), "Arbitration is disallowed.");

        (Party callingParty, Party otherParty) = getCallingPartyAndOtherParty(agreement);

        require(
            !partyResolutionIsNull(agreement, callingParty),
            "Need to enter a resolution before requesting arbitration."
        );

        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];

        // We don't allow appeals yet, so once a dispute is created its result is final.
        require(!arbData.disputeCreated, "Dispute already created.");

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

        // Currently ERC792 doesn't support payment in ERC20 tokens, so assume ETH. We 'require'
        // this in createAgreementA
        arbData.weiPaidIn[uint(callingParty)] = add(
            arbData.weiPaidIn[uint(callingParty)],
            msg.value
        );
        uint arbitrationFee = standardArbitrationFee_Untrusted(
            agreement,
            arbitrationExtraData[agreementID]
        );

        require(
            arbData.weiPaidIn[uint(callingParty)] >= arbitrationFee,
            "Arbitration payment was not enough."
        );

        if (arbData.weiPaidIn[uint(otherParty)] >= arbitrationFee) {
            // Both parties have paid at least the arbitrationFee, so create a dispute.
            arbData.disputeCreated = true;
            arbData.weiPaidToArbitrator = arbitrationFee;
            arbData.disputeID = createDispute_Untrusted(
                agreement,
                NUM_STANDARD_RESOLUTION_TYPES,
                arbitrationExtraData[agreementID],
                arbitrationFee
            );
            disputeToAgremeentID[agreement.arbitratorAddress][arbData.disputeID] = agreementID;
            emit Dispute(
                Arbitrator(agreement.arbitratorAddress),
                arbData.disputeID,
                agreementID,
                agreementID
            );
        } else {
            // The other party hasn't paid the full arbitration fee yet. This might be because
            // they previously paid it but the fee has increased since they did so. We need to
            // determine whether to extend the time allowed for the other party to pay.
            // We extend the time only when the calling party's dispute fee has 'leapfrogged' the
            // dispute fee paid by the other party. This means the other party will only get
            // extensions when the situation in which the calling party has paid more than them
            // is "new."
            uint balanceBeforePayment = sub(arbData.weiPaidIn[uint(callingParty)], msg.value);
            if (balanceBeforePayment <= arbData.weiPaidIn[uint(otherParty)]) {
                updateArbitrationResponseDeadline(agreement);
            }
        }
    }

    // -------------------------------------------------------------------------------------------
    // ----------------------------- internal helper functions -----------------------------------
    // -------------------------------------------------------------------------------------------

    /// @dev This is a no-op in this version of the contract. It exists because we use inheritance
    function storeArbitrationExtraData(uint agreementID, bytes memory arbExtraData) internal {
        arbitrationExtraData[agreementID] = arbExtraData;
     }

    /// @notice Enforce that the arbitrator must be paid in ETH
    function checkContractSpecificConditionsForCreation(address arbitratorToken) internal {
        require(
            arbitratorToken == address(0),
            "Must pay arbitrator in ETH when using ERC792 arbitration"
        );
    }

    /// @dev This function is untrusted in this contract.
    /// @return whether the given party has paid the arbitration fee in full.
    function partyFullyPaidDisputeFee_SometimesUntrusted(
        uint agreementID,
        AgreementDataERC20 storage agreement,
        Party party
    )
        internal
        returns (bool)
    {
        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];
        if (arbData.disputeCreated) {
            return true;
        }
        uint arbitrationFee = standardArbitrationFee_Untrusted(
            agreement,
            arbitrationExtraData[agreementID]
        );
        return arbData.weiPaidIn[uint(party)] >= arbitrationFee;
    }

    /// @notice Get the arbitration cost for a dispute
    /// @dev The call to the external function 'arbitrationCost' is untrusted, so we need to wrap
    /// it in a reentrancy guard.
    /// @param extraData is some data that the arbitration service should understand. It may
    /// control what type of arbitration is being requested, so the fee can vary based on it.
    function standardArbitrationFee_Untrusted(
        AgreementDataERC20 storage agreement,
        bytes memory extraData
    )
        internal
        returns (uint)
    {
        // Unsafe external call. Using reentrancy guard.
        setPendingExternalCall(agreement, true);
        uint cost = Arbitrator(agreement.arbitratorAddress).arbitrationCost(extraData);
        setPendingExternalCall(agreement, false);

        return cost;
    }

    /// @notice Create a dispute using the ERC792 standard, assuming that
    /// agreement.arbitratorAddress is an arbitration service that conforms to this standard.
    /// The arbitration service will associate our request with the text of the agreement using
    /// the MetaEvidence event that we emitted when the agreement was created.
    /// @dev The call to the external function 'createDispute' is untrusted, so we need to wrap it
    /// in a reentrancy guard.
    /// @param nChoices The number of choices that we're giving to the arbitration service for how
    /// to rule on the dispute.
    /// @param extraData Details about how the dispute should be arbitrated. Sent in whatever
    /// format the arbitration service understands.
    /// @return An ID given to our dispute by the arbitration service.
    function createDispute_Untrusted(
        AgreementDataERC20 storage agreement,
        uint nChoices,
        bytes memory extraData,
        uint arbFee
    )
        internal
        returns (uint)
    {
        // Unsafe external call. Using reentrancy guard.
        setPendingExternalCall(agreement, true);
        uint disputeID = Arbitrator(
            agreement.arbitratorAddress
        ).createDispute.value(arbFee)(nChoices, extraData);
        setPendingExternalCall(agreement, false);

        return disputeID;
    }

    /// @return Whether the party provided is closer to winning a default judgment than the other
    /// party. For ERC792 arbitration, this means that they'd paid the arbitration fee
    /// and the other party hasn't, or if they've paid more arbitration fees than the other party.
    function partyIsCloserToWinningDefaultJudgment(
        uint agreementID,
        AgreementDataERC20 storage agreement,
        Party party
    )
        internal
        returns (bool)
    {
        if (partyRequestedArbitration(agreement, party)) {
            Party otherParty = getOtherParty(party);
            if (!partyRequestedArbitration(agreement, otherParty)) {
                return true;
            }
            ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];
            return !arbData.disputeCreated &&
                arbData.weiPaidIn[uint(party)] > arbData.weiPaidIn[uint(otherParty)];
        }
        return false;
    }

    /// @notice See comments in AgreementManagerETH to understand the goal of this
    /// important function. Note that parties might have overpaid their arbitration fees when
    /// using ERC792 arbitration.
    function getPartyArbitrationRefundInWei(
        uint agreementID,
        AgreementDataERC20 storage agreement,
        Party party
    )
        internal
        view
        returns (uint)
    {
        if (!partyRequestedArbitration(agreement, party)) {
            // party didn't pay an arbitration fee, so gets no refund.
            return 0;
        }

        // Now we know party paid an arbitration fee, so figure out how much of it they get back.

        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];

        if (partyDisputeFeeLiability(agreement, party)) {
            // party has liability for the dispute fee. The only question is whether they
            // pay the full amount or half.
            Party otherParty = getOtherParty(party);
            if (partyDisputeFeeLiability(agreement, otherParty)) {
                // Pay half. We add one before the division to round up, so that the refund
                // amount is rounded down.
                return sub(
                    arbData.weiPaidIn[uint(party)],
                    add(arbData.weiPaidToArbitrator, 1)/2
                ); // half fee
            }
            return sub(arbData.weiPaidIn[uint(party)], arbData.weiPaidToArbitrator); // full fee
        }
        // No liability -- full refund
        return arbData.weiPaidIn[uint(party)];
    }

    /// @return whether the arbitrator has either already gotten or is entitled to withdraw
    /// the dispute fee
    function arbitratorGetsDisputeFee(
        uint agreementID,
        AgreementDataERC20 storage /*agreement*/
    )
        internal
        returns (bool)
    {
        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];
        return arbData.disputeCreated;
    }
}
