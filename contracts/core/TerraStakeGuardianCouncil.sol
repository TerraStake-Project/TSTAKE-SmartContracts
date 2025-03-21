// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../interfaces/ITerraStakeGuardianCouncil.sol";

/**
 * @title TerraStakeGuardianCouncil
 * @author TerraStake Protocol Team
 * @notice Secure, lean guardian council for emergency actions on Arbitrum
 */
contract TerraStakeGuardianCouncil is 
    Initializable, 
    AccessControlEnumerableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable
{
    using ECDSA for bytes32;
    
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    
    bytes4 public constant EMERGENCY_PAUSE = 0x72a24f77;
    bytes4 public constant EMERGENCY_UNPAUSE = 0x8b05f491;
    bytes4 public constant REMOVE_VALIDATOR = 0x3d18f5f9;
    bytes4 public constant REDUCE_THRESHOLD = 0x7e9e7d8e;
    bytes4 public constant GUARDIAN_OVERRIDE = 0x1c4d82e4;
    
    uint96 public quorumNeeded;
    uint96 public nonce;
    uint64 public signatureExpiry;
    uint64 public changeCooldown;
    uint64 public lastChangeTime;
    
    mapping(address => bool) public guardianCouncil;
    address[] public guardianList;
    mapping(bytes32 => bool) public usedOps;
    mapping(bytes4 => address[]) public actionTargets;
    
    event GuardianAdded(address indexed guardian);
    event GuardianRemoved(address indexed guardian);
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event SignatureExpiryUpdated(uint256 newExpiry);
    event ChangeCooldownUpdated(uint256 newCooldown);
    event TargetAdded(bytes4 actionType, address target);
    event TargetRemoved(bytes4 actionType, address target);
    event NonceBumped(uint256 newNonce);
    event OverrideDone(bytes4 action, address target, bytes data);
    event ActionTried(bytes4 actionType, bool worked);
    
    constructor() {
        _disableInitializers();
    }
    
    function initialize(address boss, address[] calldata firstGuardians) external initializer {
        __AccessControlEnumerable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        require(boss != address(0), "Boss can't be zero");
        _grantRole(DEFAULT_ADMIN_ROLE, boss);
        _grantRole(UPGRADER_ROLE, boss);
        _grantRole(GOVERNANCE_ROLE, boss);
        
        require(firstGuardians.length >= 3, "Need at least 3 guardians to start");
        for (uint256 i = 0; i < firstGuardians.length; i++) {
            address guardian = firstGuardians[i];
            require(guardian != address(0) && !guardianCouncil[guardian], "Bad guardian setup");
            guardianCouncil[guardian] = true;
            guardianList.push(guardian);
            _grantRole(GUARDIAN_ROLE, guardian);
        }
        
        quorumNeeded = uint96(firstGuardians.length * 2 / 3 + 1);
        nonce = 1;
        signatureExpiry = 1 days;
        changeCooldown = 7 days;
    }
    
    function _authorizeUpgrade(address newCode) internal override onlyRole(UPGRADER_ROLE) {}
    
    function addGuardian(address newGuardian) external onlyRole(GOVERNANCE_ROLE) {
        uint64 _now = uint64(block.timestamp);
        require(_now >= lastChangeTime + changeCooldown, "Cool it, still on cooldown");
        require(newGuardian != address(0) && !guardianCouncil[newGuardian], "Bad guardian pick");
        require(guardianList.length < 100, "Too many guardians");
        
        guardianCouncil[newGuardian] = true;
        guardianList.push(newGuardian);
        _grantRole(GUARDIAN_ROLE, newGuardian);
        lastChangeTime = _now;
        
        emit GuardianAdded(newGuardian);
    }
    
    function removeGuardian(address oldGuardian) external onlyRole(GOVERNANCE_ROLE) {
        uint64 _now = uint64(block.timestamp);
        require(_now >= lastChangeTime + changeCooldown, "Cool it, still on cooldown");
        require(guardianCouncil[oldGuardian] && guardianList.length > 3, "Can't remove this one");
        
        guardianCouncil[oldGuardian] = false;
        uint256 count = guardianList.length;
        for (uint256 i = 0; i < count; i++) {
            if (guardianList[i] == oldGuardian) {
                guardianList[i] = guardianList[count - 1];
                guardianList.pop();
                break;
            }
            if (i == count - 1) {
                _revokeRole(GUARDIAN_ROLE, oldGuardian);
                emit GuardianRemoved(oldGuardian);
                return;
            }
        }
        
        _revokeRole(GUARDIAN_ROLE, oldGuardian);
        lastChangeTime = _now;
        
        uint96 minQuorum = uint96(guardianList.length * 2 / 3 + 1);
        if (quorumNeeded > guardianList.length || quorumNeeded < minQuorum) {
            uint96 old = quorumNeeded;
            quorumNeeded = minQuorum;
            emit QuorumUpdated(old, minQuorum);
        }
        
        emit GuardianRemoved(oldGuardian);
    }
    
    function updateQuorum(uint96 newQuorum) external onlyRole(GOVERNANCE_ROLE) {
        uint64 _now = uint64(block.timestamp);
        require(_now >= lastChangeTime + changeCooldown, "Cool it, still on cooldown");
        
        uint256 count = guardianList.length;
        uint96 min = uint96(count * 6 / 10 + 1);
        uint96 max = uint96(count * 9 / 10 + 1);
        require(newQuorum > 0 && newQuorum >= min && newQuorum <= max && newQuorum <= count, "Quorum out of bounds");
        
        uint96 old = quorumNeeded;
        quorumNeeded = newQuorum;
        lastChangeTime = _now;
        
        emit QuorumUpdated(old, newQuorum);
    }
    
    function setSignatureExpiry(uint64 newExpiry) external onlyRole(GOVERNANCE_ROLE) {
        require(newExpiry >= 1 hours && newExpiry <= 7 days, "Expiry out of range");
        signatureExpiry = newExpiry;
        emit SignatureExpiryUpdated(newExpiry);
    }
    
    function setChangeCooldown(uint64 newCooldown) external onlyRole(GOVERNANCE_ROLE) {
        require(newCooldown >= 1 days && newCooldown <= 30 days, "Cooldown out of range");
        changeCooldown = newCooldown;
        emit ChangeCooldownUpdated(newCooldown);
    }
    
    function addTarget(bytes4 actionType, address target) external onlyRole(GOVERNANCE_ROLE) {
        require(target != address(0), "No zero targets");
        address[] storage targets = actionTargets[actionType];
        require(targets.length < 50, "Too many targets");
        uint256 count = targets.length;
        for (uint256 i = 0; i < count; i++) {
            require(targets[i] != target, "Target already here");
        }
        targets.push(target);
        emit TargetAdded(actionType, target);
    }
    
    function removeTarget(bytes4 actionType, address target) external onlyRole(GOVERNANCE_ROLE) {
        address[] storage targets = actionTargets[actionType];
        uint256 count = targets.length;
        for (uint256 i = 0; i < count; i++) {
            if (targets[i] == target) {
                targets[i] = targets[count - 1];
                targets.pop();
                emit TargetRemoved(actionType, target);
                return;
            }
        }
        revert("Target not found");
    }
    
    function bumpNonce() external onlyRole(GUARDIAN_ROLE) {
        nonce++;
        emit NonceBumped(nonce);
    }
    
    function checkSignatures(
        bytes4 action,
        address target,
        bytes memory data,
        bytes[] calldata signatures,
        uint256 timestamp
    ) public view returns (bool) {
        if (signatures.length < quorumNeeded) return false;
        uint64 _now = uint64(block.timestamp);
        if (_now > timestamp + signatureExpiry || timestamp > _now) return false;
        
        bytes32 hash = keccak256(abi.encode(action, target, keccak256(data), nonce, timestamp));
        bytes32 signedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
        
        uint256 validVotes;
        uint256 seen;
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = signedHash.recover(signatures[i]);
            if (guardianCouncil[signer]) {
                uint256 bit = 1 << (uint8(uint160(signer) & 0xFF));
                if (seen & bit == 0) {
                    seen |= bit;
                    validVotes++;
                }
            }
        }
        return validVotes >= quorumNeeded;
    }
    
    function overrideAction(
        bytes4 action,
        address target,
        bytes calldata data,
        bytes[] calldata signatures,
        uint256 timestamp
    ) external nonReentrant {
        bytes32 opHash = keccak256(abi.encode(action, target, keccak256(data), nonce));
        require(!usedOps[opHash], "Action already done");
        require(checkSignatures(action, target, data, signatures, timestamp), "Bad signatures");
        require(uint64(block.timestamp) <= timestamp + signatureExpiry, "Signatures too old");
        
        usedOps[opHash] = true;
        (bool ok, ) = target.call{ gas: gasleft() - 3000 }(data);
        require(ok, "Action failed");
        
        nonce++;
        emit OverrideDone(action, target, data);
        emit NonceBumped(nonce);
    }
    
    function pauseAll(bytes[] calldata signatures, uint256 timestamp) external nonReentrant {
        address[] storage targets = actionTargets[EMERGENCY_PAUSE];
        require(targets.length > 0, "No targets to pause");
        
        bytes memory callData = abi.encodeWithSelector(0x8456cb59);
        bytes32 dataHash = keccak256(callData);
        uint256 count = targets.length;
        for (uint256 i = 0; i < count; i++) {
            address target = targets[i];
            bytes32 opHash = keccak256(abi.encode(EMERGENCY_PAUSE, target, dataHash, nonce));
            if (usedOps[opHash]) continue;
            
            if (checkSignatures(EMERGENCY_PAUSE, target, callData, signatures, timestamp)) {
                usedOps[opHash] = true;
                (bool ok, ) = target.call{ gas: gasleft() - 3000 }(callData);
                emit ActionTried(EMERGENCY_PAUSE, ok);
            } else {
                emit ActionTried(EMERGENCY_PAUSE, false);
            }
        }
        nonce++;
        emit NonceBumped(nonce);
    }
    
    function unpauseAll(bytes[] calldata signatures, uint256 timestamp) external nonReentrant {
        address[] storage targets = actionTargets[EMERGENCY_UNPAUSE];
        require(targets.length > 0, "No targets to unpause");
        
        bytes memory callData = abi.encodeWithSelector(0x3f4ba83a);
        bytes32 dataHash = keccak256(callData);
        uint256 count = targets.length;
        for (uint256 i = 0; i < count; i++) {
            address target = targets[i];
            bytes32 opHash = keccak256(abi.encode(EMERGENCY_UNPAUSE, target, dataHash, nonce));
            if (usedOps[opHash]) continue;
            
            if (checkSignatures(EMERGENCY_UNPAUSE, target, callData, signatures, timestamp)) {
                usedOps[opHash] = true;
                (bool ok, ) = target.call{ gas: gasleft() - 3000 }(callData);
                emit ActionTried(EMERGENCY_UNPAUSE, ok);
            } else {
                emit ActionTried(EMERGENCY_UNPAUSE, false);
            }
        }
        nonce++;
        emit NonceBumped(nonce);
    }
    
    function kickValidator(address validator, bytes[] calldata signatures, uint256 timestamp) external nonReentrant {
        address[] storage targets = actionTargets[REMOVE_VALIDATOR];
        require(targets.length > 0, "No targets for validator kick");
        
        bytes memory callData = abi.encodeWithSignature("removeValidator(address)", validator);
        bytes32 dataHash = keccak256(callData);
        uint256 count = targets.length;
        for (uint256 i = 0; i < count; i++) {
            address target = targets[i];
            bytes32 opHash = keccak256(abi.encode(REMOVE_VALIDATOR, target, dataHash, nonce));
            if (usedOps[opHash]) continue;
            
            if (checkSignatures(REMOVE_VALIDATOR, target, callData, signatures, timestamp)) {
                usedOps[opHash] = true;
                (bool ok, ) = target.call{ gas: gasleft() - 3000 }(callData);
                emit ActionTried(REMOVE_VALIDATOR, ok);
            } else {
                emit ActionTried(REMOVE_VALIDATOR, false);
            }
        }
        nonce++;
        emit NonceBumped(nonce);
    }
    
    function getAllGuardians() external view returns (address[] memory) {
        return guardianList;
    }
    
    function getGuardianCount() external view returns (uint256) {
        return guardianList.length;
    }
    
    function isOnCooldown() external view returns (bool) {
        return uint64(block.timestamp) < lastChangeTime + changeCooldown;
    }
    
    function getTargets(bytes4 actionType) external view returns (address[] memory) {
        return actionTargets[actionType];
    }
    
    function isActionDone(bytes4 action, address target, bytes calldata data) external view returns (bool) {
        return usedOps[keccak256(abi.encode(action, target, keccak256(data), nonce))];
    }
}