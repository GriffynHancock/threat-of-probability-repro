// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title CooldownStakePool
/// @notice Withdrawals enter a cooldown; matured requests are released into a claimable balance.
contract CooldownStakePool {
    uint256 private constant PRECISION = 1e18;
    uint256 public constant COOLDOWN = 3 days;

    struct Request {
        uint256 amount;
        uint256 availableAt;
    }

    IERC20 public immutable token;
    IERC20 public immutable feeToken;
    uint256 public totalStaked;
    uint256 public feeIndex;

    mapping(address => uint256) public staked;
    mapping(address => Request) public requests;
    mapping(address => uint256) public releasable;
    mapping(address => uint256) public feeDebt;
    mapping(address => uint256) public feesOwed;

    event Locked(address indexed who, uint256 amount);
    event WithdrawRequested(address indexed who, uint256 amount, uint256 availableAt);
    event Released(address indexed who, uint256 amount);
    event FeesDeposited(uint256 amount);
    event FeesClaimed(address indexed who, uint256 amount);

    constructor(IERC20 _token, IERC20 _fee) {
        token = _token;
        feeToken = _fee;
    }

    function depositFees(uint256 amount) external {
        require(totalStaked > 0, "no stake");
        require(feeToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        feeIndex += (amount * PRECISION) / totalStaked;
        emit FeesDeposited(amount);
    }

    /// @dev Moves a matured cooldown request into the releasable balance and settles fees.
    function _releaseMatured(address who) internal {
        Request storage r = requests[who];
        if (r.amount > 0 && block.timestamp >= r.availableAt) {
            releasable[who] += r.amount;
            r.amount = 0;
            r.availableAt = 0;
        }
        feesOwed[who] += (staked[who] * (feeIndex - feeDebt[who])) / PRECISION;
        feeDebt[who] = feeIndex;
    }

    /// @notice Lock stake into the pool.
    function lockStake(uint256 amount) external {
        require(amount > 0, "zero amount");
        _releaseMatured(msg.sender);
        staked[msg.sender] += amount;
        totalStaked += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Locked(msg.sender, amount);
    }

    /// @notice Start the cooldown for part of the stake. One request at a time.
    function requestWithdraw(uint256 amount) external {
        _releaseMatured(msg.sender);
        require(requests[msg.sender].amount == 0, "request pending");
        require(staked[msg.sender] >= amount && amount > 0, "bad amount");
        staked[msg.sender] -= amount;
        totalStaked -= amount;
        requests[msg.sender] = Request(amount, block.timestamp + COOLDOWN);
        emit WithdrawRequested(msg.sender, amount, block.timestamp + COOLDOWN);
    }

    /// @notice Withdraw whatever has finished its cooldown.
    function withdrawReleased() external {
        _releaseMatured(msg.sender);
        uint256 amount = releasable[msg.sender];
        require(amount > 0, "nothing released");
        releasable[msg.sender] -= amount;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit Released(msg.sender, amount);
    }

    /// @notice Claim fee revenue earned on staked tokens.
    function claimFees() external {
        _releaseMatured(msg.sender);
        uint256 amount = feesOwed[msg.sender];
        require(amount > 0, "nothing owed");
        feesOwed[msg.sender] = 0;
        require(feeToken.transfer(msg.sender, amount), "transfer failed");
        emit FeesClaimed(msg.sender, amount);
    }
}
