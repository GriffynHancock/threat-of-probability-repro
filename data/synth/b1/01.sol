// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title SupplyIndexPool
/// @notice Single-asset supply pool. Suppliers earn emissions tracked by a global index
///         that grows with elapsed time, divided across total principal.
contract SupplyIndexPool {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant EMISSION_PER_SECOND = 1e15;

    error ZeroAmount();
    error InsufficientPrincipal(uint256 requested, uint256 available);
    error RewardReserveTooLow(uint256 requested, uint256 available);
    error NotOwner();

    IERC20 public immutable asset;
    address public immutable owner;

    uint256 public emissionIndex = PRECISION;
    uint256 public lastAccrualTime;
    uint256 public totalPrincipal;
    uint256 public rewardReserve;

    struct Account {
        uint256 principal;
        uint256 indexSnapshot;
        uint256 pendingRewards;
    }

    mapping(address => Account) public accounts;

    event Supplied(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RewardsFunded(uint256 amount);
    event IndexAccrued(uint256 newIndex, uint256 elapsed);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IERC20 _asset) {
        asset = _asset;
        owner = msg.sender;
        lastAccrualTime = block.timestamp;
    }

    function fundRewards(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        rewardReserve += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit RewardsFunded(amount);
    }

    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastAccrualTime;
        lastAccrualTime = block.timestamp;
        if (elapsed == 0 || totalPrincipal == 0) return;
        uint256 delta = (EMISSION_PER_SECOND * elapsed * PRECISION) / totalPrincipal;
        emissionIndex += delta;
        emit IndexAccrued(emissionIndex, elapsed);
    }

    function _pending(Account storage a) internal view returns (uint256) {
        return (a.principal * (emissionIndex - a.indexSnapshot)) / PRECISION;
    }

    function supply(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _accrueInterest();
        Account storage a = accounts[msg.sender];
        a.pendingRewards += _pending(a);
        a.indexSnapshot = emissionIndex;
        a.principal += amount;
        totalPrincipal += amount;
        require(asset.transferFrom(msg.sender, address(this), amount), "transferFrom");
        emit Supplied(msg.sender, amount);
    }

    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        _accrueInterest();
        Account storage a = accounts[msg.sender];
        if (a.principal < amount) revert InsufficientPrincipal(amount, a.principal);
        a.pendingRewards += _pending(a);
        a.indexSnapshot = emissionIndex;
        a.principal -= amount;
        totalPrincipal -= amount;
        require(asset.transfer(msg.sender, amount), "transfer");
        emit Withdrawn(msg.sender, amount);
    }

    function claimRewards() external {
        _accrueInterest();
        Account storage a = accounts[msg.sender];
        uint256 owed = a.pendingRewards + _pending(a);
        a.pendingRewards = 0;
        a.indexSnapshot = emissionIndex;
        if (owed > rewardReserve) revert RewardReserveTooLow(owed, rewardReserve);
        rewardReserve -= owed;
        require(asset.transfer(msg.sender, owed), "transfer");
        emit RewardsClaimed(msg.sender, owed);
    }
}
