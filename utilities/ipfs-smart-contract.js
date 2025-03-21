// Import the IPFS HTTP client and ethers.js
const { create } = require('ipfs-http-client');
const { ethers } = require('ethers');
const { Buffer } = require('buffer');

// Advanced configuration with fallback providers for Arbitrum networks
const CONFIG = {
  ipfs: {
    primary: 'https://ipfs.infura.io:5001/api/v0',
    fallback: 'https://ipfs.io',
    timeout: 60000, // 1 minute timeout
    retryAttempts: 3
  },
  ethereum: {
    gasLimitMultiplier: 1.3, // Add 30% to estimated gas (Arbitrum may need higher buffer)
    confirmations: 3, // Arbitrum confirmations
    networks: {
      arbitrumOne: {
        name: 'Arbitrum One',
        contractAddress: process.env.CONTRACT_ADDRESS_ARBITRUM_ONE || '0xArbitrumOneContractAddress',
        chainId: 42161,
        rpcUrl: 'https://arb1.arbitrum.io/rpc',
        blockExplorer: 'https://arbiscan.io'
      },
      arbitrumNova: {
        name: 'Arbitrum Nova',
        contractAddress: process.env.CONTRACT_ADDRESS_ARBITRUM_NOVA || '0xArbitrumNovaContractAddress',
        chainId: 42170,
        rpcUrl: 'https://nova.arbitrum.io/rpc',
        blockExplorer: 'https://nova.arbiscan.io'
      },
      arbitrumTestnet: {
        name: 'Arbitrum Sepolia',
        contractAddress: process.env.CONTRACT_ADDRESS_ARBITRUM_TESTNET || '0xArbitrumTestnetContractAddress',
        chainId: 421614,
        rpcUrl: 'https://sepolia-rollup.arbitrum.io/rpc',
        blockExplorer: 'https://sepolia.arbiscan.io'
      }
    }
  }
};

// Initialize IPFS client with authentication if available
function createIPFSClient() {
  const auth = process.env.IPFS_AUTH_KEY ? 
    'Basic ' + Buffer.from(process.env.IPFS_AUTH_KEY).toString('base64') : '';
  
  return create({ 
    url: CONFIG.ipfs.primary,
    headers: {
      authorization: auth
    },
    timeout: CONFIG.ipfs.timeout
  });
}

// Create IPFS client
const ipfs = createIPFSClient();

// Class-based service for better organization and state management
class TerraStakeService {
  constructor(networkName = 'arbitrumTestnet') {
    this.networkConfig = CONFIG.ethereum.networks[networkName];
    if (!this.networkConfig) {
      throw new Error(`Network ${networkName} not found in configuration. Available networks: ${Object.keys(CONFIG.ethereum.networks).join(', ')}`);
    }
    
    this.contractABI = require('../abis/TerraStakeProjects.json');
    this.contract = null;
    this.isInitialized = false;
    this.eventListeners = [];
  }

  /**
   * Initialize the service with provider and contract instance
   * @param {ethers.providers.Web3Provider|null} externalProvider - Optional external provider
   * @returns {Promise<boolean>} Success status
   */
  async initialize(externalProvider = null) {
    try {
      // Use provided provider or connect to window.ethereum or RPC
      if (externalProvider) {
        this.provider = externalProvider;
      } else if (typeof window !== 'undefined' && window.ethereum) {
        this.provider = new ethers.providers.Web3Provider(window.ethereum, {
          name: this.networkConfig.name,
          chainId: this.networkConfig.chainId
        });
        
        // Request account access
        await window.ethereum.request({ method: 'eth_requestAccounts' });
        
        // Check and switch network if needed
        const currentChainId = await window.ethereum.request({ method: 'eth_chainId' });
        if (parseInt(currentChainId, 16) !== this.networkConfig.chainId) {
          try {
            await window.ethereum.request({
              method: 'wallet_switchEthereumChain',
              params: [{ chainId: `0x${this.networkConfig.chainId.toString(16)}` }],
            });
          } catch (switchError) {
            // This error code indicates that the chain has not been added to MetaMask
            if (switchError.code === 4902) {
              await window.ethereum.request({
                method: 'wallet_addEthereumChain',
                params: [{
                  chainId: `0x${this.networkConfig.chainId.toString(16)}`,
                  chainName: this.networkConfig.name,
                  nativeCurrency: {
                    name: 'ETH',
                    symbol: 'ETH',
                    decimals: 18
                  },
                  rpcUrls: [this.networkConfig.rpcUrl],
                  blockExplorerUrls: [this.networkConfig.blockExplorer]
                }]
              });
            } else {
              throw switchError;
            }
          }
        }
      } else {
        // Use RPC for Node.js environment or fallback
        this.provider = new ethers.providers.JsonRpcProvider(this.networkConfig.rpcUrl);
      }

      // Ensure correct network
      const network = await this.provider.getNetwork();
      if (network.chainId !== this.networkConfig.chainId) {
        throw new Error(`Connected to wrong network. Expected: ${this.networkConfig.name} (${this.networkConfig.chainId}), Got: ${network.name} (${network.chainId})`);
      }

      // Get signer (if available) or use provider for read-only operations
      try {
        this.signer = this.provider.getSigner();
        this.userAddress = await this.signer.getAddress();
        console.log(`Connected with address: ${this.userAddress}`);
      } catch (signerError) {
        console.log('No signer available, operating in read-only mode');
        this.signer = null;
        this.userAddress = null;
      }
      
      // Connect to contract with signer if available, otherwise use provider
      this.contract = new ethers.Contract(
        this.networkConfig.contractAddress,
        this.contractABI,
        this.signer || this.provider
      );

      // Setup event listeners
      this._setupEventListeners();
      
      this.isInitialized = true;
      console.log(`Initialized TerraStake service on ${this.networkConfig.name}`);
      return true;
    } catch (error) {
      console.error('Initialization failed:', error);
      throw new Error(`Failed to initialize TerraStake service: ${error.message}`);
    }
  }

