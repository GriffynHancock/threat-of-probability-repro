// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ----------------------------------------------------------------------------
// Minimal ERC20 surface used by the farm
// ----------------------------------------------------------------------------
interface IERC20 {
    function balanceOf(address who) external view returns (uint);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}

// ----------------------------------------------------------------------------
// Ownable (2019 style, inline)
// ----------------------------------------------------------------------------
contract Ownable {
    address private _owner;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor() {
        _owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function owner() public view returns (address) {
        return _owner;
    }

    modifier onlyOwner() {
        require(_owner == msg.sender, "Ownable: caller is not the owner");
        _;
    }

    function renounceOwnership() public onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is zero address");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }
}

// ============================================================================
// ReferralGrove - pool farm paying a referral cut from every harvest
// ============================================================================
contract ReferralGrove is Ownable {
    struct UserInfo {
        uint amount;
        uint rewardDebt;
        address referrer;
    }

    struct PoolInfo {
        IERC20 lpToken;
        uint allocPoint;
        uint lastRewardBlock;
        uint accSeedPerShare;
    }

    uint public constant REFERRAL_BPS = 200;
    uint public constant ONE = 1e12;

    IERC20 public seed;
    uint public seedPerBlock;
    uint public totalAlloc;
    uint public bonusEndBlock;

    PoolInfo[] public pools;
    mapping(uint => mapping(address => UserInfo)) public users;
    mapping(address => uint) public referralEarned;

    event Deposited(address indexed user, uint indexed pid, uint amount, address referrer);
    event Harvested(address indexed user, uint indexed pid, uint amount);
    event ReferralPaid(address indexed referrer, address indexed user, uint amount);

    constructor(IERC20 _seed, uint _seedPerBlock, uint _bonusEndBlock) {
        seed = _seed;
        seedPerBlock = _seedPerBlock;
        bonusEndBlock = _bonusEndBlock;
    }

    function createPool(uint _alloc, IERC20 _lp) external onlyOwner {
        totalAlloc += _alloc;
        pools.push(PoolInfo(_lp, _alloc, block.number, 0));
    }

    function updateRewards(uint _pid) public {
        PoolInfo storage pool = pools[_pid];
        if (block.number <= pool.lastRewardBlock) return;
        uint supply = pool.lpToken.balanceOf(address(this));
        if (supply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint blocks = block.number - pool.lastRewardBlock;
        uint minted = blocks * seedPerBlock * pool.allocPoint / totalAlloc;
        pool.accSeedPerShare += minted * ONE / supply;
        pool.lastRewardBlock = block.number;
    }

    // Settlement helper: pays out what the user has earned so far and
    // routes REFERRAL_BPS of it to the stored referrer.
    function _harvest(uint _pid, address _who) internal returns (uint paid) {
        UserInfo storage user = users[_pid][_who];
        if (user.amount == 0) return 0;
        uint pending = user.amount * pools[_pid].accSeedPerShare / ONE - user.rewardDebt;
        if (pending == 0) return 0;
        paid = pending;
        if (user.referrer != address(0)) {
            uint cut = pending * REFERRAL_BPS / 10000;
            paid = pending - cut;
            referralEarned[user.referrer] += cut;
            require(seed.transfer(user.referrer, cut), "ReferralGrove: referral transfer");
            emit ReferralPaid(user.referrer, _who, cut);
        }
        require(seed.transfer(_who, paid), "ReferralGrove: harvest transfer");
        emit Harvested(_who, _pid, paid);
    }

    function depositWithReferrer(uint _pid, uint _amount, address _referrer) external {
        updateRewards(_pid);
        _harvest(_pid, msg.sender);
        UserInfo storage user = users[_pid][msg.sender];
        if (user.referrer == address(0) && _referrer != msg.sender) {
            user.referrer = _referrer;
        }
        user.amount += _amount;
        user.rewardDebt = user.amount * pools[_pid].accSeedPerShare / ONE;
        if (_amount > 0) {
            require(pools[_pid].lpToken.transferFrom(msg.sender, address(this), _amount), "ReferralGrove: lp in");
        }
        emit Deposited(msg.sender, _pid, _amount, user.referrer);
    }

    function withdraw(uint _pid, uint _amount) external {
        UserInfo storage user = users[_pid][msg.sender];
        require(user.amount >= _amount, "ReferralGrove: insufficient");
        updateRewards(_pid);
        _harvest(_pid, msg.sender);
        user.amount -= _amount;
        user.rewardDebt = user.amount * pools[_pid].accSeedPerShare / ONE;
        if (_amount > 0) {
            require(pools[_pid].lpToken.transfer(msg.sender, _amount), "ReferralGrove: lp out");
        }
    }

    function pendingSeed(uint _pid, address _who) external view returns (uint) {
        UserInfo storage user = users[_pid][_who];
        return user.amount * pools[_pid].accSeedPerShare / ONE - user.rewardDebt;
    }
}
