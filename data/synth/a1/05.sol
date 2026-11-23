// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IErc20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

contract BondingRewards {
    uint256 private constant ONE = 1e12;

    IErc20 public immutable bondToken;
    IErc20 public immutable rewardToken;
    address public governor;

    uint256 public emissionPerBlock;
    uint256 public syncedBlock;
    uint256 public rewardIndex;
    uint256 public bondedSupply;

    mapping(address => uint256) public bonded;
    mapping(address => uint256) public rewardDebt;

    event Bonded(address indexed holder, uint256 amount);
    event Unbonded(address indexed holder, uint256 amount);
    event Collected(address indexed holder, uint256 amount);
    event EmissionChanged(uint256 previous, uint256 current);

    constructor(IErc20 bond_, IErc20 reward_, uint256 emission_) {
        bondToken = bond_;
        rewardToken = reward_;
        governor = msg.sender;
        emissionPerBlock = emission_;
        syncedBlock = block.number;
    }

    /// @notice Explicit pool update. Idempotent within a block.
    function syncRewards() public {
        uint256 current = block.number;
        if (current == syncedBlock) {
            return;
        }
        if (bondedSupply != 0) {
            rewardIndex += ((current - syncedBlock) * emissionPerBlock * ONE) / bondedSupply;
        }
        syncedBlock = current;
    }

    function _owedTo(address holder) internal view returns (uint256) {
        return (bonded[holder] * rewardIndex) / ONE - rewardDebt[holder];
    }

    function pendingFor(address holder) external view returns (uint256) {
        uint256 index = rewardIndex;
        if (block.number > syncedBlock && bondedSupply != 0) {
            index += ((block.number - syncedBlock) * emissionPerBlock * ONE) / bondedSupply;
        }
        return (bonded[holder] * index) / ONE - rewardDebt[holder];
    }

    function bond(uint256 amount) external {
        require(amount != 0, "amount");
        syncRewards();
        uint256 owedNow = _owedTo(msg.sender);

        bonded[msg.sender] += amount;
        bondedSupply += amount;
        rewardDebt[msg.sender] = (bonded[msg.sender] * rewardIndex) / ONE;

        require(bondToken.transferFrom(msg.sender, address(this), amount), "bond pull");
        if (owedNow > 0) {
            require(rewardToken.transfer(msg.sender, owedNow), "reward push");
        }
        emit Bonded(msg.sender, amount);
    }

    function unbond(uint256 amount) external {
        require(amount != 0 && bonded[msg.sender] >= amount, "bad amount");
        syncRewards();
        uint256 owedNow = _owedTo(msg.sender);

        bonded[msg.sender] -= amount;
        bondedSupply -= amount;
        rewardDebt[msg.sender] = (bonded[msg.sender] * rewardIndex) / ONE;

        require(bondToken.transfer(msg.sender, amount), "bond return");
        if (owedNow > 0) {
            require(rewardToken.transfer(msg.sender, owedNow), "reward push");
        }
        emit Unbonded(msg.sender, amount);
    }

    function collect() external {
        syncRewards();
        uint256 owedNow = _owedTo(msg.sender);
        require(owedNow > 0, "nothing to collect");

        rewardDebt[msg.sender] = (bonded[msg.sender] * rewardIndex) / ONE;
        require(rewardToken.transfer(msg.sender, owedNow), "reward push");
        emit Collected(msg.sender, owedNow);
    }

    function setEmission(uint256 newEmission) external {
        require(msg.sender == governor, "not governor");
        syncRewards();
        emit EmissionChanged(emissionPerBlock, newEmission);
        emissionPerBlock = newEmission;
    }
}
