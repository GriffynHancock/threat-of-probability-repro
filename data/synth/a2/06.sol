// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.25;

interface IRewardToken {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

contract BudgetedVault {
    uint256 private constant UNIT = 1e18;

    IRewardToken public immutable stakeToken;
    IRewardToken public immutable payToken;
    address public admin;
    bool public halted;

    // Budget stream: `budgetLeft` is paid out linearly at `streamRate` until `streamEnd`.
    uint256 public budgetLeft;
    uint256 public streamRate;
    uint256 public streamEnd;
    uint256 public rptStored;
    uint256 public rptTouched;

    uint256 public supply;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public rptPaidTo;
    mapping(address => uint256) public unclaimed;

    event Provided(address indexed user, uint256 amount);
    event Retired(address indexed user, uint256 amount);
    event Harvested(address indexed user, uint256 amount);
    event Funded(uint256 amount, uint256 rate, uint256 end);
    event HaltChanged(bool halted);

    modifier onlyAdmin() {
        require(msg.sender == admin, "BudgetedVault: admin");
        _;
    }

    modifier whenLive() {
        require(!halted, "BudgetedVault: halted");
        _;
    }

    modifier settle(address user) {
        _checkpoint(user);
        _;
    }

    constructor(IRewardToken _stake, IRewardToken _pay) {
        stakeToken = _stake;
        payToken = _pay;
        admin = msg.sender;
        rptTouched = block.timestamp;
    }

    function streamable() public view returns (uint256) {
        uint256 horizon = block.timestamp < streamEnd ? block.timestamp : streamEnd;
        if (horizon <= rptTouched) {
            return 0;
        }
        uint256 wanted = (horizon - rptTouched) * streamRate;
        return wanted < budgetLeft ? wanted : budgetLeft;
    }

    function rewardPerTokenNow() public view returns (uint256) {
        if (supply == 0) {
            return rptStored;
        }
        return rptStored + (streamable() * UNIT) / supply;
    }

    function owed(address user) public view returns (uint256) {
        return unclaimed[user] + (staked[user] * (rewardPerTokenNow() - rptPaidTo[user])) / UNIT;
    }

    function provide(uint256 amount) external whenLive settle(msg.sender) {
        require(amount != 0, "BudgetedVault: zero");
        staked[msg.sender] += amount;
        supply += amount;
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "BudgetedVault: in");
        emit Provided(msg.sender, amount);
    }

    function retire(uint256 amount) external settle(msg.sender) {
        require(amount != 0 && amount <= staked[msg.sender], "BudgetedVault: amount");
        staked[msg.sender] -= amount;
        supply -= amount;
        require(stakeToken.transfer(msg.sender, amount), "BudgetedVault: out");
        emit Retired(msg.sender, amount);
    }

    function harvest() external settle(msg.sender) {
        uint256 amount = unclaimed[msg.sender];
        require(amount != 0, "BudgetedVault: none");
        unclaimed[msg.sender] = 0;
        require(payToken.transfer(msg.sender, amount), "BudgetedVault: pay");
        emit Harvested(msg.sender, amount);
    }

    /// Adds budget and restarts the stream over a fresh window.
    function fund(uint256 amount, uint256 duration) external onlyAdmin settle(address(0)) {
        require(duration > 0, "BudgetedVault: duration");
        require(amount > 0, "BudgetedVault: amount");
        budgetLeft += amount;
        streamRate = budgetLeft / duration;
        require(streamRate > 0, "BudgetedVault: rate");
        streamEnd = block.timestamp + duration;
        require(payToken.transferFrom(msg.sender, address(this), amount), "BudgetedVault: fund");
        emit Funded(amount, streamRate, streamEnd);
    }

    function setHalted(bool value) external onlyAdmin {
        halted = value;
        emit HaltChanged(value);
    }

    /// Moves the global accumulator to now, consuming budget only while
    /// there are stakers, then credits the user (if any).
    function _checkpoint(address user) internal {
        uint256 paid = streamable();
        if (supply != 0 && paid != 0) {
            budgetLeft -= paid;
            rptStored += (paid * UNIT) / supply;
        }
        rptTouched = block.timestamp;

        if (user != address(0)) {
            unclaimed[user] = owed(user);
            rptPaidTo[user] = rptStored;
        }
    }
}
