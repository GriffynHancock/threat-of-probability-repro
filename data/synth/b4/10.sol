// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title DelegatedBalanceRegistry
/// @notice Deposits carry a voting delegate. Yield flows accrue per-second to each depositor and are pulled lazily.
contract DelegatedBalanceRegistry {
    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable token;
    address public immutable steward;

    mapping(address => uint256) public balanceOf;
    mapping(address => address) public delegateOf;
    mapping(address => uint256) public delegatedPower;
    mapping(address => uint256) public flowRate;
    mapping(address => uint256) public flowAccrued;
    mapping(address => uint256) public lastFlowTick;

    event Contributed(address indexed who, uint256 amount, address indexed delegatee);
    event Delegated(address indexed who, address indexed to);
    event FlowRateSet(address indexed who, uint256 rate);
    event Withdrawn(address indexed who, uint256 amount);
    event FlowClaimed(address indexed who, uint256 amount);

    constructor(IERC20 _token) {
        token = _token;
        steward = msg.sender;
    }

    function _delegatee(address who) internal view returns (address) {
        address d = delegateOf[who];
        return d == address(0) ? who : d;
    }

    /// @dev Pulls accrued per-second flows for `who` up to now.
    function _pullDelegatedFlows(address who) internal {
        uint256 last = lastFlowTick[who];
        if (last != 0 && flowRate[who] > 0) {
            flowAccrued[who] += flowRate[who] * (block.timestamp - last);
        }
        lastFlowTick[who] = block.timestamp;
    }

    function setFlowRate(address who, uint256 rate) external {
        require(msg.sender == steward, "not steward");
        _pullDelegatedFlows(who);
        flowRate[who] = rate;
        emit FlowRateSet(who, rate);
    }

    function delegate(address to) external {
        _pullDelegatedFlows(msg.sender);
        uint256 bal = balanceOf[msg.sender];
        address oldTo = _delegatee(msg.sender);
        delegatedPower[oldTo] -= bal;
        delegateOf[msg.sender] = to;
        delegatedPower[_delegatee(msg.sender)] += bal;
        emit Delegated(msg.sender, to);
    }

    /// @notice Deposit balance; voting power is credited to the caller's delegatee.
    function contribute(uint256 amount) external {
        require(amount > 0, "zero amount");
        _pullDelegatedFlows(msg.sender);
        balanceOf[msg.sender] += amount;
        delegatedPower[_delegatee(msg.sender)] += amount;
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit Contributed(msg.sender, amount, _delegatee(msg.sender));
    }

    /// @notice Withdraw part of the deposited balance.
    function withdraw(uint256 amount) external {
        _pullDelegatedFlows(msg.sender);
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        delegatedPower[_delegatee(msg.sender)] -= amount;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Claim accrued flows.
    function claimFlow() external {
        _pullDelegatedFlows(msg.sender);
        uint256 amount = flowAccrued[msg.sender];
        require(amount > 0, "nothing to claim");
        flowAccrued[msg.sender] = 0;
        require(token.transfer(msg.sender, amount), "transfer failed");
        emit FlowClaimed(msg.sender, amount);
    }
}
