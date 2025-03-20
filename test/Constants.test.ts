import { expect } from "chai";
import { ethers } from "hardhat";
import { Contract } from "ethers";

describe("Constants", () => {
  let contract: Contract;

  before(async () => {
    const ContractFactory = await ethers.getContractFactory("StakingContract");
    contract = await ContractFactory.deploy();
    await contract.deployed();
  });

  describe("Role Constants", () => {
    it("should have correct GOVERNANCE_ROLE hash", async () => {
      const expectedHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("GOVERNANCE_ROLE"));
      expect(await contract.GOVERNANCE_ROLE()).to.equal(expectedHash);
    });

    it("should have correct UPGRADER_ROLE hash", async () => {
      const expectedHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("UPGRADER_ROLE"));
      expect(await contract.UPGRADER_ROLE()).to.equal(expectedHash);
    });

    it("should have correct EMERGENCY_ROLE hash", async () => {
      const expectedHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EMERGENCY_ROLE"));
      expect(await contract.EMERGENCY_ROLE()).to.equal(expectedHash);
    });

    it("should have correct SLASHER_ROLE hash", async () => {
      const expectedHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("SLASHER_ROLE"));
      expect(await contract.SLASHER_ROLE()).to.equal(expectedHash);
    });
  });

  describe("APR Constants", () => {
    it("should have correct BASE_APR value", async () => {
      expect(await contract.BASE_APR()).to.equal(10);
    });

    it("should have correct BOOSTED_APR value", async () => {
      expect(await contract.BOOSTED_APR()).to.equal(20);
    });

    it("should have correct NFT_APR_BOOST value", async () => {
      expect(await contract.NFT_APR_BOOST()).to.equal(10);
    });

    it("should have correct LP_APR_BOOST value", async () => {
      expect(await contract.LP_APR_BOOST()).to.equal(15);
    });
  });

  describe("Penalty Constants", () => {
    it("should have correct BASE_PENALTY_PERCENT value", async () => {
      expect(await contract.BASE_PENALTY_PERCENT()).to.equal(10);
    });

    it("should have correct MAX_PENALTY_PERCENT value", async () => {
      expect(await contract.MAX_PENALTY_PERCENT()).to.equal(30);
    });
  });

  describe("Threshold and Duration Constants", () => {
    it("should have correct LOW_STAKING_THRESHOLD value", async () => {
      expect(await contract.LOW_STAKING_THRESHOLD()).to.equal(ethers.utils.parseEther("1000000"));
    });

    it("should have correct GOVERNANCE_VESTING_PERIOD value", async () => {
      expect(await contract.GOVERNANCE_VESTING_PERIOD()).to.equal(7 * 24 * 60 * 60);
    });

    it("should have correct MIN_STAKING_DURATION value", async () => {
      expect(await contract.MIN_STAKING_DURATION()).to.equal(30 * 24 * 60 * 60);
    });

    it("should have correct GOVERNANCE_THRESHOLD value", async () => {
      expect(await contract.GOVERNANCE_THRESHOLD()).to.equal(ethers.utils.parseEther("10000"));
    });
  });

  describe("Other Constants", () => {
    it("should have correct MAX_LIQUIDITY_RATE value", async () => {
      expect(await contract.MAX_LIQUIDITY_RATE()).to.equal(10);
    });

    it("should have correct BURN_ADDRESS value", async () => {
      expect(await contract.BURN_ADDRESS()).to.equal("0x000000000000000000000000000000000000dEaD");
    });
  });
});
