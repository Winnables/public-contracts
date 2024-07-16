// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IRollStar {

  enum RoundStatus {
    SCHEDULED,
    OPEN,
    REQUESTED,
    DRAWN,
    CANCELED
  }

  struct Config {
    uint16 roundDuration;
    uint16 roundCooldown;
    uint64 ethPerEntry;
    uint16 feeBps;
    uint8 maxParticipants;
    uint16 maxEntryValue;
  }

  struct Entry {
    address participant;
    uint16 value;
  }

  struct Participation {
    address participant;
    uint16 value;
  }

  struct Round {
    RoundStatus status;
    uint40 timeEnd;
    uint64 totalValue;
    uint8 participants;
    uint256 randomWord;
    mapping(uint64 => bytes32) entries;
    address winnerClaimed;
    bytes32 config;
  }

  /// @dev A version of the Round that can be fetched and returned in a view function (aka: without a mapping)
  struct RoundView {
    uint256 id;
    RoundStatus status;
    uint40 timeEnd;
    uint64 totalValue;
    uint8 participants;
    uint256 randomWord;
    Participation[] participations;
    address winnerClaimed;
    Config config;
  }

  error WaitForCurrentRound();
  error WaitForRoundCooldown();
  error NotCurrentRound();
  error RoundNotOpen();
  error IncorrectParticipationAmount();
  error RequestNotFound();
  error RoundNotDrawn();
  error InsufficientBalance();
  error IncorrectWinner();
  error ETHTransferFail();
  error NothingToWithdraw();

  event RoundStarted(uint256 indexed roundId);
  event RoundCanceled(uint256 indexed roundId);
  event RoundClosed(uint256 indexed roundId, bool indexed valid, uint256 indexed requestId);
  event WinnerDrawn(uint256 indexed requestId);
  event RollStarEntry(address indexed participant, uint256 indexed roundId, uint256 value);
}
