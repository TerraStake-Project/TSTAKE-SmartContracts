// Import the IPFS HTTP client and Web3 (or ethers.js)
const ipfsClient = require('ipfs-http-client');
const { ethers } = require('ethers');

// Configuration for IPFS and Ethereum
const ipfsNodeAddress = 'https://ipfs.infura.io:5001/api/v0'; // Infura IPFS endpoint
const contractAddress = '0xYourContractAddress'; // Replace with your contract's address
const contractABI = require('./YourContractABI.json'); // Replace with your contract's ABI

// Create IPFS client
const ipfs = ipfsClient.create({ url: ipfsNodeAddress });

// Setup Ethereum provider and contract instance
const provider = new ethers.providers.Web3Provider(window.ethereum);
const signer = provider.getSigner();
const contractInstance = new ethers.Contract(contractAddress, contractABI, signer);

/**
 * Uploads data to IPFS and returns the resulting CID.
 * @param {File|Blob|Buffer|string} data The data to upload to IPFS.
 * @returns {Promise<string>} The IPFS CID.
 */
async function uploadToIPFS(data) {
    try {
        const result = await ipfs.add(data);
        console.log('IPFS CID:', result.cid.toString());
        return result.cid.toString();
    } catch (error) {
        console.error('IPFS upload failed:', error);
        throw error;
    }
}

/**
 * Automatically uploads a file to IPFS and calls the smart contract.
 * @param {File} file The file to upload to IPFS.
 * @param {number} projectId The ID of the project in the smart contract.
 */
async function autoUploadDocumentAndInsert(file, projectId) {
    try {
        const ipfsHash = await uploadToIPFS(file);
        const tx = await contractInstance.uploadProjectDocuments(projectId, [ipfsHash]);
        await tx.wait();
        console.log('Document uploaded and IPFS hash inserted into smart contract');
    } catch (error) {
        console.error('Failed to upload document and insert IPFS hash:', error);
    }
}

/**
 * Automatically uploads JSON metadata to IPFS and adds a new project to the smart contract.
 * @param {Object} metadata The project metadata object.
 */
async function autoAddProject(metadata) {
    try {
        const ipfsHash = await uploadToIPFS(JSON.stringify(metadata));
        const tx = await contractInstance.addProject(
            metadata.name,
            metadata.description,
            metadata.location,
            metadata.impactMetrics,
            ipfsHash,
            metadata.category,
            metadata.stakingMultiplier,
            metadata.startBlock,
            metadata.endBlock
        );
        await tx.wait();
        console.log('Project added with IPFS metadata automatically');
    } catch (error) {
        console.error('Failed to add project with IPFS hash:', error);
    }
}

// Example UI integration for file uploads
document.getElementById('file-input').addEventListener('change', async (event) => {
    const file = event.target.files[0];
    if (file) {
        await autoUploadDocumentAndInsert(file, 1); // Assume project ID = 1
    }
});

// Example UI integration for project metadata submission
document.getElementById('create-project-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const formData = new FormData(event.target);
    const metadata = {
        name: formData.get('name'),
        description: formData.get('description'),
        location: formData.get('location'),
        impactMetrics: formData.get('impactMetrics'),
        category: formData.get('category'),
        stakingMultiplier: formData.get('stakingMultiplier'),
        startBlock: formData.get('startBlock'),
        endBlock: formData.get('endBlock')
    };
    await autoAddProject(metadata);
});