  /**
   * Get Arbitrum-specific gas parameters
   * @returns {Promise<Object>} Gas parameters for Arbitrum
   */
  async getArbitrumGasParams() {
    // Get current gas price data
    const gasPrice = await this.provider.getGasPrice();
    
    // For Arbitrum, we don't need maxFeePerGas/maxPriorityFeePerGas
    // but we return them for compatibility with certain wallets
    const params = {
      gasPrice: gasPrice,
      // Add small buffer to current gas price
      maxFeePerGas: gasPrice.mul(12).div(10),
      maxPriorityFeePerGas: ethers.utils.parseUnits("0.1", "gwei"),
    };
    
    return params;
  }

  /**
   * Validates and uploads data to IPFS with retry mechanism
   * @param {File|Blob|Buffer|string} data - The data to upload
   * @param {Object} options - Upload options
   * @returns {Promise<string>} IPFS CID
   */
  async uploadToIPFS(data, options = {}) {
    if (!data) throw new Error('No data provided for IPFS upload');
    
    // Add metadata if provided
    let uploadData = data;
    if (options.metadata) {
      // Create a directory structure with metadata
      const files = [
        { path: 'data', content: data },
        { path: 'metadata.json', content: JSON.stringify(options.metadata) }
      ];
      uploadData = files;
    }

    // Implement retry logic
    let attempt = 0;
    let lastError = null;

    while (attempt < CONFIG.ipfs.retryAttempts) {
      try {
        // Calculate progress callback if provided
        const progressCallback = options.onProgress ? 
          (bytes) => options.onProgress(bytes) : null;

        const result = await ipfs.add(uploadData, {
          pin: true,
          progress: progressCallback,
          wrapWithDirectory: options.metadata ? true : false
        });

        // Get the root CID (either the file CID or directory CID)
        const cid = options.metadata ? 
          result.cid.toString() : 
          (Array.isArray(result) ? result[0].cid.toString() : result.cid.toString());
        
        console.log('IPFS upload successful, CID:', cid);
        
        // Verify the upload is accessible
        await this._verifyIPFSUpload(cid);
        
        return cid;
      } catch (error) {
        lastError = error;
        console.warn(`IPFS upload attempt ${attempt + 1} failed:`, error);
        attempt++;
        
        // Wait before retrying (exponential backoff)
        if (attempt < CONFIG.ipfs.retryAttempts) {
          const backoffTime = Math.pow(2, attempt) * 1000;
          await new Promise(resolve => setTimeout(resolve, backoffTime));
        }
      }
    }

    throw new Error(`IPFS upload failed after ${CONFIG.ipfs.retryAttempts} attempts: ${lastError.message}`);
  }

  /**
   * Verify IPFS content is accessible
   * @param {string} cid - IPFS CID to verify
   * @returns {Promise<boolean>} Verification result
   */
  async _verifyIPFSUpload(cid) {
    try {
      // Try to retrieve a small amount of data to verify the CID exists
      const chunks = [];
      for await (const chunk of ipfs.cat(cid, { length: 100 })) {
        chunks.push(chunk);
        break; // We only need to verify the CID exists
      }
      return true;
    } catch (error) {
      throw new Error(`Failed to verify IPFS content: ${error.message}`);
    }
  }

  /**
   * Enhanced document upload with progress tracking and validation
   * @param {File} file - The file to upload
   * @param {number} projectId - Project ID
   * @param {Object} options - Upload options
   * @returns {Promise<Object>} Transaction receipt and IPFS hash
   */
  async uploadProjectDocument(file, projectId, options = {}) {
    if (!this.isInitialized) await this.initialize();
    if (!this.signer) throw new Error('No signer available. Cannot perform write operations.');
    
    if (!file) throw new Error('No file provided');
    if (!projectId || projectId <= 0) throw new Error('Invalid project ID');
    
    // Validate file size (10MB max by default)
    const maxSize = options.maxSize || 10 * 1024 * 1024;
    if (file.size > maxSize) {
      throw new Error(`File too large. Maximum size is ${maxSize / (1024 * 1024)}MB`);
    }
    
    // Validate file type if specified
    if (options.allowedTypes && !options.allowedTypes.includes(file.type)) {
      throw new Error(`Invalid file type. Allowed types: ${options.allowedTypes.join(', ')}`);
    }

    try {
      if (options.onStatus) options.onStatus('Uploading to IPFS...');
      
      // Create metadata with file info
      const metadata = {
        name: file.name,
        type: file.type,
        size: file.size,
        lastModified: file.lastModified,
        projectId: projectId,
        uploadedBy: this.userAddress,
        timestamp: Date.now(),
        network: this.networkConfig.name,
        chainId: this.networkConfig.chainId
      };

      // Upload to IPFS with metadata
      const ipfsHash = await this.uploadToIPFS(file, {
        metadata: metadata,
        onProgress: options.onProgress
      });

      if (options.onStatus) options.onStatus('Submitting to blockchain...');
      
      // Get Arbitrum-specific gas parameters
      const gasParams = await this.getArbitrumGasParams();
      
      // Prepare transaction with proper gas estimation
      const gasEstimate = await this.contract.estimateGas.uploadProjectDocuments(
        projectId, 
        [ipfsHash]
      );
      
      const gasLimit = Math.ceil(gasEstimate.toNumber() * CONFIG.ethereum.gasLimitMultiplier);
      
      // Execute the transaction with Arbitrum gas params
      const tx = await this.contract.uploadProjectDocuments(
        projectId, 
        [ipfsHash],
        { 
          gasLimit,
          gasPrice: gasParams.gasPrice
        }
      );
      
      if (options.onStatus) options.onStatus(`Transaction submitted: ${tx.hash}`);
      
      // Wait for confirmation with specified number of blocks
      const receipt = await tx.wait(CONFIG.ethereum.confirmations);
      
      if (options.onStatus) options.onStatus('Document successfully uploaded');
      
      return {
        success: true,
        ipfsHash,
        transactionHash: receipt.transactionHash,
        blockNumber: receipt.blockNumber,
        network: this.networkConfig.name,
        explorerLink: `${this.networkConfig.blockExplorer}/tx/${receipt.transactionHash}`
      };
    } catch (error) {
      console.error('Document upload failed:', error);
      if (options.onStatus) options.onStatus(`Error: ${error.message}`);
      throw new Error(`Failed to upload document: ${error.message}`);
    }
  }

