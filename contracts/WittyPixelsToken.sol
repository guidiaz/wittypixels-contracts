// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppeling's patterns
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

// Witnet deployment and testing dependencies:
import "witnet-solidity-bridge/contracts/apps/WitnetRequestFactory.sol";
import "witnet-solidity-bridge/contracts/impls/WitnetProxy.sol";
import "witnet-solidity-bridge/contracts/impls/bytecodes/WitnetBytecodes.sol";
import "witnet-solidity-bridge/contracts/impls/boards/trustable/WitnetRequestBoardTrustableDefault.sol";
import "witnet-solidity-bridge/contracts/libs/WitnetLib.sol";
import "witnet-solidity-bridge/contracts/libs/WitnetEncodingLib.sol";

// Witnet build dependency:
import "witnet-solidity-bridge/contracts/UsingWitnet.sol";

// WittyPixels interfaces:
import "./interfaces/ITokenVaultFactory.sol";
import "./interfaces/IWittyPixelsToken.sol";
import "./interfaces/IWittyPixelsTokenAdmin.sol";

import "./patterns/WittyPixelsUpgradeableBase.sol";

/// @title  Witty Pixels NFT - ERC721 token contract
/// @author Otherplane Labs Ltd., 2022
/// @dev    This contract needs to be proxified.
contract WittyPixelsToken
    is
        ERC721Upgradeable,
        IWittyPixelsToken,
        IWittyPixelsTokenAdmin,
        WittyPixelsUpgradeableBase,
        // Secured by Witnet !!
        UsingWitnet
{
    using ERC165Checker for address;
    using WitnetLib for Witnet.Result;
    using WittyPixelsLib for bytes;
    using WittyPixelsLib for bytes32[];
    using WittyPixelsLib for uint256;
    using WittyPixelsLib for WitnetCBOR.CBOR;
    using WittyPixelsLib for WittyPixelsLib.ERC721Token;

    bytes32 public constant SLOTHASH =
        /* keccak256("art.wittypixels.token") */
        0xa1c65a69721a75d8ec79c686c8573bd06e7f0c400997cbe153064301cbc480d5;

    WitnetRequestTemplate immutable public imageDigestRequestTemplate;
    WitnetRequestTemplate immutable public tokenStatsRequestTemplate;

    /// @notice A new token has been fractionalized from this factory.
    event Fractionalized(
        address indexed from,   // owner of the token being fractionalized
        address indexed token,  // token collection address
        uint256 tokenId,        // token id
        address tokenVault      // token vault contract just created
    );
    
    modifier initialized {
        require(
            __proxiable().implementation != address(0),
            "WittyPixelsToken: not initialized"
        );
        _;
    }

    modifier tokenExists(uint256 _tokenId) {
        require(
            _exists(_tokenId),
            "WittyPixelsToken: unknown token"
        );
        _;
    }

    modifier tokenInStatus(uint256 _tokenId, WittyPixelsLib.ERC721TokenStatus _status) {
        require(
            getTokenStatus(_tokenId) == _status,
            "WittyPixelsToken: bad mood"
        );
        _;
    }

    constructor(
            WitnetRequestBoard _witnetRequestBoard,
            WitnetRequestTemplate _imageDigestRequestTemplate,
            WitnetRequestTemplate _tokenStatsRequestTemplate,
            bool _upgradable,
            bytes32 _version
        )
        UsingWitnet(_witnetRequestBoard)
        WittyPixelsUpgradeableBase(
            _upgradable,
            _version,
            "art.wittypixels.token"
        )
    {
        require(
            address(_imageDigestRequestTemplate) != address(0)
                && _imageDigestRequestTemplate.class() == type(WitnetRequestTemplate).interfaceId
                && _imageDigestRequestTemplate.parameterized(),
            "WittyPixelsToken: invalid image-digest request template"
        );
        require(
            address(_tokenStatsRequestTemplate) != address(0)
                && _tokenStatsRequestTemplate.class() == type(WitnetRequestTemplate).interfaceId
                && _tokenStatsRequestTemplate.parameterized(),
            "WittyPixelsToken: invalid token-stats request template"
        );
        imageDigestRequestTemplate = _imageDigestRequestTemplate;
        tokenStatsRequestTemplate = _tokenStatsRequestTemplate;
    }


    // ================================================================================================================
    // --- Overrides IERC165 interface --------------------------------------------------------------------------------

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 _interfaceId)
      public view
      virtual override
      onlyDelegateCalls
      returns (bool)
    {
        return _interfaceId == type(ITokenVaultFactory).interfaceId
            || _interfaceId == type(IWittyPixelsToken).interfaceId
            || ERC721Upgradeable.supportsInterface(_interfaceId)
            || _interfaceId == type(Ownable2StepUpgradeable).interfaceId
            || _interfaceId == type(Upgradeable).interfaceId
            || _interfaceId == type(IWittyPixelsTokenAdmin).interfaceId
        ;
    }


    // ================================================================================================================
    // --- Overrides 'Upgradeable' ------------------------------------------------------------------------------------

    /// Initialize storage-context when invoked as delegatecall. 
    /// @dev Must fail when trying to initialize same instance more than once.
    function initialize(bytes memory _initdata) 
        public
        virtual override
        onlyDelegateCalls // => we don't want the logic base contract to be ever initialized
    {
        if (__proxiable().proxy == address(0)) {
            // a proxy is being initilized for the first time ...
            __initializeProxy(_initdata);
        }
        else {
            // a proxy is being upgraded ...
            // only the proxy's owner can upgrade it
            require(
                msg.sender == owner(),
                "WittyPixelsToken: not the owner"
            );
            // the implementation cannot be upgraded more than once, though
            require(
                __proxiable().implementation != base(),
                "WittyPixelsToken: already initialized"
            );
            emit Upgraded(msg.sender, base(), codehash(), version());
        }
        __proxiable().implementation = base();
    }

    
    // ================================================================================================================
    // --- Overrides 'ERC721TokenMetadata' overriden functions --------------------------------------------------------

    function tokenURI(uint256 _tokenId)
        public view
        virtual override
        tokenExists(_tokenId)
        returns (string memory)
    {
        return WittyPixelsLib.tokenMetadataURI(_tokenId, __wpx721().items[_tokenId].baseURI);
    }


    // ================================================================================================================
    // --- Based on 'ITokenVaultFactory' ------------------------------------------------------------------------------

    /// @notice Fractionalize next token in collection by transferring ownership to new instance
    /// @notice of the ERC721 Token Vault prototype contract. 
    /// @dev Token must be in 'Minting' status and involved Witnet requests successfully solved.
    /// @dev Once Witnet requests involved in minting process are solved, anyone may proceed withç
    /// @dev fractionalization of next token. Curatorship of the vault will be transferred to the owner, though.
    /// @param _tokenVaultSettings Extra settings to be passed when initializing the token vault contract.
    function fractionalize(bytes memory _tokenVaultSettings)
        external
        tokenInStatus(__wpx721().totalSupply + 1, WittyPixelsLib.ERC721TokenStatus.Minting)
        returns (ITokenVault)
    {
        uint256 _tokenId = __wpx721().totalSupply + 1;

        // Check there's a token vault prototype set:
        require(
            address(__wpx721().tokenVaultPrototype) != address(0),
            "WittyPixelsToken: no token vault prototype"
        );

        WittyPixelsLib.ERC721Token storage __token = __wpx721().items[_tokenId];
        WittyPixelsLib.ERC721TokenWitnetQueries storage __witnetQueries = __wpx721().tokenWitnetQueries[_tokenId];
        {
            // Revert if any of the witnet queries was not yet solved
            if (
                !_witnetCheckResultAvailability(__witnetQueries.imageDigestId)
                    || !_witnetCheckResultAvailability(__witnetQueries.tokenStatsId)
            ) {
                revert("WittyPixelsToken: awaiting response from Witnet");
            }
        }

        Witnet.Response memory _witnetResponse;
        Witnet.Result memory _witnetResult;
        {
            // Read response to 'image-digest' query, and free storage from the Witnet Request Board:
            _witnetResponse = _witnetDeleteQuery(__witnetQueries.imageDigestId);
            _witnetResult = WitnetLib.resultFromCborBytes(_witnetResponse.cborBytes);
            {
                // Revert if the Witnet query failed:
                require(_witnetResult.success, "WittyPixelsToken: 'image-digest' failed");
                // Revert if the Witnet response was previous to when minting started:
                require(_witnetResponse.timestamp >= __token.birthTs, "WittyPixelsToken: anachronic 'image-digest'");
            }
            // Process Witnet response to 'image-digest':
            __token.imageDigest = _witnetResult.value.toString();
            __token.imageDigestWitnetTxHash = _witnetResponse.drTxHash;
        }
        {
            // Read response to 'token-stats' query, and free storage from the Witnet Request Board:
            _witnetResponse = _witnetDeleteQuery(__witnetQueries.tokenStatsId);
            _witnetResult = WitnetLib.resultFromCborBytes(_witnetResponse.cborBytes);
            {
                // Revert if the Witnet query failed:
                require(_witnetResult.success, "WittyPixelsToken: 'token-stats' failed");
                // Revert if the Witnet response was previous to when minting started:
                require(_witnetResponse.timestamp >= __token.birthTs, "WittyPixelsToken: anachronic 'token-stats'");
            }
            // Process Witnet response to 'witnetTokenStats:
            __token.theStats = _witnetResult.value.toERC721TokenStats();
        }
        
        // Clone the token vault prototype and initialize the cloned instance:
        string memory _erc20Name = string(abi.encodePacked(
            name(),
            bytes(" #"),
            _tokenId.toString()
        ));
        IWittyPixelsTokenVault _tokenVault = IWittyPixelsTokenVault(address(
            __wpx721().tokenVaultPrototype.cloneAndInitialize(abi.encode(
                WittyPixelsLib.TokenVaultInitParams({
                    curator: owner(),
                    name: _erc20Name,
                    symbol: symbol(),
                    settings: _tokenVaultSettings,
                    token: address(this),
                    tokenId: _tokenId,
                    tokenPixels: __token.theStats.canvasPixels
                })
            ))
        ));

        // Store token vault contract:
        __wpx721().vaults[_tokenId] = _tokenVault;
        __wpx721().totalTokenVaults ++;

        // Mint the actual ERC-721 token and set the just created vault contract as first owner ever:
        _mint(address(_tokenVault), _tokenId);
        
        // Increment total supply:
        __wpx721().totalSupply ++;

        // Emits event
        emit Fractionalized(msg.sender, address(this), _tokenId, address(_tokenVault));

        return ITokenVault(address(_tokenVault));
    }

    /// @notice Returns token vault prototype being instantiated when fractionalizing. 
    /// @dev If destructible, it must be owned by this contract.
    function getTokenVaultFactoryPrototype()
        external view
        returns (ITokenVault)
    {
        return ITokenVault(__wpx721().tokenVaultPrototype);
    }


    // ================================================================================================================
    // --- Implementation of 'IWittyPixelsToken' ----------------------------------------------------------------------

    /// @notice Returns base URI to be used by upcoming tokens of this collection.
    function baseURI()
        override public view
        initialized
        returns (string memory)
    {
        return __wpx721().baseURI;
    }

    /// @notice Returns status of given WittyPixels token.
    /// @dev Possible values:
    /// @dev - 0 => Unknown, not yet launched
    /// @dev - 1 => Launched: info about the corresponding WittyPixels events has been provided by the collection's owner
    /// @dev - 2 => Minting: the token is being minted, awaiting for external data to be retrieved by the Witnet Oracle.
    /// @dev - 3 => Fracionalized: the token has been minted and its ownership transfered to a WittyPixelsTokenVault contract.
    /// @dev - 4 => Acquired: token's ownership has been acquired and belongs to the WittyPixelsTokenVault no more. 
    function getTokenStatus(uint256 _tokenId)
        override public view
        initialized
        returns (WittyPixelsLib.ERC721TokenStatus)
    {
        if (_tokenId <= __wpx721().totalSupply) {
            IWittyPixelsTokenVault _tokenVault = __wpx721().vaults[_tokenId];
            if (
                address(_tokenVault) != address(0)
                    && ownerOf(_tokenId) != address(__wpx721().vaults[_tokenId])
            ) {
                return WittyPixelsLib.ERC721TokenStatus.Acquired;
            } else {
                return WittyPixelsLib.ERC721TokenStatus.Fractionalized;
            }
        } else {
            WittyPixelsLib.ERC721Token storage __token = __wpx721().items[_tokenId];
            if (__token.birthTs > 0) {
                return WittyPixelsLib.ERC721TokenStatus.Minting;
            } else if (bytes(__token.theEvent.name).length > 0) {
                return WittyPixelsLib.ERC721TokenStatus.Launching;
            } else {
                return WittyPixelsLib.ERC721TokenStatus.Void;
            }
        }
    }

    /// @notice Returns literal string representing current status of given WittyPixels token.    
    function getTokenStatusString(uint256 _tokenId)
        override external view
        initialized
        returns (string memory)
    {
        WittyPixelsLib.ERC721TokenStatus _status = getTokenStatus(_tokenId);
        if (_status == WittyPixelsLib.ERC721TokenStatus.Acquired) {
            return "Acquired";
        } else if (_status == WittyPixelsLib.ERC721TokenStatus.Fractionalized) {
            return "Fractionalized";
        } else if (_status == WittyPixelsLib.ERC721TokenStatus.Minting) {
            return "Minting";
        } else if (_status == WittyPixelsLib.ERC721TokenStatus.Launching) {
            return "Launching";
        } else {
            return "Void";
        }
    }

    /// @notice Returns WittyPixels token metadata of given token.
    function getTokenMetadata(uint256 _tokenId)
        external view
        override
        initialized
        returns (WittyPixelsLib.ERC721Token memory)
    {
        return __wpx721().items[_tokenId];
    }
    
    /// @notice Returns WittyPixelsTokenVault instance bound to the given token.
    /// @dev Reverts if the token has not yet been fractionalized.
    function getTokenVault(uint256 _tokenId)
        public view
        override
        tokenExists(_tokenId)
        returns (ITokenVaultWitnet)
    {
        return __wpx721().vaults[_tokenId];
    }

    /// @notice Returns Identifiers of Witnet queries involved in the minting process.
    /// @dev Returns zero addresses if the token is yet in 'Unknown' or 'Launched' status.
    function getTokenWitnetQueries(uint256 _tokenId)
        external view
        override
        initialized
        returns (WittyPixelsLib.ERC721TokenWitnetQueries memory)
    {
        return __wpx721().tokenWitnetQueries[_tokenId];
    }

    /// @notice Returns image URI of given token.
    function imageURI(uint256 _tokenId)
        override
        external view 
        initialized
        returns (string memory)
    {
        WittyPixelsLib.ERC721TokenStatus _tokenStatus = getTokenStatus(_tokenId);
        if (_tokenStatus == WittyPixelsLib.ERC721TokenStatus.Void) {
            return string(hex"");
        } else {
            return WittyPixelsLib.tokenImageURI(
                _tokenId,
                _tokenStatus == WittyPixelsLib.ERC721TokenStatus.Launching
                    ? baseURI()
                    : __wpx721().items[_tokenId].baseURI
            );
        }
    }

    /// @notice Serialize token ERC721Token to JSON string.
    function metadata(uint256 _tokenId)
        external view 
        override
        tokenExists(_tokenId)
        returns (string memory)
    {
        return __wpx721().items[_tokenId].toJSON(_tokenId);
    }

    /// @notice Returns number of pixels within the WittyPixels Canvas of given token.
    function pixelsOf(uint256 _tokenId)
        virtual override
        external view
        returns (uint256)
    {
        return __wpx721().items[_tokenId].theStats.totalPixels;
    }

    /// @notice Returns number of pixels contributed to given WittyPixels Canvas by given address.
    /// @dev Every WittyPixels player needs to claim contribution to a WittyPixels Canvas by calling 
    /// @dev to the `redeem(bytes deeds)` method on the corresponding token's vault contract.
    function pixelsFrom(uint256 _tokenId, address _from)
        virtual override
        external view
        returns (uint256)
    {
        IWittyPixelsTokenVault _vault = IWittyPixelsTokenVault(address(getTokenVault(_tokenId)));
        return (address(_vault) != address(0)
            ? _vault.pixelsOf(_from)
            : 0
        );
    }

    /// @notice Count NFTs tracked by this contract.
    /// @return A count of valid NFTs tracked by this contract, where each one of
    ///         them has an assigned and queryable owner not equal to the zero address
    function totalSupply()
        external view
        override
        returns (uint256)
    {
        return __wpx721().totalSupply;
    }

    /// @notice Verifies the provided Merkle Proof matches the token's authorship's root that
    /// @notice was retrieved by the Witnet Oracle upon minting of given token. 
    /// @dev Reverts if the token has not yet been fractionalized.
    function verifyTokenAuthorship(
            uint256 _tokenId,
            uint256 _playerIndex,
            uint256 _playerPixels,
            bytes32[] memory _proof
        )
        external view
        override
        tokenExists(_tokenId)
        returns (bool)
    {
        WittyPixelsLib.ERC721Token storage __token = __wpx721().items[_tokenId];
        return (
            _proof.merkle(keccak256(abi.encode(
                _playerIndex,
                _playerPixels
            ))) == __token.theStats.canvasRoot
        );
    }


    // ================================================================================================================
    // --- Implementation of 'IWittyPixelsTokenAdmin' -----------------------------------------------------------------

    function launch(WittyPixelsLib.ERC721TokenEvent calldata _theEvent)
        override external
        onlyOwner
        returns (uint256 _tokenId)
    {
        _tokenId = __wpx721().totalSupply + 1;
        WittyPixelsLib.ERC721TokenStatus _status = getTokenStatus(_tokenId);
        require(
            _status == WittyPixelsLib.ERC721TokenStatus.Void
                || _status == WittyPixelsLib.ERC721TokenStatus.Launching,
            "WittyPixelsToken: bad mood"
        );
        // Check the event data:
        require(
            bytes(_theEvent.name).length > 0
                && bytes(_theEvent.venue).length > 0,
            "WittyPixelsToken: event empty strings"
        );
        require(
            _theEvent.startTs <= _theEvent.endTs,
            "WittyPixelsToken: event bad timestamps"
        );
        // Change token status:
        __wpx721().items[_tokenId].theEvent = _theEvent;
    }
    
    function mint(WitnetV2.RadonSLA calldata _witnetSLA)
        override external payable
        onlyOwner
        nonReentrant
    {
        uint256 _tokenId = __wpx721().totalSupply + 1;
        WittyPixelsLib.ERC721TokenStatus _status = getTokenStatus(_tokenId);
        require(
            _status == WittyPixelsLib.ERC721TokenStatus.Launching
                || _status == WittyPixelsLib.ERC721TokenStatus.Minting,
            "WittyPixelsToken: bad mood"
        );        
        WittyPixelsLib.ERC721Token storage __token = __wpx721().items[_tokenId];
        require(
            block.timestamp >= __token.theEvent.endTs,
            "WittyPixelsToken: the event is not over yet"
        );

        WittyPixelsLib.ERC721TokenWitnetQueries storage __witnetQueries = __wpx721().tokenWitnetQueries[_tokenId];
        if (__witnetQueries.imageDigestId > 0) {
            // Revert if both queries from previous minting attempt were not yet solved
            if (
                !_witnetCheckResultAvailability(__witnetQueries.imageDigestId)
                    && !_witnetCheckResultAvailability(__witnetQueries.tokenStatsId)
            ) {
                revert("WittyPixelsToken: awaiting Witnet responses");
            }
        }
        
        // Set the token's base uri and inception timestamp
        string memory _currentBaseURI = __wpx721().baseURI;
        string memory _imageuri = WittyPixelsLib.tokenImageURI(_tokenId, _currentBaseURI);
        {
            __token.baseURI = _currentBaseURI;
            __token.birthTs = block.timestamp;
            __token.tokenStatsWitnetRadHash = __wpx721().witnetTokenStats.radHash();
        }

        uint _totalUsedFunds;
        {
            // Ask Witnet to confirm the token's image URI actually exists:
            (__witnetQueries.imageDigestId, _totalUsedFunds) = _witnetPostRequest(
                __wpx721().witnetImageDigest.modifySLA(_witnetSLA)
            );
        }
        {
            uint _usedFunds;
            // Ask Witnet to retrieve token's metadata stats from the token base uri provider:            
            (__witnetQueries.tokenStatsId, _usedFunds) = _witnetPostRequest(
                __wpx721().witnetTokenStats.modifySLA(_witnetSLA)
            );
            _totalUsedFunds += _usedFunds;
        }

        // Transfer back unused funds, if any:
        if (_totalUsedFunds < msg.value) {
            payable(msg.sender).transfer(msg.value - _totalUsedFunds);
        }
        
        // Emit event:
        emit Minting(_tokenId, _imageuri, _witnetSLA);
    }

    /// @notice Sets collection's base URI.
    function setBaseURI(string calldata _uri)
        external 
        override
        onlyOwner 
    {
        __setBaseURI(_uri);
    }

    /// @notice Vault logic contract to be used in next calls to `fractionalize(..)`. 
    /// @dev Prototype ownership needs to have been previously transferred to this contract.
    function setTokenVaultFactoryPrototype(address _prototype)
        external
        override
        onlyOwner
    {
        _verifyPrototypeCompliance(_prototype);
        __wpx721().tokenVaultPrototype = IWittyPixelsTokenVault(_prototype);
    }


    // ================================================================================================================
    // --- Internal virtual methods -----------------------------------------------------------------------------------

    function __initializeProxy(bytes memory _initdata)
        virtual internal
        initializer 
    {
        // As for OpenZeppelin's ERC721Upgradeable implementation,
        // name and symbol can only be initialized once;
        // as for an upgradable (and proxiable) contract as this one,
        // the setting of name and symbol needs to be invoked in
        // a dedicated and unique 'initializer' method, other from the
        // `initialize(bytes)` method that gets called every time
        // a proxy contract is upgraded.

        // read and set ERC721 initialization parameters
        WittyPixelsLib.TokenInitParams memory _params = abi.decode(
            _initdata,
            (WittyPixelsLib.TokenInitParams)
        );
        __setBaseURI(_params.baseURI);
        __ERC721_init(
            _params.name,
            _params.symbol
        );        
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __proxiable().proxy = address(this);
        __proxiable().implementation = base();
    }

    function __setBaseURI(string memory _baseuri)
        virtual internal
    {
        __wpx721().baseURI = WittyPixelsLib.checkBaseURI(_baseuri);
        {
            // re-settle parameterized witnet request templates into actual witnet requests
            string[][] memory _args = new string[][](1);
            _args[0] = new string[](1);
            _args[0][0] = _baseuri;
            __wpx721().witnetImageDigest = imageDigestRequestTemplate.settleArgs(_args);
            __wpx721().witnetTokenStats = tokenStatsRequestTemplate.settleArgs(_args);
        }
    }

    function _verifyPrototypeCompliance(address _prototype)
        virtual
        internal view
    {
        require(
            _prototype.supportsInterface(type(IWittyPixelsTokenVault).interfaceId),
            "WittyPixelsToken: uncompliant prototype"
        );
    }

    function __wpx721()
        internal pure
        returns (WittyPixelsLib.TokenStorage storage ptr)
    {
        assembly {
            ptr.slot := SLOTHASH
        }
    }
}