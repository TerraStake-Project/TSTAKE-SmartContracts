const { ethers } = require('ethers');

/**
 * @notice Creates a deterministic hash of an environmental impact report
 * @param {Object} impactData - The structured impact report data
 * @param {number} impactData.projectId - Associated project ID
 * @param {number|string} impactData.impactValue - Quantified impact amount
 * @param {string} impactData.impactType - Type of environmental impact
 * @param {string} impactData.location - Geographic location
 * @param {string} impactData.timestamp - ISO timestamp of the impact measurement
 * @param {string} impactData.methodology - Methodology used for measurement
 * @param {string} impactData.verifierName - Name of verifying organization
 * @returns {string} - Bytes32 hash compatible with TerraStakeNFT contract
 */
function generateImpactReportHash(impactData) {
  // Ensure all required fields are present
  const requiredFields = ['projectId', 'impactValue', 'impactType', 'location', 'timestamp'];
  requiredFields.forEach(field => {
    if (impactData[field] === undefined) {
      throw new Error(`Missing required field: ${field}`);
    }
  });

  // Create a deterministic string representation of the impact data
  // Order matters for consistent hashing!
  const encodedData = ethers.utils.defaultAbiCoder.encode(
    ['uint256', 'uint256', 'string', 'string', 'string', 'string', 'string'],
    [
      impactData.projectId,
      ethers.BigNumber.from(String(impactData.impactValue)),
      impactData.impactType,
      impactData.location,
      impactData.timestamp,
      impactData.methodology || '',
      impactData.verifierName || ''
    ]
  );

  // Generate keccak256 hash (same algorithm used in Solidity)
  const hash = ethers.utils.keccak256(encodedData);
  
  return hash;
}

/**
 * @notice Verifies that an impact report matches its claimed hash
 * @param {Object} impactData - The structured impact report data
 * @param {string} claimedHash - The bytes32 hash to verify against
 * @returns {boolean} - True if the data matches the hash
 */
function verifyImpactReportHash(impactData, claimedHash) {
  try {
    const generatedHash = generateImpactReportHash(impactData);
    return generatedHash.toLowerCase() === claimedHash.toLowerCase();
  } catch (error) {
    console.error('Error verifying hash:', error);
    return false;
  }
}

/**
 * @notice Integrates with TerraStakeNFT contract to mint an impact NFT
 * @param {Object} terraStakeNFT - The contract instance
 * @param {Object} impactData - The impact report data
 * @param {string} uri - The IPFS URI for the full report
 * @param {Object} options - Transaction options
 * @returns {Promise<Object>} - Transaction receipt
 */
async function mintImpactNFT(terraStakeNFT, impactData, uri, options = {}) {
  const reportHash = generateImpactReportHash(impactData);
  
  // Call the mintImpactNFT function on the contract
  const tx = await terraStakeNFT.mintImpactNFT(
    options.recipient || impactData.recipient, 
    impactData.projectId,
    uri,
    reportHash,
    options
  );
  
  const receipt = await tx.wait();
  
  // Extract the tokenId from the event
  const mintEvent = receipt.events.find(e => e.event === 'TokenMinted');
  const tokenId = mintEvent.args.tokenId;
  
  return {
    receipt,
    tokenId,
    reportHash
  };
}

/**
 * @notice Prepares verification data for an impact certificate
 * @param {Object} terraStakeNFT - The contract instance 
 * @param {number} tokenId - The token ID to verify
 * @param {Object} impactData - The verified impact data
 * @returns {Promise<Object>} - Transaction receipt
 */
async function verifyImpactCertificate(terraStakeNFT, tokenId, impactData, options = {}) {
  // Convert impact value to contract format
  const impactValue = ethers.BigNumber.from(String(impactData.impactValue));
  
  // Call the verifyImpactCertificate function
  const tx = await terraStakeNFT.verifyImpactCertificate(
    tokenId,
    impactValue,
    impactData.impactType,
    impactData.location,
    options
  );
  
  return tx.wait();
}

module.exports = {
  generateImpactReportHash,
  verifyImpactReportHash,
  mintImpactNFT,
  verifyImpactCertificate
};
