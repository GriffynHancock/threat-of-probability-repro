// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18 <0.9.0;

/*
 * StreamingStake
 *
 * Continuous-time emission. Rewards accrue per second and are shared
 * pro rata by stake size at each moment. Each holder stores an offset
 * into the cumulative per-token counter; accounts are settled lazily.
 */
contract StreamingStake {
    struct Holding {
        uint256 balance;
        uint256 offset;
        uint256 owedRewards;
    }

    uint256 private constant MUL = 1e18;

    address public immutable stakingToken;
    address public immutable rewardsToken;
    address public immutable operator;

    uint256 public rewardsPerSecond;
    uint256 public lastSync;
    uint256 public perTokenStored;
    uint256 public supply;

    mapping(address => Holding) private holdings;

    event Staked(address indexed account, uint256 value);
    event Unstaked(address indexed account, uint256 value);
    event Harvested(address indexed account, uint256 value);
    event RateUpdated(uint256 rate);

    constructor(address stakingToken_, address rewardsToken_, uint256 rate_) {
        stakingToken = stakingToken_;
        rewardsToken = rewardsToken_;
        operator = msg.sender;
        rewardsPerSecond = rate_;
        lastSync = block.timestamp;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "operator only");
        _;
    }

    function _syncRewards() internal {
        uint256 nowTs = block.timestamp;
        if (nowTs > lastSync && supply != 0) {
            perTokenStored += ((nowTs - lastSync) * rewardsPerSecond * MUL) / supply;
        }
        lastSync = nowTs;
    }

    // Adds the holder's unsettled share into owedRewards. Callers must
    // re-anchor `offset` after changing `balance`.
    function _accrueHolder(Holding storage h) private {
        h.owedRewards += (h.balance * perTokenStored) / MUL - h.offset;
    }

    function _pullToken(address token, address from, uint256 value) private {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, address(this), value)
        );
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "pull failed");
    }

    function _pushToken(address token, address to, uint256 value) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, value));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "push failed");
    }

    function balanceOf(address account) external view returns (uint256) {
        return holdings[account].balance;
    }

    function earned(address account) external view returns (uint256) {
        Holding storage h = holdings[account];
        uint256 perToken = perTokenStored;
        if (block.timestamp > lastSync && supply != 0) {
            perToken += ((block.timestamp - lastSync) * rewardsPerSecond * MUL) / supply;
        }
        return h.owedRewards + (h.balance * perToken) / MUL - h.offset;
    }

    function stake(uint256 value) external {
        require(value > 0, "zero value");
        _syncRewards();
        Holding storage h = holdings[msg.sender];
        _accrueHolder(h);

        h.balance += value;
        supply += value;
        h.offset = (h.balance * perTokenStored) / MUL;

        _pullToken(stakingToken, msg.sender, value);
        emit Staked(msg.sender, value);
    }

    function unstake(uint256 value) external {
        Holding storage h = holdings[msg.sender];
        require(value > 0 && h.balance >= value, "invalid value");
        _syncRewards();
        _accrueHolder(h);

        h.balance -= value;
        supply -= value;
        h.offset = (h.balance * perTokenStored) / MUL;

        _pushToken(stakingToken, msg.sender, value);
        emit Unstaked(msg.sender, value);
    }

    function harvest() external {
        _syncRewards();
        Holding storage h = holdings[msg.sender];
        _accrueHolder(h);

        uint256 payout = h.owedRewards;
        require(payout > 0, "no rewards");
        h.owedRewards = 0;
        h.offset = (h.balance * perTokenStored) / MUL;

        _pushToken(rewardsToken, msg.sender, payout);
        emit Harvested(msg.sender, payout);
    }

    function setRate(uint256 newRate) external onlyOperator {
        _syncRewards();
        rewardsPerSecond = newRate;
        emit RateUpdated(newRate);
    }
}
