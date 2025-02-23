import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Using governance address:", deployer.address);

  // ** Load TerraStakeGovernance Contract **
  const governanceAddress = "0xYourGovernanceContractAddressHere"; // ✅ Replace with actual contract address
  const governance = await ethers.getContractAt("TerraStakeGovernance", governanceAddress);

  // ** Example Proposal Data **
  const proposalType = 3; // Liquidity Injection
  const proposalData = "0x"; // This should be a properly encoded function call
  const proposalTarget = "0xLiquidityContractAddressHere"; // Replace with actual contract target
  const linkedProjectId = 0; // No project linked
  const proposalDescription = "Proposal to inject liquidity into Uniswap.";

  console.log("Creating proposal...");
  const tx = await governance.createProposal(proposalData, proposalTarget, proposalType, linkedProjectId, proposalDescription);
  const receipt = await tx.wait();
  console.log("✅ Proposal Created! Transaction Hash:", receipt.transactionHash);

  // ** Get Proposal Count **
  const proposalCount = await governance.proposalCount();
  console.log("Total Proposals Created:", proposalCount.toString());

  // ** Fetch Latest Proposal Details **
  const proposalId = proposalCount.toNumber() - 1;
  const proposal = await governance.proposals(proposalId);
  console.log(`📜 Proposal #${proposalId} Details:`, proposal);

  // ** Vote on the Proposal **
  console.log("Voting on proposal...");
  const voteTx = await governance.vote(proposalId, true); // true = support, false = against
  await voteTx.wait();
  console.log("✅ Vote Casted Successfully!");

  // ** Check if Proposal is Ready for Execution **
  const blockNumber = await ethers.provider.getBlockNumber();
  if (blockNumber >= proposal.endBlock.toNumber()) {
    console.log("⏳ Proposal voting period ended. Executing...");
    
    try {
      const execTx = await governance.executeProposal(proposalId);
      await execTx.wait();
      console.log("🚀 Proposal Executed Successfully!");
    } catch (error) {
      console.error("⚠️ Proposal Execution Failed:", error);
    }
  } else {
    console.log("⏳ Proposal is still in voting period. Cannot execute yet.");
  }
}

// ** Error Handling & Execution **
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Error in governance script:", error);
    process.exit(1);
  });

