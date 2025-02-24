// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITerraStakeGovernance {
    // -------------------------------------------
    // 🔹 Proposal Enums & Structs
    // -------------------------------------------
    enum ProposalStatus { Active, Timelocked, Vetoed, Executed, VotingEnded }
    enum ProposalType { General, RewardDistribution, Buyback, LiquidityInjection }

    struct Proposal {
        bytes data;
        address target;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endBlock;
        uint256 timelockEndTime;
        bool executed;
        bool vetoed;
        ProposalType proposalType;
        uint256 linkedProjectId;
        string description;
    }

    // -------------------------------------------
    // 🔹 Governance Functions
    // -------------------------------------------
    
    /**
     * @notice Initializes the governance contract with key configurations.
     */
    function initialize(
        address _stakingContract,
        address _rewardDistributor,
        address _liquidityGuard,
        address _uniswapRouter,
        address _uniswapQuoter,
        address _uniswapPool,
        address _nftContract,
        address _treasuryWallet,
        uint256 _votingDuration,
        uint256 _proposalThreshold,
        uint256 _minimumHolding,
        uint256 _halvingPeriod
    ) external;

    /**
     * @notice Executes a successful governance proposal.
     * @dev Can only be called once the voting period has ended and timelock has passed.
     */
    function executeProposal(uint256 proposalId) external;

    /**
     * @notice Finalizes the voting process for a given proposal.
     */
    function finalizeVoting(uint256 proposalId) external;

    /**
     * @notice Checks if halving conditions are met and executes if necessary.
     */
    function checkAndTriggerHalving() external;

    /**
     * @notice Returns full proposal details.
     */
    function getProposal(uint256 proposalId) external view returns (Proposal memory);

    /**
     * @notice Returns the total number of proposals created.
     */
    function getProposalCount() external view returns (uint256);

    /**
     * @notice Returns whether a given address has voted on a proposal.
     */
    function hasUserVoted(uint256 proposalId, address user) external view returns (bool);

    /**
     * @notice Calculates the quadratic voting power for a given voter.
     */
    function calculateQuadraticVotingPower(address voter) external view returns (uint256);

    // -------------------------------------------
    // 🔹 Events
    // -------------------------------------------
    
    event ProposalCreated(
        uint256 indexed proposalId,
        bytes data,
        uint256 endBlock,
        address target,
        ProposalType proposalType,
        uint256 linkedProjectId,
        string description
    );

    event ProposalTimelocked(uint256 indexed proposalId, uint256 unlockTime);
    event ProposalExecuted(uint256 indexed proposalId, address target, ProposalType proposalType);
    event ProposalVetoed(uint256 indexed proposalId);
    event ProposalThresholdUpdated(uint256 newThreshold);
    event VotingDurationUpdated(uint256 newDuration);
    event MinimumHoldingUpdated(uint256 newMinimumHolding);
    event HalvingApplied(uint256 newEpoch);
    event HalvingPeriodUpdated(uint256 newHalvingPeriod);
    event ProposalVotingEnded(uint256 indexed proposalId, uint256 votesFor, uint256 votesAgainst);
    event BuybackExecuted(uint256 usdcAmount, uint256 tStakeReceived);
    event LiquidityInjected(uint256 usdcAmount, uint256 tStakeAdded);
}
