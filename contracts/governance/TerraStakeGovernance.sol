// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


interface ITerraStakeStaking {
    function totalStaked() external view returns (uint256);
    function totalStakedByUser(address user) external view returns (uint256);
    function updateRewardRate(uint256 newRate) external;
    function updateLockPeriod(uint256 newLockPeriod) external;
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

    // Roles for access control
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
    event ProposalCreated(uint256 indexed proposalId, bytes data, uint256 endBlock, address target);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalVetoed(uint256 indexed proposalId);

    // Initialize function
    function initialize(
        address admin,
        address _stakingContract,
        address _itoContract,
        address _priceFeed,
        uint256 _votingDuration,
        uint256 _proposalThreshold,
        uint256 _minimumHolding
    ) external initializer {
        if (admin == address(0) || _stakingContract == address(0) || _itoContract == address(0) || _priceFeed == address(0)) revert UnauthorizedAccess();
        if (_votingDuration == 0 || _proposalThreshold == 0 || _minimumHolding == 0) revert InvalidProposalData();

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

    function createProposal(bytes calldata data, address target) external onlyRole(GOVERNANCE_ROLE) {
        if (stakingContract.totalStaked() < proposalThreshold) revert VotingPowerNotSufficient();
        uint256 proposalId = proposalCount++;
        uint256 endBlock = block.number + votingDuration;

        proposals[proposalId] = Proposal({
            data: data,
            target: target,
            votesFor: 0,
            votesAgainst: 0,
            endBlock: endBlock,
            executed: false,
            vetoed: false
        });

        emit ProposalCreated(proposalId, data, endBlock, target);
    }

    function vote(uint256 proposalId, bool support) public {
        Proposal storage proposal = proposals[proposalId];
        if (block.number > proposal.endBlock) revert VotingPeriodEnded();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();
        if (proposal.vetoed) revert ProposalAlreadyVetoed();

        uint256 votingPower = stakingContract.totalStakedByUser(msg.sender);
        if (votingPower == 0) revert VotingPowerNotSufficient();
        if (votingPower < minimumHolding) revert InsufficientHolding();

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
        if (block.number <= proposal.endBlock) revert VotingPeriodNotEnded();
        if (proposal.executed) revert ProposalAlreadyExecuted();
        if (proposal.vetoed) revert ProposalAlreadyVetoed();

        if (proposal.votesFor > proposal.votesAgainst) {
            if (!_isValidProposalData(proposal.data)) revert InvalidProposalData();
            (bool success, ) = proposal.target.call(proposal.data);
            if (!success) revert InvalidProposalData();
        }

        proposal.executed = true;

        emit ProposalExecuted(proposalId);
    }

    function vetoProposal(uint256 proposalId) external onlyRole(VETO_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        if (block.number > proposal.endBlock) revert VotingPeriodEnded();
        if (proposal.vetoed) revert ProposalAlreadyVetoed();

        proposal.vetoed = true;

        emit ProposalVetoed(proposalId);
    }

    function validateOraclePrice(uint256 expectedPrice) public view {
        (, int256 answer, , , ) = priceFeed.latestRoundData();
        if (answer <= 0 || uint256(answer) != expectedPrice) revert OracleValidationFailed();
    }

    function _isValidProposalData(bytes memory data) internal pure returns (bool) {
        bytes4 updateRewardSignature = bytes4(keccak256("updateRewardRate(uint256)"));
        bytes4 updateLockPeriodSignature = bytes4(keccak256("updateLockPeriod(uint256)"));
        bytes4 createVestingScheduleSignature = bytes4(keccak256("createVestingSchedule(address,uint256,uint256,uint256,uint256,uint256,bool)"));

        bytes4 functionSignature = bytes4(data);
        return (
            functionSignature == updateRewardSignature ||
            functionSignature == updateLockPeriodSignature ||
            functionSignature == createVestingScheduleSignature
        );
    }

    function updateStakingContract(address _stakingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_stakingContract != address(0), "Invalid address");
        stakingContract = ITerraStakeStaking(_stakingContract);
    }

    function updateITOContract(address _itoContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_itoContract != address(0), "Invalid address");
        itoContract = ITerraStakeITO(_itoContract);
    }

    function getProposalStatus(uint256 proposalId) public view returns (string memory) {
        Proposal storage proposal = proposals[proposalId];

        if (proposal.vetoed) return "Vetoed";
        if (proposal.executed) return "Executed";
        if (block.number > proposal.endBlock) return "Voting Ended";
        return "Active";
    }

    function updateProposalThreshold(uint256 newThreshold) external onlyRole(GOVERNANCE_ROLE) {
        if (newThreshold == 0) revert InvalidProposalData();
        proposalThreshold = newThreshold;
    }

    function updateVotingDuration(uint256 newDuration) external onlyRole(GOVERNANCE_ROLE) {
        if (newDuration == 0) revert InvalidProposalData();
        votingDuration = newDuration;
    }

    function updateMinimumHolding(uint256 newMinimumHolding) external onlyRole(GOVERNANCE_ROLE) {
        if (newMinimumHolding == 0) revert InvalidProposalData();
        minimumHolding = newMinimumHolding;
    }
}

