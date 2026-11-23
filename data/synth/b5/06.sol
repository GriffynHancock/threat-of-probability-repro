// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// ----------------------------------------------------------------------
// IERC20 (abridged, 2020 style)
// ----------------------------------------------------------------------
interface IERC20 {
    function balanceOf(address account) external view returns (uint);
    function transfer(address recipient, uint amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
}

// ======================================================================
// LockedVault - single pool. Deposits are locked for a chosen number of
// days; the lock can only be extended, never shortened.
// ======================================================================
contract LockedVault {
    struct UserInfo {
        uint amount;
        uint rewardDebt;
        uint unlockAt;
    }

    uint constant SCALE = 1e12;
    uint constant MAX_LOCK_DAYS = 365;

    IERC20 public stakeToken;
    IERC20 public rewardToken;
    address public admin;
    uint public rewardPerSecond;
    uint public lastRewardTime;
    uint public accRewardPerShare;
    uint public lockedTotal;

    mapping(address => UserInfo) public userInfo;

    event LockedDeposit(address indexed user, uint amount, uint unlockAt);
    event Harvest(address indexed user, uint amount);
    event Withdraw(address indexed user, uint amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "LockedVault: not admin");
        _;
    }

    constructor(IERC20 _stake, IERC20 _reward, uint _rewardPerSecond) {
        stakeToken = _stake;
        rewardToken = _reward;
        rewardPerSecond = _rewardPerSecond;
        lastRewardTime = block.timestamp;
        admin = msg.sender;
    }

    // Settlement helper: checkpoints the global reward index.
    function _checkpointLock() internal {
        if (block.timestamp <= lastRewardTime) {
            return;
        }
        if (lockedTotal == 0) {
            lastRewardTime = block.timestamp;
            return;
        }
        uint elapsed = block.timestamp - lastRewardTime;
        accRewardPerShare += elapsed * rewardPerSecond * SCALE / lockedTotal;
        lastRewardTime = block.timestamp;
    }

    function pending(address _user) public view returns (uint) {
        UserInfo storage u = userInfo[_user];
        return u.amount * accRewardPerShare / SCALE - u.rewardDebt;
    }

    function lockAndDeposit(uint _amount, uint _days) external {
        require(_days >= 1 && _days <= MAX_LOCK_DAYS, "LockedVault: bad lock");
        _checkpointLock();
        UserInfo storage user = userInfo[msg.sender];
        uint owed = 0;
        if (user.amount > 0) {
            owed = user.amount * accRewardPerShare / SCALE - user.rewardDebt;
        }
        user.amount += _amount;
        lockedTotal += _amount;
        uint newUnlock = block.timestamp + _days * 1 days;
        if (newUnlock > user.unlockAt) {
            user.unlockAt = newUnlock;
        }
        user.rewardDebt = user.amount * accRewardPerShare / SCALE;

        require(stakeToken.transferFrom(msg.sender, address(this), _amount), "LockedVault: stake in");
        if (owed > 0) {
            require(rewardToken.transfer(msg.sender, owed), "LockedVault: reward");
            emit Harvest(msg.sender, owed);
        }
        emit LockedDeposit(msg.sender, _amount, user.unlockAt);
    }

    function harvest() external {
        _checkpointLock();
        UserInfo storage user = userInfo[msg.sender];
        uint owed = user.amount * accRewardPerShare / SCALE - user.rewardDebt;
        user.rewardDebt = user.amount * accRewardPerShare / SCALE;
        if (owed > 0) {
            require(rewardToken.transfer(msg.sender, owed), "LockedVault: reward");
            emit Harvest(msg.sender, owed);
        }
    }

    function withdraw(uint _amount) external {
        UserInfo storage user = userInfo[msg.sender];
        require(block.timestamp >= user.unlockAt, "LockedVault: still locked");
        require(user.amount >= _amount, "LockedVault: insufficient");
        _checkpointLock();
        uint owed = user.amount * accRewardPerShare / SCALE - user.rewardDebt;
        user.amount -= _amount;
        lockedTotal -= _amount;
        user.rewardDebt = user.amount * accRewardPerShare / SCALE;
        if (owed > 0) {
            require(rewardToken.transfer(msg.sender, owed), "LockedVault: reward");
        }
        require(stakeToken.transfer(msg.sender, _amount), "LockedVault: stake out");
        emit Withdraw(msg.sender, _amount);
    }

    function emergencyWithdraw() external {
        UserInfo storage user = userInfo[msg.sender];
        uint amount = user.amount;
        require(amount > 0, "LockedVault: nothing");
        user.amount = 0;
        user.rewardDebt = 0;
        user.unlockAt = 0;
        lockedTotal -= amount;
        require(stakeToken.transfer(msg.sender, amount), "LockedVault: stake out");
    }

    function setRewardPerSecond(uint _rate) external onlyAdmin {
        _checkpointLock();
        rewardPerSecond = _rate;
    }
}
