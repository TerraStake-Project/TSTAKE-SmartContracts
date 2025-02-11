// Import required libraries
const { create } = require('ipfs-http-client');
const { ethers } = require('ethers');

// Create an IPFS client instance (adjust host/port/protocol as needed)
const ipfs = create({ host: 'ipfs.infura.io', port: 5001, protocol: 'https' });

// Replace with your TerraStakeProjects contract ABI and address
const terraStakeProjectsAbi = [ /* ... ABI array ... */ ];
const terraStakeProjectsAddress = '0xYourContractAddressHere';

// Configure an ethers.js provider and signer (e.g., using Infura)
const provider = new ethers.providers.JsonRpcProvider('https://mainnet.infura.io/v3/YOUR_INFURA_PROJECT_ID');
const signer = provider.getSigner(); // For example, from MetaMask or a private key

// Create an instance of the TerraStakeProjects contract
const terraStakeProjectsContract = new ethers.Contract(terraStakeProjectsAddress, terraStakeProjectsAbi, signer);

/**
 * @notice Uploads document content to IPFS and adds the resulting CID to a project.
 * @param {number} projectId - The ID of the project.
 * @param {string} documentContent - The content of the document to upload.
 */
async function uploadDocument(projectId, documentContent) {
  try {
    // Upload document content to IPFS
    const { cid } = await ipfs.add(documentContent);
    console.log("IPFS CID (string):", cid.toString());
    const cidBytes = cid.bytes; // Raw bytes Buffer of the CID

    // Call the addProjectDocument function on the contract with the raw CID bytes
    const tx = await terraStakeProjectsContract.addProjectDocument(projectId, cidBytes);
    await tx.wait();
    console.log("Document added successfully for project:", projectId);
  } catch (error) {
    console.error("Error adding document:", error);
  }
}

/**
 * @notice Retrieves document content from IPFS using stored CID bytes.
 * @param {number} projectId - The ID of the project.
 * @param {number} documentIndex - The index of the document.
 * @returns {Promise<string|null>} The document content or null if retrieval fails.
 */
async function retrieveDocument(projectId, documentIndex) {
  try {
    // Retrieve raw CID bytes array from the contract
    const cidBytesArray = await terraStakeProjectsContract.getProjectDocuments(projectId);
    if (cidBytesArray.length <= documentIndex) {
      console.error("Document index out of bounds");
      return null;
    }
    const cidBuffer = cidBytesArray[documentIndex];

    // Retrieve data from IPFS using the CID bytes
    let data = '';
    for await (const chunk of ipfs.cat(cidBuffer)) {
      data += chunk.toString();
    }
    console.log("Retrieved document content:", data);
    return data;
  } catch (error) {
    console.error("Error retrieving document:", error);
    return null;
  }
}

// Example usage:
async function exampleUsage() {
  const projectId = 0; // Replace with an actual project ID
  const documentContent = "This is the full documentation content for the project.";
  await uploadDocument(projectId, documentContent);
  await retrieveDocument(projectId, 0);
}

exampleUsage().catch(console.error);