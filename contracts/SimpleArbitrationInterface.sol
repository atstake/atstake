pragma solidity 0.5.7;

/** 
    @notice A contract that AgreementManagers that implement simple (non-ERC792) arbitration can 
    inherit from.

    This is currently too simple to be that useful, but things may be added to it in the future.
*/

contract SimpleArbitrationInterface {
    // -------------------------------------------------------------------------------------------
    // ------------------------------------- events ----------------------------------------------
    // -------------------------------------------------------------------------------------------

    event DisputeFeeWithdrawn(uint32 indexed agreementID);

    // -------------------------------------------------------------------------------------------
    // ----------------------------- internal helper functions -----------------------------------
    // -------------------------------------------------------------------------------------------

    /// @dev This is a no-op when using simlple arbitration. 
    /// Extra arbitration data is only needed for ERC792 arbitration.
    function storeArbitrationExtraData(uint, bytes memory) internal { } 
}
