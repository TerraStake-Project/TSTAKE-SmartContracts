// SPDX-License-Identifier: MIT
const { ethers, upgrades } = require("hardhat");
const { expect } = require("chai");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("TerraStakeAccessControl - Robust Tests", function () {
  let TerraStakeAccessControl, terraStakeAccessControl, terraStakeAccessControlV2;
  let ERC20Mock, tStakeToken, usdc, weth, wtstk, wbtc;
  let MockV3Aggregator, priceFeed;
  let owner, admin, user1, user2, attacker;

  const MINIMUM_LIQUIDITY = ethers.utils.parseEther("1000");
  const MINIMUM_PRICE = ethers.utils.parseEther("1");
  const MAXIMUM_PRICE = ethers.utils.parseEther("10000");
  const MAX_ORACLE_DATA_AGE = 3600; // 1 hour
  const ONE_YEAR = 365 * 24 * 60 * 60;
  const ROLE_DURATION = ONE_YEAR / 2;

  // Utility function to deploy fresh contract
  async function deployContract() {
    const instance = await upgrades.deployProxy(TerraStakeAccessControl, [
      admin.address,
      priceFeed.address,
      usdc.address,
      weth.address,
      tStakeToken.address,
      wtstk.address,
      wbtc.address,
      MINIMUM_LIQUIDITY,
      MINIMUM_PRICE,
      MAXIMUM_PRICE,
      MAX_ORACLE_DATA_AGE
    ], { initializer: "initialize" });
    return instance;
  }

  before(async function () {
    [owner, admin, user1, user2, attacker] = await ethers.getSigners();

    // Deploy mock ERC20 tokens with realistic supply
    ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    tStakeToken = await ERC20Mock.deploy("TerraStake Token", "TSTK", ethers.utils.parseEther("1000000"));
    usdc = await ERC20Mock.deploy("USD Coin", "USDC", ethers.utils.parseEther("1000000"));
    weth = await ERC20Mock.deploy("Wrapped Ether", "WETH", ethers.utils.parseEther("1000000"));
    wtstk = await ERC20Mock.deploy("Wrapped TerraStake", "WTSTK", ethers.utils.parseEther("1000000"));
    wbtc = await ERC20Mock.deploy("Wrapped Bitcoin", "WBTC", ethers.utils.parseEther("1000000"));
    await Promise.all([
      tStakeToken.deployed(),
      usdc.deployed(),
      weth.deployed(),
      wtstk.deployed(),
      wbtc.deployed()
    ]);

    // Deploy mock Chainlink price feed with realistic price
    MockV3Aggregator = await ethers.getContractFactory("MockV3Aggregator");
    priceFeed = await MockV3Aggregator.deploy(8, ethers.utils.parseEther("2000")); // 2000 USD/ETH
    await priceFeed.deployed();

    // Deploy TerraStakeAccessControl
    TerraStakeAccessControl = await ethers.getContractFactory("TerraStakeAccessControl");
    terraStakeAccessControl = await deployContract();

    // Mint tokens to users
    await tStakeToken.transfer(user1.address, ethers.utils.parseEther("5000"));
    await wtstk.transfer(user1.address, ethers.utils.parseEther("5000"));
    await wbtc.transfer(user2.address, ethers.utils.parseEther("10"));
  });

  describe("Initialization", function () {
    it("should initialize with correct parameters", async function () {
      expect(await terraStakeAccessControl.tStakeToken()).to.equal(tStakeToken.address);
      expect(await terraStakeAccessControl.usdc()).to.equal(usdc.address);
      expect(await terraStakeAccessControl.weth()).to.equal(weth.address);
      expect(await terraStakeAccessControl.wtstk()).to.equal(wtstk.address);
      expect(await terraStakeAccessControl.wbtc()).to.equal(wbtc.address);
      expect(await terraStakeAccessControl.priceFeed()).to.equal(priceFeed.address);
      expect(await terraStakeAccessControl.minimumLiquidity()).to.equal(MINIMUM_LIQUIDITY);
      expect(await terraStakeAccessControl.minimumPrice()).to.equal(MINIMUM_PRICE);
      expect(await terraStakeAccessControl.maximumPrice()).to.equal(MAXIMUM_PRICE);
      expect(await terraStakeAccessControl.maxOracleDataAge()).to.equal(MAX_ORACLE_DATA_AGE);
      expect(await terraStakeAccessControl.hasRole(await terraStakeAccessControl.DEFAULT_ADMIN_ROLE(), admin.address)).to.be.true;
      expect(await terraStakeAccessControl.hasRole(await terraStakeAccessControl.DEFAULT_ADMIN_ROLE(), owner.address)).to.be.false;
    });

    it("should revert with invalid addresses", async function () {
      await expect(upgrades.deployProxy(TerraStakeAccessControl, [
        ethers.constants.AddressZero, priceFeed.address, usdc.address, weth.address,
        tStakeToken.address, wtstk.address, wbtc.address, MINIMUM_LIQUIDITY,
        MINIMUM_PRICE, MAXIMUM_PRICE, MAX_ORACLE_DATA_AGE
      ])).to.be.revertedWithCustomError(TerraStakeAccessControl, "InvalidAddress");
    });
  });

  describe("Role Management", function () {
    beforeEach(async function () {
      terraStakeAccessControl = await deployContract();
    });

    it("should grant role with expiration and verify hierarchy", async function () {
      await terraStakeAccessControl.connect(admin).setRoleHierarchy(terraStakeAccessControl.MINTER_ROLE(), terraStakeAccessControl.GOVERNANCE_ROLE());
      await terraStakeAccessControl.connect(admin).setRoleRequirement(terraStakeAccessControl.GOVERNANCE_ROLE(), ethers.utils.parseEther("1000"));
      await terraStakeAccessControl.connect(admin).grantRoleWithExpiration(terraStakeAccessControl.GOVERNANCE_ROLE(), user1.address, ONE_YEAR);
      
      await terraStakeAccessControl.connect(admin).setRoleRequirement(terraStakeAccessControl.MINTER_ROLE(), ethers.utils.parseEther("500"));
      await terraStakeAccessControl.connect(admin).grantRoleWithExpiration(terraStakeAccessControl.MINTER_ROLE(), user1.address, ROLE_DURATION);
      
      expect(await terraStakeAccessControl.hasValidRole(terraStakeAccessControl.MINTER_ROLE(), user1.address)).to.be.true;
      const expiration = await terraStakeAccessControl.roleExpirations(terraStakeAccessControl.MINTER_ROLE(), user1.address);
      expect(expiration).to.be.closeTo((await ethers.provider.getBlock("latest")).timestamp + ROLE_DURATION, 100);
    });

    it("should fail granting role without parent role", async function () {
      await terraStakeAccessControl.connect(admin).setRoleHierarchy(terraStakeAccessControl.MINTER_ROLE(), terraStakeAccessControl.GOVERNANCE_ROLE());
      await expect(
        terraStakeAccessControl.connect(admin).grantRoleWithExpiration(terraStakeAccessControl.MINTER_ROLE(), user2.address, ONE_YEAR)
      ).to.be.revertedWithCustomError(terraStakeAccessControl, "InvalidHierarchy");
    });

    it("should handle expired role", async function () {
      await terraStakeAccessControl.connect(admin).grantRoleWithExpiration(terraStakeAccessControl.MINTER_ROLE(), user1.address, 100);
      await time.increase(101);
      await terraStakeAccessControl.checkAndHandleExpiredRole(terraStakeAccessControl.MINTER_ROLE(), user1.address);
      expect(await terraStakeAccessControl.hasRole(terraStakeAccessControl.MINTER_ROLE(), user1.address)).to.be.false;
    });

    it("should grant batch roles with different tokens", async function () {
      await terraStakeAccessControl.connect(admin).setRoleRequirement(terraStakeAccessControl.LIQUIDITY_MANAGER_ROLE(), ethers.utils.parseEther("2000"));
      await terraStakeAccessControl.connect(admin).setRoleRequirementToken(terraStakeAccessControl.REWARD_MANAGER_ROLE(), wtstk.address);
      await terraStakeAccessControl.connect(admin).setRoleRequirement(terraStakeAccessControl.REWARD_MANAGER_ROLE(), ethers.utils.parseEther("1000"));
      
      const roles = [terraStakeAccessControl.LIQUIDITY_MANAGER_ROLE(), terraStakeAccessControl.REWARD_MANAGER_ROLE()];
      const durations = [ONE_YEAR, ROLE_DURATION];
      await terraStakeAccessControl.connect(admin).grantRoleBatch(roles, user1.address, durations);
      
      expect(await terraStakeAccessControl.hasValidRole(terraStakeAccessControl.LIQUIDITY_MANAGER_ROLE(), user1.address)).to.be.true;
      expect(await terraStakeAccessControl.hasValidRole(terraStakeAccessControl.REWARD_MANAGER_ROLE(), user1.address)).to.be.true;
    });

    it("should fail batch with mismatched lengths", async function () {
      await expect(
        terraStakeAccessControl.connect(admin).grantRoleBatch(
          [terraStakeAccessControl.MINTER_ROLE()],
          user1.address,
          [ONE_YEAR, ROLE_DURATION]
        )
      ).to.be.revertedWithCustomError(terraStakeAccessControl, "InvalidParameters");
    });

    it("should revoke and renounce roles", async function () {
      await terraStakeAccessControl.connect(admin).grantRole(terraStakeAccessControl.MINTER_ROLE(), user1.address);
      await terraStakeAccessControl.connect(admin).revokeRole(terraStakeAccessControl.MINTER_ROLE(), user1.address);
      expect(await terraStakeAccessControl.hasRole(terraStakeAccessControl.MINTER_ROLE(), user1.address)).to.be.false;

      await terraStakeAccessControl.connect(admin).grantRole(terraStakeAccessControl.MINTER_ROLE(), user2.address);
      await terraStakeAccessControl.connect(user2).renounceOwnRole(terraStakeAccessControl.MINTER_ROLE());
      expect(await terraStakeAccessControl.hasRole(terraStakeAccessControl.MINTER_ROLE(), user2.address)).to.be.false;
    });
  });

  describe("Token Configuration", function () {
    beforeEach(async function () {
      terraStakeAccessControl = await deployContract();
    });

    it("should configure role requirement with WBTC", async function () {
      await terraStakeAccessControl.connect(admin).setRoleRequirementToken(terraStakeAccessControl.MINTER_ROLE(), wbtc.address);
      await terraStakeAccessControl.connect(admin).setRoleRequirement(terraStakeAccessControl.MINTER_ROLE(), ethers.utils.parseEther("5"));
      await terraStakeAccessControl.connect(admin).grantRoleWithExpiration(terraStakeAccessControl.MINTER_ROLE(), user2.address, ONE_YEAR);
      expect(await terraStakeAccessControl.hasRole(terraStakeAccessControl.MINTER_ROLE(), user2.address)).to.be.true;
    });

    it("should fail with insufficient WTSTK balance", async function () {
      await terraStakeAccessControl.connect(admin).setRoleRequirementToken(terraStakeAccessControl.VESTING_MANAGER_ROLE(), wtstk.address);
      await terraStakeAccessControl.connect(admin).setRoleRequirement(terraStakeAccessControl.VESTING_MANAGER_ROLE(), ethers.utils.parseEther("10000"));
      await expect(
        terraStakeAccessControl.connect(admin).grantRole(terraStakeAccessControl.VESTING_MANAGER_ROLE(), user2.address)
      ).to.be.revertedWithCustomError(terraStakeAccessControl, "InsufficientTStakeBalance");
    });
  });

  describe("Oracle Validation", function () {
    beforeEach(async function () {
      terraStakeAccessControl = await deployContract();
      await priceFeed.updateAnswer(ethers.utils.parseEther("2000")); // Reset price
    });

    it("should validate price within bounds", async function () {
      await terraStakeAccessControl.validateWithOracle(ethers.utils.parseEther("2100")); // 5% deviation allowed
    });

    it("should fail with price too high", async function () {
      await priceFeed.updateAnswer(ethers.utils.parseEther("15000"));
      await expect(
        terraStakeAccessControl.validateWithOracle(ethers.utils.parseEther("2000"))
      ).to.be.revertedWithCustomError(terraStakeAccessControl, "PriceOutOfBounds");
    });

    it("should validate with timestamp and fail if stale", async function () {
      await terraStakeAccessControl.validateWithOracleAndTimestamp(ethers.utils.parseEther("2000"));
      await time.increase(MAX_ORACLE_DATA_AGE + 1);
      await expect(
        terraStakeAccessControl.validateWithOracleAndTimestamp(ethers.utils.parseEther("2000"))
      ).to.be.revertedWithCustomError(terraStakeAccessControl, "StaleOracleData");
    });

    it("should fail with invalid round", async function () {
      await priceFeed.updateRoundData(2, ethers.utils.parseEther("2000"), 0, 1); // answeredInRound < roundId
      await expect(
        terraStakeAccessControl.validateWithOracleAndTimestamp(ethers.utils.parseEther("2000"))
      ).to.be.revertedWithCustomError(terraStakeAccessControl, "InvalidOracleRound");
    });
  });

  describe("Liquidity Threshold", function () {
    beforeEach(async function () {
      terraStakeAccessControl = await deployContract();
    });

    it("should pass with combined TSTK and WTSTK liquidity", async function () {
      await tStakeToken.transfer(terraStakeAccessControl.address, ethers.utils.parseEther("600"));
      await wtstk.transfer(terraStakeAccessControl.address, ethers.utils.parseEther("500"));
      await terraStakeAccessControl.validateLiquidityThreshold();
    });

    it("should fail below threshold", async function () {
      await tStakeToken.transfer(terraStakeAccessControl.address, ethers.utils.parseEther("400"));
      await wtstk.transfer(terraStakeAccessControl.address, ethers.utils.parseEther("300"));
      await expect(
        terraStakeAccessControl.validateLiquidityThreshold()
      ).to.be.revertedWithCustomError(terraStakeAccessControl, "LiquidityThresholdNotMet");
    });
  });

  describe("Configuration Updates", function () {
    beforeEach(async function () {
      terraStakeAccessControl = await deployContract();
    });

    it("should update price bounds and oracle", async function () {
      const newMin = ethers.utils.parseEther("2");
      const newMax = ethers.utils.parseEther("5000");
      await terraStakeAccessControl.connect(admin).updatePriceBounds(newMin, newMax);
      expect(await terraStakeAccessControl.minimumPrice()).to.equal(newMin);
      expect(await terraStakeAccessControl.maximumPrice()).to.equal(newMax);

      const newPriceFeed = await MockV3Aggregator.deploy(8, ethers.utils.parseEther("3000"));
      await terraStakeAccessControl.connect(admin).updatePriceOracle(newPriceFeed.address);
      expect(await terraStakeAccessControl.priceFeed()).to.equal(newPriceFeed.address);
    });

    it("should fail with invalid price bounds", async function () {
      await expect(
        terraStakeAccessControl.connect(admin).updatePriceBounds(MAXIMUM_PRICE, MINIMUM_PRICE)
      ).to.be.revertedWithCustomError(terraStakeAccessControl, "InvalidParameters");
    });
  });

  describe("Security and Access Control", function () {
    beforeEach(async function () {
      terraStakeAccessControl = await deployContract();
    });

    it("should prevent non-admin from managing roles", async function () {
      await expect(
        terraStakeAccessControl.connect(attacker).grantRole(terraStakeAccessControl.MINTER_ROLE(), attacker.address)
      ).to.be.revertedWith("AccessControl: account is missing role");
    });

    it("should handle pausing correctly", async function () {
      await terraStakeAccessControl.connect(admin).pause();
      await expect(
        terraStakeAccessControl.connect(admin).grantRole(terraStakeAccessControl.MINTER_ROLE(), user1.address)
      ).to.be.revertedWith("Pausable: paused");

      await terraStakeAccessControl.connect(admin).unpause();
      await terraStakeAccessControl.connect(admin).grantRole(terraStakeAccessControl.MINTER_ROLE(), user1.address);
      expect(await terraStakeAccessControl.hasRole(terraStakeAccessControl.MINTER_ROLE(), user1.address)).to.be.true;
    });

    it("should prevent reentrancy", async function () {
      // Deploy a malicious contract to test reentrancy
      const MaliciousContract = await ethers.getContractFactory("MaliciousContract");
      const malicious = await MaliciousContract.deploy(terraStakeAccessControl.address);
      await tStakeToken.transfer(malicious.address, ethers.utils.parseEther("1000"));
      await expect(
        malicious.connect(attacker).attack(terraStakeAccessControl.MINTER_ROLE())
      ).to.be.revertedWith("ReentrancyGuard: reentrant call");
    });
  });

  describe("Upgradeability", function () {
    it("should upgrade contract and maintain state", async function () {
      await terraStakeAccessControl.connect(admin).grantRole(terraStakeAccessControl.MINTER_ROLE(), user1.address);
      const TerraStakeAccessControlV2 = await ethers.getContractFactory("TerraStakeAccessControl"); // Assume same contract for simplicity
      terraStakeAccessControlV2 = await upgrades.upgradeProxy(terraStakeAccessControl.address, TerraStakeAccessControlV2);
      expect(await terraStakeAccessControlV2.hasRole(terraStakeAccessControlV2.MINTER_ROLE(), user1.address)).to.be.true;
      expect(await terraStakeAccessControlV2.tStakeToken()).to.equal(tStakeToken.address);
    });

    it("should fail upgrade from non-upgrader", async function () {
      await expect(
        upgrades.upgradeProxy(terraStakeAccessControl.address, TerraStakeAccessControl, { signer: attacker })
      ).to.be.revertedWith("AccessControl: account is missing role");
    });
  });
});

// Mock Malicious Contract for reentrancy test
const MaliciousContract = {
  abi: [
    "function attack(bytes32 role) external"
  ],
  source: `
    // SPDX-License-Identifier: MIT
    pragma solidity ^0.8.0;
    import "./ITerraStakeAccessControl.sol";
    contract MaliciousContract {
      ITerraStakeAccessControl public target;
      constructor(address _target) {
        target = ITerraStakeAccessControl(_target);
      }
      function attack(bytes32 role) external {
        target.grantRoleWithExpiration(role, address(this), 365 days);
      }
      function onRoleGranted(bytes32, address, uint256) external {
        target.grantRoleWithExpiration(bytes32(0), address(this), 365 days); // Attempt reentrancy
      }
    }
  `
};
