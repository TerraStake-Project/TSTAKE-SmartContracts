// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "../interfaces/IChainlinkDataFeeder.sol";

interface ITerraStakeStaking {
    function totalStaked() external view returns (uint256);
    function totalStakedByUser(address user) external view returns (uint256);
    function getDelegatedPower(address user) external view returns (uint256);
    function getStakingMultiplier(address user) external view returns (uint256);
}

interface ITerraStakeITO {
    function createVestingSchedule(
        address beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 duration,
        uint256 cliff,
        uint256 interval,
        bool revocable
    ) external;

    function revokeVestingSchedule(address beneficiary) external;
}

contract TerraStakeGovernance is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    // Custom Errors
    error UnauthorizedAccess();
    error InvalidProposalData();
    error ProposalAlreadyExecuted();
    error ProposalAlreadyVetoed();
    error VotingPeriodEnded();
    error VotingPowerNotSufficient();
    error AlreadyVoted();
    error InvalidProposalId();
    error VotingPeriodNotEnded();
    error InsufficientHolding();
    error OracleValidationFailed();

    // Roles
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant VETO_ROLE = keccak256("VETO_ROLE");

    // Governance-related structs and variables
    struct Proposal {
        bytes data;
        address target;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 endBlock;
        bool executed;
        bool vetoed;
        uint256 proposalType; // 0: Regular, 1: Enhanced (Project-specific)
        uint256 linkedProjectId;
    }

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    uint256 public votingDuration;
    uint256 public proposalThreshold;
    uint256 public minimumHolding;

    ITerraStakeStaking public stakingContract;
    ITerraStakeITO public itoContract;
    AggregatorV3Interface public priceFeed;

    // Events
    event ProposalCreated(uint256 indexed proposalId, bytes data, uint256 endBlock, address target, uint256 proposalType, uint256 linkedProjectId);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalVetoed(uint256 indexed proposalId);
    event ProposalThresholdUpdated(uint256 newThreshold);
    event VotingDurationUpdated(uint256 newDuration);
    event MinimumHoldingUpdated(uint256 newMinimumHolding);

    // Initialization function
    function initialize(
        address admin,
        address _stakingContract,
        address _itoContract,
        address _priceFeed,
        uint256 _votingDuration,
        uint256 _proposalThreshold,
        uint256 _minimumHolding
    ) external initializer {
        require(admin != address(0) && _stakingContract != address(0) && _itoContract != address(0) && _priceFeed != address(0), "Invalid address");
        require(_votingDuration > 0 && _proposalThreshold > 0 && _minimumHolding > 0, "Invalid parameters");

        __AccessControl_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(GOVERNANCE_ROLE, admin);
        _grantRole(VETO_ROLE, admin);

        stakingContract = ITerraStakeStaking(_stakingContract);
        itoContract = ITerraStakeITO(_itoContract);
        priceFeed = AggregatorV3Interface(_priceFeed);

        votingDuration = _votingDuration;
        proposalThreshold = _proposalThreshold;
        minimumHolding = _minimumHolding;
    }

    function createProposal(bytes calldata data, address target, uint256 proposalType, uint256 linkedProjectId) external onlyRole(GOVERNANCE_ROLE) {
        require(stakingContract.totalStaked() >= proposalThreshold, "Insufficient proposal threshold");

        uint256 proposalId = proposalCount++;
        uint256 endBlock = block.number + votingDuration;

        proposals[proposalId] = Proposal({
            data: data,
            target: target,
            votesFor: 0,
            votesAgainst: 0,
            endBlock: endBlock,
            executed: false,
            vetoed: false,
            proposalType: proposalType,
            linkedProjectId: linkedProjectId
        });

        emit ProposalCreated(proposalId, data, endBlock, target, proposalType, linkedProjectId);
    }

    function vote(uint256 proposalId, bool support) external {
        Proposal storage proposal = proposals[proposalId];
        require(block.number <= proposal.endBlock, "Voting period ended");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        require(!proposal.vetoed, "Proposal vetoed");

        uint256 votingPower = _calculateVotingPower(msg.sender);
        require(votingPower >= minimumHolding, "Insufficient voting power");

        if (support) {
            proposal.votesFor += votingPower;
        } else {
            proposal.votesAgainst += votingPower;
        }

        hasVoted[proposalId][msg.sender] = true;

        emit Voted(proposalId, msg.sender, support);
    }

    function executeProposal(uint256 proposalId) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        require(block.number > proposal.endBlock, "Voting period not ended");
        require(!proposal.executed, "Proposal already executed");
        require(!proposal.vetoed, "Proposal vetoed");

        if (proposal.votesFor > proposal.votesAgainst) {
            require(_isValidProposalData(proposal.data), "Invalid proposal data");
            (bool success, ) = proposal.target.call(proposal.data);
            require(success, "Proposal execution failed");
        }

        proposal.executed = true;

        emit ProposalExecuted(proposalId);
    }

    function vetoProposal(uint256 proposalId) external onlyRole(VETO_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        require(block.number <= proposal.endBlock, "Voting period ended");
        require(!proposal.vetoed, "Proposal already vetoed");

        proposal.vetoed = true;

        emit ProposalVetoed(proposalId);
    }

    function _calculateVotingPower(address voter) internal view returns (uint256) {
        uint256 basePower = stakingContract.totalStakedByUser(voter);
        uint256 delegatedPower = stakingContract.getDelegatedPower(voter);
        uint256 timeMultiplier = stakingContract.getStakingMultiplier(voter);

        return (basePower + delegatedPower) * timeMultiplier / 10000;
    }

    function _isValidProposalData(bytes memory data) internal pure returns (bool) {
        bytes4 updateRewardRateSig = bytes4(keccak256("updateRewardRate(uint256)"));
        bytes4 updateLockPeriodSig = bytes4(keccak256("updateLockPeriod(uint256)"));
        bytes4 createVestingScheduleSig = bytes4(keccak256("createVestingSchedule(address,uint256,uint256,uint256,uint256,uint256,bool)"));

        bytes4 functionSig = bytes4(data);
        return (
            functionSig == updateRewardRateSig ||
            functionSig == updateLockPeriodSig ||
            functionSig == createVestingScheduleSig
        );
    }

    function updateVotingDuration(uint256 newDuration) external onlyRole(GOVERNANCE_ROLE) {
        require(newDuration > 0, "Invalid duration");
        votingDuration = newDuration;
        emit VotingDurationUpdated(newDuration);
    }

    function updateProposalThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        require(newThreshold > 0, "Invalid threshold");
        proposalThreshold = newThreshold;
        emit ProposalThresholdUpdated(newThreshold);
    }

    function updateMinimumHolding(uint256 newMinimumHolding) external onlyRole(GOVERNANCE_ROLE) {
        require(newMinimumHolding > 0, "Invalid minimum holding");
        minimumHolding = newMinimumHolding;
        emit MinimumHoldingUpdated(newMinimumHolding);
    }

    function getProposalStatus(uint256 proposalId) external view returns (string memory) {
        Proposal storage proposal = proposals[proposalId];
        if (proposal.vetoed) return "Vetoed";
        if (proposal.executed) return "Executed";
        if (block.number > proposal.endBlock) return "Voting Ended";
        return "Active";
    }
}