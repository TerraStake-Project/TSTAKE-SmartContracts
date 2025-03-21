// SPDX-License-Identifier: MIT
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");
const readline = require("readline");

/**
 * Adds a constituent to the AIEngine contract with enhanced validation and error handling.
 * @param {ethers.Contract} aiEngine - Deployed AIEngine contract instance
 * @param {string} assetAddress - Address of the asset to add (e.g., WETH)
 * @param {string} priceFeedAddress - Chainlink price feed address for the asset
 * @param {ethers.Signer} signer - Signer with AI_ADMIN_ROLE
 * @param {Object} options - Additional options
 * @returns {Promise<Object>} - Transaction receipt and added constituent details
 * @throws {Error} - If the operation fails or validations are not met
 */
async function addConstituent(aiEngine, assetAddress, priceFeedAddress, signer, options = {}) {
  const { dryRun = false, maxRetries = 3, gasMultiplier = 1.2 } = options;
  
  console.log(`\n====== Processing ${assetAddress} ======`);
  
  // Validate inputs
  if (!ethers.utils.isAddress(assetAddress) || assetAddress === ethers.constants.AddressZero) {
    throw new Error("Invalid asset address");
  }
  if (!ethers.utils.isAddress(priceFeedAddress) || priceFeedAddress === ethers.constants.AddressZero) {
    throw new Error("Invalid price feed address");
  }

  // Check if signer has AI_ADMIN_ROLE
  const AI_ADMIN_ROLE = await aiEngine.AI_ADMIN_ROLE();
  const hasAdminRole = await aiEngine.hasRole(AI_ADMIN_ROLE, signer.address);
  if (!hasAdminRole) {
    throw new Error(`Signer ${signer.address} lacks AI_ADMIN_ROLE. Please grant role first.`);
  }

  // Check if contract is paused
  const isPaused = await aiEngine.paused();
  if (isPaused) {
    throw new Error("Contract is paused. Please unpause before adding constituents.");
  }

  // Check if asset is already active
  const constituent = await aiEngine.constituents(assetAddress);
  if (constituent.isActive) {
    console.log(`WARNING: Asset ${assetAddress} is already an active constituent. Skipping.`);
    return { skipped: true, reason: "already_active", constituent };
  }

  // Check if this asset has a balance in the contract
  const assetContract = await ethers.getContractAt("IERC20", assetAddress);
  const balance = await assetContract.balanceOf(aiEngine.address);
  
  if (balance.eq(0)) {
    console.log(`WARNING: AIEngine has zero balance of asset ${assetAddress}`);
  } else {
    console.log(`Contract has ${ethers.utils.formatUnits(balance, 18)} tokens of ${assetAddress}`);
  }

  // If dry run mode, don't execute transaction
  if (dryRun) {
    console.log(`DRY RUN: Would add constituent ${assetAddress} with price feed ${priceFeedAddress}`);
    return { dryRun: true, asset: assetAddress, priceFeed: priceFeedAddress };
  }

  // Transaction execution with retry logic
  let attempts = 0;
  let lastError;

  while (attempts < maxRetries) {
    attempts++;
    try {
      console.log(`Attempt ${attempts}/${maxRetries}: Adding constituent ${assetAddress}`);
      
      // Estimate gas dynamically
      const gasEstimate = await aiEngine.estimateGas.addConstituent(assetAddress, priceFeedAddress);
      const gasLimit = Math.ceil(Number(gasEstimate) * gasMultiplier);
      
      console.log(`Estimated gas: ${gasEstimate.toString()}, Using limit: ${gasLimit}`);
      
      // Execute transaction
      const tx = await aiEngine.connect(signer).addConstituent(assetAddress, priceFeedAddress, {
        gasLimit
      });
      
      console.log(`Transaction submitted: ${tx.hash}`);
      console.log(`Waiting for confirmation...`);
      
      const receipt = await tx.wait();
      
      // Verify state changes
      const updatedConstituent = await aiEngine.constituents(assetAddress);
      const activeCount = await aiEngine.activeConstituentCount();
      const currentPriceFeed = await aiEngine.priceFeeds(assetAddress);
      
      console.log(`Successfully added constituent ${assetAddress}`);
      console.log(`Transaction details:`);
      console.log(`   - Hash: ${receipt.transactionHash}`);
      console.log(`   - Block: ${receipt.blockNumber}`);
      console.log(`   - Gas used: ${receipt.gasUsed.toString()}`);
      console.log(`   - Active constituent count: ${activeCount}`);
      console.log(`   - Price feed: ${currentPriceFeed}`);
      
      // Log any events
      const events = receipt.events?.filter(e => e.event === "ConstituentAdded") || [];
      if (events.length > 0) {
        console.log(`Events emitted: ${events.length} ConstituentAdded events`);
      }

      return {
        success: true,
        receipt,
        constituent: updatedConstituent,
        attempts
      };
    } catch (error) {
      lastError = error;
      
      // Check if error is potentially recoverable
      const errorMessage = error.message.toLowerCase();
      const isNonceError = errorMessage.includes("nonce") || errorMessage.includes("replacement");
      const isGasError = errorMessage.includes("gas") || errorMessage.includes("underpriced");
      const isTimeoutError = errorMessage.includes("timeout") || errorMessage.includes("network");
      
      if (isNonceError || isGasError || isTimeoutError) {
        console.log(`Recoverable error on attempt ${attempts}. Retrying...`);
        console.log(`   Error: ${error.message}`);
        
        // Wait with exponential backoff before retrying
        const backoffMs = Math.min(1000 * (2 ** (attempts - 1)), 30000);
        console.log(`   Waiting ${backoffMs/1000} seconds before retry...`);
        await new Promise(resolve => setTimeout(resolve, backoffMs));
      } else {
        // Non-recoverable error
        console.error(`Fatal error adding constituent ${assetAddress}:`, error.message);
        throw error;
      }
    }
  }
  
  // If we've reached here, we've exhausted all retry attempts
  console.error(`Failed after ${maxRetries} attempts to add constituent ${assetAddress}`);
  throw lastError;
}

