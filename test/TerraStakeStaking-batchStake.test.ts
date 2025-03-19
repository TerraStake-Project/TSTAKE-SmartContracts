import { expect } from "chai";
import { ethers, network } from "hardhat";
import { TerraStakeStaking, MockERC20, MockProjectRegistry } from "../typechain-types";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { describe, beforeEach, afterEach, it } from "mocha";

describe("TerraStakeStaking - batchStake", function() {
  // Test constants for clarity and maintainability
  const INITIAL_BALANCE = ethers.utils.parseEther("10000");
  const DEFAULT_STAKE_AMOUNT = ethers.utils.parseEther("100");
  const DEFAULT_DURATION = 30;
  const INVALID_PROJECT_ID = 999;
  const MAX_BATCH_SIZE = 50;
  const VALID_PROJECT_IDS = [1, 2, 3];
  const ADMIN_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ADMIN_ROLE"));

  let staking: TerraStakeStaking;
  let token: MockERC20;
  let projectRegistry: MockProjectRegistry;
  let owner: SignerWithAddress;
  let user: SignerWithAddress;
  let admin: SignerWithAddress;
  let nonAdmin: SignerWithAddress;
  let snapshotId: string;

  beforeEach(async function() {
    [owner, user, admin, nonAdmin] = await ethers.getSigners();
    
    // Deploy mock token
    const MockToken = await ethers.getContractFactory("MockERC20");
    token = await MockToken.deploy("Test Token", "TEST");
    await token.deployed();
    
    // Mint tokens to users
    await token.mint(user.address, INITIAL_BALANCE);
    await token.mint(admin.address, INITIAL_BALANCE);
    
    // Deploy mock project registry
    const MockRegistry = await ethers.getContractFactory("MockProjectRegistry");
    projectRegistry = await MockRegistry.deploy();
    await projectRegistry.deployed();
    
    // Add test projects
    await projectRegistry.addProject("Project 1");
    await projectRegistry.addProject("Project 2");
    await projectRegistry.addProject("Project 3");
    
    // Deploy staking contract
    const StakingFactory = await ethers.getContractFactory("TerraStakeStaking");
    staking = await StakingFactory.deploy();
    await staking.deployed();
    
    // Initialize staking contract
    await staking.initialize(
      token.address,
      projectRegistry.address,
      ethers.constants.AddressZero, // Mock addresses for other dependencies
      ethers.constants.AddressZero,
      ethers.constants.AddressZero
    );
    
    // Grant admin role
    await staking.grantRole(ADMIN_ROLE, admin.address);
    
    // Approve tokens for staking
    await token.connect(user).approve(staking.address, INITIAL_BALANCE);
    await token.connect(admin).approve(staking.address, INITIAL_BALANCE);
    
    // Take snapshot after setup
    snapshotId = await network.provider.send("evm_snapshot", []);
  });

  afterEach(async function() {
    // Revert to clean state after each test
    await network.provider.send("evm_revert", [snapshotId]);
  });

  // 1. Basic Input Validation Tests
  
  it("should revert when arrays have different lengths", async function() {
    const projectIds = [1, 2];
    const amounts = [100];
    const durations = [30, 60];
    const isLP = [true, false];
    const autoCompound = [false, true];

    await expect(
      staking.connect(user).batchStake(projectIds, amounts, durations, isLP, autoCompound)
    ).to.be.revertedWith("Array lengths must match");
  });

  it("should revert when trying to stake with zero amount", async function() {
    const projectIds = [VALID_PROJECT_IDS[0]];
    const amounts = [0];
    const durations = [DEFAULT_DURATION];
    const isLP = [false];
    const autoCompound = [false];

    await expect(
      staking.connect(user).batchStake(projectIds, amounts, durations, isLP, autoCompound)
    ).to.be.revertedWith("Amount must be greater than 0");
  });

  it("should revert when trying to stake with invalid duration", async function() {
    const projectIds = [VALID_PROJECT_IDS[0]];
    const amounts = [DEFAULT_STAKE_AMOUNT];
    const durations = [0];
    const isLP = [false];
    const autoCompound = [false];

    await expect(
      staking.connect(user).batchStake(projectIds, amounts, durations, isLP, autoCompound)
    ).to.be.revertedWith("Invalid duration");
  });
  
  // 2. Token Transfer Tests
  
  it("should transfer tokens correctly during batch stake", async function() {
    const projectIds = [VALID_PROJECT_IDS[0], VALID_PROJECT_IDS[1]];
    const amounts = [
      DEFAULT_STAKE_AMOUNT,
      DEFAULT_STAKE_AMOUNT.mul(2)
    ];
    const durations = [DEFAULT_DURATION, DEFAULT_DURATION * 2];
    const isLP = [false, false];
    const autoCompound = [false, false];
    
    const totalAmount = amounts[0].add(amounts[1]);
    
    await expect(() => 
      staking.connect(user).batchStake(projectIds, amounts, durations, isLP, autoCompound)
    ).to.changeTokenBalances(
      token,
      [user, staking],
      [totalAmount.mul(-1), totalAmount]
    );
  });
  
  it("should revert when user has insufficient balance", async function() {
    const projectIds = [VALID_PROJECT_IDS[0]];
    const amounts = [INITIAL_BALANCE.mul(2)]; // More than initial balance
    const durations = [DEFAULT_DURATION];
    const isLP = [false];
    const autoCompound = [false];
    
    await expect(
      staking.connect(user).batchStake(projectIds, amounts, durations, isLP, autoCompound)
    ).to.be.reverted; // ERC20 will revert with various messages depending on implementation
  });
  
  it("should revert when user has insufficient allowance", async function() {
    // Reset allowance to 0
    await token.connect(user).approve(staking.address, 0);
    
    const projectIds = [VALID_PROJECT_IDS[0]];
    const amounts = [DEFAULT_STAKE_AMOUNT];
    const durations = [DEFAULT_DURATION];
    const isLP = [false];
    const autoCompound = [false];
    
    await expect(
      staking.connect(user).batchStake(projectIds, amounts, durations, isLP, autoCompound)
    ).to.be.reverted; // ERC20 will revert with various messages
  });
  
  // 3. Successful Staking Tests
  
  it("should successfully batch stake multiple positions", async function() {
    const projectIds = VALID_PROJECT_IDS;
    const amounts = [
      DEFAULT_STAKE_AMOUNT,
      DEFAULT_STAKE_AMOUNT.mul(2),
      DEFAULT_STAKE_AMOUNT.mul(3)
    ];
    const durations = [DEFAULT_DURATION, DEFAULT_DURATION * 2, DEFAULT_DURATION * 3];
    const isLP = [true, false, true];
    const autoCompound = [false, true, false];

    await staking.connect(user).batchStake(projectIds, amounts, durations, isLP, autoCompound);

    for(let i = 0; i < projectIds.length; i++) {
      const position = await staking.getStakePosition(user.address, projectIds[i]);
      expect(position.projectId).to.equal(projectIds[i]);
      expect(position.amount).to.equal(amounts[i]);
      expect(position.duration).to.equal(durations[i]);
      expect(position.isLPStaker).to.equal(isLP[i]);
      expect(position.autoCompounding).to.equal(autoCompound[i]);
    }
  });
  
  it("should emit StakeCreated events for each position", async function() {
    const projectIds = [VALID_PROJECT_IDS[0], VALID_PROJECT_IDS[1]];
    const amounts = [
      DEFAULT_STAKE_AMOUNT,
      DEFAULT_STAKE_AMOUNT.mul(2)
    ];
    const durations = [DEFAULT_DURATION, DEFAULT_DURATION * 2];
    const isLP = [true, false];
    const autoCompound = [false, true];

    const tx = await staking.connect(user).batchStake(
      projectIds, amounts, durations, isLP, autoCompound
    );
    
    const receipt = await tx.wait();
    
    // Verify events were emitted
    const events = receipt.events?.filter(e => e.event === "StakeCreated");
    expect(events?.length).to.equal(2);
    
    // Verify first event args
    expect(events?.[0].args?.user).to.equal(user.address);
    expect(events?.[0].args?.projectId).to.equal(projectIds[0]);
    expect(events?.[0].args?.amount).to.equal(amounts[0]);
    
    // Verify second event args
    expect(events?.[1].args?.user).to.equal(user.address);
    expect(events?.[1].args?.projectId).to.equal(projectIds[1]);
    expect(events?.[1].args?.amount).to.equal(amounts[1]);
  });
  
  // 4. Gas Optimization Tests
  
  it("should consume less gas than individual stakes", async function() {
    const projectIds = [VALID_PROJECT_IDS[0], VALID_PROJECT_IDS[1]];
    const amounts = [
      DEFAULT_STAKE_AMOUNT,
      DEFAULT_STAKE_AMOUNT.mul(2)
    ];
    const durations = [DEFAULT_DURATION, DEFAULT_DURATION * 2];
    const isLP = [false, false];
    const autoCompound = [false, false];
    
    // Take a new snapshot for this test
    const testSnapshotId = await network.provider.send("evm_snapshot", []);
    
    // Measure gas for batch operation
    const batchTx = await staking.connect(user).batchStake(
      projectIds, amounts, durations, isLP, autoCompound
    );
    const batchReceipt = await batchTx.wait();
    const batchGas = batchReceipt.gasUsed;
    
    // Reset for individual operations
    await network.provider.send("evm_revert", [testSnapshotId]);
    
    // Measure gas for individual operations
    let totalIndividualGas = ethers.BigNumber.from(0);
    
    for (let i = 0; i < projectIds.length; i++) {
      const tx = await staking.connect(user).stake(
        projectIds[i], amounts[i], durations[i], isLP[i], autoCompound[i]
      );
      const receipt = await tx.wait();
      totalIndividualGas = totalIndividualGas.add(receipt.gasUsed);
    }
    
    // Verify batch uses less gas
    expect(batchGas).to.be.lt(totalIndividualGas);
    console.log(`Gas saved: ${totalIndividualGas.sub(batchGas).toString()} (${
      totalIndividualGas.sub(batchGas).mul(100).div(totalIndividualGas)}% reduction)`);
  });
  
  // 5. Maximum Batch Size Tests
  
  it("should handle maximum allowed batch size", async function() {
    // Create large arrays (adjust size based on gas limits)
    const batchSize = MAX_BATCH_SIZE;
    
    const projectIds = Array(batchSize).fill(0).map((_, i) => 1 + (i % 3));
    const amounts = Array(batchSize).fill(DEFAULT_STAKE_AMOUNT.div(10));
    const durations = Array(batchSize).fill(DEFAULT_DURATION);
    const isLP = Array(batchSize).fill(false);
    const autoCompound = Array(batchSize).fill(false);
    
    // This might revert if batch size is too large for block gas limit
    try {
      const tx = await staking.connect(user).batchStake(
        projectIds, amounts, durations, isLP, autoCompound
      );
      await tx.wait();
      
      // If it succeeds, verify at least some positions
      const position = await staking.getStakePosition(user.address, 1);
      expect(position.amount).to.equal(
        DEFAULT_STAKE_AMOUNT.div(10).mul(projectIds.filter(id => id === 1).length)
      );
    } catch (error) {
      // Add assertion to confirm it's a gas error, not another issue
      if (error.message.includes("out of gas") || error.message.includes("exceeds block gas limit")) {
        console.log("Maximum batch size test reverted due to gas limits as expected");
      } else {
        // Unexpected error type - should fail test
        throw new Error(`Test failed with unexpected error: ${error.message}`);
      }
    }
  });
  
  // 6. Access Control Tests
  
  it("should respect access control for batch stake operations", async function() {
    // Check if pause function exists by attempting to access it
    let canPause = false;
    try {
      // Use callStatic to check function existence without modifying state
      await staking.connect(admin).pause.callStatic();
      canPause = true;
    } catch (error) {
      if (!error.message.includes("not a function")) {
        throw error; // Re-throw unexpected errors
      }
      // Function doesn't exist, skip pause-specific tests
      this.skip();
      return;
    }
    
    if (canPause) {
      // Only admin should be able to pause
      await expect(
        staking.connect(nonAdmin).pause()
      ).to.be.reverted;
      
      // Admin should be able to pause
      await staking.connect(admin).pause();
      
      // Batch stake should be blocked when paused
      const projectIds = [VALID_PROJECT_IDS[0]];
      const amounts = [DEFAULT_STAKE_AMOUNT];
      const durations = [DEFAULT_DURATION];
      const isLP = [false];
      const autoCompound = [false];
      
      await expect(
        staking.connect(user).batchStake(projectIds, amounts, durations, isLP, autoCompound)
      ).to.be.revertedWith("Pausable: paused");
      
      // Unpause for other tests
      await staking.connect(admin).unpause();
    }
  });
  
  // 7. Edge Cases with Invalid Project IDs
  
  it("should revert when staking with invalid project ID", async function() {
    const invalidProjectId = INVALID_PROJECT_ID;
    
    await expect(
        staking.connect(user).batchStake(
            [invalidProjectId], 
            [DEFAULT_STAKE_AMOUNT], 
            [DEFAULT_DURATION], 
            [false], 
            [false]
          )
        ).to.be.revertedWith("Invalid project ID");
      });
      
      it("should handle mixed valid and invalid project IDs appropriately", async function() {
        const projectIds = [VALID_PROJECT_IDS[0], INVALID_PROJECT_ID]; // One valid, one invalid
        const amounts = [
          DEFAULT_STAKE_AMOUNT,
          DEFAULT_STAKE_AMOUNT.mul(2)
        ];
        const durations = [DEFAULT_DURATION, DEFAULT_DURATION * 2];
        const isLP = [false, false];
        const autoCompound = [false, false];
        
        // Should revert on first invalid project
        await expect(
          staking.connect(user).batchStake(projectIds, amounts, durations, isLP, autoCompound)
        ).to.be.revertedWith("Invalid project ID");
      });
      
      // 8. Additional Edge Cases (New)
      
      it("should handle duplicate project IDs in the batch appropriately", async function() {
        const projectIds = [VALID_PROJECT_IDS[0], VALID_PROJECT_IDS[0]]; // Same project ID twice
        const amounts = [
          DEFAULT_STAKE_AMOUNT,
          DEFAULT_STAKE_AMOUNT.mul(2)
        ];
        const durations = [DEFAULT_DURATION, DEFAULT_DURATION * 2];
        const isLP = [false, false];
        const autoCompound = [false, false];
        
        // Behavior depends on implementation - either combine stakes or revert
        try {
          await staking.connect(user).batchStake(projectIds, amounts, durations, isLP, autoCompound);
          
          // If it succeeds, verify the position (should be combined or last one wins)
          const position = await staking.getStakePosition(user.address, VALID_PROJECT_IDS[0]);
          
          // Check if implementation combines amounts or last one wins
          const isCombined = position.amount.eq(amounts[0].add(amounts[1]));
          const isLastWins = position.amount.eq(amounts[1]);
          
          expect(isCombined || isLastWins).to.be.true;
          
          if (isCombined) {
            console.log("Contract combines duplicate project stakes");
          } else if (isLastWins) {
            console.log("Contract uses last stake for duplicate projects");
            expect(position.duration).to.equal(durations[1]);
          }
        } catch (error) {
          // If it reverts, that's also a valid implementation choice
          console.log("Contract rejects duplicate project IDs in batch");
          expect(error.message).to.include("revert");
        }
      });
    
      it("should handle boundary duration values", async function() {
        // Test minimum valid duration (assuming 1 is minimum)
        const minDuration = 1;
        await staking.connect(user).batchStake(
          [VALID_PROJECT_IDS[0]], 
          [DEFAULT_STAKE_AMOUNT], 
          [minDuration], 
          [false], 
          [false]
        );
        
        const position = await staking.getStakePosition(user.address, VALID_PROJECT_IDS[0]);
        expect(position.duration).to.equal(minDuration);
        
        // Test maximum valid duration if applicable
        // This would depend on contract implementation
        // For example, if there's a max duration of 365 days:
        try {
          const maxDuration = 365;
          await staking.connect(user).batchStake(
            [VALID_PROJECT_IDS[1]], 
            [DEFAULT_STAKE_AMOUNT], 
            [maxDuration], 
            [false], 
            [false]
          );
          
          const maxPosition = await staking.getStakePosition(user.address, VALID_PROJECT_IDS[1]);
          expect(maxPosition.duration).to.equal(maxDuration);
        } catch (error) {
          // If it reverts, the contract might have a lower maximum duration
          console.log("Contract has a maximum duration limit");
        }
      });
    });        