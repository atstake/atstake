pragma solidity 0.5.3;

import "./Arbitrable.sol";
import "./Arbitrator.sol";

/**
    @notice A contract that AgreementManagers that implement ERC792 arbitration can inherit from.
*/

contract ERC792ArbitrationInterface is Arbitrable {
    // -------------------------------------------------------------------------------------------
    // --------------------------------- special values ------------------------------------------
    // -------------------------------------------------------------------------------------------

    // Agreements using the ERC792 arbitration standard can only have resolutions which fit a list
    // of predefined outcomes. The resolution names below should be pretty self explanatory,
    // except the last two:
    //  Swap means A gets B's deposit and vice versa
    //  FiftyFifty means the sum of stakes is split evenly between A and B.
    enum PredefinedResolution { None, Refund, EverythingToA, EverythingToB, Swap, FiftyFifty }
    // 'None' isn't a real resolution type, so we have 5 types. When we pass in this value to
    // the ERC792 arbitration service, it will interpret 1, 2, ..., NUM_STANDARD_RESOLUTION_TYPES
    // as valid rulings, and 0 as a refusal to rule.
    uint constant NUM_STANDARD_RESOLUTION_TYPES = 5;

    // ArbitrationData is created only when the parties create a dispute with ERC792 style
    // arbitration. If the parties are using "normal" arbitration, all the relevant data is kept
    // in the AgreementData struct, and ArbitrationData is not used.
    // Unlike our other internal data, amounts are stored in wei for arbitration data.
    struct ArbitrationData {
        uint[2] weiPaidIn;
        uint weiPaidToArbitrator;
        uint disputeID;
        bool disputeCreated;
    }

    // -------------------------------------------------------------------------------------------
    // --------------------------------- internal state ------------------------------------------
    // -------------------------------------------------------------------------------------------


    // If we created an ERC-792 dispute for an agreement, we map the agreementID to its
    // ArbitrationData
    mapping(uint => ArbitrationData) arbitrationDataForAgreement;

    // ERC-792 disputes involve passing in an "extraData" argument to arbitration services. For
    // each agreementID we store the extraData that tells the arbitration service any extra info
    // it needs about the type of arbitration that we want.
    mapping(uint => bytes) arbitrationExtraData;

    // When we get a 'ruling' from an ERC-792 arbitrator, they'll only pass back the disputeID.
    // We need this mapping so we can find the agreement corresponding to that disputeID.
    mapping(address => mapping(uint => uint)) disputeToAgreementID;
}
