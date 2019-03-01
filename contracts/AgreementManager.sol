pragma solidity 0.5.3;

import "./SafeUtils.sol";
import "./Arbitrable.sol";
import "./Arbitrator.sol";
import "./EvidenceProducer.sol";

// AgreementManager allows two parties (A and B) to represent some sort of agreement that involves 
// staking ETH. The general flow is: they both deposit a stake (they can withdraw until both stakes have been 
// deposited), then their agreement is either fulfilled or not based on actions outside of this contract, then
// either party can "resolve" by specifying how they think funds should be split based on each party's
// actions in relation to the agreement terms. If the parties disagree, they can summon a predefined arbitrator
// to settle their dispute.

// Notes on reentrancy: the only external calls are Arbitrator.arbitrationCost and Arbitrator.createDispute. 
// The PREVENT_REENTRANCY variable is used to guard these calls, and block calls to this contract's
// sensitive functions while PREVENT_REENTRANCY is set. 
// The only functions that indirectly call arbitrationCost or createDispute require the agreement to be
// 'locked in', so we don't need to protect functions that aren't callable after the agreement is locked in
// (like earlyWithdrawalA and depositB)
// For ease of review, functions that call untrusted external functions (even via multiple calls) will have 
// "_Untrusted" appended to the function name, except if that function is directly callable by an external party.

