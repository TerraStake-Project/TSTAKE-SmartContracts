import { ethers } from 'ethers';
import EventEmitter from 'events';
import fs from 'fs';
import path from 'path';
import dotenv from 'dotenv';

// Import ABIs
import {
    TerraStakeTokenABI,
    TerraStakeStakingABI,
    TerraStakeRewardsABI,
    TerraStakeProjectsABI,
    TerraStakeITOABI,
    TerraGovernanceABI,
    TerraStakeAccessControlABI,
    ChainlinkDataFeederABI
} from './abi';

// Interfaces
interface StakingPosition {
    tStakeAmount: ethers.BigNumber; // Amount of TSTAKE staked
    lockEndTime: number;            // Timestamp when staking lock ends
    pendingRewards: ethers.BigNumber; // TSTAKE rewards pending claim
    multiplier: number;             // Reward multiplier applied to the position
    lastUpdateTime: number;         // Timestamp of the last position update
}

interface RewardConfig {
    minAPY: number;
    maxAPY: number;
    timeMultiplierIncrease: number;
    maxTimeMultiplier: number;
}

interface NetworkConfig {
    chainId: number;
    name: string;
    contracts: ContractAddresses;
    provider: string;
    rewardConfig: RewardConfig;
}

interface ContractAddresses {
    token: string;
    staking: string;
    rewards: string;
    projects: string;
    ito: string;
    governance: string;
    oracle: string;
}

interface ContractConfig {
    defaultNetwork: string;
    networks: Record<string, NetworkConfig>;
}

class ContractManager {
    private provider: ethers.providers.Provider;
    private signer: ethers.Signer;
    private contracts: Record<string, ethers.Contract>;
    private config: ContractConfig;
    private networkConfig: NetworkConfig;
    private eventEmitter: EventEmitter;

    constructor(provider: ethers.providers.Provider, configPath: string = '../config/contracts.json') {
        if (!provider) throw new Error("Provider is required");

        this.provider = provider;
        this.signer = provider.getSigner();
        this.eventEmitter = new EventEmitter();

        this.loadConfiguration(configPath);
        this.contracts = this.initializeContracts();
    }

