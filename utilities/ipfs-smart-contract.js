// Import the IPFS HTTP client and ethers.js
const { create } = require('ipfs-http-client');
const { ethers } = require('ethers');
const { Buffer } = require('buffer');

// Advanced configuration with fallback providers
const CONFIG = {
  ipfs: {
    primary: 'https://ipfs.infura.io:5001/api/v0',
    fallback: 'https://ipfs.io',
    timeout: 60000, // 1 minute timeout
    retryAttempts: 3
  },
  ethereum: {
    gasLimitMultiplier: 1.2, // Add 20% to estimated gas
    confirmations: 2, // Wait for 2 confirmations
    networks: {
      mainnet: {
        contractAddress: '0xMainnetContractAddress',
        chainId: 1
      },
      polygon: {
        contractAddress: '0xPolygonContractAddress',
        chainId: 137
      },
      testnet: {
        contractAddress: '0xTestnetContractAddress',
        chainId: 5 // Goerli
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
  constructor(networkName = 'testnet') {
    this.networkConfig = CONFIG.ethereum.networks[networkName];
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
      // Use provided provider or connect to window.ethereum
      if (externalProvider) {
        this.provider = externalProvider;
      } else if (window.ethereum) {
        this.provider = new ethers.providers.Web3Provider(window.ethereum);
        // Request account access
        await window.ethereum.request({ method: 'eth_requestAccounts' });
      } else {
        throw new Error('No Ethereum provider found. Please install MetaMask or another wallet.');
      }

      // Ensure correct network
      const network = await this.provider.getNetwork();
      if (network.chainId !== this.networkConfig.chainId) {
        throw new Error(`Please connect to the correct network. Expected chainId: ${this.networkConfig.chainId}`);
      }

      this.signer = this.provider.getSigner();
      this.userAddress = await this.signer.getAddress();
      
      this.contract = new ethers.Contract(
        this.networkConfig.contractAddress,
        this.contractABI,
        this.signer
      );

      // Setup event listeners
      this._setupEventListeners();
      
      this.isInitialized = true;
      return true;
    } catch (error) {
      console.error('Initialization failed:', error);
      throw new Error(`Failed to initialize TerraStake service: ${error.message}`);
    }
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
        timestamp: Date.now()
      };

      // Upload to IPFS with metadata
      const ipfsHash = await this.uploadToIPFS(file, {
        metadata: metadata,
        onProgress: options.onProgress
      });

      if (options.onStatus) options.onStatus('Submitting to blockchain...');
      
      // Prepare transaction with proper gas estimation
      const gasEstimate = await this.contract.estimateGas.uploadProjectDocuments(
        projectId, 
        [ipfsHash]
      );
      
      const gasLimit = Math.ceil(gasEstimate.toNumber() * CONFIG.ethereum.gasLimitMultiplier);
      
      // Execute the transaction
      const tx = await this.contract.uploadProjectDocuments(
        projectId, 
        [ipfsHash],
        { gasLimit }
      );
      
      if (options.onStatus) options.onStatus(`Transaction submitted: ${tx.hash}`);
      
      // Wait for confirmation with specified number of blocks
      const receipt = await tx.wait(CONFIG.ethereum.confirmations);
      
      if (options.onStatus) options.onStatus('Document successfully uploaded');
      
      return {
        success: true,
        ipfsHash,
        transactionHash: receipt.transactionHash,
        blockNumber: receipt.blockNumber
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
            projectId: projectId
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
        { gasLimit }
      );
      
      // Wait for confirmation
      const receipt = await tx.wait(CONFIG.ethereum.confirmations);
      
      // Update results with transaction data
      results.forEach(result => {
        result.transactionHash = receipt.transactionHash;
        result.blockNumber = receipt.blockNumber;
        result.status = 'Confirmed';
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
   * Enhanced project creation with comprehensive metadata
   * @param {Object} metadata - Project metadata
   * @param {Object} options - Creation options
   * @returns {Promise<Object>} Creation result with project ID
   */
  async createProject(metadata, options = {}) {
    if (!this.isInitialized) await this.initialize();
    
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
            const ipfsHashBytes32 = ethers.utils.hexlify(
        ethers.utils.base58.decode(ipfsMetadataHash).slice(2)
      );
      
      if (options.onStatus) options.onStatus('Creating project on blockchain...');
      
      // Ensure numeric values are properly converted
      const stakingMultiplier = ethers.BigNumber.from(metadata.stakingMultiplier || 100);
      const startBlock = ethers.BigNumber.from(metadata.startBlock || 0);
      const endBlock = ethers.BigNumber.from(metadata.endBlock || 0);
      
      // Estimate gas for project creation
      const gasEstimate = await this.contract.estimateGas.addProject(
        metadata.name,
        metadata.description,
        metadata.location,
        metadata.impactMetrics,
        ipfsHashBytes32,
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
        ipfsHashBytes32,
        metadata.category,
        stakingMultiplier,
        startBlock,
        endBlock,
        { gasLimit }
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
        ipfsHash: ipfsMetadataHash
      };
    } catch (error) {
      console.error('Project creation failed:', error);
      if (options.onStatus) options.onStatus(`Error: ${error.message}`);
      throw new Error(`Failed to create project: ${error.message}`);
    }
  }

  /**
   * Submit an impact report for a project
   * @param {number} projectId - Project ID
   * @param {Object} reportData - Report data
   * @param {Object} options - Submission options
   * @returns {Promise<Object>} Submission result
   */
  async submitImpactReport(projectId, reportData, options = {}) {
    if (!this.isInitialized) await this.initialize();
    
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
        submittedAt: Date.now()
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
        { gasLimit }
      );
      
      if (options.onStatus) options.onStatus(`Transaction submitted: ${tx.hash}`);
      
      // Wait for confirmation
      const receipt = await tx.wait(CONFIG.ethereum.confirmations);
      
      if (options.onStatus) options.onStatus('Impact report successfully submitted');
      
      return {
        success: true,
        transactionHash: receipt.transactionHash,
        blockNumber: receipt.blockNumber,
        ipfsHash: reportIpfsHash
      };
    } catch (error) {
      console.error('Impact report submission failed:', error);
      if (options.onStatus) options.onStatus(`Error: ${error.message}`);
      throw new Error(`Failed to submit impact report: ${error.message}`);
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
      localStorage.setItem('terraStake_projects', JSON.stringify(this._projectCache));
    } catch (e) {
      console.warn('Failed to update localStorage cache:', e);
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
        setStatus('Preparing upload...');
        setError(null);
        
        try {
          const uploadResult = await service.uploadProjectDocument(file, projectId, {
            onProgress: (progressData) => {
              setProgress(Math.round((progressData.loaded / progressData.total) * 100));
            },
            onStatus: setStatus,
            ...options
          });
          
          setResult(uploadResult);
          return uploadResult;
        } catch (err) {
          setError(err.message);
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
          setProgress(0);
          setStatus('');
          setResult(null);
          setError(null);
        }
      };
    },
    
    /**
     * Custom React hook for project creation
     * @returns {Object} Project creation functions and state
     */
    useProjectCreation: () => {
      const [isCreating, setIsCreating] = React.useState(false);
      const [status, setStatus] = React.useState('');
      const [result, setResult] = React.useState(null);
      const [error, setError] = React.useState(null);
      
      const createProject = async (metadata, options = {}) => {
        setIsCreating(true);
        setStatus('Preparing project creation...');
        setError(null);
        
        try {
          const creationResult = await service.createProject(metadata, {
            onStatus: setStatus,
            ...options
          });
          
          setResult(creationResult);
          return creationResult;
        } catch (err) {
          setError(err.message);
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
          setStatus('');
          setResult(null);
          setError(null);
        }
      };
    }
  };
}

// Export the service
module.exports = {
  TerraStakeService,
  createTerraStakeHooks,
  ipfs,
  CONFIG
};
