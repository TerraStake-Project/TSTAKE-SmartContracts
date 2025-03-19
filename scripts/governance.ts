import { ethers } from "hardhat";
import dotenv from "dotenv";

// Load environment variables
dotenv.config();

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Using governance operator:", deployer.address);

  // ** Load TerraStakeGovernance Contract **
  const governanceAddress = process.env.GOVERNANCE_ADDRESS || "0xYourGovernanceContractAddressHere";
  const governance = await ethers.getContractAt("TerraStakeGovernance", governanceAddress);

  // ** Example Proposal Data **
  const proposalType = 3; // Liquidity Injection
  // Properly encode function call data - this is just an example
  const proposalData = ethers.utils.defaultAbiCoder.encode(
    ["uint256", "bool"], 
    [ethers.utils.parseEther("1000"), true]
  );
  
  const proposalTarget = process.env.LIQUIDITY_CONTRACT_ADDRESS || "0xLiquidityContractAddressHere";
  const linkedProjectId = 0; // No project linked
  const proposalDescription = "Proposal to inject liquidity into Uniswap.";

  try {
    console.log("Creating proposal...");
    console.log(`Type: ${proposalType}, Target: ${proposalTarget}`);
    const tx = await governance.createProposal(proposalData, proposalTarget, proposalType, linkedProjectId, proposalDescription);
    console.log("Transaction submitted, waiting for confirmation...");
    const receipt = await tx.wait();
    console.log("✅ Proposal Created! Transaction Hash:", receipt.transactionHash);

    // ** Get Proposal Count **
    const proposalCount = await governance.proposalCount();
    console.log("Total Proposals Created:", proposalCount.toString());

    // ** Fetch Latest Proposal Details **
    const proposalId = proposalCount.toNumber() - 1;
    const proposal = await governance.proposals(proposalId);
    
    // Format proposal details for better readability
    console.log(`📜 Proposal #${proposalId} Details:`);
    console.log(`- Creator: ${proposal.creator}`);
    console.log(`- Type: ${proposal.proposalType}`);
    console.log(`- Target: ${proposal.target}`);
    console.log(`- Description: ${proposal.description}`);
    console.log(`- Status: ${proposal.status}`);
    console.log(`- Start Block: ${proposal.startBlock.toString()}`);
    console.log(`- End Block: ${proposal.endBlock.toString()}`);

    // ** Vote on the Proposal **
    console.log("Voting on proposal...");
    const voteTx = await governance.vote(proposalId, true); // true = support, false = against
    console.log("Vote transaction submitted, waiting for confirmation...");
    await voteTx.wait();
    console.log("✅ Vote Casted Successfully!");

    // ** Check if Proposal is Ready for Execution **
    const blockNumber = await ethers.provider.getBlockNumber();
    const blocksRemaining = proposal.endBlock.toNumber() - blockNumber;
    
    if (blocksRemaining <= 0) {
      console.log("⏳ Proposal voting period ended.");
      
      // Check proposal status to see if it passed
      const status = await governance.getProposalStatus(proposalId);
      if (status === 2) { // Assuming 2 = Passed (adjust based on your contract)
        console.log("Proposal passed. Executing...");
        try {
          const execTx = await governance.executeProposal(proposalId);
          console.log("Execution transaction submitted, waiting for confirmation...");
          await execTx.wait();
          console.log("🚀 Proposal Executed Successfully!");
        } catch (error) {
          console.error("⚠️ Proposal Execution Failed:", error.message);
          console.error("Details:", error);
        }
      } else {
        console.log(`Proposal cannot be executed. Current status: ${status}`);
      }
    } else {
      console.log(`⏳ Proposal is still in voting period. ${blocksRemaining} blocks remaining before execution.`);
    }
  } catch (error) {
    console.error("❌ Error in proposal creation/voting:", error.message);
    throw error;
  }
}

// ** Error Handling & Execution **
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error("❌ Error in governance script:", error);
      process.exit(1);
    });
}

export { main };