    /**
     * Load configuration from a JSON file.
     */
    private loadConfiguration(configPath: string): void {
        dotenv.config();
        try {
            const configFile = fs.readFileSync(path.resolve(__dirname, configPath), 'utf8');
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
     * Validate network configuration for required contracts.
     */
    private validateConfiguration(): void {
        const requiredContracts = ['token', 'staking', 'rewards', 'projects', 'ito', 'governance', 'oracle'];
        for (const contract of requiredContracts) {
            const address = this.networkConfig.contracts[contract];
            if (!address || !ethers.utils.isAddress(address)) {
                throw new Error(`Invalid or missing address for ${contract}`);
            }
        }
    }

    /**
     * Initialize all smart contracts using their respective ABIs.
     */
    private initializeContracts(): Record<string, ethers.Contract> {
        const abiMap = {
            token: TerraStakeTokenABI,
            staking: TerraStakeStakingABI,
            rewards: TerraStakeRewardsABI,
            projects: TerraStakeProjectsABI,
            ito: TerraStakeITOABI,
            governance: TerraGovernanceABI,
            oracle: ChainlinkDataFeederABI
        };

        const contracts: Record<string, ethers.Contract> = {};
        Object.entries(abiMap).forEach(([name, abi]) => {
            contracts[name] = new ethers.Contract(this.networkConfig.contracts[name], abi, this.signer);
        });
        return contracts;
    }

    /**
     * Validate Ethereum address.
     */
    private validateAddress(address: string): void {
        if (!ethers.utils.isAddress(address)) throw new Error(`Invalid address: ${address}`);
    }

    /**
     * Validate a numeric amount.
     */
    private validateAmount(amount: number): void {
        if (amount <= 0) throw new Error("Amount must be greater than zero");
    }

    // -------------------------------
    // Token (TSTAKE) Management
    // -------------------------------
    async getTSTAKEBalance(address: string): Promise<ethers.BigNumber> {
        this.validateAddress(address);
        return this.contracts.token.balanceOf(address);
    }

    async transferTSTAKE(to: string, amount: number): Promise<ethers.ContractReceipt> {
        this.validateAddress(to);
        this.validateAmount(amount);

        const tx = await this.contracts.token.transfer(to, ethers.utils.parseUnits(amount.toString(), 18));
        return await tx.wait();
    }

    async approveTSTAKE(spender: string, amount: number): Promise<ethers.ContractReceipt> {
        this.validateAddress(spender);
        this.validateAmount(amount);

        const tx = await this.contracts.token.approve(spender, ethers.utils.parseUnits(amount.toString(), 18));
        return await tx.wait();
    }

    // -------------------------------
    // Staking Management
    // -------------------------------
    async stakeTSTAKE(projectId: number, amount: number, lockPeriod: number = 0): Promise<ethers.ContractReceipt> {
        this.validateAmount(amount);

        const parsedAmount = ethers.utils.parseUnits(amount.toString(), 18);
        const userBalance = await this.contracts.token.balanceOf(await this.signer.getAddress());
        if (userBalance.lt(parsedAmount)) throw new Error("Insufficient TSTAKE balance");

        // Approve tokens for staking
        await this.approveTSTAKE(this.contracts.staking.address, amount);

        const tx = await this.contracts.staking.stake(projectId, parsedAmount, lockPeriod);
        return await tx.wait();
    }

    async getStakingPosition(address: string, projectId: number): Promise<StakingPosition> {
        this.validateAddress(address);
        return this.contracts.staking.getStakingPosition(address, projectId);
    }

    // -------------------------------
    // Liquidity Management (TSTAKE/USDC)
    // -------------------------------
    async addTSTAKELiquidity(
        amountTSTAKE: number,
        amountUSDC: number,
        lowerTick: number,
        upperTick: number
    ): Promise<ethers.ContractReceipt> {
        const parsedTSTAKE = ethers.utils.parseUnits(amountTSTAKE.toString(), 18);
        const parsedUSDC = ethers.utils.parseUnits(amountUSDC.toString(), 6); // USDC has 6 decimals

        await this.approveTSTAKE(this.contracts.ito.address, amountTSTAKE);
        await this.approveUSDC(this.contracts.ito.address, amountUSDC);

        const tx = await this.contracts.ito.addLiquidity(parsedTSTAKE, parsedUSDC, lowerTick, upperTick);
        return await tx.wait();
    }

    async approveUSDC(spender: string, amount: number): Promise<ethers.ContractReceipt> {
        this.validateAddress(spender);
        this.validateAmount(amount);

        const tx = await this.contracts.usdc.approve(spender, ethers.utils.parseUnits(amount.toString(), 6));
        return await tx.wait();
    }

    // -------------------------------
    // Events
    // -------------------------------
    on(event: string, listener: (...args: any[]) => void): void {
        this.eventEmitter.on(event, listener);
    }

    off(event: string, listener: (...args: any[]) => void): void {
        this.eventEmitter.off(event, listener);
    }
}
/**
 * Claim pending rewards for a specific project.
 */
async claimRewards(projectId: number): Promise<ethers.ContractReceipt> {
    const rewards = this.contracts.rewards;

    try {
        const tx = await rewards.claimRewards(projectId, {
            gasLimit: 200000
        });
        return await tx.wait();
    } catch (error) {
        throw new Error(`Claiming rewards failed: ${error.message}`);
    }
}
/**
 * Claim rewards for multiple projects at once.
 */
async batchClaimRewards(projectIds: number[]): Promise<ethers.ContractReceipt> {
    const rewards = this.contracts.rewards;

    try {
        const tx = await rewards.batchClaimRewards(projectIds, {
            gasLimit: 500000
        });
        return await tx.wait();
    } catch (error) {
        throw new Error(`Batch rewards claim failed: ${error.message}`);
    }
}
/**
 * Ensure sufficient token allowance for a spender.
 */
async ensureTokenAllowance(
    spender: string,
    amount: ethers.BigNumber
): Promise<void> {
    const token = this.contracts.token;
    const currentAllowance = await token.allowance(await this.signer.getAddress(), spender);

    if (currentAllowance.lt(amount)) {
        const approvalTx = await token.approve(spender, amount);
        await approvalTx.wait();
    }
}
/**
 * Emergency withdraw staked tokens without rewards.
 */
async emergencyWithdraw(projectId: number): Promise<ethers.ContractReceipt> {
    const staking = this.contracts.staking;

    try {
        const tx = await staking.emergencyWithdraw(projectId, {
            gasLimit: 300000
        });
        return await tx.wait();
    } catch (error) {
        throw new Error(`Emergency withdrawal failed: ${error.message}`);
    }
}
/**
 * Get TSTAKE token supply details.
 */
async getTSTAKESupply(): Promise<{
    totalSupply: ethers.BigNumber;
    circulatingSupply: ethers.BigNumber;
}> {
    const token = this.contracts.token;

    try {
        const totalSupply = await token.totalSupply();
        const circulatingSupply = totalSupply.sub(await token.balanceOf(this.contracts.staking.address));
        return { totalSupply, circulatingSupply };
    } catch (error) {
        throw new Error(`Failed to fetch TSTAKE supply: ${error.message}`);
    }
}
/**
 * Set up listeners for critical contract events.
 */
private setupEventListeners(): void {
    const staking = this.contracts.staking;
    const rewards = this.contracts.rewards;
    const ito = this.contracts.ito;

    staking.on('Staked', (user, amount, projectId) => {
        this.eventEmitter.emit('Staked', { user, amount, projectId });
    });

    rewards.on('RewardsClaimed', (user, amount, projectId) => {
        this.eventEmitter.emit('RewardsClaimed', { user, amount, projectId });
    });

    ito.on('LiquidityAdded', (tStakeAmount, usdcAmount, timestamp) => {
        this.eventEmitter.emit('LiquidityAdded', { tStakeAmount, usdcAmount, timestamp });
    });
}
/**
 * Validate sufficient balances before adding liquidity.
 */
async validateLiquidityBalances(amountTSTAKE: number, amountUSDC: number): Promise<void> {
    const tokenBalance = await this.contracts.token.balanceOf(await this.signer.getAddress());
    const usdcBalance = await this.contracts.usdc.balanceOf(await this.signer.getAddress());

    const parsedTSTAKE = ethers.utils.parseUnits(amountTSTAKE.toString(), 18);
    const parsedUSDC = ethers.utils.parseUnits(amountUSDC.toString(), 6);

    if (tokenBalance.lt(parsedTSTAKE)) throw new Error("Insufficient TSTAKE balance for liquidity");
    if (usdcBalance.lt(parsedUSDC)) throw new Error("Insufficient USDC balance for liquidity");
}
/**
 * Customizable gas parameters for transactions.
 */
private getGasOptions(options?: { gasLimit?: number; gasPrice?: ethers.BigNumber }) {
    return {
        gasLimit: options?.gasLimit || 300000,
        gasPrice: options?.gasPrice || undefined,
    };
}
export default ContractManager;

