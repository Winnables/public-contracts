// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/LinkTokenInterface.sol";

import "./Roles.sol";
import "./interfaces/IWinnablesTicketManager.sol";
import "./interfaces/IWinnablesTicket.sol";
import "./libraries/Bits.sol";
import "./libraries/ECDSA.sol";
import "./BaseCCIPSender.sol";
import "./BaseCCIPReceiver.sol";

contract WinnablesTicketManager is Roles, VRFConsumerBaseV2, IWinnablesTicketManager, BaseCCIPSender, BaseCCIPReceiver {
    using Bits for bytes32;
    using SafeERC20 for IERC20;

    uint256 constant internal MIN_RAFFLE_DURATION = 60;

    address immutable internal VRF_COORDINATOR;
    address immutable private TICKETS_CONTRACT;

    /// @dev The key hash of the Chainlink VRF
    bytes32 private immutable KEY_HASH;

    /// @dev The subscription ID of the Chainlink VRF
    uint64 public immutable SUBSCRIPTION_ID;

    /// @dev Mapping from Chainlink request id to struct RequestStatus
    mapping(uint256 => RequestStatus) internal _chainlinkRequests;

    /// @dev Mapping from raffle ID to struct Raffle
    mapping(uint256 => Raffle) private _raffles;

    /// @dev Nonces used in the signature that allows ticket sales to avoid signature reuse
    mapping(address => uint256) private _userNonces;

    /// @dev Contract constructor
    /// @param _linkToken Address of the LINK ERC20 token on the chain you are deploying to
    /// @param _vrfCoordinator Address of the Chainlink VRFCoordinator contract on the chain you are deploying to
    /// @param _subscriptionId ID of the Chainlink VRF subscription that will fund Random Number request
    /// @param _keyHash The key hash of the Chainlink VRF
    /// @param _tickets Address of the ERC1155 collection of the tickets
    /// @param _ccipRouter Address of the Chainlink CCIP Router
    constructor(
        address _linkToken,
        address _vrfCoordinator,
        uint64 _subscriptionId,
        bytes32 _keyHash,
        address _tickets,
        address _ccipRouter
    ) VRFConsumerBaseV2(_vrfCoordinator) BaseCCIPContract(_ccipRouter) BaseLinkConsumer(_linkToken) {
        VRF_COORDINATOR = _vrfCoordinator;
        SUBSCRIPTION_ID = _subscriptionId;
        KEY_HASH = _keyHash;
        TICKETS_CONTRACT = _tickets;
        _setRole(msg.sender, 0, true); // Deployer is admin by default
        LinkTokenInterface(LINK_TOKEN).approve(_ccipRouter, type(uint256).max);
    }

    // =============================================================
    // -- Public Views
    // =============================================================

    /// @notice (Public) Get general information about the state of a raffle
    /// @param id ID of the Raffle
    /// @return General information about the state the Raffle
    function getRaffle(uint256 id) external view returns(RaffleView memory) {
        Raffle storage raffle = _raffles[id];
        return RaffleView({
            raffleType: raffle.raffleType,
            startsAt: raffle.startsAt,
            endsAt: raffle.endsAt,
            minTicketsThreshold: raffle.minTicketsThreshold,
            maxTicketSupply: raffle.maxTicketSupply,
            maxHoldings: raffle.maxHoldings,
            totalRaised: raffle.totalRaised,
            status: raffle.status,
            chainlinkRequestId: raffle.chainlinkRequestId
        });
    }

    /// @notice (Public) Shows the participation details of a participant to a raffle
    /// @param raffleId ID of the raffle
    /// @param participant Address of the participant
    /// @return Participation data as an unpacked struct
    function getParticipation(uint256 raffleId, address participant) external view returns(ParticipationData memory) {
        bytes32 participation = _raffles[raffleId].participations[participant];
        return ParticipationData({
            totalSpent: participation.getUint64(0),
            totalPurchased: participation.getUint32(64),
            withdrawn: participation.getBool(96)
        });
    }

    /// @notice (Public) Shows the address of the winner of a raffle
    /// @param raffleId ID of the raffle
    /// @return winner Address of the winner
    function getWinner(uint256 raffleId) external view returns(address winner) {
        Raffle storage raffle = _raffles[raffleId];
        if (raffle.status < RaffleStatus.FULFILLED || raffle.status == RaffleStatus.CANCELED) {
            revert RaffleNotFulfilled();
        }
        winner = _getWinnerByRequestId(raffle.chainlinkRequestId);
    }

    /// @notice (Public) Get the status of a Chainlink request
    /// @param requestId ID of the Chainlink request
    /// @return fulfilled The fulfillment status
    /// @return randomWord the Random number if the request is fulfilled
    /// @return raffleId the ID of the associated raffle
    function getRequestStatus(uint256 requestId) external view returns (
        bool fulfilled,
        uint256 randomWord,
        uint256 raffleId
    ) {
        RequestStatus storage request = _chainlinkRequests[requestId];
        if (request.raffleId == 0) revert RequestNotFound(requestId);
        Raffle storage raffle = _raffles[request.raffleId];
        fulfilled = raffle.status == RaffleStatus.FULFILLED;
        randomWord = request.randomWord;
        raffleId = request.raffleId;
    }

    function shouldDrawRaffle(uint256 raffleId) external view returns(bool) {
        _checkShouldDraw(raffleId);
        return true;
    }

    function shouldCancelRafflle(uint256 raffleId) external view returns(bool) {
        _checkShouldCancel(raffleId);
        return true;
    }

    // =============================================================
    // -- Public functions
    // =============================================================

    /// @notice (Public) Participate in a raffle
    /// @param raffleId ID of the Raffle
    /// @param ticketCount Number of tickets purchased
    /// @param blockNumber Number of the block when the signature expires
    /// @param signature Signature provided by the API to authorize this ticket sale at given price
    function buyTickets(
        uint256 raffleId,
        uint16 ticketCount,
        uint256 blockNumber,
        bytes calldata signature
    ) external payable {
        if (ticketCount == 0) {
            revert InvalidTicketCount();
        }
        _checkTicketPurchaseable(raffleId, ticketCount);
        _checkPurchaseSig(raffleId, ticketCount, blockNumber, signature);

        Raffle storage raffle = _raffles[raffleId];
        bytes32 participation = raffle.participations[msg.sender];
        unchecked {
            raffle.participations[msg.sender] = participation
                .setUint64(0, uint64(participation.getUint64(0) + msg.value))
                .setUint32(64, uint32(participation.getUint32(64) + ticketCount));
        }
        IWinnablesTicket(TICKETS_CONTRACT).mint(msg.sender, raffleId, ticketCount);
        unchecked {
            raffle.totalRaised += msg.value;
            _userNonces[msg.sender]++;
        }
        IWinnablesTicket(TICKETS_CONTRACT).refreshMetadata(raffleId);
    }

    /// @notice (Public) Refund their participation to a list of players for a canceled Raffle ID
    /// @param raffleId ID of the canceled Raffle
    /// @param players List of players to refund
    function refundPlayers(uint256 raffleId, address[] calldata players) external {
        Raffle storage raffle = _raffles[raffleId];
        if (raffle.status != RaffleStatus.CANCELED) {
            revert InvalidRaffle();
        }
        for (uint256 i = 0; i < players.length; ) {
            address player = players[i];
            bytes32 participation = raffle.participations[player];

            if (participation.getBool(96)) {
                revert PlayerAlreadyRefunded(player);
            }
            raffle.participations[player] = participation.setBool(96, true);
            _sendETH(uint256(participation.getUint64(0)), player);
            emit PlayerRefund(raffleId, player, participation);
            unchecked { ++i; }
        }
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

    /// @notice (Admin) Create NFT Raffle for an prize NFT previously sent to this contract
    /// @param raffleId ID Of the raffle shared with the remote chain
    /// @param startsAt Epoch timestamp in seconds of the raffle start time
    /// @param endsAt Epoch timestamp in seconds of the raffle end time
    /// @param minTickets Minimum number of tickets required to be sold for this raffle
    /// @param maxHoldings Maximum number of tickets one player can hold
    function createRaffle(
        uint256 raffleId,
        uint64 startsAt,
        uint64 endsAt,
        uint32 minTickets,
        uint32 maxTickets,
        uint32 maxHoldings
    ) external onlyRole(0) {
        _checkRaffleTimings(startsAt, endsAt);
        Raffle storage raffle = _raffles[raffleId];
        if (raffle.status != RaffleStatus.PRIZE_LOCKED) {
            revert PrizeNotLocked();
        }

        raffle.status = RaffleStatus.IDLE;
        raffle.startsAt = startsAt;
        raffle.endsAt = endsAt;
        raffle.minTicketsThreshold = minTickets;
        raffle.maxTicketSupply = maxTickets;
        raffle.maxHoldings = maxHoldings;

        emit NewRaffle(raffleId);
    }

    /// @notice (Admin) Cancel a raffle
    /// @param raffleId ID of the raffle to cancel
    function cancelRaffle(address prizeManager, uint64 chainSelector, uint256 raffleId) external {
        _checkShouldCancel(raffleId);

        _raffles[raffleId].status = RaffleStatus.CANCELED;
        _sendCCIPMessage(prizeManager, chainSelector, abi.encodePacked(uint8(CCIPMessageType.RAFFLE_CANCELED), raffleId));
        IWinnablesTicket(TICKETS_CONTRACT).refreshMetadata(raffleId);
    }

    /// @notice (Admin) Withdraw Link or any ERC20 tokens accidentally sent here
    /// @param tokenAddress Address of the token contract
    function withdrawTokens(address tokenAddress, uint256 amount) external onlyRole(0) {
        IERC20 token = IERC20(tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (amount < balance) {
            revert InsufficientBalance();
        }
        token.safeTransfer(msg.sender, amount);
    }

    /// @notice (Admin) Withdraw ETH from a canceled raffle or ticket sales
    function withdrawETH() external onlyRole(0) {
        uint256 balance = address(this).balance;
        _sendETH(balance, msg.sender);
    }

    /// @notice (API) Send a request for random number from Chainlink VRF
    /// @param raffleId ID of the Raffle we wish to draw a winner for
    function drawWinner(uint256 raffleId) external {
        Raffle storage raffle = _raffles[raffleId];
        _checkShouldDraw(raffleId);

        uint256 requestId = VRFCoordinatorV2Interface(VRF_COORDINATOR).requestRandomWords(
            KEY_HASH,
            SUBSCRIPTION_ID,
            3,
            100_000,
            1
        );
        _chainlinkRequests[requestId] = RequestStatus({
            raffleId: raffleId,
            randomWord: 0
        });
        raffle.chainlinkRequestId = requestId;
        raffle.status = RaffleStatus.REQUESTED;
        emit RequestSent(requestId, raffleId);
        IWinnablesTicket(TICKETS_CONTRACT).refreshMetadata(raffleId);
    }

    function propagateRaffleWinner(address prizeManager, uint64 chainSelector, uint256 raffleId) external {
        Raffle storage raffle = _raffles[raffleId];
        if (raffle.status != RaffleStatus.FULFILLED) {
            revert InvalidRaffleStatus();
        }
        raffle.status = RaffleStatus.PROPAGATED;
        address winner = _getWinnerByRequestId(raffle.chainlinkRequestId);

        _sendCCIPMessage(prizeManager, chainSelector, abi.encodePacked(uint8(CCIPMessageType.WINNER_DRAWN), raffleId, winner));
        IWinnablesTicket(TICKETS_CONTRACT).refreshMetadata(raffleId);
    }

    /// @notice (Approver) Get the nonce of a given address to use for a ticket purchase approval signature
    /// @param buyer Address of the account that wants to purchase a ticket
    /// @return nonce for this account
    function getNonce(address buyer) external view returns(uint256) {
        return _userNonces[buyer];
    }

    /// @notice (Chainlink VRF Coordinator) Use given random number as a result to determine the winner of a Raffle
    /// @param requestId ID of the VRF request to fulfill
    /// @param randomWords Array of 32 bytes integers sent back from the oracle
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal override {
        RequestStatus storage request = _chainlinkRequests[requestId];
        if (request.raffleId == 0) revert RequestNotFound(requestId);
        request.randomWord = randomWords[0];
        Raffle storage raffle = _raffles[request.raffleId];
        if (raffle.status != RaffleStatus.REQUESTED) {
            revert InvalidRaffle();
        }
        raffle.status = RaffleStatus.FULFILLED;

        emit WinnerDrawn(requestId);
        IWinnablesTicket(TICKETS_CONTRACT).refreshMetadata(request.raffleId);
    }

    /// @notice (Chainlink CCIP Router) Mark prize as locked
    /// @param message CCIP Message
    function _ccipReceive(
        Client.Any2EVMMessage memory message
    ) internal override {
        (address _senderAddress) = abi.decode(message.sender, (address));
        bytes32 counterpart = _packCCIPContract(_senderAddress, message.sourceChainSelector);
        if (!_ccipContracts[counterpart]) {
            revert UnauthorizedCCIPSender();
        }
        (uint256 raffleId) = abi.decode(message.data, (uint256));
        _raffles[raffleId].status = RaffleStatus.PRIZE_LOCKED;

        emit RafflePrizeLocked(
            message.messageId,
            message.sourceChainSelector,
            raffleId
        );
    }

    // =============================================================
    // -- Internal functions
    // =============================================================

    /// @dev Checks that a raffle's start time and end time are consistent with the rules:
    ///      - Raffle duration should be at least MIN_RAFFLE_DURATION
    ///      - Raffle duration from the moment of creation should be at least MIN_RAFFLE_DURATION
    ///      We check both conditions to avoid someone creating a raffle with a starting time in the past and an
    ///      ending time in less than MIN_RAFFLE_DURATION. But at the same time, we don't want to force a starting time
    ///      in the future because someone might want to create a raffle that starts immediately and the transaction
    ///      may be mined a few seconds after it was submitted.
    /// @param startsAt Raffle scheduled starting time
    /// @param endsAt Raffle scheduled ending time
    function _checkRaffleTimings(uint64 startsAt, uint64 endsAt) internal view {
        if (startsAt == 0) {
            revert RaffleNeedsStartTime();
        }
        if (endsAt < startsAt) {
            revert RaffleClosingTooSoon();
        }
        if (startsAt + MIN_RAFFLE_DURATION > endsAt) {
            revert RaffleClosingTooSoon();
        }
        if (endsAt < block.timestamp + MIN_RAFFLE_DURATION) {
            revert RaffleClosingTooSoon();
        }
    }

    /// @dev Checks that all the necessary conditions are met to purchase a ticket
    /// @param raffleId ID of the raffle for which the tickets are being sold
    /// @param ticketCount Number of tickets to be sold
    function _checkTicketPurchaseable(uint256 raffleId, uint256 ticketCount) internal view {
        Raffle storage raffle = _raffles[raffleId];
        if (raffle.startsAt == 0) {
            revert RaffleHasNotStarted();
        }
        if (raffle.status != RaffleStatus.IDLE) {
            revert RaffleHasEnded();
        }
        if (block.timestamp < raffle.startsAt) {
            revert RaffleHasNotStarted();
        }
        if (raffle.endsAt > 0) { // If endsAt === 0 it means the raffle has no forced end time
            if (block.timestamp > raffle.endsAt) {
                revert RaffleHasEnded();
            }
        }
        if (raffle.maxHoldings > 0) {
            unchecked {
                if (raffle.participations[msg.sender].getUint32(64) + ticketCount > raffle.maxHoldings) {
                    revert TooManyTickets();
                }
            }
        }
        if (raffle.maxTicketSupply > 0) {
            uint256 supply = IWinnablesTicket(TICKETS_CONTRACT).supplyOf(raffleId);
            unchecked {
                if (supply + ticketCount > raffle.maxTicketSupply) {
                    revert TooManyTickets();
                }
            }
        }
    }

    function _checkShouldDraw(uint256 raffleId) internal view {
        Raffle storage raffle = _raffles[raffleId];
        if (raffle.status != RaffleStatus.IDLE) {
            revert InvalidRaffle();
        }
        uint256 currentTicketSold = IWinnablesTicket(TICKETS_CONTRACT).supplyOf(raffleId);
        if (currentTicketSold == 0) {
            revert NoParticipants();
        }

        if (block.timestamp < raffle.endsAt) {
            if (currentTicketSold < raffle.maxTicketSupply) {
                revert RaffleIsStillOpen();
            }
        }
        if (currentTicketSold < raffle.minTicketsThreshold) {
            revert TargetTicketsNotReached();
        }
    }

    function _checkShouldCancel(uint256 raffleId) internal view {
        Raffle storage raffle = _raffles[raffleId];
        if (raffle.status == RaffleStatus.PRIZE_LOCKED) {
            return;
        }
        if (raffle.status != RaffleStatus.IDLE) {
            revert InvalidRaffle();
        }
        if (raffle.endsAt > block.timestamp) {
            revert RaffleIsStillOpen();
        }
        uint256 supply = IWinnablesTicket(TICKETS_CONTRACT).supplyOf(raffleId);
        if (supply > raffle.minTicketsThreshold) {
            revert TargetTicketsReached();
        }
    }

    /// @dev Checks the validity of a signature to allow the purchase of tickets at a given price
    /// @param raffleId ID of the Raffle
    /// @param ticketCount Number of tickets purchased
    /// @param blockNumber Number of the block when the signature expires
    /// @param signature Signature to check
    function _checkPurchaseSig(uint256 raffleId, uint16 ticketCount, uint256 blockNumber, bytes calldata signature) internal view {
        if (blockNumber < block.number) {
            revert ExpiredCoupon();
        }
        address signer = _getSigner(
            keccak256(
                abi.encodePacked(
                    msg.sender, _userNonces[msg.sender], raffleId, ticketCount, blockNumber, msg.value
                )
            ), signature
        );
        if (!_hasRole(signer, 1)) {
            revert Unauthorized();
        }
    }

    /// @dev Extracts the address of the signer from a signed message
    /// @param message SHA-3 Hash of the signed message
    /// @param signature Signature
    /// @return Address of the signer
    function _getSigner(bytes32 message, bytes calldata signature) internal pure returns(address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                message
            )
        );
        return ECDSA.recover(hash, signature);
    }

    /// @dev Get the address of the winner of a raffle for a given Chainlink request
    /// @param requestId ID of the Chainlink request
    /// @return Address of the winner of the raffle
    function _getWinnerByRequestId(uint256 requestId) internal view returns(address) {
        RequestStatus storage request = _chainlinkRequests[requestId];
        uint256 supply = IWinnablesTicket(TICKETS_CONTRACT).supplyOf(request.raffleId);
        uint256 winningTicketNumber = request.randomWord % supply;
        return IWinnablesTicket(TICKETS_CONTRACT).ownerOf(request.raffleId, winningTicketNumber);
    }

    /// @dev Sends ETH to an account and handles error cases
    /// @param amount The amount to send
    /// @param to The recipient
    function _sendETH(uint256 amount, address to) internal {
        if (amount == 0) {
            revert NothingToSend();
        }
        (bool success, ) = to.call{ value: amount }("");
        if (!success) {
            revert SendETHFailed();
        }
    }
}
