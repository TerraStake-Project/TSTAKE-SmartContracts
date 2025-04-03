// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.21;

/**
 * @title ITerraStakeGovernance
 * @notice Interface for the TerraStake governance contract
 */
interface ITerraStakeGovernance {
    // ========== Enums ==========
    enum ProposalState {
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }
    
    // ========== Structs ==========
    struct ProposalParameters {
        uint32 votingPeriod;
        uint32 executionDelay;
        uint32 gracePeriod;
        uint256 quorumThreshold;
        uint256 requiredMajority;
    }
    
    struct CrossChainState {
        uint256 halvingEpoch;
        uint256 treasury;
        uint256 totalVotes;
        uint256 nextProposalId;
        uint256 timestamp;
    }

    // ========== Events ==========
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        uint8 proposalType,
        string description,
        uint32 votingStart,
        uint32 votingEnd
    );
    event VoteCast(
        uint256 indexed proposalId,
        address indexed voter,
        bool support,
        uint256 weight
    );
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCanceled(uint256 indexed proposalId);
    event EmergencyShutdown(bool paused);
    event HalvingTriggered(uint256 epoch, uint256 timestamp);
    event VotingPowerUpdated(address indexed account, uint256 newVotingPower);
    event TreasuryUpdated(address newTreasury);
    event StakingContractUpdated(address newStakingContract);
    event TokenUpdated(address newToken);
    event ITOContractUpdated(address newITO);
    event AntiBotContractUpdated(address newAntiBot);

    // ========== Proposal Management ==========
    function propose(
        string calldata description,
        uint8 proposalType,
        bytes calldata data
    ) external returns (uint256);
    
    function castVote(uint256 proposalId, bool support) external;
    
    function executeProposal(uint256 proposalId) external;
    
    function cancelProposal(uint256 proposalId) external;
    
    // ========== Voting Power Management ==========
    function updateVotingPower(address account, uint256 newVotingPower) external;
    
    function getVotingPower(address account) external view returns (uint256);
    
    function delegate(address delegatee) external;
    
    // ========== Treasury Management ==========
    function depositToTreasury(address token, uint256 amount) external payable;
    
    function emergencyWithdrawal(
        address token,
        address recipient,
        uint256 amount
    ) external;
    
    // ========== Halving Functions ==========
    function applyHalving() external returns (uint256);
    
    function syncHalvingEpoch(uint256 epoch, uint256 timestamp) external;
    
    // ========== Cross-Chain Integration ==========
    function setCCIPRouter(address _router) external;
    
    function setDestinationChains(uint64[] calldata _chains) external;
    
    function setTrustedSourceChain(uint64 chainSelector, bool trusted) external;
    
    function ccipReceive(
        uint64 sourceChainSelector,
        bytes calldata sender,
        bytes calldata message,
        bytes32 messageId
    ) external;
    
    function decodeCrossChainState(bytes calldata data) external pure returns (CrossChainState memory);
    
    function decodeStringCommand(bytes calldata data) external pure returns (string memory command, bytes memory commandData);
    
    // ========== ITO Integration ==========
    function setITOContract(address _ito) external;
    
    function startITO(uint256 duration) external;
    
    function endITO() external;
    
    function updateITOPriceParameters(
        uint256 startingPrice,
        uint256 endingPrice,
        uint256 priceDuration
    ) external;
    
    function setITOParticipantTier(address participant, uint8 tier) external;
    
    // ========== AntiBot Integration ==========
    function setAntiBotContract(address _antiBot) external;
    
    function resetCircuitBreaker() external;
    
    function resetPriceSurgeBreaker() external;
    
    function updateAntiBotPriceThresholds(
        uint256 impact,
        uint256 surge,
        uint256 circuit
    ) external;
    
    // ========== Multi-Sig Functions ==========
    function approveMultiSigOperation(bytes32 operationHash) external;
    
    function resetMultiSigApprovals(bytes32 operationHash) external;
    
    function updateRequiredApprovals(uint256 newRequiredApprovals) external;
    
    // ========== Utility Functions ==========
    function getProposalState(uint256 proposalId) external view returns (ProposalState);
    
    function getProposalDetails(uint256 proposalId) external view returns (
        address proposer,
        string memory description,
        uint8 proposalType,
        uint32 votingStart,
        uint32 votingEnd,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 quorumVotes,
        bool executed,
        ProposalState state
    );
    
    function hasVoted(uint256 proposalId, address account) external view returns (bool);
    
    function getProposalCount() external view returns (uint256);
    
    function getTotalVotes() external view returns (uint256);
    
    function getHalvingStatus() external view returns (
        uint256 epoch,
        uint256 lastTime,
        uint256 nextTime
    );
    
    function isHalvingDue() external view returns (bool);
    
    function setTokenContract(address _token) external;
    
    function setStakingContract(address _stakingContract) external;
    
    function isRoleMember(bytes32 role, address account) external view returns (bool);
    
    function version() external pure returns (string memory);
}
