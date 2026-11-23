// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.17;

interface IERC20Minimal {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

// Receipt token that accrues a fixed rate on balance-seconds.
contract BalanceSecondsReceipt {
    string public constant name = "Staked Receipt";
    string public constant symbol = "sRCPT";
    uint8 public constant decimals = 18;

    // Reward per token per second, scaled by ACC.
    uint256 public constant ACC = 1e18;
    uint256 public constant RATE_PER_TOKEN_SECOND = 6e9;

    IERC20Minimal public immutable stakeToken;
    IERC20Minimal public immutable rewardToken;
    address public immutable admin;

    uint256 public totalSupply;
    uint256 public rewardReserve;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public balanceSeconds;
    mapping(address => uint256) public rewardAccrued;
    mapping(address => uint256) private _lastTouched;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Entered(address indexed account, uint256 amount);
    event Exited(address indexed account, uint256 amount);
    event Harvested(address indexed account, uint256 amount);

    constructor(IERC20Minimal _stakeToken, IERC20Minimal _rewardToken) {
        stakeToken = _stakeToken;
        rewardToken = _rewardToken;
        admin = msg.sender;
    }

    function enter(uint256 amount) external {
        require(amount > 0, "amount=0");
        // Settle time-weighted balance up to now, then change the balance.
        _touch(msg.sender);
        balanceOf[msg.sender] += amount;
        totalSupply += amount;
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "pull failed");
        emit Entered(msg.sender, amount);
        emit Transfer(address(0), msg.sender, amount);
    }

    function exit(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        _touch(msg.sender);
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        require(stakeToken.transfer(msg.sender, amount), "push failed");
        emit Exited(msg.sender, amount);
        emit Transfer(msg.sender, address(0), amount);
    }

    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "insufficient");
        _touch(msg.sender);
        _touch(to);
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function harvest() external returns (uint256 amount) {
        _touch(msg.sender);
        amount = rewardAccrued[msg.sender];
        if (amount == 0) return 0;
        require(amount <= rewardReserve, "reserve low");

        rewardAccrued[msg.sender] = 0;
        rewardReserve -= amount;
        require(rewardToken.transfer(msg.sender, amount), "reward push failed");
        emit Harvested(msg.sender, amount);
    }

    function fundRewards(uint256 amount) external {
        require(msg.sender == admin, "not admin");
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "fund failed");
        rewardReserve += amount;
    }

    function averageBalance(address account) external view returns (uint256) {
        uint256 elapsed = block.timestamp - _lastTouched[account];
        if (elapsed == 0) return 0;
        return balanceSeconds[account] / elapsed;
    }

    function _touch(address account) internal {
        uint256 last = _lastTouched[account];
        _lastTouched[account] = block.timestamp;
        if (last == 0) return;

        uint256 bal = balanceOf[account];
        uint256 dt = block.timestamp - last;
        if (bal == 0 || dt == 0) return;

        uint256 bs = bal * dt;
        balanceSeconds[account] += bs;
        rewardAccrued[account] += bs * RATE_PER_TOKEN_SECOND / ACC;
    }
}