contract AgreementManager is SafeUtils, Arbitrable, EvidenceProducer{
    // ---------------------------------
    // -------- special values
    // --------------------------------

    // We store ETH amounts in millionths of ETH, not Wei. 
    // So we need to do conversions using this factor. 
    // 10^6 * 10^12 = 10^18, the number of wei in one Ether
    uint constant ETH_AMOUNT_ADJUST_FACTOR = 1000*1000*1000*1000;

    // When the parties to an agreement report the outcome, they enter a "resolution", which is the
    // amount of wei that party A should get. Party B is understood to get the remaining wei.
    // RESOLUTION_NULL is a special value indicating "no resolution has been entered yet".
    uint48 constant RESOLUTION_NULL = uint48(0xffffffffffff); // 48 bits

    // Use the constants A and B as shorthand for "party A" and "party B", the two parties to the contract.
    uint constant A = 0; 
    uint constant B = 1;

    // Agreements using the ERC792 arbitration standard can only have resolutions which fit a list of
    // predefined outcomes. The resolution names below should be pretty self explanatory, except the last two:
    // Swap means A gets B's deposit and vice versa
    // FiftyFifty means the sum of stakes is split evenly between A and B.
    enum PredefinedResolution { None, Refund, EverythingToA, EverythingToB, Swap, FiftyFifty }
    uint constant NUM_STANDARD_RESOLUTION_TYPES = 5;

    // ---------------------------------
    // Offsets for AgreementData.boolValues
    // --------------------------------
    // We pack all of our bool values into a uint32 for gas cost optimization.
    // Each constant below represents a "virtual" boolean variable. 
    // These are the offets into that uint32 (AgreementData.boolValues) 
    uint constant PARTY_A_STAKE_PAID = 0; // Has party A fully paid their stake?
    uint constant PARTY_B_STAKE_PAID = 1; // Has party B fully paid their stake?
    uint constant PARTY_A_REQUESTED_ARBITRATION = 2; // Has party A requested arbitration?
    uint constant PARTY_B_REQUESTED_ARBITRATION = 3; // Has party B requested arbitration?
    uint constant PARTY_A_WITHDREW = 4; // Did party A withdraw their funds?
    uint constant PARTY_B_WITHDREW = 5; // Did party B withdraw their funds?
    // PARTY_A_RESOLVED_LAST is used to detect certain bad behavior where a party will first 
    // resolve to a "bad" value, wait for their counterparty to summon an arbitrator, and then
    // resolve to the correct value to avoid having the arbitator rule against them.
    // At any point where the arbitrator has been paid before the dishonest party switches to a
    // reasonable ruling, we want the person who switched to the eventually official ruling last to
    // be the one to pay the arbitration fee.  
    uint constant PARTY_A_RESOLVED_LAST = 6;
    uint constant ARBITRATOR_RESOLVED = 7; // Did the arbitrator enter a resolution?
    uint constant ARBITRATOR_WITHDREW_DISPUTE_FEE = 8; // Did the arbitrator withdraw the dispute fee?
    // The ERC 792 standard defines a protocol for how disputes are handled. It allows our contract to work
    // with services such as Kleros. This contract can work in two modes: standard arbitration (for Kleros), and
    // normal/simple arbitration, where the arbitrator is generally just an external ETH address instead of a 
    // full fledged arbitration service.
    uint constant USING_ARBITRATION_STANDARD = 9;
    // We use this flag internally to guard against reentrancy attacks.
    uint constant PREVENT_REENTRANCY = 10;

    // ---------------------------------
    // -------- struct definitions
    // --------------------------------

    // Whenever an agreement is created, we store its state in an AgreementData object.
    // The variables are arranged so that the compiler can easily "pack" them into 4 uint256s 
    // under the hood. Look at the comments for createAgreementA to see what all these 
    // variables represent.
    // Spacing shows the uint256 words that we expect these to be packed in.
    struct AgreementData {
        // Put the data that can change all in the first "uint" slot, for gas cost optimization.

        uint48 partyAResolution; // Resolution for partyA
        uint48 partyBResolution; // Resolution for partyB
        // An agreement can be created with an optional "automatic" resolution, which either party
        // can trigger after autoResolveAfterTimestamp.
        uint48 automaticResolution; 
        // Resolution holds the "official, final" resolution of the agreement. Once this
        // value has been set, it means the agreement is over and funds can be withdrawn.
        uint48 resolution;
        // nextArbitrationStepAllowedAfterTimestamp is the most complex state variable, as we needed
        // to keep the contract small to save gas cost.
        // Initially it represents the timestamp after which the parties are allowed to request arbitration.
        // Once arbitration is requested the first time, it represents how long the party who hasn't yet
        // requested arbitration (or fully paid for arbitration in the case of ERC 792 arbitration) has until they
        // lose via a "default judgment" (aka lose the dispute simply because they didn't post the arbitration fee)
        uint32 nextArbitrationStepAllowedAfterTimestamp;
        // A bitmap that holds all of our "virtual" bool values. 
        // See the offsets for bool values defined above for a list of the boolean info we store.
        uint32 boolValues; 

        
        address partyAAddress; // ETH address of party A
        uint48 partyAStakeAmount; // Amount that party A is required to stake
        // An optional arbitration fee that is sent to the arbitrator's ETH address once
        // both parties have deposited their stakes.
        uint48 partyAInitialArbitratorFee;
        
        address partyBAddress; // ETH address of party B
        uint48 partyBStakeAmount; // Amount that party B is required to stake
        // An optional arbitration fee that is sent to the arbitrator's ETH address once
        // both parties have deposited their stakes.
        uint48 partyBInitialArbitratorFee;
        
        address arbitratorAddress; // ETH address of Arbitrator
        uint48 disputeFee; // Fee paid to the arbitrator only if there's a dispute and they must do work.
        // The timestamp after which either party can trigger the "automatic resolution".
        // This can only be triggered if no one has requested arbitration.
        uint32 autoResolveAfterTimestamp;
        // The # of days that the other party has to respond to an arbitration request from the other party.
        // If they fail to respond in time, the other party can trigger a default judgment.
        uint16 daysToRespondToArbitrationRequest;
    }

    // ArbitrationData is created only when the parties create a dispute with ERC792 style arbitration. 
    // If the parties are using "normal" arbitration, all the relevant data is kept in the 
    // AgreementData struct, and ArbitrationData is not used. 
    // Unlike our other internal data, amounts are stored in wei for arbitration data.
    struct ArbitrationData{
        uint[2] weiPaidIn;
        uint weiPaidToArbitrator;
        uint disputeID;
        bool disputeCreated;
    }

    // ---------------------------------
    // -------- internal state
    // --------------------------------

    // We store our agreements in a single array. When a new agreement is created we add it to the end.
    // The index into this array is the agreementID.
    // Agreements not having ERC792 disputes will only use an element in the agreements array for their state.
    AgreementData[] agreements;

    // If we created an ERC-792 dispute for an agreement, we map the agreementID to its ArbitrationData
    mapping(uint => ArbitrationData) arbitrationDataForAgreement; 
    // ERC-792 disputes involve passing in an "extraData" argument to arbitration services. For each agreementID
    // we store the extraData that tells the arbitration service any extra info it needs about the type of arbitration.
    // that we want.
    mapping(uint => bytes) arbitrationExtraData; 
    // When we get a 'ruling' from an ERC-792 arbitrator, they'll only pass back the disputeID. We need this mapping
    // so we can find the agreement corresponding to that disputeID.
    mapping(address => mapping(uint => uint)) disputeToAgremeentID; 

    // --------------------------------
    // -------- events
    // --------------------------------

    // This event is used to link the agreementID to the hash of the agreement, so the written agreement terms can be 
    // associated with this Ethereum agreement.
    event AgreementCreated(
        address sender,
        uint agreementID,
        bytes32 hashOfAgreement
    );

    // --------------------------------------------
    // ---- internal getter and setter functions
    // --------------------------------------------

    // Return the value of one of our "virtual" bool values stored in our boolValues bitmask.
    function getBool(AgreementData storage agreement, uint offset) internal view returns (bool){
        return ((agreement.boolValues >> offset) & 1) == 1;
    }

    // Set the value of one of our "virtual" bool values stored in our boolValues bitmask.
    function setBool(uint32 field, uint offset, bool value) internal pure returns (uint32){
        if(value){
            return field | uint32(1 << offset);
        } else{
            return field ^ uint32(1 << offset);
        }
    }

    // Functions that simulate direct access to AgreementData state variables.
    // These are used either for bools (where we need to use a bitmask), or for
    // functions when we need to vary between party A/B depending on the argument.
    // The later is necessary because the solidity compiler can't pack structs well when their elements
    // are arrays. So we can't just index into an array.

    // Some getter functions
    function partyResolution(AgreementData storage agreement, uint party) internal view returns (uint48){
        if(party == A) return agreement.partyAResolution;
        else return agreement.partyBResolution;
    }
    function partyStakePaid(AgreementData storage agreement, uint party) internal view returns (bool){
        if(party == A) return getBool(agreement, PARTY_A_STAKE_PAID);
        else return getBool(agreement, PARTY_B_STAKE_PAID);
    }
    function partyRequestedArbitration(AgreementData storage agreement, uint party) internal view returns (bool){
        if(party == A) return getBool(agreement, PARTY_A_REQUESTED_ARBITRATION);
        else return getBool(agreement, PARTY_B_REQUESTED_ARBITRATION);
    }
    function partyWithdrew(AgreementData storage agreement, uint party) internal view returns (bool){
        if(party == A) return getBool(agreement, PARTY_A_WITHDREW);
        else return getBool(agreement, PARTY_B_WITHDREW);
    }
    function partyAResolvedLast(AgreementData storage agreement) internal view returns (bool){
        return getBool(agreement, PARTY_A_RESOLVED_LAST);
    }
    function arbitratorResolved(AgreementData storage agreement) internal view returns (bool){
        return getBool(agreement, ARBITRATOR_RESOLVED);
    }
    function arbitratorWithdrewDisputeFee(AgreementData storage agreement) internal view returns (bool){
        return getBool(agreement, ARBITRATOR_WITHDREW_DISPUTE_FEE);
    }
    function usingArbitrationStandard(AgreementData storage agreement) internal view returns (bool){
        return getBool(agreement, USING_ARBITRATION_STANDARD);
    }
    function preventReentrancy(AgreementData storage agreement) internal view returns (bool){
        return getBool(agreement, PREVENT_REENTRANCY);
    }

    // Some setter functions.
    function setPartyResolution(AgreementData storage agreement, uint party, uint48 value) internal{
        if(party == A) agreement.partyAResolution = value;
        else agreement.partyBResolution = value;
    }
    function setPartyStakePaid(AgreementData storage agreement, uint party, bool value) internal{
        if(party == A) agreement.boolValues = setBool(agreement.boolValues, PARTY_A_STAKE_PAID, value);
        else agreement.boolValues = setBool(agreement.boolValues, PARTY_B_STAKE_PAID, value);
    }
    function setPartyRequestedArbitration(AgreementData storage agreement, uint party, bool value) internal{
        if(party == A) agreement.boolValues = setBool(agreement.boolValues, PARTY_A_REQUESTED_ARBITRATION, value);
        else agreement.boolValues = setBool(agreement.boolValues, PARTY_B_REQUESTED_ARBITRATION, value);
    }
    function setPartyWithdrew(AgreementData storage agreement, uint party, bool value) internal{
        if(party == A) agreement.boolValues = setBool(agreement.boolValues, PARTY_A_WITHDREW, value);
        else agreement.boolValues = setBool(agreement.boolValues, PARTY_B_WITHDREW, value);
    }
    function setPartyAResolvedLast(AgreementData storage agreement, bool value) internal{
        agreement.boolValues = setBool(agreement.boolValues, PARTY_A_RESOLVED_LAST, value);
    }
    function setArbitratorResolved(AgreementData storage agreement, bool value) internal{
        agreement.boolValues = setBool(agreement.boolValues, ARBITRATOR_RESOLVED, value);
    }
    function setArbitratorWithdrewDisputeFee(AgreementData storage agreement, bool value) internal{
        agreement.boolValues = setBool(agreement.boolValues, ARBITRATOR_WITHDREW_DISPUTE_FEE, value);
    }
    function setPreventReentrancy(AgreementData storage agreement, bool value) internal{
        agreement.boolValues = setBool(agreement.boolValues, PREVENT_REENTRANCY, value);
    }


    // ---------------------------------
    // -------- modifiers
    // --------------------------------

    // See agreementIsOpen comments
    modifier onlyOpen(uint agreementID) {
        require(agreementIsOpen(agreementID), "Agreement not open.");
        _;
    }

    // See agreementIsOpen comments
    modifier onlyLockedIn(uint agreementID) {
        require(agreementIsLockedIn(agreementID), "Agreement not locked in.");
        _;
    }

    // The opposite of onlyOpen
    modifier onlyClosed(uint agreementID) {
        require(!agreementIsOpen(agreementID), "Agreement not closed.");
        _;
    }

    // ---------------------------------
    // -------- helper functions
    // --------------------------------

    // We store ETH/token amounts in uint48s demoninated in "millionths of ETH".
    // resolutionToWei converts from our internal representation to the wei amount.
    // It's different from "toWei" because it's for "resolution" values which might
    // have a special value of RESOLUTION_NULL, which we need to handle separately.
    function toWei(uint millionthValue) internal pure returns (uint){
        return mul(millionthValue, ETH_AMOUNT_ADJUST_FACTOR);
    }
    // Like toWei but resolutionToWei is for "resolution" values which might
    // have a special value of RESOLUTION_NULL, which we need to handle separately.
    function resolutionToWei(uint millionthValue) internal pure returns (uint){
        if(millionthValue == RESOLUTION_NULL){
            return uint(~0);
        }
        return mul(millionthValue, ETH_AMOUNT_ADJUST_FACTOR);
    }
    // Convert a value expressed in wei to our internal representation in "millionths of ETH"
    function toMillionth(uint weiValue) internal pure returns (uint48){
        return toUint48(weiValue / ETH_AMOUNT_ADJUST_FACTOR);
    }

    // Requires that the caller be party A or party B. Returns whichever party the caller is.
    function getParty(AgreementData storage agreement) internal view returns (uint){
        if(msg.sender == agreement.partyAAddress){
            return A;
        } else if(msg.sender == agreement.partyBAddress){
            return B;
        } else{
            require(false, "getParty must be called by a party to the agreement.");
        }
    }

    // Requires that the caller be party A or party B, and returns the "other" party.
    function getOtherParty(uint partyIndex) internal pure returns (uint){
        require(partyIndex == A || partyIndex == B, "Bad party index.");
        if(partyIndex == A){
            return B;
        }
        return A;
    }

    // Returns the calling party first and the "other party" second.
    function getParties(AgreementData storage agreement) internal view returns (uint, uint){
        if(msg.sender == agreement.partyAAddress){
            return (A, B);
        } else if(msg.sender == agreement.partyBAddress){
            return (B, A);
        } else{
            require(false, "getParties must be called by a party to the agreement.");
        }
    }

    // This function assumes that at least one person has resolved.
    // Return whichever party was the last to submit a resolution.
    function partyResolvedLast(AgreementData storage agreement, uint party) internal view returns (bool){
        if(partyAResolvedLast(agreement)){
            return party == A;
        }
        return party == B;
    }

    // Test whether res1 and res2 are compatible, given that res1 is given by party res1Party..
    // Compatible means that they don't disagree in a selfish direction. 
    // Assumes that res1 and res2 are not RESOLUTION_NULL
    function resolutionsAreCompatible(uint res1, uint res2, uint res1Party) internal pure returns (bool){
        if(res1Party == A){
            return res1 <= res2;
        } else{
            return res1 >= res2;
        }
    }

    // Safely create a dispute using the ERC792 standard. The call to the external function 'createDispute' is untrusted,
    // so we need to wrap it in a reentrancy guard.
    // We tell the arbitation service how many choices it has and send extraData to tell it details about how the arbitration
    // should be done. The arbitration service will associate our request with the text of the agreement using the 
    // MetaEvidence event that we emitted when the dispute was created. 
    function createDispute_Untrusted(AgreementData storage agreement, uint nChoices, bytes memory extraData, uint arbFee) internal returns (uint){
        // Unsafe external call. Using reentrancy guard.
        setPreventReentrancy(agreement, true);
        uint disputeID = Arbitrator(agreement.arbitratorAddress).createDispute.value(arbFee)(nChoices, extraData);
        setPreventReentrancy(agreement, false);

        return disputeID;
    }

    // Safely get the arbitration cost for a dispute of the kind specified with extraData.
    // The call to the external function 'arbitrationCost' is untrusted, so we need to wrap it in a reentrancy guard.
    function standardArbitrationFee_Untrusted(AgreementData storage agreement, bytes memory extraData) internal returns (uint){
        // Unsafe external call. Using reentrancy guard.
        setPreventReentrancy(agreement, true);
        uint cost = Arbitrator(agreement.arbitratorAddress).arbitrationCost(extraData);
        setPreventReentrancy(agreement, false);

        return cost;
    }

    // Check whether the given party has paid the full dispute fee. A party will only have
    // paid a nonzero portion of the dispute fee in ERC792 disputes, and only when the fee
    // was increased after they already paid what used to be the full fee.
    function partyFullyPaidDisputeFee_Untrusted(uint agreementID, uint party) internal returns (bool){
        AgreementData storage agreement = agreements[agreementID];
        if(!usingArbitrationStandard(agreement)){
            return partyRequestedArbitration(agreement, party);
        }
        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];
        if(arbData.disputeCreated){
            return true;
        }
        uint arbitrationFee = standardArbitrationFee_Untrusted(agreement, arbitrationExtraData[agreementID]);
        return arbData.weiPaidIn[party] >= arbitrationFee;
    }

    // 'Open' means people should be allowed to take steps toward a future resolution. 
    // An agreement isn't open after it has ended (a final resolution exists), or if
    // someone withdrew their funds before the second party could deposit theirs.
    function agreementIsOpen(uint agreementID) internal view returns (bool){
        AgreementData storage agreement = agreements[agreementID];

        return agreement.resolution == RESOLUTION_NULL &&
            !partyWithdrew(agreement, A) &&
            !partyWithdrew(agreement, B);
    }

    // 'Locked in' means both parties have deposited their stake. It conveys that the agreement is fully 
    // accepted and no one can withdraw without someone else's approval.
    function agreementIsLockedIn(uint agreementID) internal view returns (bool){
        AgreementData storage agreement = agreements[agreementID];
        return partyStakePaid(agreement, A) && partyStakePaid(agreement, B);
    }

    // When both parties have deposited their stakes, the arbitrator is paid any 'initial' arbitration fee
    // that was required. We assume we've already checked that the arbitrator is owed a nonzero amount.
    function payOutInitialArbitratorFee_Untrusted(uint agreementID) internal {
        AgreementData storage agreement = agreements[agreementID];
        
        uint totalInitialFeesWei = toWei(add(agreement.partyAInitialArbitratorFee, agreement.partyBInitialArbitratorFee));

        address(uint160(agreement.arbitratorAddress)).transfer(totalInitialFeesWei);
    }

    // When a party withdraws, they may be owed a refund for any arbitration fee that they've paid in because
    // this contract requires the loser of arbitration to pay the full fee. But since we don't know who the loser
    // will be ahead of time, both parties must pay in the full arbitration amount when requesting arbitration. 
    // This is the trickiest function in the contract, and if it has a bug that overestimates the amount of refunds
    // owed it could cause funds to be drained from the contract. As such, it will be commented extensively.
    // Note that the sum of party A and party B's calls to this function should not exceed disputeFee.
    // We assume we're only calling this function from an agreement with an official resolution.
    // The return value is in millionths of ETH (our internal representation).
    // The logic is slightly different for the ERC792 case, so there's getPartyStandardArbitrationRefundInWei for that.
    function getPartyArbitrationRefund(AgreementData storage agreement, uint party) internal view returns (uint){
        uint otherParty = getOtherParty(party);

        // If the calling party never requested arbitration then they never paid in an arbitration fee,
        // so they should never get an arbitration refund.
        if(!partyRequestedArbitration(agreement, party)){
            return 0;
        }

        // Beyond this point, we know the caller requested arbitration and paid an arbitration fee
        // (if disputeFee was nonzero).

        // If the other party didn't request arbitration, then the arbitrator couldn't have been paid
        // because the arbitrator is only paid when both parties have paid the full arbitration fee. 
        // So in that case the calling party is entitled to a full refund of what they paid in.
        if(!partyRequestedArbitration(agreement, otherParty)){
            return agreement.disputeFee;
        }
        
        // Beyond this point we know that both parties paid the full arbitration fee.
        // This implies they've also both resolved.

        // If the arbitrator didn't resolve or withdraw, that means they weren't paid. 
        // And they can never be paid, because we'll only call this function after a final resolution
        // has been determined. So we should get our fee back.
        if(!arbitratorResolved(agreement) && !arbitratorWithdrewDisputeFee(agreement)){
            return agreement.disputeFee;
        }

        // Beyond this point, we know the arbitrator either was already paid or is entitled to withdraw
        // the full arbitration fee. So party A and party B only have a single arbitration fee to split
        // between themselves. We need to figure out how to split up that fee.
        
        // If A and B have compatible resolutions, then whichever of them resolved latest 
        // should have to pay the full fee (because if they had resolved earlier, the arbitrator would
        // never have had to be called). See comments for PARTY_A_RESOLVED_LAST
        if(resolutionsAreCompatible(agreement.partyAResolution, agreement.partyBResolution, A)){ 
            if(partyResolvedLast(agreement, party)){
                return 0;
            }else{
                return agreement.disputeFee; 
            }
        }

        // Beyond this point we know A and B's resolutions are incompatible. If either of them
        // agree with the arbiter they should get a refund, leaving the other person with nothing.
        if(resolutionsAreCompatible(partyResolution(agreement, party), agreement.resolution, party)){
            return agreement.disputeFee;
        }
        if(resolutionsAreCompatible(partyResolution(agreement, otherParty), agreement.resolution, otherParty)){
            return 0;
        }

        // A and B's resolutions are different but both incompatible with the overall resolution. 
        // Neither party was "right", so they can both split the dispute fee.
        return agreement.disputeFee/2;
    }

    // Same functionality as getPartyArbitrationRefund except for the case of ERC792 arbitration.
    // As with getPartyArbitrationRefund, this function is extremely important so will be heavily commented.
    // One difference is that this function's return value represents wei, not millionths of ETH.
    // Another difference is that parties might have overpaid their arbitration fees when using ERC792 arbitration.
    function getPartyStandardArbitrationRefundInWei(uint agreementID, uint party) internal view returns (uint){
        uint otherParty = getOtherParty(party);

        AgreementData storage agreement = agreements[agreementID];
        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];

        // If a dispute was never created, then the arbitrator was never paid. So everyone should 
        // just get back whatever they paid in.
        if(!arbData.disputeCreated){
            return arbData.weiPaidIn[party];
        }

        // Beyond this point we know the arbitrator has been paid. So party A and party B only have a single arbitration 
        // fee to split between themselves. We need to figure out how to split up that fee.
        
        // If A and B have a compatible resolution, then whichever of them resolved to this value the latest 
        // should have to pay the full fee (because if they had resolved to it earlier, the arbitrator would
        // never have had to be called). See comments for PARTY_A_RESOLVED_LAST
        if(resolutionsAreCompatible(agreement.partyAResolution, agreement.partyBResolution, A)){
            if(partyResolvedLast(agreement, party)){
                return sub(arbData.weiPaidIn[party], arbData.weiPaidToArbitrator);
            }else{
                return arbData.weiPaidIn[party];
            }
        }
        
        // Beyond this point we know A and B's resolutions are incompatible. If either of them
        // agree with the arbiter they should get a refund, leaving the other person with nothing.
        if(resolutionsAreCompatible(partyResolution(agreement, party), agreement.resolution, party)){
            return arbData.weiPaidIn[party]; 
        }
        if(resolutionsAreCompatible(partyResolution(agreement, otherParty), agreement.resolution, otherParty)){
            return sub(arbData.weiPaidIn[party], arbData.weiPaidToArbitrator); 
        }

        // A and B's resolutions are different but unequal to the overall resolution. 
        // Neither party was "right", so they can both split the dispute fee.
        return sub(arbData.weiPaidIn[party], arbData.weiPaidToArbitrator/2);
    }

    // ---------------------------------
    // -------- constructor
    // --------------------------------

    constructor() public {
        // We don't want agreementID 0 to be valid, since the map of disputeIDs to agreementIDs will map
        // to 0 if the dispute ID doesn't exist.
        AgreementData memory dummyAgreement;
        agreements.push(dummyAgreement);
    }

    // ------------------------------------------------------------------
    // --------------- getter functions 
    // -----------------------------------------------------------------

    function getResolutionNull() external pure returns (uint){
        return resolutionToWei(RESOLUTION_NULL);
    }
    function getNumberOfAgreements() external view returns (uint){
        return agreements.length;
    }

    // Return a bunch of arrays representing the entire state of the agreement. 
    function getState(uint agreementID) external view returns (
        address[3] memory, 
        uint[16] memory, 
        bool[11] memory,
        bytes memory){ 

        if(agreementID >= agreements.length){
            address[3] memory zeroAddrs;
            uint[16] memory zeroUints;
            bool[11] memory zeroBools;
            bytes memory zeroBytes;
            return (zeroAddrs, zeroUints, zeroBools, zeroBytes);
        }
        
        AgreementData storage agreement = agreements[agreementID];
        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];

        address[3] memory addrs = [agreement.partyAAddress, agreement.partyBAddress, agreement.arbitratorAddress];
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
            arbData.weiPaidIn[A],
            arbData.weiPaidIn[B],
            arbData.weiPaidToArbitrator,
            arbData.disputeID];
        bool[11] memory boolVals = [
            partyStakePaid(agreement, A),
            partyStakePaid(agreement, B),
            partyRequestedArbitration(agreement, A),
            partyRequestedArbitration(agreement, B),
            partyWithdrew(agreement, A),
            partyWithdrew(agreement, B),
            partyAResolvedLast(agreement),
            arbitratorResolved(agreement),
            arbitratorWithdrewDisputeFee(agreement),
            usingArbitrationStandard(agreement),
            arbData.disputeCreated];
        bytes memory bytesVal = arbitrationExtraData[agreementID];
        
        return (addrs, uints, boolVals, bytesVal);
    }

    // ----------------------------------------------------------------------
    // -------- main external/public functions ------------------------------
    // ----------------------------------------------------------------------

    // Adds a new agreement to the agreements array, returns the agreementID.
    // This is only callable by partyA. So the caller needs to rearrange addresses so that they're partyA.
    // Party A needs to pay their stake as part of calling this function by sending ETH.
    // Inputs:
    // _hashOfAgreement: hash of agreement details. not stored, just emitted in an event.
    // agreementURI: URI to 'metaEvidence' as defined in ERC 1497
    // participants: 
    //      Address of partyA
    //      Address of partyB
    //      Address of arbitrator
    // quantities: 
    //      Amount that party A is staking
    //      Amount that party B is staking
    //      Amount that party A pays arbitrator regardless of whether there's a dispute
    //      Amount that party B pays arbitrator regardless of whether there's a dispute
    //      Fee for arbitrator if there is a dispute 
    //      Amount of wei to go to party A if an automatic resolution is triggered. 
    //      16 bit value, # of days to respond to arbitration request
    //      32 bit timestamp value before which arbitration can't be requested.
    //      32 bit timestamp value after which auto-resolution is allowed if no one requested arbitration. 0 means never.
    // flags: 0 if arbitrator will use simple arbitration, or 1 to use the ERC792 arbitration standard (Kleros)
    // arbExtraData: Data to pass in to ERC792 arbitrator if a dispute is ever created. 
    function createAgreementA(
        bytes32 agreementHash, 
        string calldata agreementURI,
        address[3] calldata participants, 
        uint[9] calldata quantities, 
        uint flags, 
        bytes calldata arbExtraData) external payable returns (uint) {

        require(msg.sender == participants[0], "Only party A can call createAgreementA.");
        require(msg.value == add(quantities[0], quantities[2]), "Payment not correct.");

        // Populate a AgreementData struct with the info provided.
        AgreementData memory agreement;
        agreement.partyAAddress = participants[0];
        agreement.partyBAddress = participants[1];
        agreement.arbitratorAddress = participants[2];
        agreement.partyAResolution = RESOLUTION_NULL;
        agreement.partyBResolution = RESOLUTION_NULL;
        agreement.resolution = RESOLUTION_NULL;
        agreement.partyAStakeAmount = toMillionth(quantities[0]);
        agreement.partyBStakeAmount = toMillionth(quantities[1]);
        agreement.partyAInitialArbitratorFee = toMillionth(quantities[2]);
        agreement.partyBInitialArbitratorFee = toMillionth(quantities[3]);
        agreement.disputeFee = toMillionth(quantities[4]);
        agreement.automaticResolution = toMillionth(quantities[5]);
        agreement.daysToRespondToArbitrationRequest = toUint16(quantities[6]);
        agreement.nextArbitrationStepAllowedAfterTimestamp = toUint32(quantities[7]);
        agreement.autoResolveAfterTimestamp = toUint32(quantities[8]);
        // set boolean values
        uint32 tempBools = setBool(0, PARTY_A_STAKE_PAID, true);
        if(add(quantities[1], quantities[3]) == 0){
            tempBools = setBool(tempBools, PARTY_B_STAKE_PAID, true);
        }
        if((flags & 1) == 1){
            tempBools = setBool(tempBools, USING_ARBITRATION_STANDARD, true);
        }
        agreement.boolValues = tempBools;

        // Add the new agreement to our array and create the agreementID
        uint agreementID = sub(agreements.push(agreement), 1);

        if(arbExtraData.length > 0){
            arbitrationExtraData[agreementID] = arbExtraData;
        }
        
        if(bytes(agreementURI).length > 0){
            // If we're using the evidence standard, emit the agreementURI associated with this agreement.
            emit MetaEvidence(agreementID, agreementURI);
        }
        emit AgreementCreated(msg.sender, agreementID, agreementHash);

        // Pay the arbiter if needed, which happens if B was staking no funds and needed no initial fee, 
        // but there was an initial fee from A.
        if((add(quantities[1], quantities[3]) == 0) && (quantities[2] > 0)){
            payOutInitialArbitratorFee_Untrusted(agreementID);
        }
        return agreementID;
    }

    // Called by PartyB to deposit their stake, locking in the agreement.
    // PartyA already deposited funds in createAgreementA, so we only need a deposit function for partyB.
    function depositB(uint agreementID) external payable onlyOpen(agreementID) {
        AgreementData storage agreement = agreements[agreementID];

        require(msg.sender == agreement.partyBAddress, "Function can only be called by party B.");
        require(!partyStakePaid(agreement, B), "Party B has already deposited their stake.");
        require(partyStakePaid(agreement, A), "Should never get here without party A depositing their stake.");
        require(msg.value == toWei(add(agreement.partyBStakeAmount, agreement.partyBInitialArbitratorFee)), "Party B deposit not enough.");

        setPartyStakePaid(agreement, B, true);

        if(add(agreement.partyAInitialArbitratorFee, agreement.partyBInitialArbitratorFee) > 0){
            payOutInitialArbitratorFee_Untrusted(agreementID);
        }
    }

    // Called to report a resolution of the agreement by a party. 
    // resolutionWei is the amount of wei that the caller thinks should go to party A.
    // The remaining amount of wei staked for this agreement would go to party B.
    function resolveAsParty(uint agreementID, uint resolutionWei) external onlyOpen(agreementID) onlyLockedIn(agreementID) {
        AgreementData storage agreement = agreements[agreementID];

        require(!preventReentrancy(agreement), "Reentrancy protection is on.");

        (uint party, uint otherParty) = getParties(agreement);
        uint48 res = toMillionth(resolutionWei);

        require(res <= add(agreement.partyAStakeAmount, agreement.partyBStakeAmount), "Resolution out of range.");

        // Keep track of who was the last to resolve.. useful for punishing 'late' resolutions.
        if(party == A && !partyAResolvedLast(agreement)){
            setPartyAResolvedLast(agreement, true);
        } else if(party == B && partyAResolvedLast(agreement)){
            setPartyAResolvedLast(agreement, false);
        }

        setPartyResolution(agreement, party, res);

        // Set the official resolution if one party wants to give the other at least as much as
        // they requested, or at least as much as the most they could request (if they haven't resolved yet).
        uint otherRes = partyResolution(agreement, otherParty);
        if((otherRes != RESOLUTION_NULL && resolutionsAreCompatible(res, otherRes, party)) ||
            (party == A && res == 0) ||
            (party == B && res == add(agreement.partyAStakeAmount, agreement.partyBStakeAmount))){
            
            agreement.resolution = res;
        }
    }

    // Called by arbitrator to report their resolution. See resolveAsParty comments for resolution interpretation.
    // Can only be called after arbitrator is asked to arbitrate by both parties.
    function resolveAsArbitrator(uint agreementID, uint resolutionWei) external onlyOpen(agreementID) onlyLockedIn(agreementID) {
        AgreementData storage agreement = agreements[agreementID];

        uint48 res = toMillionth(resolutionWei);

        require(!usingArbitrationStandard(agreement), "Only simple arbitration uses resolveAsArbitrator.");
        require(msg.sender == agreement.arbitratorAddress, "resolveAsArbitrator can only be called by arbitrator.");
        require(res <= add(agreement.partyAStakeAmount, agreement.partyBStakeAmount), "Resolution out of range.");
        require(partyRequestedArbitration(agreement, A) && partyRequestedArbitration(agreement, B), 
            "Arbitration not requested by both parties.");

        setArbitratorResolved(agreement, true);

        agreement.resolution = res;
    }

    // The function that an ERC792 arbitration service calls instead of resolveAsArbitrator to report their resolution.
    // Can only be called after a dispute is created, which only happens if arbitration is requested by both parties.
    function rule(uint dispute_id, uint ruling) public {
        uint agreementID = disputeToAgremeentID[msg.sender][dispute_id];

        require(agreementID > 0, "Dispute doesn't correspond to a valid agreement.");
        require(agreementIsOpen(agreementID) && agreementIsLockedIn(agreementID), "Agreement not open and locked.");

        AgreementData storage agreement = agreements[agreementID];

        require(!preventReentrancy(agreement), "Reentrancy protection is on.");

        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];

        require(arbData.disputeCreated, "Arbitration not requested.");
        require(ruling <= NUM_STANDARD_RESOLUTION_TYPES, "Ruling out of range.");
        
        setArbitratorResolved(agreement, true);

        // We only allow a set of predefined resolutions for ERC792 arbitration services for now.
        if(ruling == uint(PredefinedResolution.None)){
            // Do nothing. We already updated state with setArbitratorResolved.
            // Resolving as None can be interpreted as the arbitrator refusing to rule.
        }else if(ruling == uint(PredefinedResolution.Refund)){
            agreement.resolution = agreement.partyAStakeAmount;
        }else if(ruling == uint(PredefinedResolution.EverythingToA)){
            agreement.resolution = toUint48(add(agreement.partyAStakeAmount, agreement.partyBStakeAmount));
        }
        else if(ruling == uint(PredefinedResolution.EverythingToB)){
            agreement.resolution = 0;
        }else if(ruling == uint(PredefinedResolution.Swap)){
            agreement.resolution = agreement.partyBStakeAmount;
        }
        else if(ruling == uint(PredefinedResolution.FiftyFifty)){
            agreement.resolution = toUint48(add(agreement.partyAStakeAmount, agreement.partyBStakeAmount)/2);
        }else{
            require(false, "Hit unreachable code in rule.");
        }

        emit Ruling(Arbitrator(msg.sender), dispute_id, ruling);
    }

    // If A calls createAgreementA but B is delaying in calling depositB, A can get their funds back 
    // by calling earlyWithdrawA. This closes the agreement to further deposits. A or B would have to
    // call createAgreementA again if they still wanted to do an agreement.
    function earlyWithdrawA(uint agreementID) external onlyOpen(agreementID) {
        AgreementData storage agreement = agreements[agreementID];

        require(msg.sender == agreement.partyAAddress, "withdrawA can only be called by party A.");
        require(partyStakePaid(agreement, A) && !partyStakePaid(agreement, B), "Withdraw not allowed.");
        require(!partyWithdrew(agreement, A), "partyA already withdrew.");

        setPartyWithdrew(agreement, A, true);

        msg.sender.transfer(toWei(add(agreement.partyAStakeAmount, agreement.partyAInitialArbitratorFee)));
    }

    // This can only be called after a resolution is established (enforced by onlyClosed and onlyLockedIn)
    // Each party calls this to withdraw the funds they're entitled to, based on the resolution.
    function withdraw(uint agreementID) external onlyClosed(agreementID) onlyLockedIn(agreementID) {
        AgreementData storage agreement = agreements[agreementID];

        require(!preventReentrancy(agreement), "Reentrancy protection is on");

        uint party = getParty(agreement);

        require(!partyWithdrew(agreement, party), "This party already withdrew.");
        
        setPartyWithdrew(agreement, party, true);
        
        uint withdrawAmount = 0;
        if(party == A){
            withdrawAmount = agreement.resolution;
        } else{
            withdrawAmount = sub(add(agreement.partyAStakeAmount, agreement.partyBStakeAmount), agreement.resolution);
        }

        uint withdrawWei = 0;
        if(usingArbitrationStandard(agreement)){
            // ArbitrationStandard refunds are already in wei, so only convert withdrawAmount.
            withdrawWei = add(toWei(withdrawAmount), getPartyStandardArbitrationRefundInWei(agreementID, party));
        }else{
            // Convert both components to wei.
            withdrawWei = toWei(add(withdrawAmount, getPartyArbitrationRefund(agreement, party)));
        }
        msg.sender.transfer(withdrawWei);
    }

    // Request 'simple' (non- ERC792) arbitration. Both parties must call this (and pay the required fee) before
    // the arbitrator is allowed to rule. If one party calls this and the other refuses to, the party who called
    // this function can eventually call requestDefaultJudgment. 
    function requestArbitration(uint agreementID) external payable onlyOpen(agreementID) onlyLockedIn(agreementID) {
        AgreementData storage agreement = agreements[agreementID];

        uint party = getParty(agreement);

        bool firstArbitrationRequest = !partyRequestedArbitration(agreement, A) && !partyRequestedArbitration(agreement, B);

        require(!usingArbitrationStandard(agreement), "Only simple arbitration uses requestArbitration.");
        require(agreement.arbitratorAddress != address(0), "Arbitration is disallowed.");
        require(msg.value == toWei(agreement.disputeFee), "Arbitration fee amount was incorrect.");
        require(RESOLUTION_NULL != partyResolution(agreement, party), "Need to enter a resolution before requesting arbitration.");
        require(!partyRequestedArbitration(agreement, party), "This party already requested arbitration.");
        require(!firstArbitrationRequest || 
            block.timestamp > agreement.nextArbitrationStepAllowedAfterTimestamp, "Arbitration not allowed yet.");

        setPartyRequestedArbitration(agreement, party, true);
    
        if(firstArbitrationRequest){
            // update the deadline for the other party to pay
            agreement.nextArbitrationStepAllowedAfterTimestamp = 
                toUint32(add(block.timestamp, mul(agreement.daysToRespondToArbitrationRequest, (1 days))));
        } 
    }

    // For requesting ERC792 arbitration. A dispute will be created immediately once both parties pay the full arbitration fee.
    // The logic of this function is somewhat tricky, because fees can rise in between the time that the two parties call
    // this. Both parties must call this before the arbitrator is allowed to rule.
    // We allow parties to overpay this fee if they like, to be ready for any possible fee increases.
    function requestStandardArbitration(uint agreementID) external payable onlyOpen(agreementID) onlyLockedIn(agreementID) {
        AgreementData storage agreement = agreements[agreementID];

        require(!preventReentrancy(agreement), "Reentrancy protection is on");
        require(usingArbitrationStandard(agreement), "Only standard arbitration uses requestStandardArbitration.");
        require(agreement.arbitratorAddress != address(0), "Arbitration is disallowed.");

        (uint party, uint otherParty) = getParties(agreement);
        
        require(RESOLUTION_NULL != partyResolution(agreement, party), "Need to enter a resolution before requesting arbitration.");

        ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];
        
        // We don't allow appeals yet, so once a dispute is created its result is final.
        require(!arbData.disputeCreated, "Dispute already created.");
                
        bool firstArbitrationRequest = !partyRequestedArbitration(agreement, A) && !partyRequestedArbitration(agreement, B);

        require(!firstArbitrationRequest || 
            block.timestamp > agreement.nextArbitrationStepAllowedAfterTimestamp, "Arbitration not allowed yet.");

        setPartyRequestedArbitration(agreement, party, true);

        arbData.weiPaidIn[party] = add(arbData.weiPaidIn[party], msg.value);
        uint arbitrationFee = standardArbitrationFee_Untrusted(agreement, arbitrationExtraData[agreementID]);        

        require(arbData.weiPaidIn[party] >= arbitrationFee, "Arbitration payment was not enough.");
    
        if(arbData.weiPaidIn[otherParty] >= arbitrationFee){
            // Both parties have paid at least the arbitrationFee, so create a dispute.
            arbData.disputeCreated = true;
            arbData.weiPaidToArbitrator = arbitrationFee;
            arbData.disputeID = createDispute_Untrusted(agreement, NUM_STANDARD_RESOLUTION_TYPES,
                arbitrationExtraData[agreementID], arbitrationFee);
            disputeToAgremeentID[agreement.arbitratorAddress][arbData.disputeID] = agreementID;
            emit Dispute(Arbitrator(agreement.arbitratorAddress), arbData.disputeID, agreementID);
        } else{
            // The other party hasn't paid the full arbitration fee yet. This might be because they previously paid it but
            // the fee has increased since they did so. 
            // We need to determine whether to extend the time allowed for the other party to pay.  
            // We extend the time only when the calling party's dispute fee has 'leapfrogged' the dispute fee paid by the other
            // party. This means the other party will only get extensions when the situation in which the calling party
            // has paid more than them is "new." 
            if(sub(arbData.weiPaidIn[party], msg.value) <= arbData.weiPaidIn[otherParty]){
                agreement.nextArbitrationStepAllowedAfterTimestamp = 
                    toUint32(add(block.timestamp, mul(agreement.daysToRespondToArbitrationRequest, (1 days))));
            }
        }
    }

    // Allow the arbitrator to indicate they're working on the dispute by withdrawing the funds.
    // We can't prevent dishonest arbitrator from taking funds without doing work, because they can
    // always call 'rule' quickly. So just avoid the case where we send funds to a nonresponsive arbitrator.
    function withdrawDisputeFee(uint agreementID) external onlyLockedIn(agreementID) {
        AgreementData storage agreement = agreements[agreementID];

        require(!usingArbitrationStandard(agreement), "Only simple arbitration uses withdrawDisputeFee.");
        require(partyRequestedArbitration(agreement, A) && partyRequestedArbitration(agreement, B), "Arbitration not requested");
        require(msg.sender == agreement.arbitratorAddress, "withdrawDisputeFee can only be called by Arbitrator.");
        require(!resolutionsAreCompatible(agreement.partyAResolution, agreement.partyBResolution, A), 
            "partyA and partyB already resolved their dispute.");
        require(!arbitratorWithdrewDisputeFee(agreement), "Already withdrew dispute fee.");

        setArbitratorWithdrewDisputeFee(agreement, true);

        msg.sender.transfer(toWei(agreement.disputeFee));
    }

    // If the other person hasn't paid their arbitration fee in time, this function allows the caller to cause 
    // the agreement to be resolved in their favor without the arbitrator getting involved. 
    function requestDefaultJudgment(uint agreementID) external onlyOpen(agreementID) onlyLockedIn(agreementID) {
        AgreementData storage agreement = agreements[agreementID];
        
        require(!preventReentrancy(agreement), "Reentrancy protection is on");

        (uint party, uint otherParty) = getParties(agreement);

        require(RESOLUTION_NULL != partyResolution(agreement, party), "requestDefaultJudgment called before party resolved.");
        require(block.timestamp > agreement.nextArbitrationStepAllowedAfterTimestamp, "requestDefaultJudgment not allowed yet.");

        agreement.resolution = partyResolution(agreement, party);

        // Put these requires at the end of the function to be extra safe, since they're untrusted
        require(partyFullyPaidDisputeFee_Untrusted(agreementID, party), "Party didn't fully pay dispute fee.");
        require(!partyFullyPaidDisputeFee_Untrusted(agreementID, otherParty), "Other party fully paid dispute fee.");
    }

    // If enough time has elapsed, either party can trigger auto-resolution (if it's enabled) by calling this function,
    // provided that neither party has requested arbitration yet.
    function requestAutomaticResolution(uint agreementID) external onlyOpen(agreementID) onlyLockedIn(agreementID) { 
        AgreementData storage agreement = agreements[agreementID];

        require(!preventReentrancy(agreement), "Reentrancy protection is on.");
        require(!partyRequestedArbitration(agreement, A) && !partyRequestedArbitration(agreement, B), "Arbitration stops auto-resolution");
        require(msg.sender == agreement.partyAAddress || msg.sender == agreement.partyBAddress, "Unauthorized sender.");
        require(agreement.autoResolveAfterTimestamp > 0, "Agreement does not support automatic resolutions.");
        require(block.timestamp > agreement.autoResolveAfterTimestamp, "AutoResolution not allowed yet.");

        agreement.resolution = agreement.automaticResolution;
    }

    // Allows either party to record evidence on the blockchain, in case off-chain communication breaks down.
    // If we're using the ERC792 arbitration standard, parties can only submit evidence during a dispute.
    // If we're using simple arbitration, parties can submit evidence whenever.
    function submitEvidence(uint agreementID, string calldata evidence) external onlyOpen(agreementID) {
        AgreementData storage agreement = agreements[agreementID];

        require(msg.sender == agreement.partyAAddress || msg.sender == agreement.partyBAddress, "Unauthorized sender.");

        if(usingArbitrationStandard(agreement)){
            ArbitrationData storage arbData = arbitrationDataForAgreement[agreementID];
            require(arbData.disputeCreated, "Need a dispute before you can submit ERC 1497 evidence.");
            emit Evidence(Arbitrator(agreement.arbitratorAddress), arbData.disputeID, msg.sender, evidence);
        }else{
            // If using simple arbitration, don't put restrictions on when people can submit evidence.
            emit Evidence(Arbitrator(agreement.arbitratorAddress), agreementID, msg.sender, evidence);
        }        
    }
}
