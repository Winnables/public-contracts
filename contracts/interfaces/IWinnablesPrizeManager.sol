// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./IWinnables.sol";

interface IWinnablesPrizeManager is IWinnables {
    error InvalidRaffleId();
    error NFTLocked();

    event NFTPrizeLocked(uint256 indexed raffleId, address indexed contractAddress, uint256 indexed tokenId);
    event TokenPrizeLocked(uint256 indexed raffleId, address indexed contractAddress, uint256 indexed amount);
    event ETHPrizeLocked(uint256 indexed raffleId, uint256 indexed amount);
    event PrizeUnlocked(uint256 indexed raffleId);
    event TokenPrizeUnlocked(uint256 indexed raffleId);
    event ETHPrizeUnlocked(uint256 indexed raffleId);
    event WinnerPropagated(uint256 indexed raffleId, address indexed winner);

    enum CCIPMessageType {
        RAFFLE_CANCELED,
        WINNER_DRAWN
    }
}
