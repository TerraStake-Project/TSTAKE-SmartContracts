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
import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { 
  TerraStakeStaking,
  TerraStakeRewardDistributor,
  TerraStakeProjects,
  TerraStakeGovernance,
  TerraStakeSlashing,
  ERC1155,
  ERC20
} from "../typechain-types";

describe("TerraStakeStaking", () => {
  let staking: TerraStakeStaking;
  let nft: ERC1155;
  let token: ERC20;
  let rewardDistributor: TerraStakeRewardDistributor;
  let projects: TerraStakeProjects;
  let governance: TerraStakeGovernance;
  let slashing: TerraStakeSlashing;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let liquidityPool: SignerWithAddress;

  const GOVERNANCE_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("GOVERNANCE_ROLE"));
  const UPGRADER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("UPGRADER_ROLE"));
  const EMERGENCY_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("EMERGENCY_ROLE"));
  const SLASHER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("SLASHER_ROLE"));

  beforeEach(async () => {
    [owner, user1, user2, liquidityPool] = await ethers.getSigners();

    const NFT = await ethers.getContractFactory("ERC1155");
    nft = await NFT.deploy("");

    const Token = await ethers.getContractFactory("ERC20");
    token = await Token.deploy("Test Token", "TEST");

    const RewardDistributor = await ethers.getContractFactory("TerraStakeRewardDistributor");
    rewardDistributor = await RewardDistributor.deploy();

    const Projects = await ethers.getContractFactory("TerraStakeProjects");
    projects = await Projects.deploy();

    const Governance = await ethers.getContractFactory("TerraStakeGovernance");
    governance = await Governance.deploy();

    const Slashing = await ethers.getContractFactory("TerraStakeSlashing");
    slashing = await Slashing.deploy();

    const Staking = await ethers.getContractFactory("TerraStakeStaking");
    staking = await upgrades.deployProxy(Staking, [
      nft.address,
      token.address,
      rewardDistributor.address,
      liquidityPool.address,
      projects.address,
      governance.address,
      owner.address
    ]) as TerraStakeStaking;
  });

  describe("Initialization", () => {
    it("should initialize with correct parameters", async () => {
      expect(await staking.nftContract()).to.equal(nft.address);
      expect(await staking.stakingToken()).to.equal(token.address);
      expect(await staking.rewardDistributor()).to.equal(rewardDistributor.address);
      expect(await staking.liquidityPool()).to.equal(liquidityPool.address);
      expect(await staking.projectsContract()).to.equal(projects.address);
      expect(await staking.governanceContract()).to.equal(governance.address);
    });

    it("should set up correct roles", async () => {
      expect(await staking.hasRole(GOVERNANCE_ROLE, governance.address)).to.be.true;
      expect(await staking.hasRole(UPGRADER_ROLE, owner.address)).to.be.true;
      expect(await staking.hasRole(EMERGENCY_ROLE, owner.address)).to.be.true;
    });

    it("should revert initialization with zero addresses", async () => {
      const Staking = await ethers.getContractFactory("TerraStakeStaking");
      await expect(upgrades.deployProxy(Staking, [
        ethers.constants.AddressZero,
        token.address,
        rewardDistributor.address,
        liquidityPool.address,
        projects.address,
        governance.address,
        owner.address
      ])).to.be.revertedWith("InvalidAddress");
    });
  });

  describe("Staking Operations", () => {
    beforeEach(async () => {
      await token.mint(user1.address, ethers.utils.parseEther("1000"));
      await token.connect(user1).approve(staking.address, ethers.constants.MaxUint256);
      await projects.addProject("Test Project", "Description");
    });

    it("should allow staking with valid parameters", async () => {
      const amount = ethers.utils.parseEther("100");
      await expect(staking.connect(user1).stake(1, amount, 30 * 24 * 3600, false, true))
        .to.emit(staking, "Staked")
        .withArgs(user1.address, 1, amount, 30 * 24 * 3600, await ethers.provider.getBlock("latest").then(b => b.timestamp + 1), amount);
    });

    it("should revert staking with zero amount", async () => {
      await expect(staking.connect(user1).stake(1, 0, 30 * 24 * 3600, false, true))
        .to.be.revertedWith("ZeroAmount");
    });

    it("should revert staking with insufficient duration", async () => {
      await expect(staking.connect(user1).stake(1, ethers.utils.parseEther("100"), 86400, false, true))
        .to.be.revertedWith("InsufficientStakingDuration");
    });

    it("should track total staked amount correctly", async () => {
      const amount = ethers.utils.parseEther("100");
      await staking.connect(user1).stake(1, amount, 30 * 24 * 3600, false, true);
      expect(await staking.getTotalStaked()).to.equal(amount);
    });
  });

  describe("Validator Operations", () => {
    beforeEach(async () => {
      await token.mint(user1.address, ethers.utils.parseEther("1000000"));
      await token.connect(user1).approve(staking.address, ethers.constants.MaxUint256);
    });

    it("should allow becoming validator with sufficient stake", async () => {
      await staking.connect(user1).stake(1, ethers.utils.parseEther("100000"), 30 * 24 * 3600, false, true);
      await expect(staking.connect(user1).becomeValidator())
        .to.emit(staking, "ValidatorAdded")
        .withArgs(user1.address, await ethers.provider.getBlock("latest").then(b => b.timestamp + 1));
    });

    it("should revert becoming validator with insufficient stake", async () => {
      await staking.connect(user1).stake(1, ethers.utils.parseEther("1000"), 30 * 24 * 3600, false, true);
      await expect(staking.connect(user1).becomeValidator())
        .to.be.revertedWith("InvalidParameter");
    });
  });

  describe("Governance Operations", () => {
    beforeEach(async () => {
      await token.mint(user1.address, ethers.utils.parseEther("1000000"));
      await token.connect(user1).approve(staking.address, ethers.constants.MaxUint256);
    });

    it("should allow voting with sufficient stake", async () => {
      await staking.connect(user1).stake(1, ethers.utils.parseEther("100000"), 30 * 24 * 3600, false, true);
      await governance.createMockProposal(1);
      await expect(staking.connect(user1).voteOnProposal(1, true))
        .to.emit(staking, "ProposalVoted");
    });

    it("should revert voting without sufficient stake", async () => {
      await staking.connect(user1).stake(1, ethers.utils.parseEther("100"), 30 * 24 * 3600, false, true);
      await governance.createMockProposal(1);
      await expect(staking.connect(user1).voteOnProposal(1, true))
        .to.be.revertedWith("InvalidParameter");
    });
  });

  describe("Reward Calculations", () => {
    beforeEach(async () => {
      await token.mint(user1.address, ethers.utils.parseEther("1000000"));
      await token.connect(user1).approve(staking.address, ethers.constants.MaxUint256);
    });

    it("should calculate rewards correctly with NFT boost", async () => {
      await nft.mint(user1.address, 1, 1, "0x");
      await staking.connect(user1).stake(1, ethers.utils.parseEther("100000"), 365 * 24 * 3600, false, true);
      const rewards = await staking.calculateRewards(user1.address, 1);
      expect(rewards).to.be.gt(0);
    });

    it("should calculate rewards correctly with LP boost", async () => {
      await staking.connect(user1).stake(1, ethers.utils.parseEther("100000"), 365 * 24 * 3600, true, true);
      const rewards = await staking.calculateRewards(user1.address, 1);
      expect(rewards).to.be.gt(0);
    });
  });
});
