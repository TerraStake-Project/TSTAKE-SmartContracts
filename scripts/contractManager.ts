import { ethers } from "ethers";
import EventEmitter from "events";
import fs from "fs";
import path from "path";
import dotenv from "dotenv";

// Load environment variables
dotenv.config();

// Import contract ABIs
import {
    TerraStakeTokenABI,
    TerraStakeStakingABI,
    TerraStakeRewardDistributorABI,
    TerraStakeProjectsABI,
    TerraStakeITOABI,
    TerraStakeGovernanceABI,
    TerraStakeAccessControlABI,
    ChainlinkDataFeederABI,
    TerraStakeSlashingABI,
    TerraStakeNFTABI,
    TerraStakeMarketPlaceABI,
    TerraStakeLiquidityGuardABI,
    TerraStakeAntiBotABI,
} from "./abi";

// Interface for Staking Positions
interface StakingPosition {
    tStakeAmount: ethers.BigNumber;
    lockEndTime: number;
    pendingRewards: ethers.BigNumber;
    multiplier: number;
    lastUpdateTime: number;
}

// Interface for Reward Configuration
interface RewardConfig {
    minAPY: number;
    maxAPY: number;
    timeMultiplierIncrease: number;
    maxTimeMultiplier: number;
}

// Interface for Network Configuration
interface NetworkConfig {
    chainId: number;
    name: string;
    contracts: ContractAddresses;
    provider: string;
    rewardConfig: RewardConfig;
}

// Interface for Contract Addresses
interface ContractAddresses {
    token: string;
    staking: string;
    rewards: string;
    projects: string;
    ito: string;
    governance: string;
    oracle: string;
}

// Interface for Config File
interface ContractConfig {
    defaultNetwork: string;
    networks: Record<string, NetworkConfig>;
}

class ContractManager {
    private provider: ethers.providers.JsonRpcProvider;
    private signer: ethers.Wallet;
    private contracts: Record<string, ethers.Contract>;
    private config: ContractConfig;
    private networkConfig: NetworkConfig;
    private eventEmitter: EventEmitter;

    constructor(configPath: string = "../config/contracts.json") {
        if (!process.env.PRIVATE_KEY) throw new Error("PRIVATE_KEY is missing in .env");
        if (!process.env.RPC_URL) throw new Error("RPC_URL is missing in .env");

        this.provider = new ethers.providers.JsonRpcProvider(process.env.RPC_URL);
        this.signer = new ethers.Wallet(process.env.PRIVATE_KEY, this.provider);
        this.eventEmitter = new EventEmitter();

        this.loadConfiguration(configPath);
        this.contracts = this.initializeContracts();
    }

    /**
     * Load the configuration file (contracts.json).
     */
    private loadConfiguration(configPath: string): void {
        try {
            const configFile = fs.readFileSync(path.resolve(__dirname, configPath), "utf8");
            this.config = JSON.parse(configFile);

            const networkId = process.env.NETWORK_ID || this.config.defaultNetwork;
            this.networkConfig = this.config.networks[networkId];

            if (!this.networkConfig) throw new Error(`Network configuration not found for ${networkId}`);
            this.validateConfiguration();
        } catch (error) {
            throw new Error(`Configuration loading failed: ${error.message}`);
        }
    }

    /**
     * Validate contract addresses.
     */
    private validateConfiguration(): void {
        const requiredContracts = ["token", "staking", "rewards", "projects", "ito", "governance", "oracle"];
        for (const contract of requiredContracts) {
            const address = this.networkConfig.contracts[contract];
            if (!address || !ethers.utils.isAddress(address)) {
                throw new Error(`Invalid or missing address for ${contract}`);
            }
        }
    }

    /**
     * Initialize smart contracts using ABIs and network configuration.
     */
    private initializeContracts(): Record<string, ethers.Contract> {
        const abiMap = {
            token: TerraStakeTokenABI,
            staking: TerraStakeStakingABI,
            projects: TerraStakeProjectsABI,
            ito: TerraStakeITOABI,
            governance: TerraStakeGovernanceABI,
            oracle: ChainlinkDataFeederABI,
            slashing: TerraStakeSlashingABI,
            NFT: TerraStakeNFTABI,
            Marketplace: TerraStakeMarketPlaceABI,
            LiquidityGuard: TerraStakeLiquidityGuardABI,
            AntiBot: TerraStakeAntiBotABI,
            AccessControl: TerraStakeAccessControlABI,
            RewardDistributor: TerraStakeRewardDistributorABI,
        };

        const contracts: Record<string, ethers.Contract> = {};
        Object.entries(abiMap).forEach(([name, abi]) => {
            contracts[name] = new ethers.Contract(this.networkConfig.contracts[name], abi, this.signer);
        });
        return contracts;
    }

    /**
     * Get TSTAKE balance of a user.
     */
    async getTSTAKEBalance(address: string): Promise<ethers.BigNumber> {
        this.validateAddress(address);
        return this.contracts.token.balanceOf(address);
    }

    /**
     * Transfer TSTAKE tokens.
     */
    async transferTSTAKE(to: string, amount: number): Promise<ethers.ContractReceipt> {
        this.validateAddress(to);
        this.validateAmount(amount);

        const tx = await this.contracts.token.transfer(to, ethers.utils.parseUnits(amount.toString(), 18));
        return await tx.wait();
    }

    /**
     * Stake TSTAKE in a project.
     */
    async stakeTSTAKE(projectId: number, amount: number, lockPeriod: number = 0): Promise<ethers.ContractReceipt> {
        this.validateAmount(amount);

        const parsedAmount = ethers.utils.parseUnits(amount.toString(), 18);
        await this.approveTSTAKE(this.contracts.staking.address, amount);

        const tx = await this.contracts.staking.stake(projectId, parsedAmount, lockPeriod);
        return await tx.wait();
    }

    /**
     * Claim staking rewards.
     */
    async claimRewards(projectId: number): Promise<ethers.ContractReceipt> {
        const tx = await this.contracts.rewards.claimRewards(projectId, { gasLimit: 200000 });
        return await tx.wait();
    }

    /**
     * Add liquidity to Uniswap (TSTAKE/USDC pair).
     */
    async addTSTAKELiquidity(amountTSTAKE: number, amountUSDC: number): Promise<ethers.ContractReceipt> {
        const parsedTSTAKE = ethers.utils.parseUnits(amountTSTAKE.toString(), 18);
        const parsedUSDC = ethers.utils.parseUnits(amountUSDC.toString(), 6);

        await this.approveTSTAKE(this.contracts.ito.address, amountTSTAKE);
        await this.approveUSDC(this.contracts.ito.address, amountUSDC);

        const tx = await this.contracts.ito.addLiquidity(parsedTSTAKE, parsedUSDC, -887220, 887220);
        return await tx.wait();
    }

    /**
     * Approve USDC for spending.
     */
    async approveUSDC(spender: string, amount: number): Promise<ethers.ContractReceipt> {
        this.validateAddress(spender);
        this.validateAmount(amount);

        const tx = await this.contracts.usdc.approve(spender, ethers.utils.parseUnits(amount.toString(), 6));
        return await tx.wait();
    }

    /**
     * Validate Ethereum address.
     */
    private validateAddress(address: string): void {
        if (!ethers.utils.isAddress(address)) throw new Error(`Invalid address: ${address}`);
    }

    /**
     * Validate numeric amount.
     */
    private validateAmount(amount: number): void {
        if (amount <= 0) throw new Error("Amount must be greater than zero");
    }
}

export default ContractManager;