/**
 * Main function to add new tokens to an already deployed AIEngine contract
 */
async function main() {
  try {
    console.log("Adding new constituents to AIEngine contract");
    
    // Process command line arguments
    const args = process.argv.slice(2);
    const isDryRun = args.includes("--dry-run");
    const configPath = args.find(arg => arg.startsWith("--config="))?.split("=")[1] || "constituents-config.json";
    
    console.log(`Mode: ${isDryRun ? "DRY RUN (no transactions will be sent)" : "LIVE"}`);
    console.log(`Config: ${configPath}`);
    
    // Get the deployed contract address
    const DEPLOYED_ENGINE_ADDRESS = process.env.AI_ENGINE_ADDRESS;
    if (!DEPLOYED_ENGINE_ADDRESS) {
      throw new Error("Please set AI_ENGINE_ADDRESS in your environment");
    }
    
    // Connect to the deployed AIEngine contract
    const AIEngine = await ethers.getContractFactory("AIEngine");
    const aiEngine = await AIEngine.attach(DEPLOYED_ENGINE_ADDRESS);
    console.log(`Connected to AIEngine at ${DEPLOYED_ENGINE_ADDRESS}`);
    
    // Get network information
    const network = await ethers.provider.getNetwork();
    console.log(`Network: ${network.name} (chainId: ${network.chainId})`);
    
    // Get admin signer
    const [admin] = await ethers.getSigners();
    console.log(`Using admin account: ${admin.address}`);
    console.log(`Admin balance: ${ethers.utils.formatEther(await admin.getBalance())} ETH`);
    
    // Check if admin has the required role
    const AI_ADMIN_ROLE = await aiEngine.AI_ADMIN_ROLE();
    const hasAdminRole = await aiEngine.hasRole(AI_ADMIN_ROLE, admin.address);
    
    if (!hasAdminRole) {
      console.log("WARNING: Admin role not found. You need to grant AI_ADMIN_ROLE to proceed.");
      if (isDryRun) {
        console.log("DRY RUN: Would need to grant admin role");
      } else {
        const rl = readline.createInterface({
          input: process.stdin,
          output: process.stdout
        });
        
        const answer = await new Promise(resolve => {
          rl.question("Do you have the default admin role to grant this role? (y/n): ", resolve);
        });
        rl.close();
        
        if (answer.toLowerCase() === 'y') {
          console.log("Attempting to grant admin role...");
          const grantRoleTx = await aiEngine.grantRole(AI_ADMIN_ROLE, admin.address);
          await grantRoleTx.wait();
          console.log("Admin role granted successfully");
        } else {
          throw new Error("Cannot proceed without admin role");
        }
      }
    }
    
    // Load constituent configuration
    let constituents = [];
    
    if (fs.existsSync(configPath)) {
      constituents = JSON.parse(fs.readFileSync(configPath, 'utf8'));
      console.log(`Loaded ${constituents.length} constituents from config file`);
    } else {
      console.log(`Config file not found. Creating sample config at ${configPath}`);
      
      // Sample config
      constituents = [
        {
          name: "Arbitrum",
          address: "0x912CE59144191C1204E64559FE8253a0e49E6548", // ARB on Arbitrum
          priceFeed: "0xb2A824043730FE05F3DA2efaFa1CBbe83fa548D6" // ARB/USD price feed
        },
        {
          name: "Wrapped Ether",
          address: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", // WETH on Arbitrum
          priceFeed: "0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612" // ETH/USD price feed
        }
      ];
      
      fs.writeFileSync(configPath, JSON.stringify(constituents, null, 2));
      
      if (!isDryRun) {
        console.log("WARNING: Please edit the config file and run again");
        return;
      }
    }
    
    // Process each constituent
    console.log(`\nProcessing ${constituents.length} constituents`);
    
    const results = {
      successful: [],
      failed: [],
      skipped: []
    };
    
    for (let i = 0; i < constituents.length; i++) {
      const constituent = constituents[i];
      console.log(`\nProcessing ${i+1}/${constituents.length}: ${constituent.name || constituent.address}`);
      
      try {
        const result = await addConstituent(
          aiEngine, 
          constituent.address, 
          constituent.priceFeed, 
          admin,
          { dryRun: isDryRun, maxRetries: 3, gasMultiplier: 1.3 }
        );
        
        if (result.skipped) {
          results.skipped.push({ constituent, reason: result.reason });
        } else {
          results.successful.push({ constituent, txHash: result.receipt?.transactionHash });
        }
      } catch (error) {
        console.error(`Error processing ${constituent.name || constituent.address}: ${error.message}`);
        results.failed.push({ constituent, error: error.message });
      }
    }
    
    // Print summary
    console.log("\n====== Summary ======");
    console.log(`Successful: ${results.successful.length}`);
    console.log(`Skipped: ${results.skipped.length}`);
    console.log(`Failed: ${results.failed.length}`);
    
    if (results.successful.length > 0) {
      console.log("\nSuccessfully added:");
      results.successful.forEach(item => {
        console.log(`   - ${item.constituent.name || item.constituent.address}${isDryRun ? " (dry run)" : ` (tx: ${item.txHash})`}`);
      });
    }
    
    if (results.skipped.length > 0) {
      console.log("\nSkipped:");
      results.skipped.forEach(item => {
        console.log(`   - ${item.constituent.name || item.constituent.address} (${item.reason})`);
      });
    }
    
    if (results.failed.length > 0) {
      console.log("\nFailed:");
      results.failed.forEach(item => {
        console.log(`   - ${item.constituent.name || item.constituent.address}: ${item.error}`);
      });
    }
    
    // Save results log
    const timestamp = new Date().toISOString().replace(/:/g, '-');
    const logFilePath = `constituents-log-${timestamp}.json`;
    fs.writeFileSync(logFilePath, JSON.stringify({
      timestamp,
      network: network.name,
      chainId: network.chainId,
      aiEngine: DEPLOYED_ENGINE_ADDRESS,
      admin: admin.address,
      isDryRun,
      results
    }, null, 2));
    
    console.log(`\nResults saved to ${logFilePath}`);
    
  } catch (error) {
    console.error("\nFATAL ERROR:", error);
    process.exit(1);
  }
}

// Execute the script
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
