// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";

import "./Roles.sol";
import "./BaseCCIPSender.sol";
import "./BaseCCIPReceiver.sol";
import "./interfaces/IWinnables.sol";
import "./interfaces/IWinnablesPrizeManager.sol";

import "hardhat/console.sol";

contract WinnablesPrizeManager is Roles, BaseCCIPSender, BaseCCIPReceiver, IWinnablesPrizeManager {
    using SafeERC20 for IERC20;

    error UnauthorizedToClaim();
    error InvalidAddress();

    /// @dev Mapping from raffleId to raffleType
    mapping(uint256 => RaffleType) private _raffleType;

    /// @dev Mapping from raffle ID to struct NFTInfo (only set when an NFT is locked in for a raffle)
    mapping(uint256 => NFTInfo) private _nftRaffles;

    /// @dev Mapping from raffle ID to prize amount (only set when ETH is locked in for a raffle)
    mapping(uint256 => uint256) private _ethRaffles;

    /// @dev Mapping from raffle ID to struct TokenInfo (only set for Tokens are locked in for a raffle)
    mapping(uint256 => TokenInfo) private _tokenRaffles;

    /// @dev Mapping from raffle ID to winner Address
    mapping(uint256 => address) private _winners;

    /// @dev Amount of ETH currently locked in an ETH Raffle
    uint256 private _ethLocked;

    /// @dev Mapping from token address to amount of tokens currently locked in a Token Raffle
    mapping(address => uint256) private _tokensLocked;

    /// @dev Mapping from NFT address to a mapping from tokenId to boolean
    ///      (true if locked in an NFT Raffle)
    mapping(address => mapping(uint256 => bool)) private _nftLocked;

    /// @dev Contract constructor
    /// @param _linkToken Address of the LINK ERC20 token on the chain you are deploying to
    /// @param _ccipRouter Address of the Chainlink RouterClient contract on the chain you are deploying to
    constructor(
        address _linkToken,
        address _ccipRouter
    ) BaseCCIPContract(_ccipRouter) BaseLinkConsumer(_linkToken) {
        _setRole(msg.sender, 0, true); // Deployer is admin by default
        LinkTokenInterface(LINK_TOKEN).approve(_ccipRouter, type(uint256).max);
    }

    // =============================================================
    // -- Public functions
    // =============================================================

    /// @notice (Public) Get information about the prize of an NFT raffle
    /// @param id ID of the Raffle
    /// @return Information about the prize of an NFT raffle
    function getNFTRaffle(uint256 id) external view returns(NFTInfo memory) {
        RaffleType raffleType = _raffleType[id];
        if (raffleType != RaffleType.NFT) {
            revert InvalidRaffle();
        }
        return _nftRaffles[id];
    }

    /// @notice (Public) Get the prize amount of an ETH raffle
    /// @param id ID of the Raffle
    /// @return Prize amount of an ETH raffle
    function getETHRaffle(uint256 id) external view returns(uint256) {
        RaffleType raffleType = _raffleType[id];
        if (raffleType != RaffleType.ETH) {
            revert InvalidRaffle();
        }
        return _ethRaffles[id];
    }

    /// @notice (Public) Get information about the prize of a Token raffle
    /// @param id ID of the Raffle
    /// @return Information about the prize of a Token raffle
    function getTokenRaffle(uint256 id) external view returns(TokenInfo memory) {
        RaffleType raffleType = _raffleType[id];
        if (raffleType != RaffleType.TOKEN) {
            revert InvalidRaffle();
        }
        return _tokenRaffles[id];
    }

    /// @notice (Public) Get the winner of a raffle by ID
    /// @param id ID of the Raffle
    /// @return Address of the winner if any, or address(0) otherwise
    function getWinner(uint256 id) external view returns(address) {
        return _winners[id];
    }

    /// @notice (Public) Send the prize for a Raffle to its rightful winner
    /// @param raffleId ID of the raffle
    function claimPrize(uint256 raffleId) external {
        if (msg.sender != _winners[raffleId]) {
            revert UnauthorizedToClaim();
        }
        RaffleType raffleType = _raffleType[raffleId];
        if (raffleType == RaffleType.NONE) {
            revert InvalidRaffle();
        }
        if (raffleType == RaffleType.NFT) {
            NFTInfo storage raffle = _nftRaffles[raffleId];
            _nftLocked[raffle.contractAddress][raffle.tokenId] = false;
            _sendNFTPrize(raffle.contractAddress, raffle.tokenId, msg.sender);
        }
        if (raffleType == RaffleType.TOKEN) {
            TokenInfo storage raffle = _tokenRaffles[raffleId];
            unchecked { _tokensLocked[raffle.tokenAddress] -= raffle.amount; }
            _sendTokenPrize(raffle.tokenAddress, raffle.amount, msg.sender);
        }
        if (raffleType == RaffleType.ETH) {
            unchecked { _ethLocked -= _ethRaffles[raffleId]; }
            _sendETHPrize(_ethRaffles[raffleId], msg.sender);
        }
        emit PrizeClaimed(raffleId, msg.sender);
    }

    // =============================================================
    // -- Admin functions
    // =============================================================

    /// @notice (Admin) Manage approved counterpart CCIP contracts
    /// @param contractAddress Address of counterpart contract on the remote chain
    /// @param chainSelector CCIP Chain selector of the remote chain
    /// @param enabled Boolean representing whether this counterpart should be allowed or denied
    function setCCIPCounterpart(
        address contractAddress,
        uint64 chainSelector,
        bool enabled
    ) external override onlyRole(0) {
        bytes32 counterpart = _packCCIPContract(contractAddress, chainSelector);
        _ccipContracts[counterpart] = enabled;
    }

    /// @notice (Admin) Send the prize for a Raffle to its rightful winner
    /// @param ticketManager Address of the Ticket Manager on the remote chain
    /// @param chainSelector CCIP Chain selector of the remote chain
    /// @param raffleId ID of the Raffle that will be associated
    /// @param nft NFT contract address
    /// @param tokenId NFT token id
    function lockNFT(
        address ticketManager,
        uint64 chainSelector,
        uint256 raffleId,
        address nft,
        uint256 tokenId
    ) external onlyRole(0) {
        if (_raffleType[raffleId] != RaffleType.NONE) {
            revert InvalidRaffleId();
        }
        if (IERC721(nft).ownerOf(tokenId) != address(this)) {
            revert InvalidPrize();
        }
        if (_nftLocked[nft][tokenId]) {
            revert InvalidPrize();
        }
        _raffleType[raffleId] = RaffleType.NFT;
        _nftLocked[nft][tokenId] = true;
        _nftRaffles[raffleId].contractAddress = nft;
        _nftRaffles[raffleId].tokenId = tokenId;

        _sendCCIPMessage(ticketManager, chainSelector, abi.encodePacked(raffleId));
        emit NFTPrizeLocked(raffleId, nft, tokenId);
    }

    /// @notice (Admin) Send the prize for a Raffle to its rightful winner
    /// @param ticketManager Address of the Ticket Manager on the remote chain
    /// @param chainSelector CCIP Chain selector of the remote chain
    /// @param raffleId ID of the Raffle that will be associated
    /// @param amount Amount of ETH to lock as a prize
    function lockETH(
        address ticketManager,
        uint64 chainSelector,
        uint256 raffleId,
        uint256 amount
    ) external payable onlyRole(0) {
        if (_raffleType[raffleId] != RaffleType.NONE) {
            revert InvalidRaffleId();
        }
        uint256 ethBalance = address(this).balance;

        if (ethBalance < amount + _ethLocked) {
            revert InvalidPrize();
        }
        _raffleType[raffleId] = RaffleType.ETH;
        _ethLocked += amount;
        _ethRaffles[raffleId] = amount;

        _sendCCIPMessage(ticketManager, chainSelector, abi.encodePacked(raffleId));
        emit ETHPrizeLocked(raffleId, amount);
    }

    /// @notice (Admin) Send the prize for a Raffle to its rightful winner
    /// @param ticketManager Address of the Ticket Manager on the remote chain
    /// @param chainSelector CCIP Chain selector of the remote chain
    /// @param raffleId ID of the Raffle that will be associated
    /// @param token Token contract address
    /// @param amount Amount of tokens to lock as a prize
    function lockTokens(
        address ticketManager,
        uint64 chainSelector,
        uint256 raffleId,
        address token,
        uint256 amount
    ) external onlyRole(0) {
        if (_raffleType[raffleId] != RaffleType.NONE) {
            revert InvalidRaffleId();
        }
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if (tokenBalance < amount + _tokensLocked[token]) {
            revert InvalidPrize();
        }
        _raffleType[raffleId] = RaffleType.TOKEN;
        unchecked { _tokensLocked[token] += amount; }
        _tokenRaffles[raffleId].tokenAddress = token;
        _tokenRaffles[raffleId].amount = amount;

        _sendCCIPMessage(ticketManager, chainSelector, abi.encodePacked(raffleId));
        emit TokenPrizeLocked(raffleId, token, amount);
    }

    /// @notice (Admin) Use this to withdraw any ERC20 from the contract that
    ///         is not locked in a raffle, or withdraw LINK
    /// @param token ERC20 address
    function withdrawToken(address token, uint256 amount) external onlyRole(0) {
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        uint256 availableBalance;
        unchecked { availableBalance = tokenBalance - _tokensLocked[token]; }
        if (availableBalance < amount) {
            revert InsufficientBalance();
        }
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice (Admin) Use this to withdraw any NFT from the contract that is
    ///         not locked in a raffle
    /// @param nft Address of the NFT contract
    /// @param tokenId ID of the NFT
    function withdrawNFT(address nft, uint256 tokenId) external onlyRole(0) {
        if (_nftLocked[nft][tokenId]) {
            revert NFTLocked();
        }

        IERC721(nft).transferFrom(address(this), msg.sender, tokenId);
    }

    /// @notice (Admin) Use this to withdraw ETH from the contract that is not
    ///         locked in a raffle
    /// @param amount Amount of ETH to withdraw
    function withdrawETH(uint256 amount) external onlyRole(0) {
        uint256 balance = address(this).balance;
        uint256 availableBalance;
        unchecked { availableBalance = balance - _ethLocked; }
        if (availableBalance < amount) {
            revert InsufficientBalance();
        }
        (bool success,) = msg.sender.call{ value: amount }("");
        if (!success) {
            revert ETHTransferFail();
        }
    }

    // =============================================================
    // -- Internal functions
    // =============================================================

    /// @notice Callback called by CCIP Router. Receives CCIP message and handles it
    /// @param message CCIPMessage
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        (address _senderAddress) = abi.decode(message.sender, (address));
        bytes32 counterpart = _packCCIPContract(_senderAddress, message.sourceChainSelector);
        if (!_ccipContracts[counterpart]) {
            revert UnauthorizedCCIPSender();
        }

        CCIPMessageType messageType = CCIPMessageType(uint8(message.data[0]));
        if (messageType == CCIPMessageType.RAFFLE_CANCELED) {
            uint256 raffleId = _decodeRaffleCanceledMessage(message.data);
            _cancelRaffle(raffleId);
            return;
        }
        if (messageType == CCIPMessageType.WINNER_DRAWN) {
            (uint256 raffleId, address winner) = _decodeWinnerDrawnMessage(message.data);
            _winners[raffleId] = winner;
            emit WinnerPropagated(raffleId, winner);
            return;
        }
        revert InvalidCCIPMessage();
    }

    function _cancelRaffle(uint256 raffleId) internal {
        RaffleType raffleType = _raffleType[raffleId];
        if (raffleType == RaffleType.NFT) {
            NFTInfo storage nftInfo = _nftRaffles[raffleId];
            _nftLocked[nftInfo.contractAddress][nftInfo.tokenId] = false;
        }
        if (raffleType == RaffleType.TOKEN) {
            TokenInfo storage tokenInfo = _tokenRaffles[raffleId];
            unchecked { _tokensLocked[tokenInfo.tokenAddress] -= tokenInfo.amount; }
        }
        if (raffleType == RaffleType.ETH) {
            unchecked { _ethLocked -= _ethRaffles[raffleId]; }
        }
        _raffleType[raffleId] = RaffleType.NONE;
        emit PrizeUnlocked(raffleId);
    }

    /// @dev Transfers the NFT prize to the winner
    /// @param nft NFT address
    /// @param tokenId NFT token id
    /// @param winner Address of the winner
    function _sendNFTPrize(address nft, uint256 tokenId, address winner) internal {
        IERC721(nft).transferFrom(address(this), winner, tokenId);
    }

    /// @dev Transfers the NFT prize to the winner
    /// @param token Token address
    /// @param amount Amount of tokens to send
    /// @param winner Address of the winner
    function _sendTokenPrize(address token, uint256 amount, address winner) internal {
        IERC20(token).safeTransfer(winner, amount);
    }
    /// @dev Transfers the NFT prize to the winner
    /// @param amount Amount of ETH to send
    /// @param winner Address of the winner
    function _sendETHPrize(uint256 amount, address winner) internal {
        (bool success, ) = winner.call{ value: amount }("");
        if (!success) {
            revert ETHTransferFail();
        }
    }

    function _decodeRaffleCanceledMessage(bytes memory b) internal pure returns(uint256 raffleId) {
        assembly {
            raffleId := mload(add(b, 0x21))
        }
    }

    function _decodeWinnerDrawnMessage(bytes memory b) internal pure returns(uint256 raffleId, address winner) {
        assembly {
            raffleId := mload(add(b, 0x21))
            winner := and(
                0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
                mload(add(b, 0x35))
            )
        }
    }
}
