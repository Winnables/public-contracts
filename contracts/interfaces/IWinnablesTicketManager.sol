// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "./IWinnables.sol";

interface IWinnablesTicketManager is IWinnables {
    error PrizeNotLocked();
    error InvalidRaffleStatus();
    error InvalidTicketCount();
    error RaffleWontDraw();

    event RafflePrizeLocked(bytes32 messageId, uint64 sourceChainSelector, uint256 raffleId);

    enum CCIPMessageType {
        RAFFLE_CANCELED,
        WINNER_DRAWN
    }
}
