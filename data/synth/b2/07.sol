// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Dual-sided incentive pool: depositors of a single LP token earn two
/// reward tokens, each tracked with its own reward-per-share accumulator.
contract DualSidedIncentive {
    uint256 private constant ONE = 1e18;
    uint256 private constant N = 2;

    IERC20 public immutable lpToken;
    IERC20[N] public rewardTokens;
    address public immutable sponsor;

    uint256 public totalDeposited;
    uint256[N] public rewardPerShare;

    mapping(address => uint256) public deposited;
    mapping(address => uint256[N]) public rewardPaid;
    mapping(address => uint256[N]) public accrued;

    event Deposited(address indexed user, uint256 amount);
    event Released(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 index, uint256 amount);
    event Notified(uint256 index, uint256 amount);

    constructor(IERC20 _lp, IERC20 _rewardA, IERC20 _rewardB) {
        lpToken = _lp;
        rewardTokens[0] = _rewardA;
        rewardTokens[1] = _rewardB;
        sponsor = msg.sender;
    }

    /// @notice Sponsor tops up one reward stream. Applied to current depositors pro-rata.
    function notifyReward(uint256 index, uint256 amount) external {
        require(msg.sender == sponsor, "not sponsor");
        require(index < N, "bad index");
        require(totalDeposited > 0, "no depositors");
        require(rewardTokens[index].transferFrom(msg.sender, address(this), amount), "transfer failed");
        rewardPerShare[index] += amount * ONE / totalDeposited;
        emit Notified(index, amount);
    }

    function provideDual(uint256 amount) external {
        require(amount > 0, "zero amount");
        _realizeRewards(msg.sender);
        deposited[msg.sender] += amount;
        totalDeposited += amount;
        require(lpToken.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Deposited(msg.sender, amount);
    }

    function releaseDual(uint256 amount) external {
        require(amount <= deposited[msg.sender], "insufficient deposit");
        _realizeRewards(msg.sender);
        deposited[msg.sender] -= amount;
        totalDeposited -= amount;
        require(lpToken.transfer(msg.sender, amount), "transfer failed");
        emit Released(msg.sender, amount);
    }

    function claimDual(uint256 index) external {
        require(index < N, "bad index");
        _realizeRewards(msg.sender);
        uint256 owed = accrued[msg.sender][index];
        if (owed == 0) return;
        accrued[msg.sender][index] = 0;
        require(rewardTokens[index].transfer(msg.sender, owed), "transfer failed");
        emit Claimed(msg.sender, index, owed);
    }

    /// @dev Credits both streams to `who` against the balance held before the
    /// caller's change, then moves its checkpoints to the current accumulators.
    function _realizeRewards(address who) internal {
        uint256 bal = deposited[who];
        for (uint256 i = 0; i < N; ++i) {
            uint256 delta = rewardPerShare[i] - rewardPaid[who][i];
            accrued[who][i] += bal * delta / ONE;
            rewardPaid[who][i] = rewardPerShare[i];
        }
    }
}
