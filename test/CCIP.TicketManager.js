const { ethers } = require('hardhat');
const { expect } = require('chai');
const helpers = require('@nomicfoundation/hardhat-network-helpers');

const {
  getWalletWithEthers, blockTime, timeSeconds,
} = require('./common/utils');
const { ccipDeployTicketManager } = require('../utils/demo');
const { randomWord } = require('./common/chainlink');
const { whileImpersonating } = require('../utils/impersonate');

ethers.utils.Logger.setLogLevel(ethers.utils.Logger.levels.ERROR);

describe('CCIP Ticket Manager', () => {
  let ccipRouter;
  let link;
  let signers;
  let manager;
  let approver;
  let winnablesDeployer;
  let nft;
  let token;
  let api;
  let snapshot;
  let counterpartContractAddress;
  let coordinator;

  before(async () => {
    signers = await ethers.getSigners();
    const result = await ccipDeployTicketManager();
    approver = result.approver;
    winnablesDeployer = signers[0];
    link = result.link;
    manager = result.ticketManager;
    nft = result.nft;
    token = result.token;
    ccipRouter = result.ccipRouter;
    coordinator = result.coordinator;
    api = await getWalletWithEthers();
    await (await manager.setRole(api.address, 1, true)).wait();
    counterpartContractAddress = signers[1].address;
  });

  it('Should not be able to create a raffle before the prize is locked', async () => {
    const now = await blockTime();
    await expect(manager.createRaffle(
      1,
      now,
      now + timeSeconds.hour,
      0,
      500,
      100
    )).to.be.revertedWithCustomError(manager, 'PrizeNotLocked');
  });

  it('Should not accept prize locked notification from unauthorized source', async () => {
    const tx = whileImpersonating(ccipRouter.address, ethers.provider, async (signer) =>
      manager.connect(signer).ccipReceive({
        messageId: ethers.constants.HashZero,
        sourceChainSelector: 1,
        sender: '0x' + counterpartContractAddress.slice(-40).padStart(64, '0'),
        data: '0x000000000000000000000000000000000000000000000000000000000000000001',
        destTokenAmounts: []
      })
    );
    await expect(tx).to.be.revertedWithCustomError(manager, 'UnauthorizedCCIPSender');
  });

  it('Should be able to notify that the prize was locked', async () => {
    await (await manager.setCCIPCounterpart(counterpartContractAddress, 1, true)).wait();
    const tx = await whileImpersonating(ccipRouter.address, ethers.provider, async (signer) =>
      manager.connect(signer).ccipReceive({
        messageId: ethers.constants.HashZero,
        sourceChainSelector: 1,
        sender: '0x' + counterpartContractAddress.slice(-40).padStart(64, '0'),
        data: '0x0000000000000000000000000000000000000000000000000000000000000001',
        destTokenAmounts: []
      })
    );
    const { events } = await tx.wait();
    expect(events).to.have.lengthOf(1);
    expect(events[0].event).to.eq('RafflePrizeLocked');
    const { raffleId } = events[0].args;
    expect(raffleId).to.eq(1);
  });

  describe('Cancellation with zero participant', async () => {
    before(async () => {
      snapshot = await helpers.takeSnapshot();
    });

    after(async () => {
      await snapshot.restore();
    });

    it('Create Raffle with 0 ticket min', async () => {
      const now = await blockTime();
      const tx = await manager.createRaffle(
        1,
        now,
        now + timeSeconds.hour,
        0,
        500,
        100
      );
      const { events } = await tx.wait();
      expect(events).to.have.lengthOf(1);
      expect(events[0].event).to.eq('NewRaffle');
      const { id } = events[0].args;
      expect(id).to.eq(1);
    });

    it('Should not be able to cancel if the raffle is still open', async () => {
      await expect(
        manager.cancelRaffle(counterpartContractAddress, 1, 1)
      ).to.be.revertedWithCustomError(manager, 'RaffleIsStillOpen');
    });

    it('Waits 1h', async () => {
      await helpers.time.increase(timeSeconds.hour);
    })

    it('Should not be able to cancel with insufficient LINK balance', async () => {
      await expect(manager.cancelRaffle(counterpartContractAddress, 1, 1)).to.be.revertedWithCustomError(
        manager,
        'InsufficientLinkBalance'
      );
    });

    it('Mints LINK to the ticket manager', async () => {
      await (await link.mint(manager.address, ethers.utils.parseEther('100'))).wait();
    });

    it('Should not be able to draw the raffle', async () => {
      await expect(manager.drawWinner(1)).to.be.revertedWithCustomError(manager, 'NoParticipants')
    });

    it('Cancels and sends cancellation CCIP Message', async () => {
      const tx = await manager.cancelRaffle(counterpartContractAddress, 1, 1);
      const { events } = await tx.wait();
      expect(events).to.have.lengthOf(3);
      const ccipMessageEvent = ccipRouter.interface.parseLog(events[0]);
      expect(ccipMessageEvent.name).to.eq('CCIPMessage');
      expect(ccipMessageEvent.args.data).to.eq('0x000000000000000000000000000000000000000000000000000000000000000001');
    });
  })

  describe('Cancellation with tickets threshold not reached', async () => {
    let buyer1;
    let buyer2;

    before(async () => {
      snapshot = await helpers.takeSnapshot();
    });

    after(async () => {
      await snapshot.restore();
    });

    it('Mints LINK to the ticket manager', async () => {
      await (await link.mint(manager.address, ethers.utils.parseEther('100'))).wait();
    });

    it('Create Raffle with 50 ticket min', async () => {
      const now = await blockTime();
      const tx = await manager.createRaffle(
        1,
        now,
        now + timeSeconds.hour,
        50,
        500,
        10
      );
      const { events } = await tx.wait();
      expect(events).to.have.lengthOf(1);
      expect(events[0].event).to.eq('NewRaffle');
      const { id } = events[0].args;
      expect(id).to.eq(1);
    });

    it('Buyer 1 gets 10 free tickets', async () => {
      buyer1 = await getWalletWithEthers();
      const currentBlock = await ethers.provider.getBlockNumber();
      const sig = await api.signMessage(ethers.utils.arrayify(
        ethers.utils.solidityKeccak256(['address', 'uint256', 'uint256', 'uint16', 'uint256', 'uint256'], [
          buyer1.address,
          0,
          1,
          10,
          currentBlock + 10,
          0
        ])
      ));
      const { events } = await (await manager.connect(buyer1).buyTickets(1, 10, currentBlock + 10, sig)).wait();
      expect(events).to.have.lengthOf(3);
    });

    it('Buyer 2 gets 10 tickets for 100 wei', async () => {
      buyer2 = await getWalletWithEthers();
      const currentBlock = await ethers.provider.getBlockNumber();
      const sig = await api.signMessage(ethers.utils.arrayify(
        ethers.utils.solidityKeccak256(['address', 'uint256', 'uint256', 'uint16', 'uint256', 'uint256'], [
          buyer2.address,
          0,
          1,
          10,
          currentBlock + 10,
          100
        ])
      ));
      const { events } = await (
        await manager.connect(buyer2).buyTickets(1, 10, currentBlock + 10, sig, { value: 100 })
      ).wait();
      expect(events).to.have.lengthOf(3);
    });

    it('Should not be able to cancel if the raffle is still open', async () => {
      await expect(manager.cancelRaffle(counterpartContractAddress, 1, 1))
        .to.be.revertedWithCustomError(manager, 'RaffleIsStillOpen');
    });

    it('Should not be able to draw the raffle', async () => {
      await expect(manager.drawWinner(1))
        .to.be.revertedWithCustomError(manager, 'RaffleIsStillOpen')
    });

    it('Waits 1h', async () => {
      await helpers.time.increase(timeSeconds.hour);
    });

    it('Should still not be able to draw the raffle', async () => {
      await expect(manager.drawWinner(1))
        .to.be.revertedWithCustomError(manager, 'TargetTicketsNotReached');
    });

    it('Cancels and sends cancellation CCIP Message', async () => {
      const tx = await manager.cancelRaffle(counterpartContractAddress, 1, 1);
      const { events } = await tx.wait();
      expect(events).to.have.lengthOf(3);
      const ccipMessageEvent = ccipRouter.interface.parseLog(events[0]);
      expect(ccipMessageEvent.name).to.eq('CCIPMessage');
      expect(ccipMessageEvent.args.data).to.eq('0x000000000000000000000000000000000000000000000000000000000000000001');
    });

    it('Should not be able to refund tickets acquired for free', async () => {
      await expect(manager.refundPlayers(1, [buyer1.address]))
        .to.be.revertedWithCustomError(manager, 'NothingToSend');
    });

    it('Should be able to refund tickets purchased', async () => {
      const contractBalanceBefore = await ethers.provider.getBalance(manager.address);
      const userBalanceBefore = await ethers.provider.getBalance(buyer2.address);
      const tx = await manager.refundPlayers(1, [buyer2.address]);
      const { events } = await tx.wait();
      expect(events).to.have.lengthOf(1);
      const [ event ] = events;
      expect(event.event).to.equal('PlayerRefund');
      const { raffleId, player, participation } = event.args;
      const contractBalanceAfter = await ethers.provider.getBalance(manager.address);
      const userBalanceAfter = await ethers.provider.getBalance(buyer2.address);
      expect(contractBalanceAfter).to.eq(contractBalanceBefore.sub(100));
      expect(userBalanceAfter).to.eq(userBalanceBefore.add(100));
    });
  });

  describe('Should be able to buy tickets and draw a winner', async () => {
    before(async () => {
      snapshot = await helpers.takeSnapshot();
    });

    after(async () => {
      await snapshot.restore();
    });
    const buyers = [];

    it('Should be able to create a raffle', async () => {
      const now = await blockTime();
      const tx = await manager.createRaffle(
        1,
        now,
        now + timeSeconds.hour,
        0,
        500,
        100
      );
      const { events } = await tx.wait();
      expect(events).to.have.lengthOf(1);
      expect(events[0].event).to.eq('NewRaffle');
      const { id } = events[0].args;
      expect(id).to.eq(1);
    });

    it('Should be able to purchase tickets', async () => {
      for (let i = 0; i < 5; i++) {
        const buyer = await getWalletWithEthers();
        const currentBlock = await ethers.provider.getBlockNumber();
        const sig = await api.signMessage(ethers.utils.arrayify(
          ethers.utils.solidityKeccak256(['address', 'uint256', 'uint256', 'uint16', 'uint256', 'uint256'], [
            buyer.address,
            0,
            1,
            10,
            currentBlock + 10,
            0
          ])
        ));
        await (await manager.connect(buyer).buyTickets(1, 10, currentBlock + 10, sig)).wait();
        buyers.push(buyer);
      }
    });

    it('Should be able to draw the winner', async () => {
      await helpers.time.increase(7200);
      const tx = await manager.connect(api).drawWinner(1);
      const { events } = await tx.wait();
      expect(events).to.have.lengthOf(3);
    });

    it('Should be able to propagate when the winner is drawn', async () => {
      await (await link.mint(manager.address, ethers.utils.parseEther('100'))).wait();
      await (await coordinator.fulfillRandomWordsWithOverride(1, manager.address, [randomWord()])).wait();
      const { events } = await (await manager.propagateRaffleWinner(counterpartContractAddress, 1, 1)).wait();
      expect(events).to.have.lengthOf(3);
      const ccipEvent = ccipRouter.interface.parseLog(events[0]);
      expect(ccipEvent.args.chain).to.eq(1);
      expect(ccipEvent.args.receiver).to.eq('0x' + counterpartContractAddress.toLowerCase().slice(-40).padStart(64, '0'));
      expect(ccipEvent.args.data).to.have.lengthOf(108);
      const drawnWinner = ethers.utils.getAddress('0x' + ccipEvent.args.data.slice(-40));
      expect(buyers.find(b => b.address === drawnWinner)).to.not.be.undefined;
      expect(ccipEvent.args.data.slice(0, 68)).to.eq('0x010000000000000000000000000000000000000000000000000000000000000001');
    });
  });
});