  /**
   * Enhanced batch document upload
   * @param {File[]} files - Array of files to upload
   * @param {number} projectId - Project ID
   * @param {Object} options - Upload options
   * @returns {Promise<Object[]>} Array of results
   */
  async batchUploadDocuments(files, projectId, options = {}) {
    if (!this.isInitialized) await this.initialize();
    if (!this.signer) throw new Error('No signer available. Cannot perform write operations.');
    
    if (!files || !files.length) throw new Error('No files provided');
    if (!projectId || projectId <= 0) throw new Error('Invalid project ID');
    
    const results = [];
    const ipfsHashes = [];
    
    try {
      // First upload all files to IPFS
      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        if (options.onBatchProgress) {
          options.onBatchProgress(i, files.length, 'Uploading to IPFS');
        }
        
        const ipfsHash = await this.uploadToIPFS(file, {
          metadata: {
            name: file.name,
            type: file.type,
            size: file.size,
            index: i,
            projectId: projectId,
            network: this.networkConfig.name,
            chainId: this.networkConfig.chainId
          },
          onProgress: options.onIndividualProgress
        });
        
        ipfsHashes.push(ipfsHash);
        results.push({ file: file.name, ipfsHash, status: 'Uploaded to IPFS' });
      }
      
      // Then submit all hashes in a single transaction
      if (options.onBatchProgress) {
        options.onBatchProgress(files.length, files.length, 'Submitting to blockchain');
      }
      
      // Get Arbitrum-specific gas parameters
      const gasParams = await this.getArbitrumGasParams();
      
      // Estimate gas for the batch transaction
      const gasEstimate = await this.contract.estimateGas.uploadProjectDocuments(
        projectId, 
        ipfsHashes
      );
      
      const gasLimit = Math.ceil(gasEstimate.toNumber() * CONFIG.ethereum.gasLimitMultiplier);
      
      // Execute the transaction
      const tx = await this.contract.uploadProjectDocuments(
        projectId, 
        ipfsHashes,
        { 
          gasLimit,
          gasPrice: gasParams.gasPrice
        }
      );
      
      // Wait for confirmation
      const receipt = await tx.wait(CONFIG.ethereum.confirmations);
      
      // Update results with transaction data
      results.forEach(result => {
        result.transactionHash = receipt.transactionHash;
        result.blockNumber = receipt.blockNumber;
        result.status = 'Confirmed';
        result.explorerLink = `${this.networkConfig.blockExplorer}/tx/${receipt.transactionHash}`;
      });
      
      return results;
    } catch (error) {
      console.error('Batch upload failed:', error);
      
      // Mark already uploaded files
      results.forEach(result => {
        if (result.status === 'Uploaded to IPFS') {
          result.status = 'IPFS only, blockchain submission failed';
        }
      });
      
      throw new Error(`Batch upload failed: ${error.message}`);
    }
  }

  /**
   * Enhanced project creation with comprehensive metadata for Arbitrum
   * @param {Object} metadata - Project metadata
   * @param {Object} options - Creation options
   * @returns {Promise<Object>} Creation result with project ID
   */
  async createProject(metadata, options = {}) {
    if (!this.isInitialized) await this.initialize();
    if (!this.signer) throw new Error('No signer available. Cannot perform write operations.');
    
    // Validate required fields
    const requiredFields = ['name', 'description', 'location', 'impactMetrics', 'category'];
    for (const field of requiredFields) {
      if (!metadata[field]) {
        throw new Error(`Missing required field: ${field}`);
      }
    }
    
    try {
      if (options.onStatus) options.onStatus('Preparing project data...');
      
      // Prepare enhanced metadata with additional fields
      const enhancedMetadata = {
        ...metadata,
        createdBy: this.userAddress,
        createdAt: Date.now(),
        version: '1.0',
        network: this.networkConfig.name,
        chainId: this.networkConfig.chainId,
        contacts: metadata.contacts || [],
        images: metadata.images || [],
        documents: metadata.documents || [],
        goals: metadata.goals || [],
        milestones: metadata.milestones || []
      };
      
      // Upload additional files if provided
      if (options.files && options.files.length) {
        if (options.onStatus) options.onStatus('Uploading project files...');
        
        const fileUploads = [];
        for (const file of options.files) {
          const ipfsHash = await this.uploadToIPFS(file, {
            onProgress: options.onFileProgress
          });
          fileUploads.push({
            name: file.name,
            type: file.type,
            size: file.size,
            ipfsHash
          });
        }
        
        enhancedMetadata.projectFiles = fileUploads;
      }
      
      // Upload the complete metadata to IPFS
      if (options.onStatus) options.onStatus('Uploading project metadata...');
      const ipfsMetadataHash = await this.uploadToIPFS(
        JSON.stringify(enhancedMetadata),
        { onProgress: options.onMetadataProgress }
      );
      
      // Convert IPFS hash to bytes32 as expected by the contract
      // This technique varies depending on the contract implementation
      const bytes32Value = ethers.utils.keccak256(
        ethers.utils.toUtf8Bytes(ipfsMetadataHash)
      );
      
      if (options.onStatus) options.onStatus('Creating project on blockchain...');
      
      // Ensure numeric values are properly converted
      const stakingMultiplier = ethers.BigNumber.from(metadata.stakingMultiplier || 100);
      const startBlock = ethers.BigNumber.from(metadata.startBlock || 0);
      const endBlock = ethers.BigNumber.from(metadata.endBlock || 0);
      
      // Get Arbitrum-specific gas parameters
      const gasParams = await this.getArbitrumGasParams();
      
      // Estimate gas for project creation
      const gasEstimate = await this.contract.estimateGas.addProject(
        metadata.name,
        metadata.description,
        metadata.location,
        metadata.impactMetrics,
        bytes32Value,
        metadata.category,
        stakingMultiplier,
        startBlock,
        endBlock
      );
      
      const gasLimit = Math.ceil(gasEstimate.toNumber() * CONFIG.ethereum.gasLimitMultiplier);
      
      // Execute the transaction
      const tx = await this.contract.addProject(
        metadata.name,
        metadata.description,
        metadata.location,
        metadata.impactMetrics,
        bytes32Value,
        metadata.category,
        stakingMultiplier,
        startBlock,
        endBlock,
        { 
          gasLimit,
          gasPrice: gasParams.gasPrice
        }
      );
      
      if (options.onStatus) options.onStatus(`Transaction submitted: ${tx.hash}`);
      
      // Wait for confirmation with event parsing to get the project ID
      const receipt = await tx.wait(CONFIG.ethereum.confirmations);
      
      // Extract the project ID from the ProjectAdded event
      const projectAddedEvent = receipt.events.find(event => 
        event.event === 'ProjectAdded'
      );
      
      const projectId = projectAddedEvent ? 
        projectAddedEvent.args.projectId.toNumber() : null;
      
      if (options.onStatus) options.onStatus(`Project created with ID: ${projectId}`);
      
      return {
        success: true,
        projectId,
        transactionHash: receipt.transactionHash,
        blockNumber: receipt.blockNumber,
        ipfsHash: ipfsMetadataHash,
        explorerLink: `${this.networkConfig.blockExplorer}/tx/${receipt.transactionHash}`
      };
    } catch (error) {
      console.error('Project creation failed:', error);
      if (options.onStatus) options.onStatus(`Error: ${error.message}`);
      throw new Error(`Failed to create project: ${error.message}`);
    }
  }

  /**
   * Submit an impact report for a project on Arbitrum
   * @param {number} projectId - Project ID
   * @param {Object} reportData - Report data
   * @param {Object} options - Submission options
   * @returns {Promise<Object>} Submission result
   */
  async submitImpactReport(projectId, reportData, options = {}) {
    if (!this.isInitialized) await this.initialize();
    if (!this.signer) throw new Error('No signer available. Cannot perform write operations.');
    
    try {
      // Prepare the report data
      const report = {
        projectId,
        periodStart: reportData.periodStart || Math.floor(Date.now() / 1000 - 30 * 24 * 60 * 60), // 30 days ago default
        periodEnd: reportData.periodEnd || Math.floor(Date.now() / 1000), // now default
        metrics: reportData.metrics || [],
        details: reportData.details || {},
        evidenceLinks: reportData.evidenceLinks || [],
        submittedBy: this.userAddress,
        submittedAt: Date.now(),
        network: this.networkConfig.name,
        chainId: this.networkConfig.chainId
      };
      
      // Upload report data to IPFS
      if (options.onStatus) options.onStatus('Uploading report to IPFS...');
      const reportIpfsHash = await this.uploadToIPFS(JSON.stringify(report), {
        onProgress: options.onProgress
      });
      
      // Convert IPFS hash to bytes32
      const reportHashBytes32 = ethers.utils.keccak256(
        ethers.utils.toUtf8Bytes(reportIpfsHash)
      );
      
      // Convert metrics to array of BigNumbers
      const metricsArray = report.metrics.map(metric => 
        ethers.BigNumber.from(metric)
      );
      
      if (options.onStatus) options.onStatus('Submitting report to blockchain...');
      
      // Get Arbitrum-specific gas parameters
      const gasParams = await this.getArbitrumGasParams();
      
      // Estimate gas
      const gasEstimate = await this.contract.estimateGas.submitImpactReport(
        projectId,
        report.periodStart,
        report.periodEnd,
        metricsArray,
        reportHashBytes32
      );
      
      const gasLimit = Math.ceil(gasEstimate.toNumber() * CONFIG.ethereum.gasLimitMultiplier);
      
      // Execute transaction
      const tx = await this.contract.submitImpactReport(
        projectId,
        report.periodStart,
        report.periodEnd,
        metricsArray,
        reportHashBytes32,
        { 
          gasLimit,
          gasPrice: gasParams.gasPrice
        }
      );
      
      if (options.onStatus) options.onStatus(`Transaction submitted: ${tx.hash}`);
      
      // Wait for confirmation
      const receipt = await tx.wait(CONFIG.ethereum.confirmations);
      
      if (options.onStatus) options.onStatus('Impact report successfully submitted');
      
      return {
        success: true,
        transactionHash: receipt.transactionHash,
        blockNumber: receipt.blockNumber,
        ipfsHash: reportIpfsHash,
        explorerLink: `${this.networkConfig.blockExplorer}/tx/${receipt.transactionHash}`
      };
    } catch (error) {
      console.error('Impact report submission failed:', error);
      if (options.onStatus) options.onStatus(`Error: ${error.message}`);
      throw new Error(`Failed to submit impact report: ${error.message}`);
    }
  }

  /**
   * Arbitrum-specific token staking functionality
   * @param {number} projectId - Project ID to stake on
   * @param {string} amount - Amount to stake (in ETH units)
   * @param {Object} options - Staking options
   * @returns {Promise<Object>} Staking result
   */
  async stakeOnProject(projectId, amount, options = {}) {
    if (!this.isInitialized) await this.initialize();
    if (!this.signer) throw new Error('No signer available. Cannot perform write operations.');
    
    if (!projectId || projectId <= 0) throw new Error('Invalid project ID');
    if (!amount || parseFloat(amount) <= 0) throw new Error('Invalid stake amount');
    
    try {
      if (options.onStatus) options.onStatus('Preparing stake transaction...');
      
      // Convert amount to wei
      const amountWei = ethers.utils.parseEther(amount);
      
      // Get Arbitrum-specific gas parameters
      const gasParams = await this.getArbitrumGasParams();
      
      // Estimate gas for staking
      const gasEstimate = await this.contract.estimateGas.stakeOnProject(
        projectId,
        { value: amountWei }
      );
      
      const gasLimit = Math.ceil(gasEstimate.toNumber() * CONFIG.ethereum.gasLimitMultiplier);
      
      if (options.onStatus) options.onStatus(`Staking ${amount} ETH on project ${projectId}...`);
      
      // Execute the transaction
      const tx = await this.contract.stakeOnProject(
        projectId,
        { 
          value: amountWei,
          gasLimit,
          gasPrice: gasParams.gasPrice
        }
      );
      
      if (options.onStatus) options.onStatus(`Transaction submitted: ${tx.hash}`);
      
      // Wait for confirmation
      const receipt = await tx.wait(CONFIG.ethereum.confirmations);
      
      if (options.onStatus) options.onStatus('Stake successfully placed');
      
      return {
        success: true,
        transactionHash: receipt.transactionHash,
        blockNumber: receipt.blockNumber,
        amount: amount,
        projectId: projectId,
        explorerLink: `${this.networkConfig.blockExplorer}/tx/${receipt.transactionHash}`
      };
    } catch (error) {
      console.error('Staking failed:', error);
      if (options.onStatus) options.onStatus(`Error: ${error.message}`);
      throw new Error(`Failed to stake on project: ${error.message}`);
    }
  }

  /**
   * Setup event listeners for contract events
   * @private
   */
  _setupEventListeners() {
    // ProjectAdded event
    this.eventListeners.push(
      this.contract.on('ProjectAdded', (projectId, name, category, event) => {
        console.log('New project added:', { projectId: projectId.toString(), name, category });
        // Store project data in local cache
        this._updateProjectCache(projectId.toString(), { name, category });
      })
    );
    
    // ProjectStateChanged event
    this.eventListeners.push(
      this.contract.on('ProjectStateChanged', (projectId, oldState, newState, event) => {
        console.log('Project state changed:', { 
          projectId: projectId.toString(), 
          oldState, 
          newState 
        });
        // Update project state in cache
        this._updateProjectCache(projectId.toString(), { state: newState });
      })
    );
    
    // ImpactReportSubmitted event
    this.eventListeners.push(
      this.contract.on('ImpactReportSubmitted', (projectId, reportHash, event) => {
        console.log('Impact report submitted:', { 
          projectId: projectId.toString(), 
          reportHash 
        });
      })
    );
    
    // StakeAdded event
    this.eventListeners.push(
      this.contract.on('StakeAdded', (staker, projectId, amount, event) => {
        console.log('New stake added:', {
          staker,
          projectId: projectId.toString(),
          amount: ethers.utils.formatEther(amount),
        });
        // Update project stake in cache
        this._updateProjectCache(projectId.toString(), { 
          totalStaked: (this._projectCache[projectId.toString()]?.totalStaked || 0) + 
            parseFloat(ethers.utils.formatEther(amount)) 
        });
      })
    );
    
    // Handle Arbitrum-specific network events
    this.provider.on("block", (blockNumber) => {
      // Every 100 blocks, check for chain reorganizations and update cache if needed
      if (blockNumber % 100 === 0) {
        this._refreshProjectData();
      }
    });
  }

  /**
   * Refresh project data from blockchain to handle potential chain reorganizations
   * @private
   */
  async _refreshProjectData() {
    try {
      // Only refresh projects we're actively tracking
      const projectIds = Object.keys(this._projectCache || {});
      
      for (const projectId of projectIds) {
        try {
          // Get fresh data from blockchain for this project
          const projectData = await this.getProjectDetails(projectId);
          
          // Update cache with latest blockchain data
          this._updateProjectCache(projectId, projectData);
        } catch (error) {
          console.warn(`Failed to refresh data for project ${projectId}:`, error.message);
        }
      }
    } catch (error) {
      console.warn('Failed to refresh project data:', error);
    }
  }

  /**
   * Get detailed project information from blockchain and IPFS
   * @param {number} projectId - Project ID to retrieve
   * @param {Object} options - Query options
   * @returns {Promise<Object>} Project details
   */
  async getProjectDetails(projectId, options = {}) {
    if (!this.isInitialized) await this.initialize();
    
    try {
      // Get on-chain data
      const project = await this.contract.getProject(projectId);
      
      // Basic project details from blockchain
      const result = {
        id: projectId,
        name: project.name,
        description: project.description,
        location: project.location,
        impactMetrics: project.impactMetrics,
        category: project.category,
        state: project.state,
        stakingMultiplier: project.stakingMultiplier.toString(),
        totalStaked: ethers.utils.formatEther(project.totalStaked),
        owner: project.owner,
        metadataHash: project.metadataHash,
        reports: [],
        documents: []
      };
      
      // If retrieveExtended flag is true, get IPFS data too
      if (options.retrieveExtended && project.metadataHash) {
        try {
          if (options.onStatus) options.onStatus('Fetching extended data from IPFS...');
          
          // Convert bytes32 to IPFS hash if needed
          const ipfsHash = project.metadataHash.startsWith('0x') 
            ? this._convertBytes32ToIpfsHash(project.metadataHash)
            : project.metadataHash;
          
          // Get extended metadata from IPFS
          const extendedData = await this._getFromIPFS(ipfsHash);
          
          if (extendedData) {
            // Merge IPFS data with blockchain data
            result.extended = JSON.parse(extendedData);
          }
        } catch (ipfsError) {
          console.warn(`Failed to retrieve extended data from IPFS: ${ipfsError.message}`);
          result.ipfsError = ipfsError.message;
        }
      }
      
      // If retrieveReports flag is true, get associated impact reports
      if (options.retrieveReports) {
        try {
          if (options.onStatus) options.onStatus('Fetching impact reports...');
          
          // Get the count of reports from the contract
          const reportCount = await this.contract.getImpactReportCount(projectId);
          
          // Retrieve each report
          for (let i = 0; i < reportCount.toNumber(); i++) {
            const reportData = await this.contract.getImpactReport(projectId, i);
            
            const report = {
              index: i,
              periodStart: reportData.periodStart.toNumber(),
              periodEnd: reportData.periodEnd.toNumber(),
              metrics: reportData.metrics.map(m => m.toString()),
              reportHash: reportData.reportHash,
              submitter: reportData.submitter,
              submissionBlock: reportData.submissionBlock.toNumber()
            };
            
            // If retrieveExtended flag is true, get report content from IPFS
            if (options.retrieveExtended && reportData.reportHash) {
              try {
                const ipfsHash = reportData.reportHash.startsWith('0x') 
                  ? this._convertBytes32ToIpfsHash(reportData.reportHash)
                  : reportData.reportHash;
                
                const reportContent = await this._getFromIPFS(ipfsHash);
                if (reportContent) {
                  report.content = JSON.parse(reportContent);
                }
              } catch (ipfsError) {
                console.warn(`Failed to retrieve report content from IPFS: ${ipfsError.message}`);
                report.ipfsError = ipfsError.message;
              }
            }
            
            result.reports.push(report);
          }
        } catch (error) {
          console.warn(`Failed to retrieve impact reports: ${error.message}`);
          result.reportsError = error.message;
        }
      }
      
      // If retrieveDocuments flag is true, get associated documents
      if (options.retrieveDocuments) {
        try {
          if (options.onStatus) options.onStatus('Fetching project documents...');
          
          // Get the count of documents from the contract
          const documentCount = await this.contract.getDocumentCount(projectId);
          
          // Retrieve each document
          for (let i = 0; i < documentCount.toNumber(); i++) {
            const docData = await this.contract.getDocument(projectId, i);
            
            result.documents.push({
              index: i,
              ipfsHash: docData.ipfsHash,
              uploadedBy: docData.uploadedBy,
              uploadBlock: docData.uploadBlock.toNumber(),
              ipfsLink: `ipfs://${docData.ipfsHash}`,
              httpLink: `https://ipfs.io/ipfs/${docData.ipfsHash}`
            });
          }
        } catch (error) {
          console.warn(`Failed to retrieve documents: ${error.message}`);
          result.documentsError = error.message;
        }
      }
      
      return result;
    } catch (error) {
      console.error(`Failed to get project details for ID ${projectId}:`, error);
      throw new Error(`Failed to get project: ${error.message}`);
    }
  }

  /**
   * Helper to get IPFS content with retries and fallbacks
   * @param {string} cid - IPFS CID to retrieve
   * @returns {Promise<string>} Content as string
   * @private
   */
  async _getFromIPFS(cid) {
    // Implement retry logic
    let attempt = 0;
    let lastError = null;

    while (attempt < CONFIG.ipfs.retryAttempts) {
      try {
        const chunks = [];
        for await (const chunk of ipfs.cat(cid)) {
          chunks.push(chunk);
        }
        
        // Combine chunks and convert to string
        return Buffer.concat(chunks).toString();
      } catch (error) {
        lastError = error;
        console.warn(`IPFS fetch attempt ${attempt + 1} failed:`, error);
        attempt++;
        
        // Try fallback gateway if primary fails
        if (attempt === 1) {
          try {
            const response = await fetch(`${CONFIG.ipfs.fallback}/ipfs/${cid}`);
            if (response.ok) {
              return await response.text();
            }
          } catch (fallbackError) {
            console.warn('Fallback IPFS gateway failed:', fallbackError);
          }
        }
        
        // Wait before retrying (exponential backoff)
        if (attempt < CONFIG.ipfs.retryAttempts) {
          const backoffTime = Math.pow(2, attempt) * 1000;
          await new Promise(resolve => setTimeout(resolve, backoffTime));
        }
      }
    }

    throw new Error(`IPFS fetch failed after ${CONFIG.ipfs.retryAttempts} attempts: ${lastError.message}`);
  }

  /**
   * Helper to convert bytes32 to IPFS hash
   * @param {string} bytes32Hex - Bytes32 value in hex
   * @returns {string} IPFS hash
   * @private
   */
  _convertBytes32ToIpfsHash(bytes32Hex) {
    // Implementation depends on how your contract stores IPFS hashes
    // This is a simplified version - you may need to adjust based on your contract
    try {
      // If using keccak256, you can't convert back directly
      // For Base58 encoded CIDs, you'd need additional logic
      return bytes32Hex;
    } catch (error) {
      console.warn('Failed to convert bytes32 to IPFS hash:', error);
      return bytes32Hex;
    }
  }

  /**
   * Update the project cache (in-memory or localStorage)
   * @param {string} projectId - Project ID
   * @param {Object} data - Project data to update
   * @private
   */
  _updateProjectCache(projectId, data) {
    // Simple in-memory cache
    if (!this._projectCache) this._projectCache = {};
    
    this._projectCache[projectId] = {
      ...(this._projectCache[projectId] || {}),
      ...data,
      lastUpdated: Date.now()
    };
    
    // Optional: store in localStorage for persistence
    try {
      if (typeof localStorage !== 'undefined') {
        localStorage.setItem('terraStake_projects', JSON.stringify(this._projectCache));
      }
    } catch (e) {
      console.warn('Failed to update localStorage cache:', e);
    }
  }

  /**
   * Get user stake information
   * @param {string} address - User address (defaults to connected user)
   * @returns {Promise<Array>} Array of stakes
   */
  async getUserStakes(address = null) {
    if (!this.isInitialized) await this.initialize();
    
    // Use provided address or default to connected user
    const userAddress = address || this.userAddress;
    if (!userAddress) throw new Error('No user address provided or connected');
    
    try {
      // Get stake count for user
      const stakeCount = await this.contract.getUserStakeCount(userAddress);
      
      const stakes = [];
      
      // Get each stake detail
      for (let i = 0; i < stakeCount.toNumber(); i++) {
        const stake = await this.contract.getUserStake(userAddress, i);
        
        stakes.push({
          index: i,
          projectId: stake.projectId.toString(),
          amount: ethers.utils.formatEther(stake.amount),
          timestamp: stake.timestamp.toNumber(),
          active: stake.active,
          lastRewardsClaimed: stake.lastRewardsClaimed.toNumber()
        });
      }
      
      return stakes;
    } catch (error) {
      console.error('Failed to get user stakes:', error);
      throw new Error(`Failed to get user stakes: ${error.message}`);
    }
  }

  /**
   * Claim rewards for a stake
   * @param {number} stakeIndex - Index of the stake
   * @param {Object} options - Claiming options
   * @returns {Promise<Object>} Claim result
   */
  async claimRewards(stakeIndex, options = {}) {
    if (!this.isInitialized) await this.initialize();
    if (!this.signer) throw new Error('No signer available. Cannot perform write operations.');
    
    try {
      if (options.onStatus) options.onStatus('Preparing reward claim...');
      
      // Get Arbitrum-specific gas parameters
      const gasParams = await this.getArbitrumGasParams();
      
      // Estimate gas
      const gasEstimate = await this.contract.estimateGas.claimRewards(stakeIndex);
      
      const gasLimit = Math.ceil(gasEstimate.toNumber() * CONFIG.ethereum.gasLimitMultiplier);
      
      if (options.onStatus) options.onStatus('Submitting claim transaction...');
      
      // Execute transaction
      const tx = await this.contract.claimRewards(stakeIndex, { 
        gasLimit,
        gasPrice: gasParams.gasPrice
      });
      
      if (options.onStatus) options.onStatus(`Transaction submitted: ${tx.hash}`);
      
      // Wait for confirmation
      const receipt = await tx.wait(CONFIG.ethereum.confirmations);
      
      // Find the reward amount from the event
      const rewardEvent = receipt.events.find(event => 
        event.event === 'RewardsClaimed'
      );
      
      const rewardAmount = rewardEvent ? 
        ethers.utils.formatEther(rewardEvent.args.amount) : '0';
      
      if (options.onStatus) options.onStatus(`Successfully claimed ${rewardAmount} rewards`);
      
      return {
        success: true,
        transactionHash: receipt.transactionHash,
        blockNumber: receipt.blockNumber,
        rewardAmount,
        explorerLink: `${this.networkConfig.blockExplorer}/tx/${receipt.transactionHash}`
      };
    } catch (error) {
      console.error('Reward claim failed:', error);
      if (options.onStatus) options.onStatus(`Error: ${error.message}`);
      throw new Error(`Failed to claim rewards: ${error.message}`);
    }
  }

  /**
   * Clean up resources and event listeners
   */
  cleanup() {
    // Remove all event listeners
    this.eventListeners.forEach(listener => {
      if (listener && typeof listener.removeAllListeners === 'function') {
        listener.removeAllListeners();
      }
    });
    this.eventListeners = [];
    
    // Clear cache if needed
    this._projectCache = {};
    
    // Remove provider listeners
    if (this.provider && typeof this.provider.removeAllListeners === 'function') {
      this.provider.removeAllListeners();
    }
    
    this.isInitialized = false;
    console.log('TerraStake service cleaned up');
  }
}

