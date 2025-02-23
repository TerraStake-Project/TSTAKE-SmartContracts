// Import required libraries
const { create } = require('ipfs-http-client');
const { ethers } = require('ethers');
const bs58 = require('bs58'); // Base58 for IPFS CID encoding/decoding

// Configure an IPFS client
const ipfs = create({ host: 'ipfs.infura.io', port: 5001, protocol: 'https' });

// Replace with your contract details
const terraStakeProjectsAbi = [ /* ... ABI array ... */ ];
const terraStakeProjectsAddress = '0xYourContractAddressHere';

// ✅ Arbitrum One RPC (Optimized for Arbitrum)
const provider = new ethers.providers.JsonRpcProvider('https://arb1.arbitrum.io/rpc');

// ✅ Use a Wallet for Signing (Replace with a Safe Key Management System)
const wallet = new ethers.Wallet('YOUR_PRIVATE_KEY', provider);
const contract = new ethers.Contract(terraStakeProjectsAddress, terraStakeProjectsAbi, wallet);

/**
 * @notice Uploads a document to IPFS and stores the CID in the contract.
 * @param {number} projectId - The ID of the project.
 * @param {string} documentContent - The content of the document.
 */
async function uploadDocument(projectId, documentContent) {
  try {
    // Upload document to IPFS
    const { cid } = await ipfs.add(documentContent);
    console.log("✅ IPFS CID:", cid.toString());

    // Convert CID to bytes32 (Compatible with Arbitrum)
    const cidBytes32 = ethers.utils.hexlify(bs58.decode(cid.toString()).slice(2));

    // ✅ Optimize gas for Arbitrum transactions
    const tx = await contract.addProjectDocument(projectId, cidBytes32, {
      gasPrice: ethers.utils.parseUnits('0.1', 'gwei'), // Arbitrum optimized gas
    });
    await tx.wait();

    console.log("✅ Document successfully added for project:", projectId);
  } catch (error) {
    console.error("❌ Error adding document:", error);
  }
}

/**
 * @notice Retrieves document content from IPFS using a stored CID.
 * @param {number} projectId - The ID of the project.
 * @param {number} documentIndex - The index of the document.
 * @returns {Promise<string|null>} The document content or null if retrieval fails.
 */
async function retrieveDocument(projectId, documentIndex) {
  try {
    // Retrieve stored CID bytes32 from contract
    const cidBytes32 = await contract.getProjectDocuments(projectId, documentIndex);

    // Convert bytes32 back to IPFS CID
    const cid = bs58.encode(Buffer.from("1220" + cidBytes32.slice(2), "hex"));

    console.log("✅ Retrieved IPFS CID:", cid);

    // Fetch data from IPFS
    let data = '';
    for await (const chunk of ipfs.cat(cid)) {
      data += chunk.toString();
    }
    
    console.log("✅ Retrieved document content:", data);
    return data;
  } catch (error) {
    console.error("❌ Error retrieving document:", error);
    return null;
  }
}

// ✅ Example usage
async function exampleUsage() {
  const projectId = 1; // Replace with an actual project ID
  const documentContent = "This is an official TerraStake project document.";

  await uploadDocument(projectId, documentContent);
  await retrieveDocument(projectId, 0);
}

// Run the script
exampleUsage().catch(console.error);
