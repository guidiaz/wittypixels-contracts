// SPDX-License-Identifier: MIT
// solhint-disable var-name-mixedcase

pragma solidity >=0.8.0 <0.9.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "witnet-solidity-bridge/contracts/patterns/Clonable.sol";

/// @title Witnet Request Board base contract, with an Upgradeable (and Destructible) touch.
/// @author The Witnet Foundation.
abstract contract WittyPixelsClonableBase
    is
        Clonable,
        OwnableUpgradeable,
        ReentrancyGuardUpgradeable
{
    bytes32 immutable internal _VERSION;

    modifier onlyDelegateCalls {
        require(
            address(this) != self(),
            "WittyPixelsClonableBase: not a delegate call"
        );
        _;
    }

    constructor(bytes32 _version) {
        _VERSION = _version;
        // make sure the (uninitialized) base implementation is owned by the deployer
        _transferOwnership(msg.sender);
    }
    
    /// @dev Reverts w/ specific message if a delegatecalls falls back into unexistent method.
    fallback() external { // solhint-disable 
        revert("WittyPixelsClonableBase: not implemented");
    }

    function version() public view returns (string memory) {
        return _toString(_VERSION);
    }


    // ================================================================================================================
    // --- Overrides Clonable -----------------------------------------------------------------------------------------

    function initialize(bytes memory) public virtual override {
        // initialize openzeppelin's underlying patterns
        __Ownable_init();
        __ReentrancyGuard_init();
    }


    // ================================================================================================================
    // --- Internal methods -------------------------------------------------------------------------------------------

    /// Converts bytes32 into string.
    function _toString(bytes32 _bytes32)
        internal pure
        returns (string memory)
    {
        bytes memory _bytes = new bytes(_toStringLength(_bytes32));
        for (uint _i = 0; _i < _bytes.length;) {
            _bytes[_i] = _bytes32[_i];
            unchecked {
                _i ++;
            }
        }
        return string(_bytes);
    }

    // Calculate length of string-equivalent to given bytes32.
    function _toStringLength(bytes32 _bytes32)
        internal pure
        returns (uint _length)
    {
        for (; _length < 32; ) {
            if (_bytes32[_length] == 0) {
                break;
            }
            unchecked {
                _length ++;
            }
        }
    }

}