// UI integration example with modern React hooks pattern
function createTerraStakeHooks(service) {
  return {
    /**
     * Custom React hook for uploading documents
     * @returns {Object} Upload functions and state
     */
    useDocumentUpload: () => {
      const [isUploading, setIsUploading] = React.useState(false);
      const [progress, setProgress] = React.useState(0);
      const [status, setStatus] = React.useState('');
      const [result, setResult] = React.useState(null);
      const [error, setError] = React.useState(null);
      
      const uploadDocument = async (file, projectId, options = {}) => {
        setIsUploading(true);
        setProgress(0);
        setStatus('Preparing...');
        setError(null);
        
        try {
          const uploadResult = await service.uploadProjectDocument(file, projectId, {
            onProgress: (bytes) => {
              const fileSize = file.size;
              const percentage = Math.min(Math.floor(bytes / fileSize * 100), 95);
              setProgress(percentage);
            },
            onStatus: (msg) => {
              setStatus(msg);
            },
            ...options
          });
          
          setResult(uploadResult);
          setProgress(100);
          setStatus('Complete');
          return uploadResult;
        } catch (err) {
          setError(err.message);
          setStatus(`Error: ${err.message}`);
          throw err;
        } finally {
          setIsUploading(false);
        }
      };
      
      return {
        uploadDocument,
        isUploading,
        progress,
        status,
        result,
        error,
        reset: () => {
          setIsUploading(false);
          setProgress(0);
          setStatus('');
          setResult(null);
          setError(null);
        }
      };
    },
    
    /**
     * Custom React hook for creating projects
     * @returns {Object} Project creation functions and state
     */
    useProjectCreation: () => {
      const [isCreating, setIsCreating] = React.useState(false);
      const [status, setStatus] = React.useState('');
      const [result, setResult] = React.useState(null);
      const [error, setError] = React.useState(null);
      
      const createProject = async (metadata, files = [], options = {}) => {
        setIsCreating(true);
        setStatus('Preparing project...');
        setError(null);
        
        try {
          const creationResult = await service.createProject(metadata, {
            files,
            onStatus: (msg) => {
              setStatus(msg);
            },
            onFileProgress: (progress) => {
              setStatus(`Uploading files: ${progress}%`);
            },
            onMetadataProgress: (progress) => {
              setStatus(`Uploading metadata: ${progress}%`);
            },
            ...options
          });
          
          setResult(creationResult);
          setStatus(`Project created with ID: ${creationResult.projectId}`);
          return creationResult;
        } catch (err) {
          setError(err.message);
          setStatus(`Error: ${err.message}`);
          throw err;
        } finally {
          setIsCreating(false);
        }
      };
      
      return {
        createProject,
        isCreating,
        status,
        result,
        error,
        reset: () => {
          setIsCreating(false);
          setStatus('');
          setResult(null);
          setError(null);
        }
      };
    },
    
    /**
     * Custom React hook for loading project details
     * @returns {Object} Project loading functions and state
     */
    useProjectDetails: (initialProjectId = null) => {
      const [projectId, setProjectId] = React.useState(initialProjectId);
      const [project, setProject] = React.useState(null);
      const [isLoading, setIsLoading] = React.useState(false);
      const [error, setError] = React.useState(null);
      
      const loadProject = React.useCallback(async (id = null, options = {}) => {
        const targetId = id !== null ? id : projectId;
        if (!targetId) return;
        
        setIsLoading(true);
        setError(null);
        
        try {
          const projectData = await service.getProjectDetails(targetId, options);
          setProject(projectData);
          return projectData;
        } catch (err) {
          setError(err.message);
          throw err;
        } finally {
          setIsLoading(false);
        }
      }, [projectId]);
      
      // Auto-load on project ID change if autoLoad is true
      React.useEffect(() => {
        if (initialProjectId !== null && initialProjectId !== undefined) {
          loadProject(initialProjectId);
        }
      }, [initialProjectId]);
      
      return {
        projectId,
        setProjectId,
        project,
        isLoading,
        error,
        loadProject,
        refreshProject: () => loadProject(projectId)
      };
    },
    
    /**
     * Custom React hook for staking on projects
     * @returns {Object} Staking functions and state
     */
    useStaking: () => {
      const [isStaking, setIsStaking] = React.useState(false);
      const [status, setStatus] = React.useState('');
      const [result, setResult] = React.useState(null);
      const [error, setError] = React.useState(null);
      
      const stakeOnProject = async (projectId, amount, options = {}) => {
        setIsStaking(true);
        setStatus('Preparing stake...');
        setError(null);
        
        try {
          const stakeResult = await service.stakeOnProject(projectId, amount, {
            onStatus: (msg) => {
              setStatus(msg);
            },
            ...options
          });
          
          setResult(stakeResult);
          setStatus(`Successfully staked ${amount} ETH on project ${projectId}`);
          return stakeResult;
        } catch (err) {
          setError(err.message);
          setStatus(`Error: ${err.message}`);
          throw err;
        } finally {
          setIsStaking(false);
        }
      };
      
      return {
        stakeOnProject,
        isStaking,
        status,
        result,
        error,
        reset: () => {
          setIsStaking(false);
          setStatus('');
          setResult(null);
          setError(null);
        }
      };
    },
    
    /**
     * Custom React hook for user stakes
     * @returns {Object} User stakes functions and state
     */
    useUserStakes: (address = null) => {
      const [stakes, setStakes] = React.useState([]);
      const [isLoading, setIsLoading] = React.useState(false);
      const [error, setError] = React.useState(null);
      
      const loadStakes = React.useCallback(async (targetAddress = null) => {
        setIsLoading(true);
        setError(null);
        
        try {
          const userStakes = await service.getUserStakes(targetAddress || address);
          setStakes(userStakes);
          return userStakes;
        } catch (err) {
          setError(err.message);
          throw err;
        } finally {
          setIsLoading(false);
        }
      }, [address]);
      
      // Load stakes on initial render if address is provided
      React.useEffect(() => {
        if (address) {
          loadStakes(address);
        }
      }, [address]);
      
      return {
        stakes,
        isLoading,
        error,
        loadStakes,
        refreshStakes: () => loadStakes(address)
      };
    },
    
    /**
     * Custom React hook for network state
     * @returns {Object} Network state and functions
     */
    useNetwork: () => {
      const [network, setNetwork] = React.useState(null);
      const [chainId, setChainId] = React.useState(null);
      const [account, setAccount] = React.useState(null);
      const [isConnected, setIsConnected] = React.useState(false);
      const [isInitializing, setIsInitializing] = React.useState(true);
      const [error, setError] = React.useState(null);
      
      const initialize = React.useCallback(async (networkName = 'arbitrumTestnet') => {
        setIsInitializing(true);
        setError(null);
        
        try {
          await service.initialize(null, networkName);
          
          setNetwork(service.networkConfig.name);
          setChainId(service.networkConfig.chainId);
          setAccount(service.userAddress);
          setIsConnected(!!service.userAddress);
          
          return true;
        } catch (err) {
          setError(err.message);
          throw err;
        } finally {
          setIsInitializing(false);
        }
      }, []);
      
      const disconnect = React.useCallback(() => {
        service.cleanup();
        setIsConnected(false);
        setAccount(null);
      }, []);
      
      // Initialize on component mount
      React.useEffect(() => {
        initialize().catch(console.error);
        
        // Setup event listeners for wallet/account changes
        if (typeof window !== 'undefined' && window.ethereum) {
          const handleAccountsChanged = (accounts) => {
            if (accounts.length === 0) {
              setAccount(null);
              setIsConnected(false);
            } else if (accounts[0] !== account) {
              setAccount(accounts[0]);
              setIsConnected(true);
              // Reinitialize with new account
              initialize().catch(console.error);
            }
          };
          
          const handleChainChanged = () => {
            // Reload the page on chain change as recommended by MetaMask
            window.location.reload();
          };
          
          window.ethereum.on('accountsChanged', handleAccountsChanged);
          window.ethereum.on('chainChanged', handleChainChanged);
          
          return () => {
            window.ethereum.removeListener('accountsChanged', handleAccountsChanged);
            window.ethereum.removeListener('chainChanged', handleChainChanged);
            service.cleanup();
          };
        }
        
        return () => {
          service.cleanup();
        };
      }, []);
      
      return {
        network,
        chainId,
        account,
        isConnected,
        isInitializing,
        error,
        initialize,
        disconnect,
        switchNetwork: initialize
      };
    }
  };
}

// Instantiate the service
const terraStakeService = new TerraStakeService('arbitrumOne');

// Export both the service instance and class for flexibility
module.exports = {
  terraStakeService,
  TerraStakeService,
  createTerraStakeHooks
};        
        
          
