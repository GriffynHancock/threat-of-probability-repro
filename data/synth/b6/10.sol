// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Native-ETH liquid staking. Rewards are pushed in and realised into the pool on the next touch.
contract NativeEthStake {
    uint256 public constant EXIT_WAIT = 1 days;

    struct Request {
        address owner;
        uint256 eth;
        uint256 finalizeAt;
    }

    address public immutable governor;
    uint256 public totalShares;
    uint256 public pooledEth;
    uint256 public pendingRewards;
    uint256 public reservedEth;
    uint256 public nextRequestId = 1;

    mapping(address => uint256) public sharesOf;
    mapping(uint256 => Request) public requests;

    error ZeroValue();
    error InsufficientShares(uint256 have, uint256 want);
    error NotRequestOwner();
    error NotFinal(uint256 finalizeAt);
    error TransferFailed();

    event Staked(address indexed user, uint256 eth, uint256 shares);
    event ExitRequested(address indexed user, uint256 id, uint256 shares, uint256 eth);
    event ExitClaimed(address indexed user, uint256 id, uint256 eth);
    event RewardsDeposited(address indexed from, uint256 amount);

    constructor() {
        governor = msg.sender;
    }

    function depositRewards() external payable {
        if (msg.value == 0) revert ZeroValue();
        pendingRewards += msg.value;
        emit RewardsDeposited(msg.sender, msg.value);
    }

    function _syncPooledEth() internal {
        if (pendingRewards == 0) return;
        pooledEth += pendingRewards;
        pendingRewards = 0;
    }

    function stakeNative() external payable returns (uint256 shares) {
        if (msg.value == 0) revert ZeroValue();
        _syncPooledEth();
        if (totalShares == 0) {
            shares = msg.value;
        } else {
            require(pooledEth > 0, "empty pool");
            shares = (msg.value * totalShares) / pooledEth;
        }
        if (shares == 0) revert ZeroValue();
        sharesOf[msg.sender] += shares;
        totalShares += shares;
        pooledEth += msg.value;
        emit Staked(msg.sender, msg.value, shares);
    }

    function requestWithdrawal(uint256 shares) external returns (uint256 id) {
        if (shares == 0) revert ZeroValue();
        _syncPooledEth();
        uint256 have = sharesOf[msg.sender];
        if (have < shares) revert InsufficientShares(have, shares);
        uint256 eth = (shares * pooledEth) / totalShares;
        sharesOf[msg.sender] -= shares;
        totalShares -= shares;
        pooledEth -= eth;
        reservedEth += eth;
        id = nextRequestId++;
        requests[id] = Request({owner: msg.sender, eth: eth, finalizeAt: block.timestamp + EXIT_WAIT});
        emit ExitRequested(msg.sender, id, shares, eth);
    }

    function claimWithdrawal(uint256 id) external returns (uint256 amount) {
        Request storage r = requests[id];
        if (r.owner != msg.sender) revert NotRequestOwner();
        if (block.timestamp < r.finalizeAt) revert NotFinal(r.finalizeAt);
        amount = r.eth;
        reservedEth -= amount;
        delete requests[id];
        emit ExitClaimed(msg.sender, id, amount);
        (bool ok, ) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
