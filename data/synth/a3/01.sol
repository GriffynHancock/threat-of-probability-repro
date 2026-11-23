// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title TimestampEpochStaking
/// @notice Fixed-length epochs derived from block.timestamp. Epochs are closed lazily
///         on the next user interaction. Each closed epoch emits a fixed reward that is
///         split across the stake that was live when the epoch closed.
contract TimestampEpochStaking {
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken;
    address public immutable owner;
    uint256 public immutable epochLength;
    uint256 public immutable rewardPerEpoch;
    uint256 public immutable genesisTime;

    struct Epoch {
        uint256 totalStakedAtClose;
        uint256 rewardEmitted;
        uint256 accRewardPerShare;
    }

    Epoch[] public epochs;
    uint256 public accRewardPerShare;
    uint256 public totalStaked;

    mapping(address => uint256) public stakes;
    mapping(address => uint256) public userAcc;
    mapping(address => uint256) public pending;

    event Deposited(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event EpochClosed(uint256 indexed index, uint256 rewardEmitted);
    event Funded(uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(IERC20 _stake, IERC20 _reward, uint256 _epochLength, uint256 _rewardPerEpoch) {
        require(_epochLength > 0, "epoch length");
        stakeToken = _stake;
        rewardToken = _reward;
        owner = msg.sender;
        epochLength = _epochLength;
        rewardPerEpoch = _rewardPerEpoch;
        genesisTime = block.timestamp;
        epochs.push(Epoch(0, 0, 0));
    }

    function deposit(uint256 amount) external {
        require(amount > 0, "zero amount");
        _rollEpoch();
        _settle(msg.sender);
        require(stakeToken.transferFrom(msg.sender, address(this), amount), "transferFrom");
        stakes[msg.sender] += amount;
        totalStaked += amount;
        emit Deposited(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        require(amount > 0 && stakes[msg.sender] >= amount, "bad amount");
        _rollEpoch();
        _settle(msg.sender);
        stakes[msg.sender] -= amount;
        totalStaked -= amount;
        require(stakeToken.transfer(msg.sender, amount), "transfer");
        emit Withdrawn(msg.sender, amount);
    }

    function claim() external {
        _rollEpoch();
        _settle(msg.sender);
        uint256 amount = pending[msg.sender];
        require(amount > 0, "nothing to claim");
        pending[msg.sender] = 0;
        require(rewardToken.transfer(msg.sender, amount), "transfer");
        emit Claimed(msg.sender, amount);
    }

    function fund(uint256 amount) external onlyOwner {
        require(rewardToken.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Funded(amount);
    }

    function currentEpochIndex() public view returns (uint256) {
        return (block.timestamp - genesisTime) / epochLength;
    }

    /// @dev Closes every epoch that has elapsed since the last interaction.
    ///      Epochs closed while nothing was staked emit no reward.
    function _rollEpoch() internal {
        uint256 target = currentEpochIndex();
        while (epochs.length - 1 < target) {
            uint256 idx = epochs.length - 1;
            uint256 emitted;
            if (totalStaked > 0) {
                emitted = rewardPerEpoch;
                accRewardPerShare += rewardPerEpoch * PRECISION / totalStaked;
            }
            epochs[idx].totalStakedAtClose = totalStaked;
            epochs[idx].rewardEmitted = emitted;
            epochs[idx].accRewardPerShare = accRewardPerShare;
            emit EpochClosed(idx, emitted);
            epochs.push(Epoch(0, 0, accRewardPerShare));
        }
    }

    /// @dev Credits the user's share of everything accrued since their last settlement.
    function _settle(address user) internal {
        uint256 delta = accRewardPerShare - userAcc[user];
        if (delta > 0) {
            pending[user] += stakes[user] * delta / PRECISION;
        }
        userAcc[user] = accRewardPerShare;
    }
}
