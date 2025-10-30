// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import "./Params.sol";
import "./Validators.sol";

contract Punish is Params {
    uint256 public punishThreshold;
    uint256 public removeThreshold;
    uint256 public decreaseRate;

    
    // Slashing percentages (basis points, where 10000 = 100%)
    uint256 public constant SLASH_PERCENTAGE_DOUBLE_SIGN = 5000; // 50%
    uint256 public constant SLASH_PERCENTAGE_INVALID_BLOCK = 2500; // 25%
    uint256 public constant SLASH_PERCENTAGE_COORDINATED = 10000; // 100%
    uint256 public constant SLASH_PERCENTAGE_LIVENESS = 100; // 1%

    // Minimum and maximum slash amounts
    uint256 public constant MIN_SLASH_AMOUNT = 1000;
    uint256 public constant MAX_SLASH_AMOUNT = 100000 ether;


    struct PunishRecord {
        uint256 missedBlocksCounter;
        uint256 index;
        bool exist;
    }

    Validators validators;

    mapping(address => PunishRecord) punishRecords;
    address[] public punishValidators;

    mapping(uint256 => bool) punished;
    mapping(uint256 => bool) decreased;
    
    // Slashing history
    mapping(address => uint256) public totalSlashed;
    mapping(address => mapping(uint8 => uint256)) public slashingHistory;

    event LogDecreaseMissedBlocksCounter();
    event LogPunishValidator(address indexed val, uint256 time);

    event PunishRecordCleaned(address indexed validator);
    event PunishValidatorRemoved(address indexed validator, uint256 index);

    // Slashing events
    event LogSlashValidator(
        address indexed validator, 
        uint256 slashedAmount, 
        uint8 misbehaviorType, 
        uint256 timestamp
    );

    modifier onlyNotPunished() {
        require(!punished[block.number], "Already punished");
        _;
    }

    modifier onlyNotDecreased() {
        require(!decreased[block.number], "Already decreased");
        _;
    }

    function initialize() external onlyNotInitialized {
        validators = Validators(ValidatorContractAddr);
        punishThreshold = 48;
        removeThreshold = 96;
        decreaseRate = 48; 

        initialized = true;
    }

    function punish(address val)
        external
        onlyMiner
        onlyInitialized
        onlyNotPunished
    {
        punished[block.number] = true;
        if (!punishRecords[val].exist) {
            punishRecords[val].index = punishValidators.length;
            punishValidators.push(val);
            punishRecords[val].exist = true;
        }
        punishRecords[val].missedBlocksCounter++;

        if (punishRecords[val].missedBlocksCounter % removeThreshold == 0) {
            validators.removeValidator(val);
            // reset validator's missed blocks counter
            punishRecords[val].missedBlocksCounter = 0;
        } else if (
            punishRecords[val].missedBlocksCounter % punishThreshold == 0
        ) {
            validators.removeValidatorIncoming(val);
        }

        emit LogPunishValidator(val, block.timestamp);
    }

    function decreaseMissedBlocksCounter(uint256 epoch)
        external
        onlyMiner
        onlyNotDecreased
        onlyInitialized
        onlyBlockEpoch(epoch)
    {
        decreased[block.number] = true;
        if (punishValidators.length == 0) {
            return;
        }

        for (uint256 i = 0; i < punishValidators.length; i++) {
            if (
                punishRecords[punishValidators[i]].missedBlocksCounter >
                removeThreshold / decreaseRate
            ) {
                punishRecords[punishValidators[i]].missedBlocksCounter =
                    punishRecords[punishValidators[i]].missedBlocksCounter -
                    removeThreshold /
                    decreaseRate;
            } else {
                punishRecords[punishValidators[i]].missedBlocksCounter = 0;
            }
        }

        emit LogDecreaseMissedBlocksCounter();
    }

    // clean validator's punish record if one restake in
    function cleanPunishRecord(address val)
        public
        onlyInitialized
        onlyValidatorsContract
        returns (bool)
    {
        if (punishRecords[val].missedBlocksCounter != 0) {
            punishRecords[val].missedBlocksCounter = 0;
            emit PunishRecordCleaned(val);
        }

        // remove it out of array if exist
        if (punishRecords[val].exist && punishValidators.length > 0) {

            uint256 index = punishRecords[val].index;
            
            if (punishRecords[val].index != punishValidators.length - 1) {
                address uval = punishValidators[punishValidators.length - 1];
                punishValidators[punishRecords[val].index] = uval;

                punishRecords[uval].index = punishRecords[val].index;
            }
            punishValidators.pop();
            punishRecords[val].index = 0;
            punishRecords[val].exist = false;

            emit PunishValidatorRemoved(val, index);
        }

        return true;
    }

    function getPunishValidatorsLen() public view returns (uint256) {
        return punishValidators.length;
    }

    function getPunishRecord(address val) public view returns (uint256) {
        return punishRecords[val].missedBlocksCounter;
    }

    // Slashing functions
    
    //   types enum (matching Go code)
    // 0 = OutOfTurn, 1 = DoubleSign, 2 = InvalidBlock, 3 = Coordinated, 4 = Liveness, 5 = StakeInsufficient

    /**
     * @notice Slash a validator's stake for misbehavior
     * @param validator The validator to slash
     * @param amount The amount to slash
     * @param misbehavior The type of misbehavior (0-5)
     * @param evidence Proof of the misbehavior
     */
    function slashValidator(
        address validator,
        uint256 amount,
        uint8 misbehavior,
        bytes calldata evidence
    ) external onlyMiner onlyInitialized {
        require(validator != address(0), "Invalid validator");
        require(amount > 0, "Invalid slash amount");
        require(misbehavior <= 5, "Invalid misbehavior type");

        // Check if validator exists and has stake
        uint256 validatorStake = validators.getStakeOfValidator(validator);
        require(validatorStake >= MIN_SLASH_AMOUNT, "Validator stake below minimum slash amount");

        // Calculate actual slash amount based on percentage
        uint256 calculatedAmount = calculateSlashAmount(validatorStake, misbehavior, amount);
        
        // Apply min/max constraints
        if (calculatedAmount < MIN_SLASH_AMOUNT && validatorStake >= MIN_SLASH_AMOUNT) {
            calculatedAmount = MIN_SLASH_AMOUNT;
        } else if (calculatedAmount > MAX_SLASH_AMOUNT) {
            calculatedAmount = MAX_SLASH_AMOUNT;
        }

        // Ensure we don't slash more than available stake
        if (calculatedAmount > validatorStake) {
            calculatedAmount = validatorStake;
        }

        // Actually reduce the validator's stake in Validators contract
        bool success = validators.slashStake(validator, calculatedAmount);
        require(success, "Failed to slash stake");

        // Record the slashing
        totalSlashed[validator] += calculatedAmount;
        slashingHistory[validator][misbehavior] += 1;

        // For severe misbehavior, remove validator
        if (misbehavior == 1 || misbehavior == 3) { // Double sign or coordinated attack
            validators.removeValidator(validator);
        }

        emit LogSlashValidator(validator, calculatedAmount, misbehavior, block.timestamp);
        
        // Log evidence for future reference
        if (evidence.length > 0) {
            // Could store in IPFS or emit event with hash
            emit LogPunishValidator(validator, block.timestamp);
        }
    }

    /**
     * @notice Calculate slash amount based on stake and misbehavior type
     */
    function calculateSlashAmount(
        uint256 stake,
        uint8 misbehavior,
        uint256 requestedAmount
    ) internal pure returns (uint256) {
        // Use the maximum of requested amount or percentage-based calculation for proper penalty
        if (misbehavior == 1) { // Double sign
            uint256 percentageAmount = (stake * SLASH_PERCENTAGE_DOUBLE_SIGN) / 10000;
            return percentageAmount > requestedAmount ? percentageAmount : requestedAmount;
        } else if (misbehavior == 2) { // Invalid block
            uint256 percentageAmount = (stake * SLASH_PERCENTAGE_INVALID_BLOCK) / 10000;
            return percentageAmount > requestedAmount ? percentageAmount : requestedAmount;
        } else if (misbehavior == 3) { // Coordinated attack
            return stake; // Slash everything for severe attacks
        } else if (misbehavior == 4) { // Liveness
            uint256 percentageAmount = (stake * SLASH_PERCENTAGE_LIVENESS) / 10000;
            return percentageAmount > requestedAmount ? percentageAmount : requestedAmount;
        }
        
        // Default to requested amount
        return requestedAmount;
    }

    /**
     * @notice Get validator's total slashed amount
     */
    function getTotalSlashed(address validator) external view returns (uint256) {
        return totalSlashed[validator];
    }

    /**
     * @notice Get slashing history for a validator
     */
    function getSlashingHistory(address validator, uint8 misbehavior) external view returns (uint256) {
        return slashingHistory[validator][misbehavior];
    }
}
